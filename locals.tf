locals {
  project        = var.project != null ? var.project : data.google_client_config.current.project
  instance_zones = var.instance_zones != null ? var.instance_zones : data.google_compute_zones.available.names

  network_self_link    = var.network_self_link != null ? var.network_self_link : google_compute_network.this[0].self_link
  subnetwork_self_link = var.subnetwork_self_link != null ? var.subnetwork_self_link : google_compute_subnetwork.this[0].self_link
  network_id           = var.network_self_link != null ? var.network_self_link : google_compute_network.this[0].id
  subnetwork_id        = var.subnetwork_self_link != null ? var.subnetwork_self_link : google_compute_subnetwork.this[0].id

  instance_templates = {
    for template in var.instance_templates :
    substr(sha1(jsonencode(template)), 0, 7) => template
  }

  function_storage_bucket = var.function_storage_bucket != null ? var.function_storage_bucket : "${local.project}_cloudbuild"
  function_name           = "${var.resource_basename}-webhook"
  function_environment_variables = {
    CONFIG_SECRET_ID     = google_secret_manager_secret.this.secret_id
    INSTANCE_NAME_PREFIX = var.instance_name_prefix
    INSTANCE_TEMPLATES = jsonencode([
      for key, template in local.instance_templates : {
        group_id      = template.group_id
        labels        = template.labels
        template_name = google_compute_instance_template.this[key].name
        zones         = template.zones != null ? template.zones : local.instance_zones
      }
    ])
    LOG_LEVEL      = var.function_log_level
    RUNNER_SCOPE   = var.runner_scope
    RUNNER_VERSION = var.runner_version
    PROJECT        = local.project
  }

  instance_creator_custom_role_id = coalesce(var.instance_creator_custom_role_id, "compute.${replace(var.resource_basename, "-", "")}Creator")
  instance_iam_roles = var.instance_iam_roles != null ? var.instance_iam_roles : [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter"
  ]
  function_iam_roles = var.function_iam_roles != null ? var.function_iam_roles : [
    "roles/logging.logWriter"
  ]
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
