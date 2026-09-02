FROM apache/airflow:3.3.1

USER airflow

ARG TOOLMETA_REPO
ARG TOOLMETA_REF

RUN pip install \
    apache-airflow-providers-git \
    "git+${TOOLMETA_REPO}@${TOOLMETA_REF}" 
