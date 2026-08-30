FROM apache/airflow:3.3.1

USER airflow

RUN pip install \
    apache-airflow-providers-git \
    "git+https://github.com/EOSC-Data-Commons/toolmeta-harvester.git@dev"
