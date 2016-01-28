FROM registry.opensource.zalan.do/stups/python:3.5.0-5

RUN apt-get update -y
RUN apt-get install -y postgresql-client git redis-tools makepasswd netcat-openbsd

RUN pip3 install --upgrade zmon-cli

VOLUME /tmp
WORKDIR /workdir

ADD bootstrap.sh /bootstrap.sh

CMD /bootstrap.sh
