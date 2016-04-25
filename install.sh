#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root!"
    exit
fi

# install Docker if necessary
docker=$(which docker)
if [ -z "$docker" ]; then
    apt-key adv --keyserver hkp://pgp.mit.edu:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D

    codename=$(lsb_release -cs)
    echo -e "deb https://apt.dockerproject.org/repo ubuntu-$codename main" > /etc/apt/sources.list.d/docker.list

    export DEBIAN_FRONTEND=noninteractive
    apt-get -y update
    apt-get -y install docker-engine
fi

docker network create --driver bridge zmon-demo

# TODO: make this configurable
mkdir -p /data/zmon-cassandra

docker rm -f zmon-demo-bootstrap
docker run -it --name zmon-demo-bootstrap \
    -v $(pwd):/workdir \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /usr/bin/docker:/usr/bin/docker \
    --net zmon-demo \
    registry.opensource.zalan.do/stups/zmon-demo-bootstrap:cd28 /workdir/bootstrap/bootstrap.sh
