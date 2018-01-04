#!/usr/bin/env bash

TRY_LOOP="20"

: "${CELERY_BROKER:="Redis"}"
: "${CELERY_RESULT_BACKEND:="Postgres"}"

: "${REDIS_HOST:="redis"}"
: "${REDIS_PORT:="6379"}"
: "${REDIS_PASSWORD:=""}"

: "${POSTGRES_HOST:="postgres"}"
: "${POSTGRES_PORT:="5432"}"
: "${POSTGRES_USER:="airflow"}"
: "${POSTGRES_PASSWORD:="airflow"}"
: "${POSTGRES_DB:="airflow"}"

: "${RABBITMQ_HOST:="rabbitmq"}"
: "${RABBITMQ_PORT:="5672"}"
: "${RABBITMQ_USER:="airflow"}"
: "${RABBITMQ_PASSWORD:="airflow"}"
: "${RABBITMQ_VHOST:="airflow"}"

# Defaults and back-compat
: "${AIRFLOW__CORE__FERNET_KEY:=${FERNET_KEY:=$(python -c "from cryptography.fernet import Fernet; FERNET_KEY = Fernet.generate_key().decode(); print(FERNET_KEY)")}}"
: "${AIRFLOW__CORE__EXECUTOR:=${EXECUTOR:-Sequential}Executor}"
: "${AIRFLOW__WEBSERVER__SECRET_KEY}:=${AIRFLOW_FLASK_KEY:=temporary_key}"

export \
  AIRFLOW__CELERY__BROKER_URL \
  AIRFLOW__CELERY__CELERY_RESULT_BACKEND \
  AIRFLOW__CORE__EXECUTOR \
  AIRFLOW__CORE__FERNET_KEY \
  AIRFLOW__CORE__LOAD_EXAMPLES \
  AIRFLOW__CORE__SQL_ALCHEMY_CONN \


# Load DAGs exemples (default: Yes)
if [[ -z "$AIRFLOW__CORE__LOAD_EXAMPLES" && "${LOAD_EX:=n}" == n ]]
then
  AIRFLOW__CORE__LOAD_EXAMPLES=False
fi

# Install custom python package if requirements.txt is present
if [ -e "/requirements.txt" ]; then
    $(which pip) install --user -r /requirements.txt
fi

if [ -n "$REDIS_PASSWORD" ]; then
    REDIS_PREFIX=:${REDIS_PASSWORD}@
else
    REDIS_PREFIX=
fi

wait_for_port() {
  local name="$1" host="$2" port="$3"
  local j=0
  while ! nc -z "$host" "$port" >/dev/null 2>&1 < /dev/null; do
    j=$((j+1))
    if [ $j -ge $TRY_LOOP ]; then
      echo >&2 "$(date) - $host:$port still not reachable, giving up"
      exit 1
    fi
    echo "$(date) - waiting for $name... $j/$TRY_LOOP"
    sleep 5
  done
}

wait_for_celery_broker() {
  if [ "$AIRFLOW__CORE__EXECUTOR" = "CeleryExecutor" ]
  then
    case "$CELERY_BROKER" in
      Redis)
        wait_for_port "Redis" "$REDIS_HOST" "$REDIS_PORT"
        ;;
      RabbitMQ)
        wait_for_port "RabbitMQ" "$RABBITMQ_HOST" "$RABBITMQ_PORT"
        ;;
      *)
        echo >&2 "$(date) - unrecognized celery broker: $CELERY_BROKER"
        exit 1
    esac
  fi
}

get_celery_broker_url() {
  case "$CELERY_BROKER" in
    Redis)
      return "redis://$REDIS_PREFIX$REDIS_HOST:$REDIS_PORT/1"
      ;;
    RabbitMQ)
      return "amqp://$RABBITMQ_USER:$RABBITMQ_PASSWORD@$RABBITMQ_HOST:$RABBITMQ_PORT/$RABBITMQ_VHOST"
      ;;
    *)
      echo >&2 "$(date) - unrecognized celery broker: $CELERY_BROKER"
      exit 1
      ;;
  esac
}

get_celery_result_backend() {
  case "$CELERY_RESULT_BACKEND" in
    Postgres)
      return "db+postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST:$POSTGRES_PORT/$POSTGRES_DB"
      ;;
    RabbitMQ)
      return "amqp://$RABBITMQ_USER:$RABBITMQ_PASS@$RABBITMQ_HOST:$RABBITMQ_PORT/$RABBITMQ_VHOST"
      ;;
    *)
      echo >&2 "$(date) - unrecognized celery result backend: $CELERY_RESULT_BACKEND"
      exit 1
      ;;
  esac
}

AIRFLOW__CORE__SQL_ALCHEMY_CONN="postgresql+psycopg2://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST:$POSTGRES_PORT/$POSTGRES_DB"
AIRFLOW__CELERY__BROKER_URL=$(get_celery_broker_url)
AIRFLOW__CELERY__CELERY_RESULT_BACKEND=$(get_celery_result_backend)

case "$1" in
  webserver)
    wait_for_port "Postgres" "$POSTGRES_HOST" "$POSTGRES_PORT"
    wait_for_celery_broker
    airflow initdb
    if [ "$AIRFLOW__CORE__EXECUTOR" = "LocalExecutor" ];
    then
      # With the "Local" executor it should all run in one container.
      airflow scheduler &
    fi
    exec airflow webserver
    ;;
  worker|scheduler)
    wait_for_port "Postgres" "$POSTGRES_HOST" "$POSTGRES_PORT"
    wait_for_celery_broker
    # To give the webserver time to run initdb.
    sleep 10
    exec airflow "$@"
    ;;
  flower)
    wait_for_celery_broker
    exec airflow "$@"
    ;;
  version)
    exec airflow "$@"
    ;;
  *)
    # The command is something like bash, not an airflow subcommand. Just run it in the right environment.
    exec "$@"
    ;;
esac
