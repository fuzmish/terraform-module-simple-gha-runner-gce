# terraform-module-simple-gha-runner-gce

Simple zero-scale self-hosted GitHub Actions runner infrastructure using Google Compute Engine.

Supports runner registration at **repository** or **organization** scope via GitHub App webhooks.

## Architecture Overview

```
GitHub (Repository / Organization)
    │ GitHub App Webhook (workflow_job.queued)
    ▼
Webhook Function (Cloud Run Function)
    │ • Verify webhook signature
    │ • Authenticate with GitHub App
    │ • Register JIT runner at configured scope
    │ • Create Runner VM
    ▼
VM Instance (Compute Engine)
    │ • Download GitHub Actions Runner
    │ • Run job
    │ • Auto-shutdown after completion
```

## Webhook Support

This module supports **GitHub App webhooks only**. The webhook endpoint:
- Receives `workflow_job.queued` events from GitHub
- Extracts `installation_id` from the webhook payload (not from secret)
- Registers runners at the scope specified by `runner_scope` variable
- Supports multiple installations dynamically

## Quick Start

### 1. Deploy infrastructure

Create a module call in your Terraform configuration:

```terraform
module "gce_gha_runner" {
  source = "github.com/fuzmish/terraform-module-simple-gha-runner-gce?ref=REVISION"

  region            = "us-central1"
  resource_basename = "gha-runner"
  runner_scope      = "repository"  # or "organization"

  instance_templates = {
    default = {
      labels       = ["default"]
      machine_type = "t2d-standard-1"
      spot         = true
    }
  }
}

output "gha_runner_webhook_url" {
  value = module.gce_gha_runner.webhook_url
}

output "gha_runner_credentials_secret_id" {
  value = module.gce_gha_runner.credentials_secret_id
}
```

Apply the configuration:

```bash
terraform apply
```

After applying, save the outputs:
- `gha_runner_webhook_url`: Use this when creating the GitHub App webhook
- `gha_runner_credentials_secret_id`: The Secret Manager secret where credentials will be stored

> **Note:** GitHub assigns the `self-hosted` label automatically. Workflows must request **all** custom labels defined in a template (in addition to `self-hosted`) to target that template. The module enforces the same behavior when selecting instance templates.

### 2. Create GitHub App

1. Go to https://github.com/settings/apps/new
2. Configure:
   - **GitHub App name**: Arbitrary name
   - **Homepage URL**: Arbitrary URL
   - **Webhook**:
     - ✓ Active
     - **URL**: Use the `gha_runner_webhook_url` from step 1
     - **Secret**: Generate a random string (used for signature verification)
   - **Permissions** (scope-specific):
     - **All scopes**: Repository permission **Administration – Read & write**
     - **Repository scope only**: Repository permission **Administration – Read & write**
     - **Organization scope only**: Organization permission **Self-hosted runners – Read & write**
  - **Subscribe to events**:
     - ✓ Workflow job
3. After creating the app:
   - Note the **App ID**.
   - Install the app to your repository or organization.
   - Generate and download **private key** file.

### 3. Store credentials in secret manager

Create a JSON configuration file with your GitHub App credentials:

```bash
cat > config.json << 'EOF'
{
  "app_id": YOUR_APP_ID,
  "app_private_key": "-----BEGIN RSA PRIVATE KEY-----\nKEY_CONTENT\n-----END RSA PRIVATE KEY-----",
  "webhook_secret": "YOUR_WEBHOOK_SECRET"
}
EOF
```

Store in the Secret Manager secret created by the module:

```bash
gcloud secrets versions add SECRET_NAME --data-file=config.json
```

Where `SECRET_NAME` is the `gha_runner_credentials_secret_id` output from step 1.

#### Required Secret Fields

| Field | Source | Purpose |
|-------|--------|---------|
| `app_id` | GitHub App settings | JWT issuer for access token generation |
| `app_private_key` | GitHub App private key | JWT signing for access token generation |
| `webhook_secret` | Webhook configuration | HMAC signature verification (X-Hub-Signature-256) |

### 4. Run a workflow

Create a workflow in your repository:

```yaml
# .github/workflows/example.yml
name: Example
on:
  workflow_dispatch:

jobs:
  test:
    runs-on:
      # group: YOUR_GROUP # if needed
      labels: [self-hosted, default]
    steps:
      - uses: actions/checkout@v4
      - run: echo "Running on self-hosted runner!"
```

Then, trigger it!

## Configuration Notes

- **Existing network/subnet reuse:** Set `network_self_link` and `subnetwork_self_link` when you want to deploy into an existing VPC. When left `null`, the module creates a dedicated network and subnet.
- **Function source bucket:** If you supply `function_storage_bucket`, ensure the bucket already exists. The default (`<project_id>_cloudbuild`) expects the Cloud Build bucket provisioned by Google Cloud.
- **Runner max runtime:** The value of `instance_max_run_duration_seconds` is the hard limit of the runner's runtime (600 seconds by default). Increase it (or set to `null`) when workflows may run longer; otherwise the VM is terminated at the configured limit.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_archive"></a> [archive](#requirement\_archive) | >=2.0 |
| <a name="requirement_google"></a> [google](#requirement\_google) | >= 7.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_archive"></a> [archive](#provider\_archive) | >=2.0 |
| <a name="provider_google"></a> [google](#provider\_google) | >= 7.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [google_cloud_run_service_iam_member.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/cloud_run_service_iam_member) | resource |
| [google_cloudfunctions2_function.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/cloudfunctions2_function) | resource |
| [google_compute_instance_template.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_instance_template) | resource |
| [google_compute_network.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_network) | resource |
| [google_compute_subnetwork.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_subnetwork) | resource |
| [google_project_iam_custom_role.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_custom_role) | resource |
| [google_project_iam_member.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_secret_manager_secret.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret) | resource |
| [google_secret_manager_secret_iam_member.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_iam_member) | resource |
| [google_service_account.function](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account.instance](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account_iam_member.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_storage_bucket_object.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket_object) | resource |
| [archive_file.this](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [google_client_config.current](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/client_config) | data source |
| [google_compute_zones.available](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/compute_zones) | data source |
| [google_storage_bucket.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/storage_bucket) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_function_available_cpu"></a> [function\_available\_cpu](#input\_function\_available\_cpu) | CPU allocation for webhook function | `string` | `".333"` | no |
| <a name="input_function_available_memory"></a> [function\_available\_memory](#input\_function\_available\_memory) | Memory allocation for webhook function | `string` | `"512Mi"` | no |
| <a name="input_function_build_service_account_id"></a> [function\_build\_service\_account\_id](#input\_function\_build\_service\_account\_id) | Service account ID for Cloud Function build (null uses default service account) | `string` | `null` | no |
| <a name="input_function_iam_roles"></a> [function\_iam\_roles](#input\_function\_iam\_roles) | IAM roles for webhook function service account (null uses defaults: logging.logWriter + custom role) | `list(string)` | `null` | no |
| <a name="input_function_log_level"></a> [function\_log\_level](#input\_function\_log\_level) | Log level for webhook function (DEBUG, INFO, WARNING, ERROR) | `string` | `"INFO"` | no |
| <a name="input_function_max_instance_count"></a> [function\_max\_instance\_count](#input\_function\_max\_instance\_count) | Maximum concurrent instances for webhook function | `number` | `5` | no |
| <a name="input_function_storage_bucket"></a> [function\_storage\_bucket](#input\_function\_storage\_bucket) | GCS bucket for webhook function code (null uses <project\_id>\_cloudbuild). Ensure that the bucket is already created. | `string` | `null` | no |
| <a name="input_function_timeout_seconds"></a> [function\_timeout\_seconds](#input\_function\_timeout\_seconds) | Timeout for webhook function invocation | `number` | `300` | no |
| <a name="input_instance_creator_custom_role_id"></a> [instance\_creator\_custom\_role\_id](#input\_instance\_creator\_custom\_role\_id) | Custom IAM role ID for webhook to create runner VMs | `string` | `null` | no |
| <a name="input_instance_creator_custom_role_permissions"></a> [instance\_creator\_custom\_role\_permissions](#input\_instance\_creator\_custom\_role\_permissions) | Permissions for custom IAM role for webhook to create runner VMs | `list(string)` | <pre>[<br/>  "compute.disks.create",<br/>  "compute.images.useReadOnly",<br/>  "compute.instanceTemplates.get",<br/>  "compute.instanceTemplates.list",<br/>  "compute.instanceTemplates.useReadOnly",<br/>  "compute.instances.create",<br/>  "compute.instances.get",<br/>  "compute.instances.setLabels",<br/>  "compute.instances.setMetadata",<br/>  "compute.instances.setServiceAccount",<br/>  "compute.instances.setTags",<br/>  "compute.networks.get",<br/>  "compute.networks.list",<br/>  "compute.subnetworks.get",<br/>  "compute.subnetworks.list",<br/>  "compute.subnetworks.use",<br/>  "compute.subnetworks.useExternalIp"<br/>]</pre> | no |
| <a name="input_instance_iam_roles"></a> [instance\_iam\_roles](#input\_instance\_iam\_roles) | IAM roles for runner VM service account (null uses defaults: logging.logWriter, monitoring.metricWriter) | `list(string)` | `null` | no |
| <a name="input_instance_name_prefix"></a> [instance\_name\_prefix](#input\_instance\_name\_prefix) | Prefix for VM instance names created from webhook | `string` | `"gha-runner"` | no |
| <a name="input_instance_service_account_scopes"></a> [instance\_service\_account\_scopes](#input\_instance\_service\_account\_scopes) | OAuth scopes for runner VM service account | `list(string)` | <pre>[<br/>  "https://www.googleapis.com/auth/cloud-platform"<br/>]</pre> | no |
| <a name="input_instance_templates"></a> [instance\_templates](#input\_instance\_templates) | VM template configurations with individual settings per template | <pre>map(object({<br/>    labels                      = list(string)<br/>    machine_type                = string<br/>    spot                        = optional(bool, false)<br/>    zones                       = optional(list(string))<br/>    group_id                    = optional(number, 1)<br/>    startup_script              = optional(string)<br/>    source_image                = optional(string, "projects/debian-cloud/global/images/family/debian-12")<br/>    disk_type                   = optional(string, "pd-standard")<br/>    disk_size                   = optional(number, 10)<br/>    access_config_network_tier  = optional(string, "STANDARD")<br/>    max_run_duration_seconds    = optional(number, 600)<br/>    enable_integrity_monitoring = optional(bool, true)<br/>    enable_secure_boot          = optional(bool, true)<br/>    enable_vtpm                 = optional(bool, true)<br/>  }))</pre> | <pre>{<br/>  "default": {<br/>    "labels": [<br/>      "default"<br/>    ],<br/>    "machine_type": "t2d-standard-1",<br/>    "spot": true<br/>  }<br/>}</pre> | no |
| <a name="input_instance_zones"></a> [instance\_zones](#input\_instance\_zones) | Zones for VM placement (null auto-detects all available zones in region) | `list(string)` | `null` | no |
| <a name="input_network_self_link"></a> [network\_self\_link](#input\_network\_self\_link) | Existing VPC network self\_link to reuse (null creates a new network) | `string` | `null` | no |
| <a name="input_project"></a> [project](#input\_project) | GCP project ID (null auto-detects from provider) | `string` | `null` | no |
| <a name="input_region"></a> [region](#input\_region) | GCP region for webhook function and auto-detection of zones | `string` | n/a | yes |
| <a name="input_resource_basename"></a> [resource\_basename](#input\_resource\_basename) | Base name for all resources (network, subnet, VMs, function, etc.) | `string` | `"gha-runner"` | no |
| <a name="input_runner_scope"></a> [runner\_scope](#input\_runner\_scope) | GitHub Actions runner registration scope: 'repository' or 'organization' | `string` | `"repository"` | no |
| <a name="input_runner_version"></a> [runner\_version](#input\_runner\_version) | GitHub Actions runner version to install on VMs (must support JIT config, v2.303.0 or later) | `string` | `"2.329.0"` | no |
| <a name="input_subnet_ip_cidr_range"></a> [subnet\_ip\_cidr\_range](#input\_subnet\_ip\_cidr\_range) | CIDR range for the subnet | `string` | `"10.0.0.0/24"` | no |
| <a name="input_subnetwork_self_link"></a> [subnetwork\_self\_link](#input\_subnetwork\_self\_link) | Existing subnet self\_link to reuse (null creates a new subnet) | `string` | `null` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_credentials_secret_id"></a> [credentials\_secret\_id](#output\_credentials\_secret\_id) | Secret Manager secret ID to store GitHub App credentials |
| <a name="output_function_service_account"></a> [function\_service\_account](#output\_function\_service\_account) | Webhook service account |
| <a name="output_instance_service_account"></a> [instance\_service\_account](#output\_instance\_service\_account) | Runner service account |
| <a name="output_network_id"></a> [network\_id](#output\_network\_id) | VPC network ID |
| <a name="output_subnet_id"></a> [subnet\_id](#output\_subnet\_id) | Subnet ID |
| <a name="output_webhook_url"></a> [webhook\_url](#output\_webhook\_url) | Webhook Cloud Function URL |
<!-- END_TF_DOCS -->
