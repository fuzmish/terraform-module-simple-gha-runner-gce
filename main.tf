terraform {
  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = ">=2.0"
    }
    google = {
      source  = "hashicorp/google"
      version = ">= 7.0"
    }
  }
}

resource "google_service_account" "instance" {
  account_id   = "${var.resource_basename}-instance"
  display_name = "${var.resource_basename}-instance"
  project      = local.project
}

resource "google_service_account" "function" {
  account_id   = "${var.resource_basename}-function"
  display_name = "${var.resource_basename}-function"
  project      = local.project
}

resource "google_project_iam_member" "this" {
  for_each = local.iam_members

  member  = each.value.member
  project = local.project
  role    = each.value.role
}

resource "google_project_iam_custom_role" "this" {
  count = var.instance_creator_custom_role_id != null ? 1 : 0

  description = "Minimum permissions to create VM instances for GitHub Actions runners"
  permissions = var.instance_creator_custom_role_permissions
  project     = local.project
  role_id     = var.instance_creator_custom_role_id
  title       = "GitHub Actions Runner VM Creator"
}

resource "google_service_account_iam_member" "this" {
  member             = google_service_account.function.member
  role               = "roles/iam.serviceAccountUser"
  service_account_id = google_service_account.instance.name
}

resource "google_compute_instance_template" "this" {
  for_each = var.instance_templates

  machine_type            = each.value.machine_type
  metadata_startup_script = coalesce(each.value.startup_script, replace(local.default_startup_script, "$RUNNER_VERSION", each.value.runner_version))
  name                    = "${var.resource_basename}-${each.key}"
  project                 = local.project

  disk {
    auto_delete  = true
    boot         = true
    disk_size_gb = each.value.disk_size
    disk_type    = each.value.disk_type
    source_image = each.value.source_image
  }
  network_interface {
    subnetwork = each.value.subnetwork

    access_config {
      network_tier = each.value.access_config_network_tier
    }
  }
  scheduling {
    automatic_restart           = each.value.spot ? false : null
    instance_termination_action = each.value.max_run_duration_seconds != null || each.value.spot ? "DELETE" : null
    on_host_maintenance         = each.value.spot ? "TERMINATE" : null
    preemptible                 = each.value.spot
    provisioning_model          = each.value.spot ? "SPOT" : "STANDARD"

    dynamic "max_run_duration" {
      for_each = each.value.max_run_duration_seconds != null ? [1] : []
      content {
        seconds = each.value.max_run_duration_seconds
      }
    }
  }
  service_account {
    email  = google_service_account.instance.email
    scopes = var.instance_service_account_scopes
  }
  shielded_instance_config {
    enable_integrity_monitoring = each.value.enable_integrity_monitoring
    enable_secure_boot          = each.value.enable_secure_boot
    enable_vtpm                 = each.value.enable_vtpm
  }
}

resource "google_secret_manager_secret" "this" {
  project   = local.project
  secret_id = "${var.resource_basename}-credentials"

  replication {
    auto {
    }
  }
}

resource "google_secret_manager_secret_iam_member" "this" {
  member    = google_service_account.function.member
  role      = "roles/secretmanager.secretAccessor"
  secret_id = google_secret_manager_secret.this.id
}

resource "google_storage_bucket_object" "this" {
  bucket = data.google_storage_bucket.this.name
  name   = ".terraform/${var.function_location}/${local.function_name}-${data.archive_file.this.output_sha}.zip"
  source = data.archive_file.this.output_path
}

resource "google_cloudfunctions2_function" "this" {
  location = var.function_location
  name     = local.function_name
  project  = local.project

  build_config {
    entry_point     = "main"
    runtime         = "python313"
    service_account = var.function_build_service_account_id

    source {
      storage_source {
        bucket = google_storage_bucket_object.this.bucket
        object = google_storage_bucket_object.this.name
      }
    }
  }
  service_config {
    available_cpu         = var.function_available_cpu
    available_memory      = var.function_available_memory
    environment_variables = local.function_environment_variables
    ingress_settings      = "ALLOW_ALL"
    max_instance_count    = var.function_max_instance_count
    min_instance_count    = 0
    service_account_email = google_service_account.function.email
    timeout_seconds       = var.function_timeout_seconds
  }
}

resource "google_cloud_run_service_iam_member" "this" {
  location = google_cloudfunctions2_function.this.location
  member   = "allUsers"
  project  = google_cloudfunctions2_function.this.project
  role     = "roles/run.invoker"
  service  = google_cloudfunctions2_function.this.service_config[0].service
}
