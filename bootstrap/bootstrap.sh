#!/bin/bash

# abort on error
set -e

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root!"
    exit
fi


function run_docker () {
    name=$1
    shift 1
    echo "Starting Docker container ${name}.."
    # ignore non-existing containers
    docker kill $name &> /dev/null || true
    docker rm -f $name &> /dev/null || true
    docker run --restart "on-failure:10" --net zmon-demo -d --name $name $@
}

function get_latest () {
    name=$1
    # REST API returns tags sorted by time
    tag=$(curl --silent https://registry.opensource.zalan.do/teams/stups/artifacts/$name/tags | jq .[].name -r | tail -n 1)
    echo "$name:$tag"
}

function wait_port () {
    until nc -w 5 -z $1 $2; do
        echo "Waiting for TCP port $1:${2}.."
        sleep 3
    done
}

echo "Retrieving latest versions.."
REPO=registry.opensource.zalan.do/stups
POSTGRES_IMAGE=$REPO/postgres:9.5.3-1
REDIS_IMAGE=$REPO/redis:3.2.0-alpine
CASSANDRA_IMAGE=cassandra:3.9
ZMON_KAIROSDB_IMAGE=$REPO/$(get_latest kairosdb)
ZMON_EVENTLOG_SERVICE_IMAGE=$REPO/$(get_latest zmon-eventlog-service)
ZMON_CONTROLLER_IMAGE=$REPO/$(get_latest zmon-controller)
ZMON_SCHEDULER_IMAGE=$REPO/$(get_latest zmon-scheduler)
ZMON_WORKER_IMAGE=$REPO/$(get_latest zmon-worker)
ZMON_METRIC_CACHE=$REPO/$(get_latest zmon-metric-cache)
ZMON_NOTIFICATION_SERVICE=$REPO/$(get_latest zmon-notification-service)

USER_ID=$(id -u daemon)

# first we pull all required Docker images to ensure they are ready
for image in $POSTGRES_IMAGE $REDIS_IMAGE $CASSANDRA_IMAGE $ZMON_KAIROSDB_IMAGE \
    $ZMON_EVENTLOG_SERVICE_IMAGE $ZMON_CONTROLLER_IMAGE $ZMON_SCHEDULER_IMAGE $ZMON_WORKER_IMAGE $ZMON_METRIC_CACHE $ZMON_NOTIFICATION_SERVICE; do
    echo "Pulling image ${image}.."
    docker pull $image
done

for i in zmon-controller zmon-eventlog-service; do
    if [ -d /workdir/$i ]; then
        rm -rf /workdir/$i
    fi

    wget https://github.com/zalando/$i/archive/master.zip -O /workdir/$i.zip
    mkdir -p /workdir/$i
    unzip /workdir/$i.zip -d /workdir/$i
    rm /workdir/$i.zip
done

# set up PostgreSQL
export PGHOST=zmon-postgres
export PGUSER=postgres
export PGPASSWORD=$(makepasswd --chars 32)
export PGDATABASE=local_zmon_db

echo "zmon-postgres:5432:*:postgres:$PGPASSWORD" > ~/.pgpass
chmod 600 ~/.pgpass

# add -v /data/postgresql:/var/lib/postgresql/data for keeping your data around
run_docker zmon-postgres -e POSTGRES_PASSWORD=$PGPASSWORD $POSTGRES_IMAGE
wait_port zmon-postgres 5432

cd /workdir/zmon-controller/zmon-controller-master/database/zmon
psql -c "CREATE DATABASE $PGDATABASE;" postgres
psql -c 'CREATE EXTENSION IF NOT EXISTS hstore;'
psql -c "CREATE ROLE zmon WITH LOGIN PASSWORD '--secret--';" postgres
find -name '*.sql' | sort | xargs cat | psql

psql -f /workdir/zmon-eventlog-service/zmon-eventlog-service-master/database/eventlog/00_create_schema.sql

# set up Redis
run_docker zmon-redis $REDIS_IMAGE
wait_port zmon-redis 6379

# set up Cassandra
run_docker zmon-cassandra \
    -v /data/zmon-cassandra:/opt/cassandra/data \
    $CASSANDRA_IMAGE
wait_port zmon-cassandra 9042

# set up KairosDB
run_docker zmon-kairosdb \
    -e "KAIROSDB_JETTY_PORT=8083" \
    -e "KAIROSDB_DATASTORE_CASSANDRA_REPLICATION_FACTOR=1" \
    -e "KAIROSDB_DATASTORE_CASSANDRA_HOST_LIST=zmon-cassandra" \
    $ZMON_KAIROSDB_IMAGE

wait_port zmon-kairosdb 8083

run_docker zmon-eventlog-service \
    -u $USER_ID \
    -e SERVER_PORT=8081 \
    -e MEM_JAVA_PERCENT=10 \
    -e POSTGRESQL_HOST=$PGHOST \
    -e POSTGRESQL_DATABASE=$PGDATABASE \
    -e POSTGRESQL_USER=$PGUSER \
    -e POSTGRESQL_PASSWORD=$PGPASSWORD \
    $ZMON_EVENTLOG_SERVICE_IMAGE

wait_port zmon-eventlog-service 8081

run_docker zmon-metric-cache \
    -u $USER_ID \
    -e MEM_JAVA_PERCENT=5 \
    $ZMON_METRIC_CACHE

# http://localhost:8888/_build/html/installation/configuration.html#authentication
SCHEDULER_TOKEN=$(makepasswd --string=0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ --chars 32)
BOOTSTRAP_TOKEN=$(makepasswd --string=0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ --chars 32)
WORKER_TOKEN=$(makepasswd --string=0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ --chars 32)
CONTROLLER_TOKEN=$(makepasswd --string=0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ --chars 32)

#run with INVALID as valid token for now, due to controlller config limitation!! this is internal service in demo!
run_docker zmon-notification-service \
    -u $USER_ID \
    -e SERVER_PORT=8087 \
    -e NOTIFICATIONS_REDIS_URI="redis://zmon-redis:6379/0" \
    -e NOTIFICATIONS_GOOGLE_PUSH_SERVICE_API_KEY="$SECRET_GOOGLE_API_KEY" \
    -e NOTIFICATIONS_ZMON_URL="https://demo.zmon.io" \
    -e NOTIFICATIONS_DRY_RUN=false \
    -e SPRING_APPLICATION_JSON="{\"notifications\":{\"shared_keys\":{\"INVALID\":1504981053654,\"$WORKER_TOKEN\":1504981053654,\"$CONTROLLER_TOKEN\":1504981053654}}}" \
    $ZMON_NOTIFICATION_SERVICE

run_docker zmon-controller \
    -u $USER_ID \
    -e SERVER_PORT=8080 \
    -e SERVER_SSL_ENABLED=false \
    -e SERVER_USE_FORWARD_HEADERS=true \
    -e MANAGEMENT_PORT=8079 \
    -e MANAGEMENT_SECURITY_ENABLED=false \
    -e MEM_JAVA_PERCENT=25 \
    -e SPRING_PROFILES_ACTIVE=github \
    -e ZMON_OAUTH2_SSO_CLIENT_ID=64210244ddd8378699d6 \
    -e ZMON_OAUTH2_SSO_CLIENT_SECRET=48794a58705d1ba66ec9b0f06a3a44ecb273c048 \
    -e ZMON_AUTHORITIES_SIMPLE_ADMINS=* \
    -e ZMON_TEAMS_SIMPLE_DEFAULT_TEAM=ZMON \
    -e POSTGRES_URL=jdbc:postgresql://$PGHOST:5432/local_zmon_db \
    -e POSTGRES_PASSWORD=$PGPASSWORD \
    -e REDIS_HOST=zmon-redis \
    -e REDIS_PORT=6379 \
    -e ENDPOINTS_CORS_ALLOWED_ORIGINS=https://demo.zmon.io \
    -e ZMON_EVENTLOG_URL=http://zmon-eventlog-service:8081/ \
    -e ZMON_KAIROSDB_URL=http://zmon-kairosdb:8083/ \
    -e ZMON_METRICCACHE_URL=http://zmon-metric-cache:8086/ \
    -e ZMON_SCHEDULER_URL=http://zmon-scheduler:8085/ \
    -e ZMON_SIGNUP_GITHUB_ALLOWED_USERS=* \
    -e ZMON_SIGNUP_GITHUB_ALLOWED_ORGAS=* \
    -e PRESHARED_TOKENS_${SCHEDULER_TOKEN}_UID=zmon-scheduler \
    -e PRESHARED_TOKENS_${SCHEDULER_TOKEN}_EXPIRES_AT=1758021422 \
    -e PRESHARED_TOKENS_${SCHEDULER_TOKEN}_AUTHORITY=user \
    -e PRESHARED_TOKENS_${BOOTSTRAP_TOKEN}_UID=zmon-demo-bootstrap \
    -e PRESHARED_TOKENS_${BOOTSTRAP_TOKEN}_EXPIRES_AT=1758021422 \
    -e PRESHARED_TOKENS_${BOOTSTRAP_TOKEN}_AUTHORITY=ADMIN \
    -e PRESHARED_TOKENS_${WORKER_TOKEN}_UID=zmon-worker \
    -e PRESHARED_TOKENS_${WORKER_TOKEN}_EXPIRES_AT=1758021422 \
    -e PRESHARED_TOKENS_${WORKER_TOKEN}_AUTHORITY=user \
    -e ZMON_ENABLE_FIREBASE=true \
    -e ZMON_NOTIFICATIONSERVICE_URL=http://zmon-notification-service:8087/ \
    -e ZMON_FIREBASE_API_KEY="AIzaSyBM1ktKS5u_d2jxWPHVU7Xk39s-PG5gy7c" \
    -e ZMON_FIREBASE_AUTH_DOMAIN="zmon-demo.firebaseapp.com" \
    -e ZMON_FIREBASE_DATABASE_URL="https://zmon-demo.firebaseio.com" \
    -e ZMON_FIREBASE_STORAGE_BUCKET="zmon-demo.appspot.com" \
    -e ZMON_FIREBASE_MESSAGING_SENDER_ID="280881042812" \
    -e OAUTH2_ACCESS_TOKENS=notification-service=$CONTROLLER_TOKEN \
    $ZMON_CONTROLLER_IMAGE

until curl http://zmon-controller:8080/index.jsp &> /dev/null; do
    echo 'Waiting for ZMON Controller..'
    sleep 3
done

psql -f /workdir/bootstrap/initial.sql

# now configure some initial checks and alerts
echo -e "url: http://zmon-controller:8080/api/v1\ntoken: $BOOTSTRAP_TOKEN" > ~/.zmon-cli.yaml
for f in /workdir/bootstrap/check-definitions/*.yaml; do
    zmon check-definitions update $f
done
for f in /workdir/bootstrap/entities/*.yaml; do
    zmon entities push $f
done
for f in /workdir/bootstrap/alert-definitions/*.yaml; do
    zmon alert-definitions create $f
done
for f in /workdir/bootstrap/dashboards/*.yaml; do
    # ZMON CLI updates the YAML file (sic!),
    # so use a temporary one
    temp=${f}.temp
    cp $f $temp
    zmon dashboard update $temp
    rm $temp
done

run_docker zmon-worker \
    -u $USER_ID \
    -e WORKER_REDIS_SERVERS=zmon-redis:6379 \
    -e WORKER_KAIROSDB_HOST=zmon-kairosdb \
    -e WORKER_METRICCACHE_URL=http://zmon-metric-cache:8086/api/v1/rest-api-metrics/ \
    -e WORKER_METRICCACHE_CHECK_ID=9 \
    -e WORKER_EVENTLOG_HOST=zmon-eventlog-service \
    -e WORKER_EVENTLOG_PORT=8081 \
    -e WORKER_PLUGIN_ENTITIES_ENTITYSERVICE_URL=http://zmon-controller:8080 \
    -e WORKER_PLUGIN_ENTITIES_ENTITYSERVICE_OAUTH2=True \
    -e OAUTH2_ACCESS_TOKENS=uid=$WORKER_TOKEN \
    -e WORKER_NOTIFICATIONS_SERVICE_URL=http://zmon-notification-service:8087/ \
    -e WORKER_NOTIFICATIONS_KEY=$WORKER_TOKEN \
    -e WORKER_NOTIFICATIONS_PUSH_URL=http://zmon-notification-service:8087/ \
    -e WORKER_NOTIFICATIONS_PUSH_KEY=$WORKER_TOKEN \
    $ZMON_WORKER_IMAGE

wait_port zmon-worker 8080

run_docker zmon-scheduler \
    -u $USER_ID \
    -e MEM_JAVA_PERCENT=20 \
    -e SCHEDULER_REDIS_HOST=zmon-redis \
    -e SCHEDULER_URLS_WITHOUT_REST=true \
    -e SCHEDULER_ENTITY_SERVICE_URL=http://zmon-controller:8080/ \
    -e SCHEDULER_OAUTH2_STATIC_TOKEN=$SCHEDULER_TOKEN \
    -e SCHEDULER_CONTROLLER_URL=http://zmon-controller:8080/ \
    $ZMON_SCHEDULER_IMAGE

wait_port zmon-scheduler 8085

# reset our metrics :-)
redis-cli -h zmon-redis del zmon:metrics

# Finally start our Apache 2 webserver (reverse proxy)
# TODO: this will not work locally
run_docker zmon-httpd \
    -p 80:80 -p 443:443 \
    -v /etc/letsencrypt/:/etc/letsencrypt/ \
    registry.opensource.zalan.do/stups/zmon-demo-httpd:v1 -DSSL
