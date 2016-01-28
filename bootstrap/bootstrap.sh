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

