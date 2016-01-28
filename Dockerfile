FROM registry.opensource.zalan.do/stups/python:3.5.0-5

RUN apt-get update -y && \
    apt-get install -y postgresql-client redis-tools makepasswd netcat-openbsd wget unzip && \
    pip3 install --upgrade zmon-cli

VOLUME /tmp
WORKDIR /workdir

COPY bootstrap /bootstrap

CMD /bootstrap/bootstrap.sh
