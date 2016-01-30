#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root!"
    exit
fi

REPO=registry.opensource.zalan.do/stups
POSTGRES_IMAGE=$REPO/postgres:9.4.5-1
REDIS_IMAGE=$REPO/redis:3.0.5
CASSANDRA_IMAGE=$REPO/cassandra:2.1.5-1
ZMON_KAIROSDB_IMAGE=$REPO/zmon-kairosdb:0.1.6
ZMON_EVENTLOG_SERVICE_IMAGE=$REPO/zmon-eventlog-service:cd5
ZMON_CONTROLLER_IMAGE=$REPO/zmon-controller:cd38
ZMON_SCHEDULER_IMAGE=$REPO/zmon-scheduler:cd15
ZMON_WORKER_IMAGE=$REPO/zmon-worker:cd62

# first we pull all required Docker images to ensure they are ready
for image in $POSTGRES_IMAGE $REDIS_IMAGE $CASSANDRA_IMAGE $ZMON_KAIROSDB_IMAGE \
    $ZMON_CONTROLLER_IMAGE $ZMON_SCHEDULER_IMAGE $ZMON_WORKER_IMAGE; do
    docker pull $image
done

for i in zmon-controller zmon-eventlog-service; do
    if [ ! -d /workdir/$i ]; then
        wget https://github.com/zalando/$i/archive/master.zip -O /workdir/$i.zip
        mkdir -p /workdir/$i
        unzip /workdir/$i.zip -d /workdir/$i
        rm /workdir/$i.zip
    fi
done

# set up PostgreSQL
export PGHOST=zmon-postgres
export PGUSER=postgres
export PGPASSWORD=$(makepasswd --chars 32)
export PGDATABASE=local_zmon_db

echo "zmon-postgres:5432:*:postgres:$PGPASSWORD" > ~/.pgpass
chmod 600 ~/.pgpass

docker kill zmon-postgres
docker rm -f zmon-postgres
docker run --restart "on-failure:10" --name zmon-postgres --net zmon-demo -e POSTGRES_PASSWORD=$PGPASSWORD -d $POSTGRES_IMAGE

until nc -w 5 -z $PGHOST 5432; do
    echo 'Waiting for Postgres port..'
    sleep 3
done

cd /workdir/zmon-controller/zmon-controller-master/database/zmon
psql -c "CREATE DATABASE $PGDATABASE;" postgres
psql -c 'CREATE EXTENSION IF NOT EXISTS hstore;'
psql -c "CREATE ROLE zmon WITH LOGIN PASSWORD '--secret--';" postgres
find -name '*.sql' | sort | xargs cat | psql

# psql -f /vagrant/vagrant/initial.sql
psql -f /workdir/zmon-eventlog-service/zmon-eventlog-service-master/database/eventlog/00_create_schema.sql

# set up Redis
docker kill zmon-redis
docker rm -f zmon-redis
docker run --restart "on-failure:10" --name zmon-redis --net zmon-demo -d $REDIS_IMAGE

until nc -w 5 -z zmon-redis 6379; do
    echo 'Waiting for Redis port..'
    sleep 3
done

# set up Cassandra
docker kill zmon-cassandra
docker rm -f zmon-cassandra
docker run --restart "on-failure:10" --name zmon-cassandra --net zmon-demo -d $CASSANDRA_IMAGE

until nc -w 5 -z zmon-cassandra 9160; do
    echo 'Waiting for Cassandra port..'
    sleep 3
done

# set up KairosDB
docker kill zmon-kairosdb
docker rm -f zmon-kairosdb
docker run --restart "on-failure:10"  --name zmon-kairosdb --net zmon-demo -d -e "CASSANDRA_HOST_LIST=zmon-cassandra:9160" $ZMON_KAIROSDB_IMAGE

until nc -w 5 -z zmon-kairosdb 8083; do
    echo 'Waiting for KairosDB port..'
    sleep 3
done

docker kill zmon-eventlog-service
docker rm -f zmon-eventlog-service
docker run --restart "on-failure:10" --name zmon-eventlog-service --net zmon-demo \
    -e SERVER_PORT=8081 \
    -e MEM_JAVA_PERCENT=10 \
    -e POSTGRESQL_HOST=$PGHOST \
    -e POSTGRESQL_USER=$PGUSER -e POSTGRESQL_PASSWORD=$PGPASSWORD -d $ZMON_EVENTLOG_SERVICE_IMAGE

docker kill zmon-controller
docker rm -f zmon-controller
docker run --restart "on-failure:10" --name zmon-controller --net zmon-demo \
    -e SERVER_PORT=8080 \
    -e SERVER_SSL_ENABLED=false \
    -e SERVER_USE_FORWARD_HEADERS=true \
    -e MEM_JAVA_PERCENT=25 \
    -e SPRING_PROFILES_ACTIVE=github \
    -e ZMON_OAUTH2_SSO_CLIENT_ID=64210244ddd8378699d6 \
    -e ZMON_OAUTH2_SSO_CLIENT_SECRET=48794a58705d1ba66ec9b0f06a3a44ecb273c048 \
    -e ZMON_AUTHORITIES_SIMPLE_ADMINS=* \
    -e POSTGRES_URL=jdbc:postgresql://$PGHOST:5432/local_zmon_db \
    -e POSTGRES_PASSWORD=$PGPASSWORD \
    -e REDIS_HOST=zmon-redis \
    -e REDIS_PORT=6379 \
    -e ZMON_EVENTLOG_URL=http://zmon-eventlog-service:8081/ \
    -e ZMON_KAIROSDB_URL=http://zmon-kairosdb:8083/ \
    -e PRESHARED_TOKENS_123_UID=demotoken \
    -e PRESHARED_TOKENS_123_EXPIRES_AT=1758021422 \
    -d $ZMON_CONTROLLER_IMAGE

until curl http://zmon-controller:8080/index.jsp &> /dev/null; do
    echo 'Waiting for ZMON Controller..'
    sleep 3
done

docker kill zmon-worker
docker rm -f zmon-worker
docker run --restart "on-failure:10" --name zmon-worker --net zmon-demo \
    -e REDIS_SERVERS=zmon-redis:6379 \
    -d $ZMON_WORKER_IMAGE

docker kill zmon-scheduler
docker rm -f zmon-scheduler
docker run --restart "on-failure:10" --name zmon-scheduler --net zmon-demo \
    -e MEM_JAVA_PERCENT=20 \
    -e SCHEDULER_URLS_WITHOUT_REST=true \
    -e SCHEDULER_ENTITY_SERVICE_URL=http://zmon-controller:8080/ \
    -e SCHEDULER_OAUTH2_STATIC_TOKEN=123 \
    -e SCHEDULER_CONTROLLER_URL=http://zmon-controller:8080/ \
    -d $ZMON_SCHEDULER_IMAGE

# Finally start our Apache 2 webserver (reverse proxy)
# TODO: this will not work locally
docker run --restart "on-failure:10" --name zmon-httpd --net zmon-demo -d \
    -p 80:80 -p 443:443 \
    -v /etc/letsencrypt/:/etc/letsencrypt/ \
    zmon-demo-httpd -DSSL
