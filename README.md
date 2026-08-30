# Harvest Airflow

Shared Apache Airflow deployment for running harvesting workflows.

The deployment uses:

-   PostgreSQL
-   RabbitMQ
-   CeleryExecutor
-   Git DAG bundles

Each harvester keeps its implementation and Airflow DAGs in its own
repository.

## Start

Create the environment:

``` bash
cp .env.example .env
```

Build and start Airflow:

``` bash
make up
```

Check list od DAGs:

``` bash
make dags
```

List DAG import errors:

``` bash
make dags-errors
```

## Adding a harvester

A harvester repository should contain its DAGs under a folder e.g. `airflow_dags/`:

``` text
toolmeta-harvester/
├── src/
├── airflow_dags/
│   ├── dynamic_harvests.py
│   └── static_harvests.py
└── pyproject.toml
```

### 1. Install the crawler scripts package to base Docker image

Add the harvester to the `Dockerfile` e.g. for the `toolmeta-harvester` `dev` branch:

``` dockerfile
RUN pip install \
    apache-airflow-providers-git \
    "git+https://github.com/EOSC-Data-Commons/toolmeta-harvester.git@dev"
```

Rebuild after changing the Dockerfile:

``` bash
docker compose build --no-cache
docker compose up -d --force-recreate
```

### 2. Add the DAG bundle (Airflow wrapper DAGs) to the deployment

Add the repository to `AIRFLOW__DAG_PROCESSOR__DAG_BUNDLE_CONFIG_LIST` e.g. for the `toolmeta-harvester` `dev` branch:

``` yaml
AIRFLOW__DAG_PROCESSOR__DAG_BUNDLE_CONFIG_LIST: >-
  [
    {
      "name": "toolmeta",
      "classpath": "airflow.providers.git.bundles.git.GitDagBundle",
      "kwargs": {
        "repo_url": "https://github.com/EOSC-Data-Commons/toolmeta-harvester.git",
        "tracking_ref": "dev",
        "subdir": "airflow_dags",
        "refresh_interval": 60
      }
    }
  ]
```

Multiple harvester repositories can be added as additional entries in
this list.

For production, use the same release tag or commit for both the
installed Python package and its Git DAG bundle.

## Useful commands

A Makefile is provided for convenience, run `make help` to see the available commands.

## Debug cheat sheet

### List DAGs
```bash
docker compose exec airflow-scheduler \
  airflow dags list
```

### Show DAG details
```bash
docker compose exec airflow-scheduler \
  airflow dags details <dag-id>
```

### Check DAG import errors
```bash
docker compose exec airflow-dag-processor \
  airflow dags list-import-errors
```

### Trigger a DAG
```bash
docker compose exec airflow-scheduler \
  airflow dags trigger <dag-id>
```

### Pause / unpause a DAG
```bash
docker compose exec airflow-scheduler \
  airflow dags pause <dag-id>

docker compose exec airflow-scheduler \
  airflow dags unpause <dag-id>
```

### List DAG runs
```bash
docker compose exec airflow-scheduler \
  airflow dags list-runs -d <dag-id>
```

### List tasks in a DAG
```bash
docker compose exec airflow-scheduler \
  airflow tasks list <dag-id>
```

### Show task tree
```bash
docker compose exec airflow-scheduler \
  airflow tasks list <dag-id> --tree
```

### Test a task directly
```bash
docker compose exec airflow-scheduler \
  airflow tasks test <dag-id> <task-id> <logical-date>
```

### Show task state
```bash
docker compose exec airflow-scheduler \
  airflow tasks state <dag-id> <task-id> <logical-date>
```


### Import/parsing errors
```bash
docker compose exec airflow-dag-processor \
  airflow dags list-import-errors
```

### DAG bundle configuration
```bash
docker compose exec airflow-dag-processor \
  airflow config get-value dag_processor dag_bundle_config_list
```

### Git bundle refresh interval
```bash
docker compose exec airflow-dag-processor \
  airflow config get-value dag_processor refresh_interval
```

### Minimum DAG processing interval
```bash
docker compose exec airflow-dag-processor \
  airflow config get-value dag_processor min_file_process_interval
```


### Show complete Airflow config
```bash
docker compose exec airflow-scheduler \
  airflow config list
```

### Executor
```bash
docker compose exec airflow-scheduler \
  airflow config get-value core executor
```

### Celery broker
```bash
docker compose exec airflow-worker \
  airflow config get-value celery broker_url
```

### Celery result backend
```bash
docker compose exec airflow-worker \
  airflow config get-value celery result_backend
```

### Extra Celery config
```bash
docker compose exec airflow-worker \
  airflow config get-value celery extra_celery_config
```


### Worker status
```bash
docker compose exec airflow-worker \
  airflow celery status
```

### Active tasks
```bash
docker compose exec airflow-worker \
  celery \
  -A airflow.providers.celery.executors.celery_executor.app \
  inspect active
```

### Reserved / queued tasks
```bash
docker compose exec airflow-worker \
  celery \
  -A airflow.providers.celery.executors.celery_executor.app \
  inspect reserved
```

### Scheduled tasks
```bash
docker compose exec airflow-worker \
  celery \
  -A airflow.providers.celery.executors.celery_executor.app \
  inspect scheduled
```

### Ping workers
```bash
docker compose exec airflow-worker \
  celery \
  -A airflow.providers.celery.executors.celery_executor.app \
  inspect ping
```

### Worker statistics
```bash
docker compose exec airflow-worker \
  celery \
  -A airflow.providers.celery.executors.celery_executor.app \
  inspect stats
```

### Check Airflow DB
```bash
docker compose exec airflow-scheduler \
  airflow db check
```

### Run database migrations
```bash
docker compose exec airflow-scheduler \
  airflow db migrate
```

### Airflow version
```bash
docker compose exec airflow-scheduler \
  airflow version
```

### Show Airflow info
```bash
docker compose exec airflow-scheduler \
  airflow info
```


## Most useful debugging sequence

### 1. Is the DAG loaded?
```bash
docker compose exec airflow-scheduler \
  airflow dags list
```

### 2. Did parsing fail?
```bash
docker compose exec airflow-dag-processor \
  airflow dags list-import-errors
```

### 3. Are runs being created?
```bash
docker compose exec airflow-scheduler \
  airflow dags list-runs -d <dag-id>
```

### 4. Are workers alive?
```bash
docker compose exec airflow-worker \
  airflow celery status
```

### 5. Are tasks active or waiting?
```bash
docker compose exec airflow-worker \
  celery \
  -A airflow.providers.celery.executors.celery_executor.app \
  inspect active

docker compose exec airflow-worker \
  celery \
  -A airflow.providers.celery.executors.celery_executor.app \
  inspect reserved
```

### 6. Test the task outside normal scheduling
```bash
docker compose exec airflow-scheduler \
  airflow tasks test <dag-id> <task-id> <logical-date>
```
