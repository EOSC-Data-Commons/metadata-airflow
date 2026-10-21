FROM apache/airflow:3.3.2

USER airflow

COPY --chown=airflow:root requirements.in /tmp/requirements.in

# Resolve all dependencies together.
# Pin the Airflow version to prevent accidental upgrades.

RUN printf 'apache-airflow==%s\n' "$AIRFLOW_VERSION" \
        > /tmp/airflow.in \
    && cat /tmp/requirements.in >> /tmp/airflow.in \
    && uv pip compile /tmp/airflow.in \
        --constraint "${HOME}/constraints.txt" \
        -o /tmp/requirements.txt \
    && pip install --no-cache-dir \
        "apache-airflow==${AIRFLOW_VERSION}" \
        -r /tmp/requirements.txt \
        --constraint "${HOME}/constraints.txt" \
    && pip check

RUN python - <<'PY'
from transformers import AutoTokenizer

tokenizer = AutoTokenizer.from_pretrained(
    "nomic-ai/nomic-embed-text-v2-moe",
)

tokenizer.save_pretrained("/home/airflow/models/nomic-embed-text-v2-moe")
PY
