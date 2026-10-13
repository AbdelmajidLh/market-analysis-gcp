locals {
  required_apis = toset([
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "bigquerystorage.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudscheduler.googleapis.com",
    "drive.googleapis.com",
    "iam.googleapis.com",
    "run.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
  ])

  image_uri = format(
    "%s-docker.pkg.dev/%s/%s/%s:%s",
    var.region,
    var.project_id,
    var.artifact_registry_repository,
    var.ingestor_image_name,
    var.image_tag
  )

  raw_schema = [
    { name = "price_date", type = "DATE", mode = "REQUIRED", description = "Date de cotation, au format YYYY-MM-DD." },
    { name = "ticker", type = "STRING", mode = "REQUIRED", description = "Symbole de marché." },
    { name = "open", type = "FLOAT", mode = "NULLABLE", description = "Cours d'ouverture." },
    { name = "high", type = "FLOAT", mode = "NULLABLE", description = "Cours le plus haut." },
    { name = "low", type = "FLOAT", mode = "NULLABLE", description = "Cours le plus bas." },
    { name = "close", type = "FLOAT", mode = "REQUIRED", description = "Cours de clôture non ajusté." },
    { name = "volume", type = "INT64", mode = "NULLABLE", description = "Volume échangé." },
    { name = "adjusted_close", type = "FLOAT", mode = "NULLABLE", description = "Cours de clôture ajusté; le modèle utilise close en repli." },
    { name = "_source_file_key", type = "STRING", mode = "REQUIRED", description = "Clé stable d'idempotence basée sur l'ID Drive et le checksum." },
    { name = "_source_file_id", type = "STRING", mode = "REQUIRED", description = "ID du fichier source Google Drive." },
    { name = "_source_file_name", type = "STRING", mode = "REQUIRED", description = "Nom du fichier source." },
    { name = "_source_checksum", type = "STRING", mode = "REQUIRED", description = "Checksum Drive MD5 ou SHA-256 de repli." },
    { name = "_source_modified_time", type = "TIMESTAMP", mode = "NULLABLE", description = "Dernière modification du fichier source." },
    { name = "_ingested_at", type = "TIMESTAMP", mode = "REQUIRED", description = "Horodatage d'ingestion UTC." },
  ]
}

resource "google_project_service" "required" {
  for_each           = local.required_apis
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "pipeline" {
  project       = var.project_id
  location      = var.region
  repository_id = var.artifact_registry_repository
  description   = "Images conteneur du pipeline market analysis."
  format        = "DOCKER"

  depends_on = [google_project_service.required]
}

resource "google_storage_bucket" "raw" {
  project                     = var.project_id
  name                        = var.raw_bucket_name
  location                    = var.dataset_location
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  labels = {
    application = "market-analysis"
    layer       = "raw"
  }
}

resource "google_bigquery_dataset" "raw" {
  project                    = var.project_id
  dataset_id                 = var.raw_dataset_id
  friendly_name              = "Market analysis - raw"
  description                = "Zone brute des cotations chargées depuis Google Drive."
  location                   = var.dataset_location
  delete_contents_on_destroy = false

  labels = {
    application = "market-analysis"
    layer       = "raw"
  }
}

resource "google_bigquery_dataset" "marts" {
  project                    = var.project_id
  dataset_id                 = var.marts_dataset_id
  friendly_name              = "Market analysis - marts"
  description                = "Tables analytiques produites par dbt."
  location                   = var.dataset_location
  delete_contents_on_destroy = false

  labels = {
    application = "market-analysis"
    layer       = "marts"
  }
}

resource "google_bigquery_table" "raw_market_prices" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.raw.dataset_id
  table_id            = "market_prices"
  friendly_name       = "Cours de marché bruts"
  description         = "Lignes source conservées par fichier, date et ticker."
  schema              = jsonencode(local.raw_schema)
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "price_date"
  }

  clustering = ["ticker"]
}

resource "google_service_account" "ingestor" {
  project      = var.project_id
  account_id   = "market-analysis-ingestor"
  display_name = "Market analysis Drive CSV ingestor"
  description  = "Lit le dossier Drive partagé, archive les CSV dans GCS et charge BigQuery."
}

resource "google_service_account" "scheduler_invoker" {
  project      = var.project_id
  account_id   = "market-analysis-scheduler"
  display_name = "Market analysis Cloud Scheduler invoker"
  description  = "Identité OAuth utilisée par Cloud Scheduler pour démarrer le job Cloud Run."
}

resource "google_storage_bucket_iam_member" "ingestor_objects" {
  bucket = google_storage_bucket.raw.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.ingestor.email}"
}

resource "google_project_iam_member" "ingestor_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.ingestor.email}"
}

resource "google_bigquery_dataset_iam_member" "ingestor_raw_editor" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.raw.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.ingestor.email}"
}

resource "google_bigquery_dataset_iam_member" "ingestor_marts_editor" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.marts.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.ingestor.email}"
}

resource "google_project_iam_member" "dbt_job_user" {
  count   = var.dbt_principal == "" ? 0 : 1
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = var.dbt_principal
}

resource "google_bigquery_dataset_iam_member" "dbt_raw_reader" {
  count      = var.dbt_principal == "" ? 0 : 1
  project    = var.project_id
  dataset_id = google_bigquery_dataset.raw.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = var.dbt_principal
}

resource "google_bigquery_dataset_iam_member" "dbt_marts_editor" {
  count      = var.dbt_principal == "" ? 0 : 1
  project    = var.project_id
  dataset_id = google_bigquery_dataset.marts.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = var.dbt_principal
}

resource "google_cloud_run_v2_job" "drive_ingestor" {
  project             = var.project_id
  name                = "drive-csv-ingestor"
  location            = var.region
  deletion_protection = false
  launch_stage        = "GA"

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account = google_service_account.ingestor.email
      timeout         = "3600s"
      max_retries     = 1

      containers {
        image = local.image_uri

        env {
          name  = "GCP_PROJECT_ID"
          value = var.project_id
        }
        env {
          name  = "GCS_BUCKET"
          value = google_storage_bucket.raw.name
        }
        env {
          name  = "DRIVE_FOLDER_ID"
          value = var.drive_folder_id
        }
        env {
          name  = "BQ_LOCATION"
          value = var.dataset_location
        }
        env {
          name  = "BQ_RAW_DATASET"
          value = google_bigquery_dataset.raw.dataset_id
        }
        env {
          name  = "BQ_RAW_TABLE"
          value = google_bigquery_table.raw_market_prices.table_id
        }
        env {
          name  = "DBT_DATASET"
          value = google_bigquery_dataset.marts.dataset_id
        }
        env {
          name  = "CSV_DELIMITER"
          value = var.csv_delimiter
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "1Gi"
          }
        }
      }
    }
  }

  depends_on = [
    google_project_service.required,
    google_bigquery_table.raw_market_prices,
    google_storage_bucket_iam_member.ingestor_objects,
    google_project_iam_member.ingestor_job_user,
    google_bigquery_dataset_iam_member.ingestor_raw_editor,
    google_bigquery_dataset_iam_member.ingestor_marts_editor,
  ]
}

resource "google_cloud_run_v2_job_iam_member" "scheduler_invoker" {
  project  = var.project_id
  location = google_cloud_run_v2_job.drive_ingestor.location
  name     = google_cloud_run_v2_job.drive_ingestor.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler_invoker.email}"
}

resource "google_cloud_scheduler_job" "drive_ingestor" {
  project          = var.project_id
  name             = "drive-csv-ingestor-schedule"
  region           = var.region
  description      = "Recherche les nouveaux CSV du dossier Drive et les charge dans BigQuery."
  schedule         = var.schedule
  time_zone        = var.schedule_time_zone
  attempt_deadline = "320s"
  paused           = var.scheduler_paused

  http_target {
    http_method = "POST"
    uri = format(
      "https://run.googleapis.com/v2/projects/%s/locations/%s/jobs/%s:run",
      var.project_id,
      var.region,
      google_cloud_run_v2_job.drive_ingestor.name
    )
    body = base64encode("{}")

    oauth_token {
      service_account_email = google_service_account.scheduler_invoker.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_project_service.required,
    google_cloud_run_v2_job_iam_member.scheduler_invoker,
  ]
}
