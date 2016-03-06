FROM ubuntu
MAINTAINER mwaeckerlin
ENV TERM xterm

ENV DOMAIN        ""
ENV ORGANIZATION  ""
ENV PASSWORD      ""
ENV DEBUG         0

RUN apt-get update
RUN apt-get install -y slapd ldap-utils debconf-utils pwgen
RUN touch /firstrun
ADD start.sh /start.sh
CMD /start.sh

EXPOSE 389
EXPOSE 636

VOLUME /certs
VOLUME /var/backups
VOLUME /etc/ldap
VOLUME /var/lib/ldap
