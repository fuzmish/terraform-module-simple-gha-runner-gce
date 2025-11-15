variable "project" {
  type        = string
  nullable    = true
  description = "GCP project ID (null auto-detects from provider)"
  default     = null
}

variable "region" {
  type        = string
  description = "GCP region for webhook function and auto-detection of zones"
}

variable "resource_basename" {
  type        = string
  description = "Base name for all resources (network, subnet, VMs, function, etc.)"
  default     = "gha-runner"
}

variable "network_self_link" {
  type        = string
  nullable    = true
  description = "Existing VPC network self_link to reuse (null creates a new network)"
  default     = null
}

variable "subnet_ip_cidr_range" {
  type        = string
  description = "CIDR range for the subnet"
  default     = "10.0.0.0/24"
}

variable "subnetwork_self_link" {
  type        = string
  nullable    = true
  description = "Existing subnet self_link to reuse (null creates a new subnet)"
  default     = null
}

variable "instance_zones" {
  type        = list(string)
  nullable    = true
  description = "Zones for VM placement (null auto-detects all available zones in region)"
  default     = null
}

variable "instance_name_prefix" {
  type        = string
  description = "Prefix for VM instance names created from webhook"
  default     = "gha-runner"
}

variable "instance_service_account_scopes" {
  type        = list(string)
  description = "OAuth scopes for runner VM service account"
  default     = ["https://www.googleapis.com/auth/cloud-platform"]
}

variable "instance_templates" {
  type = map(object({
    labels                      = list(string)
    machine_type                = string
    spot                        = optional(bool, false)
    zones                       = optional(list(string))
    group_id                    = optional(number, 1)
    startup_script              = optional(string)
    source_image                = optional(string, "projects/debian-cloud/global/images/family/debian-12")
    disk_type                   = optional(string, "pd-standard")
    disk_size                   = optional(number, 10)
    access_config_network_tier  = optional(string, "STANDARD")
    max_run_duration_seconds    = optional(number, 600)
    enable_integrity_monitoring = optional(bool, true)
    enable_secure_boot          = optional(bool, true)
    enable_vtpm                 = optional(bool, true)
  }))
  description = "VM template configurations with individual settings per template"
  default = {
    default = {
      labels       = ["default"]
      machine_type = "t2d-standard-1"
      spot         = true
    }
  }
}

variable "function_available_cpu" {
  type        = string
  description = "CPU allocation for webhook function"
  default     = ".333"
}

variable "function_available_memory" {
  type        = string
  description = "Memory allocation for webhook function"
  default     = "512Mi"
}

variable "function_timeout_seconds" {
  type        = number
  description = "Timeout for webhook function invocation"
  default     = 300
}

variable "function_max_instance_count" {
  type        = number
  description = "Maximum concurrent instances for webhook function"
  default     = 5
}

variable "function_storage_bucket" {
  type        = string
  nullable    = true
  description = "GCS bucket for webhook function code (null uses <project_id>_cloudbuild). Ensure that the bucket is already created."
  default     = null
}

variable "function_build_service_account_id" {
  type        = string
  nullable    = true
  description = "Service account ID for Cloud Function build (null uses default service account)"
  default     = null
}

variable "function_log_level" {
  type        = string
  description = "Log level for webhook function (DEBUG, INFO, WARNING, ERROR)"
  default     = "INFO"
}

variable "instance_creator_custom_role_id" {
  type        = string
  nullable    = true
  description = "Custom IAM role ID for webhook to create runner VMs"
  default     = null
}

variable "instance_creator_custom_role_permissions" {
  type        = list(string)
  description = "Permissions for custom IAM role for webhook to create runner VMs"
  default = [
    "compute.disks.create",
    "compute.images.useReadOnly",
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

variable "instance_iam_roles" {
  type        = list(string)
  nullable    = true
  description = "IAM roles for runner VM service account (null uses defaults: logging.logWriter, monitoring.metricWriter)"
  default     = null
}

variable "function_iam_roles" {
  type        = list(string)
  nullable    = true
  description = "IAM roles for webhook function service account (null uses defaults: logging.logWriter + custom role)"
  default     = null
}

variable "runner_scope" {
  type        = string
  description = "GitHub Actions runner registration scope: 'repository' or 'organization'"
  default     = "repository"

  validation {
    condition     = contains(["repository", "organization"], var.runner_scope)
    error_message = "runner_scope must be 'repository' or 'organization'."
  }
}

variable "runner_version" {
  type        = string
  description = "GitHub Actions runner version to install on VMs (must support JIT config, v2.303.0 or later)"
  default     = "2.329.0"
}
