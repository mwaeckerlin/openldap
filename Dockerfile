FROM mwaeckerlin/base
MAINTAINER mwaeckerlin
ARG backend="mdb"
ARG overlays=""
ENV DOMAIN                    ""
ENV PASSWORD                  ""
ENV DEBUG                     1
ENV ACCESS RULES              "access to * by self write by users read by anonymous auth"

#ENV SERVER_NAME              ""
#ENV MULTI_MASTER_REPLICATION ""

# available schemas:
# - collective        Collective attributes (experimental)
# - corba             Corba Object
# - core          (1) OpenLDAP "core"
# - cosine        (2) COSINE Pilot
# - duaconf           Client Configuration (work in progress)
# - dyngroup          Dynamic Group (experimental)
# - inetorgperson (3) InetOrgPerson
# - java              Java Object
# - misc              Miscellaneous Schema (experimental)
# - nadf              North American Directory Forum (obsolete)
# - nis           (3) Network Information Service (experimental)
# - openldap          OpenLDAP Project (FYI)
# - ppolicy           Password Policy Schema (work in progress)
# - samba         (3) Samba user accounts and group maps
# - openssh-lpk       Stores SSH Public Keys
# - ldapns            LDAP Name Service Additional Schema
# (1) allways added
# (2) required by inetorgperson
# (3) required by default lam configuration
ENV SCHEMAS "cosine inetorgperson nis samba"

ENV CONTAINERNAME            "openldap"
ENV USER                     "ldap"
ENV GROUP                    "$USER"
ADD samba.schema /etc/openldap/schema/samba.schema
ADD openssh-lpk.schema /etc/openldap/schema/openssh-lpk.schema
ADD ldapns.schema /etc/openldap/schema/ldapns.schema
RUN apk add --no-cache --purge --clean-protected -u openldap openldap-clients openldap-back-$backend ${overlays} \
 && addgroup $USER $SHARED_GROUP_NAME \
 && mkdir /run/openldap \
 && chown $USER.$GROUP /run/openldap

EXPOSE 389
EXPOSE 636

VOLUME /ssl
VOLUME /etc/ldap
VOLUME /var/lib/ldap
VOLUME /var/backups
VOLUME /var/restore
