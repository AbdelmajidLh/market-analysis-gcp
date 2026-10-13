# Analyse de marché avec Google Cloud, Terraform et dbt

Ce dépôt fournit un pipeline de référence qui prend des fichiers CSV déposés dans un dossier Google Drive, les archive dans Cloud Storage, les charge dans BigQuery et publie des tables analytiques avec dbt.

Le cas d'exemple porte sur des cours de marché quotidiens. Le schéma d'entrée et les requêtes sont modifiables pour pouvoir les adapter à ton fichier réel.

## Architecture

~~~mermaid
flowchart LR
    subgraph DEPLOY["Construction et déploiement"]
        TF["Terraform<br/>API · IAM · bucket · datasets<br/>Artifact Registry · Cloud Run · Scheduler"]
        CB["Cloud Build<br/>construit l'image Docker"]
        AR["Artifact Registry<br/>image du pipeline"]
        CB -->|publie l'image| AR
    end

    subgraph SOURCE["Source"]
        DRIVE["Google Drive<br/>dossier partagé avec les CSV"]
    end

    subgraph PIPELINE["Ingestion planifiée · toutes les 10 minutes"]
        SCHED["Cloud Scheduler"]
        JOB["Cloud Run Job<br/>Python : Drive API, validation,<br/>chargement BigQuery puis dbt Core"]
        GCS["Cloud Storage<br/>landing/ : archives CSV<br/>state/ : verrou et marqueurs"]
        SCHED -->|déclenche le job| JOB
        AR -.->|image exécutée| JOB
    end

    subgraph WAREHOUSE["Entrepôt analytique · BigQuery EU"]
        RAW["Dataset market_analysis_raw<br/>market_prices<br/>table partitionnée par date"]
        STG["Dataset market_analysis_marts<br/>stg_market_prices · vue dédupliquée"]
        FACT["fct_daily_returns<br/>table des rendements journaliers"]
        MART["mart_monthly_performance<br/>table des performances mensuelles"]
        RAW -->|dbt| STG --> FACT --> MART
    end

    subgraph USE["Analyse"]
        SQL["queries/market_analysis.sql"]
        BI["Console BigQuery<br/>ou outil BI"]
        SQL -->|requêtes sur les modèles| FACT
        SQL -->|requêtes sur les modèles| MART
        MART --> BI
    end

    DRIVE -->|liste et télécharge les CSV via Drive API| JOB
    JOB -->|archive les fichiers et l'état| GCS
    JOB -->|charge puis MERGE idempotent| RAW

    TF -.->|provisionne| SCHED
    TF -.->|provisionne| JOB
    TF -.->|provisionne| GCS
    TF -.->|provisionne| RAW
    TF -.->|provisionne le dataset| STG
    TF -.->|provisionne| AR
~~~

### Rôle des services

| Service | Utilisation |
| --- | --- |
| Google Drive API | Lit les fichiers CSV du dossier partagé. |
| Cloud Scheduler | Déclenche le job selon une expression cron. |
| Cloud Run Jobs | Synchronise Drive, charge BigQuery puis lance dbt sans serveur permanent. |
| Cloud Storage | Conserve les CSV sources et les marqueurs d'idempotence. |
| BigQuery | Stocke les données brutes partitionnées et exécute les transformations analytiques. |
| Artifact Registry / Cloud Build | Héberge et construit l'image du job d'ingestion. |
| Terraform | Crée les API, IAM, buckets, datasets, table brute, job et planning. |
| dbt Core + dbt-bigquery | Transforme les données brutes en rendements et agrégats mensuels. |

Le job vérifie le dossier toutes les 10 minutes par défaut. Quand il ingère un ou plusieurs nouveaux CSV, il lance dbt pour actualiser les modèles. Il ne traite que les CSV placés directement dans ce dossier, pas dans ses sous-dossiers.

## Schéma CSV fourni

Le fichier doit avoir un en-tête et contenir ces colonnes avec ces noms :

| Colonne | Type attendu | Obligatoire |
| --- | --- | --- |
| price_date | Date YYYY-MM-DD | Oui |
| ticker | Symbole texte | Oui |
| open | Nombre décimal | Non |
| high | Nombre décimal | Non |
| low | Nombre décimal | Non |
| close | Nombre décimal | Oui |
| volume | Entier | Non |
| adjusted_close | Nombre décimal | Non |

Un exemple prêt à déposer est dans [sample_data/market_prices.csv](sample_data/market_prices.csv). Pour un CSV français avec séparateur point-virgule, configure csv_delimiter = ";" dans terraform/terraform.tfvars. Les nombres décimaux doivent rester compatibles avec le schéma BigQuery, par exemple 12.34 et pas 12,34.

Si ton fichier a un autre schéma, adapte ensemble :

1. ingestion/main.py : CSV_SCHEMA et la requête MERGE;
2. terraform/main.tf : local.raw_schema et le schéma de la table brute;
3. dbt/models/ : sélection, typage et calculs;
4. queries/market_analysis.sql et le présent contrat CSV.

L'ingestion est explicite : elle ne déduit pas les types. Le chargement BigQuery associe les colonnes à partir de l'en-tête; les en-têtes doivent donc correspondre au schéma attendu.

## Prérequis

1. Un projet Google Cloud existant avec facturation active.
2. gcloud initialisé sur ce projet.
3. Terraform version 1.6 ou plus récente, mais inférieure à 2.0.
4. Python 3.12 pour l'image d'ingestion; Python 3.11 ou 3.12 convient à dbt.
5. Docker n'est pas nécessaire sur ton poste : Cloud Build construit l'image.
6. Un dossier Drive contenant de vrais fichiers CSV téléversés dans Drive.

Le compte qui applique Terraform doit pouvoir activer des API, créer les ressources, créer des comptes de service et attribuer les rôles IAM associés. Pour un premier déploiement, fais exécuter Terraform par un compte d'administration approuvé ou demande les droits à l'administrateur du projet.

## Déploiement pas à pas avec PowerShell

### 1. Initialiser les variables locales

~~~powershell
$ProjectId = "mon-projet-gcp"
$Region = "europe-west1"
$ImageTag = "v1"
gcloud config set project $ProjectId
gcloud auth login
~~~

Récupère l'ID du dossier Drive dans son URL (drive.google.com/drive/folders/ID_DU_DOSSIER) et crée le fichier de variables Terraform :

~~~powershell
Copy-Item ./terraform/terraform.tfvars.example ./terraform/terraform.tfvars
notepad ./terraform/terraform.tfvars
~~~

Remplace le projet, l'ID Drive et le nom du bucket par des valeurs uniques. Le nom du bucket est globalement unique et ne doit pas déjà exister. Conserve dataset_location = "EU" si tu gardes les valeurs par défaut.

Pour que Terraform prépare aussi les droits de dbt, indique ton compte Google :

~~~hcl
dbt_principal = "user:prenom.nom@example.com"
~~~

Cette variable est facultative; si elle est vide, attribue ensuite les rôles BigQuery à ton identité séparément.

### 2. Créer les prérequis Terraform et le dépôt d'images

~~~powershell
terraform -chdir=terraform init
terraform -chdir=terraform apply -target=google_project_service.required -target=google_artifact_registry_repository.pipeline -var-file=terraform.tfvars
~~~

Lis le plan affiché, puis confirme l'application. Cette première passe ciblée ne crée que les API nécessaires et Artifact Registry, pour que Cloud Build dispose du dépôt avant la création du job Cloud Run.

### 3. Construire l'image d'ingestion

~~~powershell
$Image = "$Region-docker.pkg.dev/$ProjectId/market-analysis/drive-ingestor:$ImageTag"
gcloud builds submit . --project $ProjectId --region $Region --tag $Image
~~~

La commande construit le Dockerfile à la racine et inclut les répertoires ingestion/ et dbt/. Le fichier .gcloudignore exclut l'infrastructure et les données d'exemple. Le dépôt doit être Artifact Registry market-analysis, comme dans les valeurs Terraform par défaut. Si tu changes artifact_registry_repository ou ingestor_image_name, construis avec les mêmes valeurs. Le compte Cloud Build doit pouvoir écrire dans Artifact Registry; si le build échoue avec PERMISSION_DENIED, demande à l'administrateur d'accorder roles/artifactregistry.writer au compte de build du projet sur ce dépôt.

### 4. Créer le pipeline GCP

~~~powershell
terraform -chdir=terraform apply -var-file=terraform.tfvars
~~~

Après lecture du plan et confirmation, Terraform crée le bucket, les datasets et la table BigQuery, les identités IAM, le job Cloud Run et son déclencheur Cloud Scheduler. Le déclencheur est créé en pause afin que tu puisses partager le dossier Drive avant les premières exécutions.

Affiche l'adresse du compte de service Drive :

~~~powershell
terraform -chdir=terraform output -raw ingestor_service_account_email
~~~

### 5. Partager le dossier Drive

Dans Google Drive, partage le dossier source en lecture avec l'adresse affichée à l'étape précédente. Pour un Drive partagé, ajoute le compte comme membre ayant au minimum l'accès lecteur. Ne téléverse pas de clés JSON de compte de service : le job utilise son identité Cloud Run.

L'API Drive est activée par Terraform. Le compte de service ne voit que les fichiers et dossiers partagés explicitement avec lui.

### 6. Déclencher une première ingestion

Dépose sample_data/market_prices.csv (ou un CSV conforme à ton schéma) dans le dossier Drive, puis lance :

~~~powershell
gcloud run jobs execute drive-csv-ingestor --project $ProjectId --region $Region --wait
~~~

Le job archive le fichier sous landing/ dans le bucket, le charge dans une table de staging temporaire, puis fait un MERGE dans market_analysis_raw.market_prices. Il lance ensuite dbt run pour actualiser les modèles analytiques. Un marqueur JSON de fichier est écrit dans state/processed/ après succès; un marqueur state/dbt-pending.json permet de reprendre dbt si la transformation échoue.

### 7. Installer et lancer dbt en local (facultatif)

Configure l'authentification locale sans clé de compte de service :

~~~powershell
gcloud auth application-default login
$env:GCP_PROJECT_ID = $ProjectId
$env:BQ_RAW_DATASET = "market_analysis_raw"
$env:DBT_DATASET = "market_analysis_marts"
$env:BQ_LOCATION = "EU"
~~~

La synchronisation Cloud Run a déjà lancé dbt automatiquement après l'ingestion. Pour lancer les transformations depuis ton poste pendant le développement, crée un environnement Python :

~~~powershell
python -m venv .venv
./.venv/Scripts/Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r ./dbt/requirements.txt
Copy-Item ./dbt/profiles.yml.example ./dbt/profiles.yml
~~~

Puis exécute les transformations depuis la racine :

~~~powershell
dbt --project-dir ./dbt --profiles-dir ./dbt run
~~~

Les modèles créés dans market_analysis_marts sont :

| Modèle | Matérialisation | Contenu |
| --- | --- | --- |
| stg_market_prices | Vue | Normalise le ticker et garde la version ingérée la plus récente pour chaque date/ticker. |
| fct_daily_returns | Table partitionnée par date | Cours précédent, rendement quotidien et volume. Le rendement utilise adjusted_close si disponible, sinon close. |
| mart_monthly_performance | Table partitionnée par mois | Rendement mensuel, moyenne et volatilité des rendements journaliers, volume total et nombre de séances. |

Les rendements dans les modèles sont des ratios décimaux : 0.05 correspond à 5 %. Les requêtes d'exemple sont dans queries/market_analysis.sql. Remplace mon-projet-gcp par ton ID projet avant d'exécuter le fichier dans l'éditeur BigQuery.

### 8. Activer le planning et consulter les logs

Une fois le partage Drive vérifié et une ingestion manuelle réussie, modifie terraform/terraform.tfvars pour passer scheduler_paused à false, puis applique le changement :

~~~powershell
terraform -chdir=terraform apply -var-file=terraform.tfvars
~~~

Consulte ensuite le planning, les exécutions et les journaux :

~~~powershell
gcloud scheduler jobs describe drive-csv-ingestor-schedule --location $Region
gcloud run jobs executions list --job drive-csv-ingestor --region $Region
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="drive-csv-ingestor"' --project $ProjectId --limit 50
~~~

Cloud Scheduler démarre une exécution et ne reste pas en attente de la fin du traitement. Les succès et erreurs se consultent dans les exécutions et les logs Cloud Run.

## Idempotence et versions de fichiers

- Un verrou GCS empêche deux synchronisations de traiter le dossier en même temps. Un verrou abandonné est récupérable après environ 65 minutes.
- Une clé stable est calculée à partir de l'ID Drive et de son checksum.
- Les jobs de chargement BigQuery ont des identifiants déterministes.
- Le MERGE évite de réinsérer les lignes si une exécution s'arrête après le chargement et redémarre.
- Le CSV source reste archivé dans GCS. Une modification du fichier Drive crée une nouvelle version brute; la vue dbt retient la version ingérée la plus récente par ticker/date.
- Les tables de staging BigQuery temporaires expirent après 7 jours; les données brutes et les objets d'archive ne sont pas supprimés automatiquement.
- Si dbt échoue après l'ingestion, le marqueur de reprise reste dans GCS et le prochain passage du Scheduler relance les modèles même s'il n'y a pas de nouveau CSV.
- Un fichier source contenant deux lignes pour le même ticker et la même date est rejeté pour éviter de choisir arbitrairement un cours.

Si tu déposes des exports complets et répétés avec des IDs Drive différents, dbt déduplique les observations par ticker/date en retenant la dernière ingestion, tandis que la table brute conserve chaque source pour traçabilité.

## Adapter le CSV à un autre domaine

Si le CSV contient des ventes, des crypto-actifs ou des données de campagne, garde l'architecture d'ingestion et remplace le schéma de marché par ton contrat. Pour des fichiers volumineux ou des débits élevés, remplace le polling Drive par une source événementielle adaptée; cette version vise des dépôts périodiques de CSV de taille modérée.

## Dépannage

| Symptôme | À vérifier |
| --- | --- |
| 403 ou aucun fichier listé | Le dossier est partagé avec le compte de service exact; le compte a au moins Lecteur; le fichier est bien un CSV; le fichier est directement dans le dossier. |
| API désactivée | drive.googleapis.com est activée dans le bon projet et la propagation de l'API est terminée. |
| Erreur de colonnes au chargement | En-tête, noms, séparateur, types et nombre de colonnes; les en-têtes doivent correspondre au schéma du README. |
| Valeurs numériques invalides | Utilise un point comme séparateur décimal; les valeurs comme 12,34 doivent être normalisées avant le chargement. |
| Permission denied BigQuery | L'ingestor a bigquery.jobUser et bigquery.dataEditor sur raw et marts. dbt local a bigquery.jobUser, dataViewer sur raw et dataEditor sur marts. |
| dbt n'authentifie pas | Vérifie gcloud auth application-default login, GCP_PROJECT_ID, BQ_LOCATION et les droits du compte local. |
| Le build ne pousse pas l'image | Le compte Cloud Build a roles/artifactregistry.writer sur le dépôt Artifact Registry. |
| Le job exécute une ancienne image | Incrémente image_tag, reconstruis l'image avec ce tag, mets la même valeur dans terraform.tfvars, puis réapplique Terraform. |

## Coûts, sécurité et limites

- Cloud Run Jobs, Scheduler, Cloud Storage et BigQuery peuvent générer des coûts. Le coût BigQuery dépend du volume stocké et des octets lus par les requêtes.
- Le dataset brut est partitionné par price_date; filtre les périodes dans les requêtes pour limiter les scans.
- Les buckets utilisent l'accès uniforme au niveau bucket et la prévention d'accès public forcée.
- Les permissions de l'ingestor sont limitées à son bucket, aux datasets raw et marts et à la création de jobs BigQuery.
- Aucune clé de compte de service n'est requise ou stockée dans le dépôt.
- Le modèle n'est pas un conseil d'investissement; il calcule des indicateurs à partir des données fournies.
- Le polling convient à des dépôts périodiques. Il n'est pas conçu pour du streaming, des fichiers multi-gigaoctets ou des dizaines de milliers de petits fichiers à chaque exécution.

## Nettoyage de l'environnement

Terraform ne vide pas un bucket ni les datasets contenant des tables créées par dbt. Pour supprimer volontairement les données, vérifie le projet et le bucket ciblés, puis vide leurs contenus avec les commandes GCP adaptées. Après vidage, tu peux lancer :

~~~powershell
terraform -chdir=terraform destroy -var-file=terraform.tfvars
~~~

La suppression Terraform laisse les API activées (disable_on_destroy = false). Ne supprime pas le bucket si tu veux conserver l'archive CSV ou les marqueurs d'ingestion.

## Documentation officielle

- [Cloud Run Jobs planifiés avec Cloud Scheduler](https://docs.cloud.google.com/run/docs/execute/jobs-on-schedule)
- [Chargement CSV dans BigQuery](https://docs.cloud.google.com/bigquery/docs/loading-data-cloud-storage-csv)
- [Ressource Terraform BigQuery Dataset](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/bigquery_dataset)
- [Ressource Terraform Cloud Run Job](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/cloud_run_v2_job)

## Arborescence

~~~text
.
├── Dockerfile            # Image contenant l'ingestion et dbt
├── dbt/                  # Projet dbt et profil d'exemple
├── ingestion/            # Job Python Drive -> GCS -> BigQuery
├── queries/              # Requêtes analytiques BigQuery
├── sample_data/          # CSV d'exemple
└── terraform/            # Infrastructure GCP et IAM
~~~
