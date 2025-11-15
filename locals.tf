locals {
  project        = coalesce(var.project, data.google_client_config.current.project)
  instance_zones = coalesce(var.instance_zones, data.google_compute_zones.available.names)

  network_self_link    = coalesce(var.network_self_link, google_compute_network.this[0].self_link)
  subnetwork_self_link = coalesce(var.subnetwork_self_link, google_compute_subnetwork.this[0].self_link)
  network_id           = coalesce(var.network_self_link, google_compute_network.this[0].id)
  subnetwork_id        = coalesce(var.subnetwork_self_link, google_compute_subnetwork.this[0].id)

  default_startup_script  = <<-EOT
  #!/bin/bash
  set -euo pipefail
  trap 'shutdown -h now' EXIT

  function get_instance_metadata() {
    curl -sSf -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"
  }
  ENCODED_JIT_CONFIG="$(get_instance_metadata encoded_jit_config)"
  RUNNER_VERSION="$(get_instance_metadata runner_version)"
  useradd -m -s /bin/bash runner
  cd /home/runner
  sudo -u runner curl -sS -o actions-runner.tar.gz -L "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz"
  sudo -u runner tar xzf actions-runner.tar.gz
  sudo -u runner ./run.sh --jitconfig "$ENCODED_JIT_CONFIG"
  EOT

  instance_templates = {
    for template in var.instance_templates :
    substr(sha1(jsonencode(template)), 0, 7) => merge(template, {
      startup_script = coalesce(template.startup_script, local.default_startup_script)
    })
  }

  function_storage_bucket = coalesce(var.function_storage_bucket, "${local.project}_cloudbuild")
  function_name           = "${var.resource_basename}-webhook"
  function_environment_variables = {
    CONFIG_SECRET_ID     = google_secret_manager_secret.this.secret_id
    INSTANCE_NAME_PREFIX = var.instance_name_prefix
    INSTANCE_TEMPLATES = jsonencode([
      for key, template in local.instance_templates : {
        group_id      = template.group_id
        labels        = template.labels
        template_name = google_compute_instance_template.this[key].name
        zones         = coalesce(template.zones, local.instance_zones)
      }
    ])
    LOG_LEVEL      = var.function_log_level
    RUNNER_SCOPE   = var.runner_scope
    RUNNER_VERSION = var.runner_version
    PROJECT        = local.project
  }

  instance_creator_custom_role_id = coalesce(var.instance_creator_custom_role_id, "compute.${replace(var.resource_basename, "-", "")}Creator")
  instance_iam_roles = coalesce(var.instance_iam_roles, [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter"
  ])
  function_iam_roles = coalesce(var.function_iam_roles, [
    "roles/logging.logWriter"
  ])
  iam_members = merge(
    { for role in local.instance_iam_roles : "instance/${role}" => {
      role   = role
      member = google_service_account.instance.member
    } },
    { for role in local.function_iam_roles : "function/${role}" => {
      role   = role
      member = google_service_account.function.member
    } },
    var.function_iam_roles == null ? {
      "function/roles/${local.instance_creator_custom_role_id}" = {
        role   = google_project_iam_custom_role.this[0].id
        member = google_service_account.function.member
      }
    } : {}
  )
}
