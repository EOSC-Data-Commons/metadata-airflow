FROM apache/airflow:3.3.1

USER airflow

ARG TOOLMETA_REPO
ARG TOOLMETA_REF

RUN pip install \
    apache-airflow-providers-git \
    "git+${TOOLMETA_REPO}@${TOOLMETA_REF}"

RUN python - <<'PY'
from transformers import AutoTokenizer

tokenizer = AutoTokenizer.from_pretrained(
    "nomic-ai/nomic-embed-text-v2-moe",
)

tokenizer.save_pretrained("/home/airflow/models/nomic-embed-text-v2-moe")
PY
