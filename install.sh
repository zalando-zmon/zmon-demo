#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root!"
    exit
fi

export DEBIAN_FRONTEND=noninteractive

# install Docker
apt-key adv --keyserver hkp://pgp.mit.edu:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D

codename=$(lsb_release -cs)
echo -e "deb https://apt.dockerproject.org/repo ubuntu-$codename main" > /etc/apt/sources.list.d/docker.list

apt-get -y update
apt-get -y install docker-engine

apt-get install -y postgresql-client git redis-tools python3-pip makepasswd netcat-openbsd

pip3 install --upgrade pip
pip3 install --upgrade zmon-cli

mkdir -p zmon-controller
git clone https://github.com/zalando/zmon-controller.git zmon-controller || echo 'zmon-controller seems to be cloned already'

mkdir -p zmon-eventlog-service
git clone https://github.com/zalando/zmon-eventlog-service.git zmon-eventlog-service || echo 'zmon-eventlog-service seems to be cloned already'

# set up PostgreSQL
export PGHOST=localhost
export PGUSER=postgres
export PGPASSWORD=$(makepasswd --chars 32)
export PGDATABASE=demo_zmon_db

echo "localhost:5432:*:postgres:$PGPASSWORD" > ~/.pgpass
chmod 600 ~/.pgpass

container=$(docker ps | grep postgres)
if [ -z "$container" ]; then
    docker rm postgres
    docker run --restart "on-failure:10" --name postgres --net host -e POSTGRES_PASSWORD=$PGPASSWORD -d registry.opensource.zalan.do/stups/postgres:9.4.5-1
fi

until nc -w 5 -z localhost 5432; do
    echo 'Waiting for Postgres port..'
    sleep 3
done

# set up Redis
container=$(docker ps | grep redis)
if [ -z "$container" ]; then
    docker rm redis
    docker run --restart "on-failure:10" --name redis --net host -d registry.opensource.zalan.do/stups/redis:3.0.5
fi

until nc -w 5 -z localhost 6379; do
    echo 'Waiting for Redis port..'
    sleep 3
done
