data "google_project" "project" {
  project_id = var.project
}

data "google_compute_zones" "available" {
  for_each = var.instance_templates

  project = local.project
  region  = split("/", each.value.subnetwork)[3] # projects/PROJECT_ID/regions/REGION/subnetworks/SUBNETWORK
  status  = "UP"
}

data "google_storage_bucket" "this" {
  name    = coalesce(var.function_storage_bucket, "${local.project}_cloudbuild")
  project = local.project
}

data "archive_file" "this" {
  output_path = "${path.module}/src.zip"
  type        = "zip"

  source {
    content  = file("${path.module}/src/main.py")
    filename = "main.py"
  }
  source {
    content  = file("${path.module}/src/requirements.txt")
    filename = "requirements.txt"
  }
}
