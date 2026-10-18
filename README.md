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

L'ingestion est explicite : elle ne déduit pas les types. Le programme valide l'en-tête, puis BigQuery associe les valeurs par position à un schéma fixe. Les colonnes doivent donc être présentes dans cet ordre exact : `price_date,ticker,open,high,low,close,volume,adjusted_close`.

## Installer les outils et créer le projet GCP

Les commandes ci-dessous sont prévues pour Windows PowerShell. Exécute-les depuis la racine du dépôt lorsqu'elles utilisent des chemins comme `./dbt` ou `./terraform`.

### 1. Utiliser le projet Google Cloud existant

Ce dépôt est configuré pour le projet `project-b2238b62-da1a-46fc-a02`. Utilise ce projet pour toutes les ressources GCP; ne crée pas un projet supplémentaire. Dans la [console Google Cloud](https://console.cloud.google.com/), vérifie que ce projet est actif et associé à un compte Cloud Billing. Pour les étapes détaillées et les rôles requis, consulte [Activer la facturation d'un projet](https://docs.cloud.google.com/billing/docs/how-to/modify-project) ou demande à ton administrateur.

### 2. Installer Google Cloud CLI et se connecter

Télécharge et installe le [Google Cloud CLI pour Windows](https://docs.cloud.google.com/sdk/docs/install-sdk), puis ouvre une nouvelle fenêtre PowerShell et initialise la connexion :

~~~powershell
gcloud init
$ProjectId = "project-b2238b62-da1a-46fc-a02"
gcloud config set project $ProjectId
gcloud auth application-default login
gcloud config list
~~~

`gcloud init` ouvre le navigateur pour connecter ton compte Google et sélectionner un projet. `gcloud auth application-default login` crée les identifiants locaux qu'utilisent Terraform et le dbt exécuté depuis ton poste. Il n'est pas nécessaire de télécharger une clé JSON de compte de service. Plus d'informations : [identifiants ADC](https://docs.cloud.google.com/docs/authentication/provide-credentials-adc).

### 3. Installer Terraform

Télécharge l'archive Windows depuis la page officielle [Installer Terraform](https://developer.hashicorp.com/terraform/install), décompresse `terraform.exe` dans un dossier, puis ajoute ce dossier à la variable d'environnement utilisateur `Path`. Ferme et rouvre PowerShell pour recharger le `Path`, puis vérifie la version :

~~~powershell
terraform -version
~~~

Ce dépôt requiert Terraform 1.6 ou plus récent, mais inférieur à 2.0. La page HashiCorp propose aussi des méthodes d'installation avec un gestionnaire de paquets.

### 4. Installer Python et dbt pour le développement local

L'installation locale de dbt est facultative : le pipeline déployé lance dbt dans l'image Cloud Run. Pour exécuter les modèles depuis ton poste, installe [Python 3.12 pour Windows](https://www.python.org/downloads/windows/), puis crée un environnement virtuel dans le dépôt et installe l'adaptateur BigQuery prévu par le projet (`dbt-bigquery==1.9.1`) :

~~~powershell
py -3.12 --version
py -3.12 -m venv .venv
./.venv/Scripts/Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r ./dbt/requirements.txt
dbt --version
~~~

L'environnement virtuel évite de mélanger les dépendances de ce dépôt avec celles d'autres projets. La procédure `pip install dbt-bigquery` est décrite dans la [documentation dbt pour BigQuery](https://docs.getdbt.com/docs/local/connect-data-platform/bigquery-setup?version=1.12).

## Prérequis

1. Un projet Google Cloud existant avec facturation active.
2. Google Cloud CLI (`gcloud`) installé, connecté et configuré sur ce projet.
3. Terraform version 1.6 ou plus récente, mais inférieure à 2.0.
4. Python 3.12 pour l'image d'ingestion; Python 3.11 ou 3.12 convient à dbt en local.
5. Docker n'est pas nécessaire sur ton poste : Cloud Build construit l'image.
6. Un dossier Drive contenant de vrais fichiers CSV téléversés dans Drive.

Le compte qui applique Terraform doit pouvoir activer des API, créer les ressources, créer des comptes de service et attribuer les rôles IAM associés. Pour un premier déploiement, fais exécuter Terraform par un compte d'administration approuvé ou demande les droits à l'administrateur du projet.

## Déploiement pas à pas avec PowerShell

### 1. Initialiser les variables locales

Récupère l'ID du dossier Drive dans son URL (drive.google.com/drive/folders/ID_DU_DOSSIER) et crée le fichier de variables Terraform :

~~~powershell
Copy-Item ./terraform/terraform.tfvars.example ./terraform/terraform.tfvars
notepad ./terraform/terraform.tfvars
~~~

Remplace le projet, l'ID Drive et le nom du bucket par des valeurs uniques. Le nom du bucket est globalement unique et ne doit pas déjà exister. Conserve dataset_location = "EU" si tu gardes les valeurs par défaut.

Définis ensuite les variables PowerShell avec les mêmes valeurs que `project_id`, `region` et `image_tag` dans `terraform/terraform.tfvars` (ou les valeurs par défaut de Terraform pour `image_tag`) :

~~~powershell
$ProjectId = "project-b2238b62-da1a-46fc-a02"
$Region = "europe-west1"
$ImageTag = "v1"
gcloud config set project $ProjectId
~~~

Le projet, la région et le tag utilisés par les commandes `gcloud` doivent correspondre à ceux de Terraform. Sinon, Cloud Build peut pousser l'image vers un autre projet ou dépôt que celui provisionné par Terraform.

Pour que Terraform prépare aussi les droits de dbt, indique ton compte Google :

~~~hcl
dbt_principal = "user:prenom.nom@example.com"
~~~

Cette variable est facultative; si elle est vide, attribue ensuite les rôles BigQuery à ton identité séparément.

### 2. Créer les prérequis Terraform et le dépôt d'images

~~~powershell
terraform -chdir=terraform init
terraform -chdir=terraform apply `
  '-target=google_project_service.required' `
  '-target=google_artifact_registry_repository.pipeline' `
  '-var-file=terraform.tfvars'
~~~

Lis le plan affiché, puis confirme l'application. Cette première passe ciblée ne crée que les API nécessaires et Artifact Registry, pour que Cloud Build dispose du dépôt avant la création du job Cloud Run.

Après cette passe ciblée, vérifie les changements restants avec un plan complet :

~~~powershell
terraform -chdir=terraform plan '-var-file=terraform.tfvars'
~~~

### 3. Construire l'image d'ingestion

~~~powershell
$ArtifactRegistryRepository = "market-analysis"
$IngestorImageName = "drive-ingestor"
$Image = "${Region}-docker.pkg.dev/${ProjectId}/${ArtifactRegistryRepository}/${IngestorImageName}:$ImageTag"
gcloud artifacts repositories describe $ArtifactRegistryRepository --project $ProjectId --location $Region
gcloud builds submit . --project $ProjectId --region $Region --tag $Image
~~~

La commande de vérification doit trouver le dépôt avant le build. Le projet, la région et le nom du dépôt dans l'image doivent correspondre à `project_id`, `region` et `artifact_registry_repository` dans Terraform. L'image et le tag doivent aussi correspondre à `ingestor_image_name` et `image_tag`; si tu personnalises ces valeurs Terraform, modifie également les variables PowerShell ci-dessus. La commande construit le Dockerfile à la racine et inclut les répertoires ingestion/ et dbt/. Le fichier .gcloudignore exclut l'infrastructure et les données d'exemple. Le compte Cloud Build doit pouvoir écrire dans Artifact Registry; en cas de `PERMISSION_DENIED`, demande à l'administrateur d'accorder `roles/artifactregistry.writer` au compte de build du projet sur ce dépôt.

### 4. Créer le pipeline GCP

~~~powershell
terraform -chdir=terraform apply '-var-file=terraform.tfvars'
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

#### Comment Python et dbt collaborent

Le programme Python (`ingestion/main.py`) gère l'extraction et le chargement : il lit les CSV du dossier Drive, les archive dans Cloud Storage, puis charge et fusionne les lignes dans `BQ_RAW_DATASET.BQ_RAW_TABLE` (par défaut `market_analysis_raw.market_prices`). Après un `MERGE` réussi, il écrit le marqueur `state/dbt-pending.json`. Quand l'exécution n'a pas d'erreur d'ingestion et que ce marqueur existe, Python lance dbt comme un sous-processus : `dbt run`, depuis le dossier `/app/dbt` dans l'image Cloud Run. Si un CSV échoue, dbt est différé; le marqueur permet de reprendre les transformations à une exécution ultérieure.

Le `Dockerfile` copie le projet `dbt/` dans l'image et y crée `profiles.yml` à partir de `profiles.yml.example`. Le profil `market_analysis` utilise l'adaptateur BigQuery, l'authentification OAuth par identifiants par défaut et les variables d'environnement suivantes :

| Variable | Rôle | Valeur habituelle |
| --- | --- | --- |
| `GCP_PROJECT_ID` | Projet BigQuery cible. | Projet configuré dans Terraform. |
| `BQ_RAW_DATASET` | Dataset source lu par dbt. | `market_analysis_raw` |
| `DBT_DATASET` | Dataset où dbt crée les modèles. | `market_analysis_marts` |
| `BQ_LOCATION` | Emplacement BigQuery des jobs et datasets. | `EU` |

Terraform transmet ces variables au job Cloud Run. Python les transmet à dbt lors de son appel. En local, le même profil lit ces variables dans l'environnement et utilise les identifiants ADC créés par `gcloud auth application-default login`. Ainsi, le SQL des modèles est exécuté par dbt avec l'identité Cloud Run en production ou avec ton compte Google local pendant le développement.

La commande `dbt run` découvre les modèles SQL sous `dbt/models/` et détermine leur ordre grâce à `source()` et `ref()` :

1. `models/staging/stg_market_prices.sql` lit `source('raw', 'market_prices')`, c'est-à-dire la table brute `market_analysis_raw.market_prices`, et fournit une vue nettoyée et dédupliquée.
2. `models/marts/fct_daily_returns.sql` lit cette vue avec `ref('stg_market_prices')` et construit la table des rendements journaliers.
3. `models/marts/mart_monthly_performance.sql` lit la table précédente avec `ref('fct_daily_returns')` et construit les indicateurs mensuels.

Les types de matérialisation sont définis dans `dbt/dbt_project.yml`; le partitionnement et le clustering sont précisés dans les fichiers SQL des modèles concernés.

Le fichier `queries/market_analysis.sql` est différent : il contient des requêtes d'exploration et de reporting à lancer manuellement dans l'éditeur SQL de BigQuery (ou avec `bq query`). Ni Python ni `dbt run` ne l'exécutent. `dbt run` exécute uniquement les modèles déclarés dans `dbt/models/`.

### 7. Lancer dbt en local (facultatif)

Configure l'authentification locale sans clé de compte de service :

~~~powershell
gcloud auth application-default login
$env:GCP_PROJECT_ID = $ProjectId
$env:BQ_RAW_DATASET = "market_analysis_raw"
$env:DBT_DATASET = "market_analysis_marts"
$env:BQ_LOCATION = "EU"
~~~

La synchronisation Cloud Run a déjà lancé dbt automatiquement après l'ingestion. Pour lancer les transformations depuis ton poste pendant le développement, active l'environnement Python créé dans la section [Installer les outils et créer le projet GCP](#installer-les-outils-et-créer-le-projet-gcp), puis copie le profil d'exemple :

~~~powershell
./.venv/Scripts/Activate.ps1
Copy-Item ./dbt/profiles.yml.example ./dbt/profiles.yml
~~~

Vérifie la connexion à BigQuery, puis exécute les transformations depuis le dossier dbt :

~~~powershell
Push-Location ./dbt
dbt debug
dbt run
Pop-Location
~~~

Les modèles créés dans market_analysis_marts sont :

| Modèle | Matérialisation | Contenu |
| --- | --- | --- |
| stg_market_prices | Vue | Normalise le ticker et garde la version ingérée la plus récente pour chaque date/ticker. |
| fct_daily_returns | Table partitionnée par date | Cours précédent, rendement quotidien et volume. Le rendement utilise adjusted_close si disponible, sinon close. |
| mart_monthly_performance | Table partitionnée par mois | Rendement mensuel, moyenne et volatilité des rendements journaliers, volume total et nombre de séances. |

Les rendements dans les modèles sont des ratios décimaux : 0.05 correspond à 5 %. Les requêtes d'exemple dans queries/market_analysis.sql ciblent le projet `project-b2238b62-da1a-46fc-a02`.

### 8. Activer le planning et consulter les logs

Une fois le partage Drive vérifié et une ingestion manuelle réussie, modifie terraform/terraform.tfvars pour passer scheduler_paused à false, puis applique le changement :

~~~powershell
terraform -chdir=terraform apply '-var-file=terraform.tfvars'
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
| 403 `storage.objects.get` sur le bucket source Cloud Build | Accorde `roles/storage.objectViewer` au compte de build indiqué dans l'erreur, sur le bucket source `${project_id}_cloudbuild` uniquement. |
| `artifactregistry.repositories.uploadArtifacts` refusé au push | Accorde `roles/artifactregistry.writer` au compte de build sur le dépôt Artifact Registry. |
| Cloud Build ne peut pas écrire les logs | Accorde `roles/logging.logWriter` au compte de build dans le projet. |
| `name unknown: Repository ... not found` au push | Vérifie que le dépôt existe dans le même projet et la même région que l'URL de l'image; compare avec `project_id`, `region` et `artifact_registry_repository` dans `terraform/terraform.tfvars`. |
| Le job exécute une ancienne image | Incrémente image_tag, reconstruis l'image avec ce tag, mets la même valeur dans terraform.tfvars, puis réapplique Terraform. |

Pour un 403 `storage.objects.get` indiquant le compte Compute Engine par défaut, accorde-lui l'accès en lecture au bucket source Cloud Build :

~~~powershell
$CloudBuildServiceAccount = "252176821483-compute@developer.gserviceaccount.com"
gcloud storage buckets add-iam-policy-binding "gs://${ProjectId}_cloudbuild" `
  --member="serviceAccount:${CloudBuildServiceAccount}" `
  --role="roles/storage.objectViewer" `
  --project $ProjectId
~~~

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
terraform -chdir=terraform destroy '-var-file=terraform.tfvars'
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
