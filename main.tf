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

resource "google_compute_network" "this" {
  count = var.network_self_link == null ? 1 : 0

  auto_create_subnetworks = false
  name                    = var.resource_basename
  project                 = local.project
}

resource "google_compute_subnetwork" "this" {
  count = var.subnetwork_self_link == null ? 1 : 0

  ip_cidr_range            = var.subnet_ip_cidr_range
  name                     = "${var.resource_basename}-${var.region}"
  network                  = var.network_self_link != null ? var.network_self_link : google_compute_network.this[0].id
  private_ip_google_access = true
  project                  = local.project
  region                   = var.region
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
  count = var.function_iam_roles == null ? 1 : 0

  description = "Minimum permissions to create VM instances for GitHub Actions runners"
  project     = local.project
  role_id     = local.instance_creator_custom_role_id
  title       = "GitHub Actions Runner VM Creator"

  permissions = [
    "compute.disks.create",
    "compute.instanceTemplates.get",
    "compute.instanceTemplates.list",
    "compute.instanceTemplates.useReadOnly",
    "compute.instances.create",
    "compute.instances.get",
    "compute.instances.setLabels",
    "compute.instances.setMetadata",
    "compute.instances.setServiceAccount",
    "compute.instances.setTags",
    "compute.networks.get",
    "compute.networks.list",
    "compute.subnetworks.get",
    "compute.subnetworks.list",
    "compute.subnetworks.use",
    "compute.subnetworks.useExternalIp"
  ]
}

resource "google_service_account_iam_member" "this" {
  member             = google_service_account.function.member
  role               = "roles/iam.serviceAccountUser"
  service_account_id = google_service_account.instance.name
}

resource "google_compute_instance_template" "this" {
  for_each = local.instance_templates

  machine_type = each.value.machine_type
  name         = "${var.resource_basename}-${each.key}"
  project      = local.project

  disk {
    auto_delete  = true
    boot         = true
    disk_size_gb = var.instance_disk_size
    disk_type    = var.instance_disk_type
    source_image = var.instance_source_image
  }
  network_interface {
    network    = local.network_self_link
    subnetwork = local.subnetwork_self_link

    access_config {
      network_tier = var.instance_access_config_network_tier
    }
  }
  scheduling {
    automatic_restart           = each.value.spot ? false : null
    instance_termination_action = var.instance_max_run_duration_seconds != null || each.value.spot ? "DELETE" : null
    on_host_maintenance         = each.value.spot ? "TERMINATE" : null
    preemptible                 = each.value.spot
    provisioning_model          = each.value.spot ? "SPOT" : "STANDARD"

    dynamic "max_run_duration" {
      for_each = var.instance_max_run_duration_seconds != null ? [1] : []
      content {
        seconds = var.instance_max_run_duration_seconds
      }
    }
  }
  service_account {
    email  = google_service_account.instance.email
    scopes = var.instance_service_account_scopes
  }
  shielded_instance_config {
    enable_integrity_monitoring = var.instance_enable_integrity_monitoring
    enable_secure_boot          = var.instance_enable_secure_boot
    enable_vtpm                 = var.instance_enable_vtpm
  }

  metadata_startup_script = <<-EOT
  #!/bin/bash
  set -euo pipefail
  trap 'shutdown -h now' EXIT

  function get_instance_metadata() {
    curl -sSf -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"
  }
  ENCODED_JIT_CONFIG="$(get_instance_metadata encoded_jit_config)"
  RUNNER_VERSION="$(get_instance_metadata runner_version)"
  useradd -u 1001 -m -s /bin/bash runner
  cd /home/runner
  sudo -u runner curl -sS -o actions-runner.tar.gz -L "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz"
  sudo -u runner tar xzf actions-runner.tar.gz
  sudo -u runner ./run.sh --jitconfig "$ENCODED_JIT_CONFIG"
  EOT
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
  name   = ".terraform/${var.region}/${local.function_name}-${data.archive_file.this.output_sha}.zip"
  source = data.archive_file.this.output_path
}

resource "google_cloudfunctions2_function" "this" {
  location = var.region
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
  project  = local.project
  role     = "roles/run.invoker"
  service  = google_cloudfunctions2_function.this.service_config[0].service
}
