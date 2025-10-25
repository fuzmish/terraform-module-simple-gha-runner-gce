import hashlib
import hmac
import json
import logging
import os
import time
from urllib.parse import urlparse

import functions_framework
import jwt
import requests
from flask import Request
from google.cloud import compute_v1beta
from google.cloud.logging.handlers import StructuredLogHandler, setup_logging
from google.cloud.secretmanager import SecretManagerServiceClient

# Configure logging
LOG_LEVEL = getattr(logging, os.environ.get("LOG_LEVEL", "INFO"))
if "K_SERVICE" in os.environ:
    setup_logging(handler=StructuredLogHandler(), log_level=LOG_LEVEL)
else:
    logging.basicConfig(level=LOG_LEVEL)

logger = logging.getLogger(__name__)


def get_config_secret(project_id: str, secret_id: str, version: str = "latest") -> dict:
    client = SecretManagerServiceClient()
    name = client.secret_version_path(project_id, secret_id, version)
    response = client.access_secret_version(name=name)
    return json.loads(response.payload.data.decode("utf-8"))


def verify_webhook_signature(request: Request, webhook_secret: str) -> None:
    if not webhook_secret:
        raise ValueError("Webhook secret not found")
    expected_signature = (
        "sha256="
        + hmac.new(
            webhook_secret.encode("utf-8"), request.get_data(), hashlib.sha256
        ).hexdigest()
    )
    signature = request.headers.get("X-Hub-Signature-256")
    if not signature or not hmac.compare_digest(signature, expected_signature):
        raise ValueError("Webhook signature verification failed")


def generate_jit_config(
    app_id: str,
    app_private_key: str,
    request_payload: dict,
    runner_group_id: int,
    runner_labels: list[str],
    runner_name: str,
    runner_scope: str,
) -> str:
    # Extract fields from payload
    installation_id = request_payload["installation"]["id"]
    if not installation_id:
        raise ValueError("installation.id not found in payload")
    if runner_scope == "repository":
        resource_url = request_payload["repository"]["url"]
    elif runner_scope == "organization":
        resource_url = request_payload["organization"]["url"]
    else:
        raise ValueError("Invalid runner scope. Use 'repository' or 'organization'.")

    parsed_resource_url = urlparse(resource_url)
    api_base_url = f"{parsed_resource_url.scheme}://{parsed_resource_url.netloc}"

    # Generate JWT and get installation token
    now = int(time.time())
    app_jwt = jwt.encode(
        {
            "iat": now - 60,
            "exp": now + 60,
            "iss": app_id,
        },
        app_private_key,
        algorithm="RS256",
    )
    res_token = requests.post(
        f"{api_base_url}/app/installations/{installation_id}/access_tokens",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {app_jwt}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        timeout=30,
    )
    res_token.raise_for_status()
    installation_token = res_token.json()["token"]

    # Request JIT config
    res = requests.post(
        f"{resource_url}/actions/runners/generate-jitconfig",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {installation_token}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        json={
            "labels": runner_labels,
            "name": runner_name,
            "runner_group_id": runner_group_id,
        },
        timeout=30,
    )
    res.raise_for_status()
    return res.json()["encoded_jit_config"]


def create_runner(
    encoded_jit_config: str,
    instance_name: str,
    instance_template_name: str,
    instance_zones: list[str],
    runner_version: str,
    project: str,
) -> None:
    instances_client = compute_v1beta.InstancesClient()
    template_client = compute_v1beta.InstanceTemplatesClient()
    logger.info(f"Creating VM {instance_name} from template {instance_template_name}")

    instance_template = template_client.get(
        project=project,
        instance_template=instance_template_name,
    )

    metadata = compute_v1beta.Metadata()
    metadata.items = [
        *(instance_template.properties.metadata.items or []),
        compute_v1beta.Items(key="encoded_jit_config", value=encoded_jit_config),
        compute_v1beta.Items(key="runner_version", value=runner_version),
    ]

    instance = compute_v1beta.Instance()
    instance.name = instance_name
    instance.metadata = metadata

    insert_request = compute_v1beta.InsertInstanceRequest()
    insert_request.project = project
    insert_request.source_instance_template = instance_template.self_link
    insert_request.instance_resource = instance

    for zone in instance_zones:
        try:
            insert_request.zone = zone
            instances_client.insert(insert_request).result()
            logger.info(f"VM {instance_name} created successfully in {zone}")
            return
        except Exception as e:
            logger.warning(f"Failed to create VM in {zone}: {e}")
            continue

    raise ValueError(f"Failed to create VM from template {instance_template_name}")


@functions_framework.http
def main(request: Request):
    # Load environment variables
    CONFIG_SECRET_ID = os.environ["CONFIG_SECRET_ID"]
    INSTANCE_NAME_PREFIX = os.environ["INSTANCE_NAME_PREFIX"]
    INSTANCE_TEMPLATES = json.loads(os.environ["INSTANCE_TEMPLATES"])
    PROJECT = os.environ["PROJECT"]
    RUNNER_SCOPE = os.environ["RUNNER_SCOPE"]
    RUNNER_VERSION = os.environ["RUNNER_VERSION"]

    # Load GitHub App credentials from Secret Manager
    config = get_config_secret(PROJECT, CONFIG_SECRET_ID)

    # Verify webhook signature
    verify_webhook_signature(request, config["webhook_secret"])

    # Parse event
    event = request.headers["X-GitHub-Event"]
    if event == "ping":
        logger.info("Received ping event")
        return "OK"
    if event != "workflow_job":
        logger.info(f"Ignoring event: {event}")
        return "OK"
    payload = request.get_json()
    event_action = payload.get("action")
    if event_action != "queued":
        logger.info(f"Ignoring event: {event} with action: {event_action}")
        return "OK"
    logger.debug(f"webhook event payload: {json.dumps(payload, indent=2)}")

    # Extract job details
    job_id = payload["workflow_job"]["id"]
    logger.info(f"Job triggered: job_id={job_id}")
    job_labels = set(
        label for label in payload["workflow_job"]["labels"] if label != "self-hosted"
    )
    logger.info(f"Job labels: {job_labels}")

    # Select template based on labels
    instance_name = f"{INSTANCE_NAME_PREFIX}-{job_id}"
    templates = []
    for template in INSTANCE_TEMPLATES:
        if job_labels.issubset(template["labels"]):
            templates.append(template)
    if len(templates) == 0:
        raise ValueError(f"No matching template for labels: {job_labels}")

    for template in templates:
        try:
            # Generate JIT config and create runner
            encoded_jit_config = generate_jit_config(
                app_id=config["app_id"],
                app_private_key=config["app_private_key"],
                request_payload=payload,
                runner_group_id=template["group_id"],
                runner_labels=template["labels"],
                runner_name=instance_name,
                runner_scope=RUNNER_SCOPE,
            )
            create_runner(
                encoded_jit_config=encoded_jit_config,
                instance_name=instance_name,
                instance_template_name=template["template_name"],
                instance_zones=template["zones"],
                project=PROJECT,
                runner_version=RUNNER_VERSION,
            )
            return "OK"
        except Exception as e:
            logger.warning(f"Failed to create VM: {e}, try next template")

    logger.error("Failed to create VM")
    return "OK"
