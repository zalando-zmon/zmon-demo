#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root!"
    exit
fi

export DEBIAN_FRONTEND=noninteractive

for i in zmon-controller zmon-eventlog-service; do
    wget https://github.com/zalando/$i/archive/master.zip -O /tmp/$i.zip
    mkdir -p /tmp/$i
    unzip /tmp/$i.zip -d /tmp/$i
done

# set up PostgreSQL
export PGHOST=localhost
export PGUSER=postgres
export PGPASSWORD=$(makepasswd --chars 32)
export PGDATABASE=demo_zmon_db

echo "localhost:5432:*:postgres:$PGPASSWORD" > ~/.pgpass
chmod 600 ~/.pgpass

container=$(docker ps | grep zmon-postgres)
if [ -z "$container" ]; then
    docker rm -f zmon-postgres
    docker run --restart "on-failure:10" --name zmon-postgres --net zmon-demo -e POSTGRES_PASSWORD=$PGPASSWORD -d registry.opensource.zalan.do/stups/postgres:9.4.5-1
fi

until nc -w 5 -z localhost 5432; do
    echo 'Waiting for Postgres port..'
    sleep 3
done

# set up Redis
container=$(docker ps | grep zmon-redis)
if [ -z "$container" ]; then
    docker rm -f zmon-redis
    docker run --restart "on-failure:10" --name zmon-redis --net zmon-demo -d registry.opensource.zalan.do/stups/redis:3.0.5
fi

until nc -w 5 -z localhost 6379; do
    echo 'Waiting for Redis port..'
    sleep 3
done
