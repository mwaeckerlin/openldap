FROM mwaeckerlin/ubuntu-base
MAINTAINER mwaeckerlin

ENV DOMAIN                   ""
ENV ORGANIZATION             ""
ENV PASSWORD                 ""
ENV DEBUG                    1
ENV MULTI_MASTER_REPLICATION ""
ENV SERVER_NAME              ""

RUN echo "slapd slapd/password1 password test" | debconf-set-selections
RUN echo "slapd slapd/password2 password test" | debconf-set-selections
RUN apt-get install -y slapd ldap-utils debconf-utils pwgen db-util
RUN usermod -a -G ssl-cert openldap
RUN chown openldap.openldap /etc/ldap /var/lib/ldap

EXPOSE 389
EXPOSE 636

VOLUME /ssl
VOLUME /var/backups
VOLUME /etc/ldap/slapd.d
VOLUME /var/lib/ldap
VOLUME /var/restore
