output "instance_service_account" {
  value = {
    email  = google_service_account.instance.email
    member = google_service_account.instance.member
  }
  description = "Runner service account"
}

output "function_service_account" {
  value = {
    email  = google_service_account.function.email
    member = google_service_account.function.member
  }
  description = "Webhook service account"
}

output "webhook_url" {
  value       = google_cloudfunctions2_function.this.service_config[0].uri
  description = "Webhook Cloud Function URL"
}

output "credentials_secret_id" {
  value       = google_secret_manager_secret.this.secret_id
  description = "Secret Manager secret ID to store GitHub App credentials"
}
