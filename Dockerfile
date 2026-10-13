FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY ingestion/requirements.txt .
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

COPY ingestion/main.py .
COPY dbt/ /app/dbt/
RUN cp /app/dbt/profiles.yml.example /app/dbt/profiles.yml

CMD ["python", "main.py"]

