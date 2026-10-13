variable "project_id" {
  description = "ID du projet Google Cloud existant, avec facturation active."
  type        = string
}

variable "region" {
  description = "Région des services Cloud Run, Cloud Scheduler et Artifact Registry."
  type        = string
  default     = "europe-west1"
}

variable "dataset_location" {
  description = "Emplacement BigQuery et Cloud Storage. Garder le même emplacement pour les chargements."
  type        = string
  default     = "EU"
}

variable "raw_bucket_name" {
  description = "Nom globalement unique du bucket de fichiers CSV bruts."
  type        = string
}

variable "drive_folder_id" {
  description = "ID du dossier Drive contenant directement les CSV à ingérer."
  type        = string
}

variable "csv_delimiter" {
  description = "Séparateur CSV à un caractère (virgule par défaut)."
  type        = string
  default     = ","

  validation {
    condition     = length(var.csv_delimiter) == 1
    error_message = "csv_delimiter doit contenir exactement un caractère."
  }
}

variable "raw_dataset_id" {
  description = "Dataset BigQuery contenant les données brutes."
  type        = string
  default     = "market_analysis_raw"
}

variable "marts_dataset_id" {
  description = "Dataset BigQuery cible des modèles dbt."
  type        = string
  default     = "market_analysis_marts"
}

variable "artifact_registry_repository" {
  description = "Nom du dépôt Artifact Registry."
  type        = string
  default     = "market-analysis"
}

variable "ingestor_image_name" {
  description = "Nom de l'image du job d'ingestion."
  type        = string
  default     = "drive-ingestor"
}

variable "image_tag" {
  description = "Tag de l'image déployée. Incrémenter après chaque nouvelle compilation."
  type        = string
  default     = "v1"
}

variable "schedule" {
  description = "Fréquence Cloud Scheduler au format cron."
  type        = string
  default     = "*/10 * * * *"
}

variable "schedule_time_zone" {
  description = "Fuseau horaire du planning Cloud Scheduler."
  type        = string
  default     = "Europe/Paris"
}

variable "scheduler_paused" {
  description = "Créer le déclencheur en pause; passer à false après le partage Drive et le premier essai."
  type        = bool
  default     = true
}

variable "dbt_principal" {
  description = "Principal dbt facultatif, par exemple user:prenom.nom@example.com."
  type        = string
  default     = ""
}
