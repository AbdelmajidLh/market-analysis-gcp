output "ingestor_service_account_email" {
  description = "Adresse à ajouter en lecture sur le dossier Drive."
  value       = google_service_account.ingestor.email
}

output "scheduler_service_account_email" {
  description = "Identité utilisée par Cloud Scheduler pour exécuter le job."
  value       = google_service_account.scheduler_invoker.email
}

output "raw_bucket_name" {
  description = "Bucket GCS de la zone d'atterrissage."
  value       = google_storage_bucket.raw.name
}

output "raw_table" {
  description = "Table BigQuery brute."
  value       = format("%s.%s.%s", var.project_id, google_bigquery_dataset.raw.dataset_id, google_bigquery_table.raw_market_prices.table_id)
}

output "marts_dataset" {
  description = "Dataset BigQuery cible de dbt."
  value       = format("%s.%s", var.project_id, google_bigquery_dataset.marts.dataset_id)
}

output "ingestor_image_uri" {
  description = "Image référencée par le job Cloud Run."
  value       = local.image_uri
}

