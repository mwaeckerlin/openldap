FROM mwaeckerlin/ubuntu-base
MAINTAINER mwaeckerlin
ENV TERM xterm

ENV DOMAIN        ""
ENV ORGANIZATION  ""
ENV PASSWORD      ""
ENV DEBUG         1

RUN echo "slapd slapd/password1 password test" | debconf-set-selections
RUN echo "slapd slapd/password2 password test" | debconf-set-selections
RUN apt-get update
RUN apt-get install -y slapd ldap-utils debconf-utils pwgen
RUN mkdir /ssl
RUN mkdir /ssl/certs
RUN mkdir /ssl/private
RUN chmod o= /ssl/private
RUN chgrp openldap /ssl/private
ADD start.sh /start.sh
CMD /start.sh

EXPOSE 389
EXPOSE 636

VOLUME /etc/letsencrypt
VOLUME /var/backups
VOLUME /etc/ldap
VOLUME /var/lib/ldap
