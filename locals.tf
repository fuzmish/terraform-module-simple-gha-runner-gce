locals {
  project = data.google_project.project.project_id

  default_startup_script = <<-EOT
  #!/bin/bash
  set -euo pipefail
  trap 'shutdown -h now' EXIT
  JIT_CONFIG=$(curl -fsS -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/jit-config')
  if [ "$(dpkg --print-architecture)" = "amd64" ]; then
    RUNNER_ARCH="x64"
  else
    RUNNER_ARCH="arm64"
  fi
  useradd -m -s /bin/bash runner
  cd /home/runner
  sudo -u runner curl -sSL --fail-with-body -o actions-runner.tar.gz "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-$RUNNER_ARCH-$RUNNER_VERSION.tar.gz"
  sudo -u runner tar xzf actions-runner.tar.gz
  sudo -u runner ./run.sh --jitconfig "$JIT_CONFIG"
  EOT

  function_name = coalesce(var.function_name, "${var.resource_basename}-webhook")
  function_environment_variables = {
    CONFIG_SECRET_ID     = google_secret_manager_secret.this.secret_id
    INSTANCE_NAME_PREFIX = var.instance_name_prefix
    INSTANCE_TEMPLATES = jsonencode([
      for key, template in var.instance_templates : {
        group_id      = template.group_id
        labels        = template.labels
        template_name = google_compute_instance_template.this[key].name
        zones         = coalesce(template.zones, data.google_compute_zones.available[key].names)
      }
    ])
    LOG_LEVEL    = var.function_log_level
    RUNNER_SCOPE = var.runner_scope
    PROJECT      = local.project
  }

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
    var.instance_creator_custom_role_id != null ? {
      "function/roles/${var.instance_creator_custom_role_id}" = {
        role   = google_project_iam_custom_role.this[0].id
        member = google_service_account.function.member
      }
    } : {}
  )
}
