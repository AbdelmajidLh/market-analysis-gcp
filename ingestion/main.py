"""Poll a shared Google Drive folder, archive CSVs in GCS, and merge them into BigQuery."""

from __future__ import annotations

import csv
import hashlib
import io
import json
import logging
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from typing import Any

import google.auth
from google.api_core.exceptions import Conflict, NotFound, PreconditionFailed
from google.cloud import bigquery, storage
from google.cloud.bigquery.enums import SourceFormat
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(message)s",
)
LOGGER = logging.getLogger("drive_csv_ingestor")

DRIVE_READONLY_SCOPE = "https://www.googleapis.com/auth/drive.readonly"
CSV_SCHEMA = [
    bigquery.SchemaField("price_date", "DATE", mode="REQUIRED"),
    bigquery.SchemaField("ticker", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("open", "FLOAT"),
    bigquery.SchemaField("high", "FLOAT"),
    bigquery.SchemaField("low", "FLOAT"),
    bigquery.SchemaField("close", "FLOAT", mode="REQUIRED"),
    bigquery.SchemaField("volume", "INT64"),
    bigquery.SchemaField("adjusted_close", "FLOAT"),
]
LOCK_TTL = timedelta(minutes=65)


def required_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise ValueError(f"La variable d'environnement {name} est obligatoire.")
    return value


def safe_filename(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", value).strip("._")
    return cleaned or "market_prices.csv"


def validate_csv_header(content: bytes, delimiter: str, file_name: str) -> None:
    expected = [field.name for field in CSV_SCHEMA]
    try:
        text = content.decode("utf-8-sig")
        reader = csv.reader(io.StringIO(text, newline=""), delimiter=delimiter)
        header = next(reader, None)
    except (UnicodeDecodeError, csv.Error) as exc:
        raise ValueError(f"En-tête CSV illisible dans {file_name}.") from exc

    actual = [column.strip() for column in header] if header else []
    if actual != expected:
        raise ValueError(
            f"En-tête CSV invalide dans {file_name}. Colonnes attendues dans cet ordre: "
            f"{', '.join(expected)}. Colonnes reçues: {', '.join(actual) or '(aucune)'}."
        )


def download_drive_file(drive: Any, file_id: str) -> bytes:
    request = drive.files().get_media(fileId=file_id, supportsAllDrives=True)
    output = io.BytesIO()
    downloader = MediaIoBaseDownload(output, request, chunksize=8 * 1024 * 1024)
    done = False
    while not done:
        _, done = downloader.next_chunk()
    return output.getvalue()


def list_csv_files(drive: Any, folder_id: str) -> list[dict[str, Any]]:
    query = f"'{folder_id}' in parents and trashed = false"
    files: list[dict[str, Any]] = []
    page_token = None
    while True:
        response = (
            drive.files()
            .list(
                q=query,
                pageSize=1000,
                pageToken=page_token,
                orderBy="modifiedTime",
                fields="nextPageToken,files(id,name,mimeType,modifiedTime,md5Checksum,size)",
                includeItemsFromAllDrives=True,
                supportsAllDrives=True,
            )
            .execute()
        )
        for item in response.get("files", []):
            name = item.get("name", "")
            mime_type = item.get("mimeType", "")
            if mime_type == "application/vnd.google-apps.folder":
                continue
            if name.lower().endswith(".csv") or mime_type == "text/csv":
                files.append(item)
        page_token = response.get("nextPageToken")
        if not page_token:
            break
    return files


def acquire_lock(bucket: storage.Bucket) -> tuple[storage.Blob, int] | None:
    lock = bucket.blob("state/drive-sync.lock")
    try:
        lock.upload_from_string(
            json.dumps({"started_at": datetime.now(timezone.utc).isoformat()}),
            content_type="application/json",
            if_generation_match=0,
        )
        lock.reload()
        return lock, int(lock.generation)
    except PreconditionFailed:
        lock.reload()
        updated = lock.updated or lock.time_created
        if updated and datetime.now(timezone.utc) - updated > LOCK_TTL:
            stale_generation = int(lock.generation)
            try:
                lock.delete(if_generation_match=stale_generation)
                return acquire_lock(bucket)
            except (NotFound, PreconditionFailed):
                return None
        LOGGER.info("Une autre exécution détient le verrou; cette exécution s'arrête.")
        return None


def release_lock(lock: storage.Blob, generation: int) -> None:
    try:
        lock.delete(if_generation_match=generation)
    except (NotFound, PreconditionFailed):
        LOGGER.warning("Le verrou a déjà été supprimé ou remplacé.")


def set_dbt_pending(bucket: storage.Bucket) -> None:
    pending = bucket.blob("state/dbt-pending.json")
    try:
        pending.upload_from_string(
            json.dumps({"requested_at": datetime.now(timezone.utc).isoformat()}),
            content_type="application/json",
            if_generation_match=0,
        )
    except PreconditionFailed:
        pass


def run_dbt(
    *, project_id: str, raw_dataset: str, marts_dataset: str, location: str
) -> None:
    environment = os.environ.copy()
    environment.update(
        {
            "GCP_PROJECT_ID": project_id,
            "BQ_RAW_DATASET": raw_dataset,
            "DBT_DATASET": marts_dataset,
            "BQ_LOCATION": location,
        }
    )
    LOGGER.info("Lancement de dbt run vers le dataset %s.", marts_dataset)
    subprocess.run(
        ["dbt", "run"],
        check=True,
        env=environment,
        cwd="/app/dbt",
    )


def get_or_start_load_job(
    bq: bigquery.Client,
    *,
    uri: str,
    destination: str,
    job_id: str,
    location: str,
    delimiter: str,
) -> bigquery.LoadJob:
    existing_job = None
    try:
        existing_job = bq.get_job(job_id, location=location)
        LOGGER.info("Job BigQuery de chargement déjà présent: %s", job_id)
        if existing_job.state == "DONE" and existing_job.errors:
            LOGGER.warning(
                "Le job de chargement précédent a échoué; une nouvelle tentative est créée."
            )
            existing_job = None
            job_id = (
                f"{job_id}_retry_"
                f"{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S%f')}"
            )
    except NotFound:
        pass

    if existing_job is not None:
        job = existing_job
    else:
        config = bigquery.LoadJobConfig(
            source_format=SourceFormat.CSV,
            schema=CSV_SCHEMA,
            skip_leading_rows=1,
            field_delimiter=delimiter,
            allow_quoted_newlines=True,
            create_disposition=bigquery.CreateDisposition.CREATE_IF_NEEDED,
            write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
            max_bad_records=0,
        )
        try:
            job = bq.load_table_from_uri(
                uri,
                destination,
                job_config=config,
                job_id=job_id,
                location=location,
            )
        except Conflict:
            job = bq.get_job(job_id, location=location)
    if job.state == "DONE" and job.errors:
        raise RuntimeError(f"Échec du chargement BigQuery {job_id}: {job.errors}")
    job.result()
    if job.errors:
        raise RuntimeError(f"Échec du chargement BigQuery {job_id}: {job.errors}")
    return job


def reject_duplicate_market_days(
    bq: bigquery.Client, temp_table: str, location: str
) -> None:
    sql = f"""
    SELECT price_date, ticker, COUNT(*) AS row_count
    FROM {chr(96)}{temp_table}{chr(96)}
    GROUP BY price_date, ticker
    HAVING COUNT(*) > 1
    LIMIT 10
    """
    duplicates = list(bq.query(sql, location=location).result())
    if duplicates:
        examples = [
            f"{row.price_date}/{row.ticker} ({row.row_count} lignes)"
            for row in duplicates
        ]
        raise ValueError(
            "Le CSV contient plusieurs lignes pour une même date et un même ticker: "
            + ", ".join(examples)
        )


def merge_into_raw(
    bq: bigquery.Client,
    *,
    temp_table: str,
    raw_table: str,
    location: str,
    file_key: str,
    file_id: str,
    file_name: str,
    checksum: str,
    modified_time: str | None,
) -> bigquery.QueryJob:
    q = chr(96)
    sql = f"""
    MERGE {q}{raw_table}{q} AS target
    USING (
      SELECT
        price_date,
        ticker,
        open,
        high,
        low,
        close,
        volume,
        adjusted_close,
        @file_key AS _source_file_key,
        @file_id AS _source_file_id,
        @file_name AS _source_file_name,
        @checksum AS _source_checksum,
        SAFE_CAST(@modified_time AS TIMESTAMP) AS _source_modified_time
      FROM {q}{temp_table}{q}
    ) AS source
    ON target._source_file_key = source._source_file_key
      AND target.price_date = source.price_date
      AND target.ticker = source.ticker
    WHEN NOT MATCHED THEN
      INSERT (
        price_date, ticker, open, high, low, close, volume, adjusted_close,
        _source_file_key, _source_file_id, _source_file_name, _source_checksum,
        _source_modified_time, _ingested_at
      )
      VALUES (
        source.price_date, source.ticker, source.open, source.high, source.low,
        source.close, source.volume, source.adjusted_close,
        source._source_file_key, source._source_file_id, source._source_file_name,
        source._source_checksum, source._source_modified_time, CURRENT_TIMESTAMP()
      )
    """
    config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("file_key", "STRING", file_key),
            bigquery.ScalarQueryParameter("file_id", "STRING", file_id),
            bigquery.ScalarQueryParameter("file_name", "STRING", file_name),
            bigquery.ScalarQueryParameter("checksum", "STRING", checksum),
            bigquery.ScalarQueryParameter("modified_time", "STRING", modified_time),
        ]
    )
    job_id = f"merge_{file_key[:40]}"
    existing_job = None
    try:
        existing_job = bq.get_job(job_id, location=location)
        if existing_job.state == "DONE" and existing_job.errors:
            LOGGER.warning(
                "Le MERGE précédent a échoué; une nouvelle tentative est créée."
            )
            existing_job = None
            job_id = (
                f"{job_id}_retry_"
                f"{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S%f')}"
            )
    except NotFound:
        pass

    if existing_job is not None:
        job = existing_job
    else:
        try:
            job = bq.query(sql, job_config=config, job_id=job_id, location=location)
        except Conflict:
            job = bq.get_job(job_id, location=location)
    if job.state == "DONE" and job.errors:
        raise RuntimeError(f"Échec du MERGE BigQuery {job_id}: {job.errors}")
    job.result()
    if job.errors:
        raise RuntimeError(f"Échec du MERGE BigQuery {job_id}: {job.errors}")
    return job


def process_file(
    item: dict[str, Any],
    *,
    drive: Any,
    bucket: storage.Bucket,
    bq: bigquery.Client,
    project_id: str,
    raw_dataset: str,
    raw_table_name: str,
    location: str,
    delimiter: str,
) -> bool:
    file_id = item["id"]
    file_name = item.get("name", "market_prices.csv")
    modified_time = item.get("modifiedTime")
    checksum = item.get("md5Checksum")

    content: bytes | None = None
    if not checksum:
        content = download_drive_file(drive, file_id)
        checksum = hashlib.sha256(content).hexdigest()

    file_key = hashlib.sha256(f"{file_id}:{checksum}".encode("utf-8")).hexdigest()
    marker_name = f"state/processed/{file_key}.json"
    marker = bucket.blob(marker_name)
    if marker.exists():
        LOGGER.info("Déjà ingéré: %s (%s)", file_name, file_id)
        return False

    if content is None:
        content = download_drive_file(drive, file_id)
    validate_csv_header(content, delimiter, file_name)

    safe_name = safe_filename(file_name)
    object_name = f"landing/drive_file_id={file_id}/source_key={file_key}/{safe_name}"
    raw_object = bucket.blob(object_name)
    if not raw_object.exists():
        raw_object.metadata = {
            "drive-file-id": file_id,
            "source-file-key": file_key,
            "source-checksum": checksum,
            "source-modified-time": modified_time or "",
        }
        raw_object.upload_from_file(
            io.BytesIO(content),
            content_type="text/csv",
            if_generation_match=0,
        )

    raw_table = f"{project_id}.{raw_dataset}.{raw_table_name}"
    temp_table = f"{project_id}.{raw_dataset}.stg_{file_key[:40]}"
    temp = bigquery.Table(temp_table, schema=CSV_SCHEMA)
    temp.expires = datetime.now(timezone.utc) + timedelta(days=7)
    bq.create_table(temp, exists_ok=True)

    load_job = get_or_start_load_job(
        bq,
        uri=f"gs://{bucket.name}/{object_name}",
        destination=temp_table,
        job_id=f"load_{file_key[:40]}",
        location=location,
        delimiter=delimiter,
    )
    reject_duplicate_market_days(bq, temp_table, location)
    merge_job = merge_into_raw(
        bq,
        temp_table=temp_table,
        raw_table=raw_table,
        location=location,
        file_key=file_key,
        file_id=file_id,
        file_name=file_name,
        checksum=checksum,
        modified_time=modified_time,
    )

    # Le MERGE est idempotent. En cas de crash avant les marqueurs, la prochaine
    # exécution peut rejouer le fichier puis relancer dbt sans perdre de lignes.
    set_dbt_pending(bucket)

    marker_payload = {
        "drive_file_id": file_id,
        "file_name": file_name,
        "checksum": checksum,
        "source_file_key": file_key,
        "gcs_uri": f"gs://{bucket.name}/{object_name}",
        "bigquery_load_job_id": load_job.job_id,
        "bigquery_merge_job_id": merge_job.job_id,
        "processed_at": datetime.now(timezone.utc).isoformat(),
        "rows_inserted": merge_job.num_dml_affected_rows,
    }
    try:
        marker.upload_from_string(
            json.dumps(marker_payload, ensure_ascii=False),
            content_type="application/json",
            if_generation_match=0,
        )
    except PreconditionFailed:
        LOGGER.info("Le marqueur a été écrit par une autre exécution: %s", file_key)
    LOGGER.info(
        "Ingestion terminée: %s; lignes insérées=%s",
        file_name,
        merge_job.num_dml_affected_rows,
    )
    return True


def main() -> int:
    project_id = required_env("GCP_PROJECT_ID")
    bucket_name = required_env("GCS_BUCKET")
    folder_id = required_env("DRIVE_FOLDER_ID")
    location = os.getenv("BQ_LOCATION", "EU")
    raw_dataset = os.getenv("BQ_RAW_DATASET", "market_analysis_raw")
    marts_dataset = os.getenv("DBT_DATASET", "market_analysis_marts")
    raw_table_name = os.getenv("BQ_RAW_TABLE", "market_prices")
    delimiter = os.getenv("CSV_DELIMITER", ",")
    if len(delimiter) != 1:
        raise ValueError("CSV_DELIMITER doit contenir exactement un caractère.")

    credentials, _ = google.auth.default(
        scopes=[
            DRIVE_READONLY_SCOPE,
            "https://www.googleapis.com/auth/cloud-platform",
        ]
    )
    drive = build("drive", "v3", credentials=credentials, cache_discovery=False)
    storage_client = storage.Client(project=project_id)
    bucket = storage_client.bucket(bucket_name)
    bq = bigquery.Client(project=project_id, location=location)

    lock_result = acquire_lock(bucket)
    if lock_result is None:
        return 0
    lock, lock_generation = lock_result
    errors: list[str] = []
    try:
        files = list_csv_files(drive, folder_id)
        LOGGER.info("%d fichier(s) CSV trouvé(s) dans le dossier Drive.", len(files))
        for item in files:
            try:
                process_file(
                    item,
                    drive=drive,
                    bucket=bucket,
                    bq=bq,
                    project_id=project_id,
                    raw_dataset=raw_dataset,
                    raw_table_name=raw_table_name,
                    location=location,
                    delimiter=delimiter,
                )
            except Exception:
                file_name = item.get("name", item.get("id", "inconnu"))
                LOGGER.exception("Échec d'ingestion du fichier %s", file_name)
                errors.append(file_name)
        pending_dbt = bucket.blob("state/dbt-pending.json")
        if pending_dbt.exists():
            if errors:
                LOGGER.warning(
                    "dbt est différé tant que %d fichier(s) CSV sont en erreur.", len(errors)
                )
            else:
                run_dbt(
                    project_id=project_id,
                    raw_dataset=raw_dataset,
                    marts_dataset=marts_dataset,
                    location=location,
                )
                pending_dbt.reload()
                pending_dbt.delete(if_generation_match=int(pending_dbt.generation))
    finally:
        release_lock(lock, lock_generation)

    if errors:
        raise RuntimeError(f"{len(errors)} fichier(s) en erreur: {', '.join(errors)}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        LOGGER.exception("Échec du job d'ingestion.")
        sys.exit(1)
