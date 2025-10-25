data "google_client_config" "current" {
}

data "google_compute_zones" "available" {
  project = local.project
  region  = var.region
}

data "google_storage_bucket" "this" {
  name    = local.function_storage_bucket
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
