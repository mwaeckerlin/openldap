FROM alpine
RUN apk add --no-cache openldap-clients openssl
# every volume the client shares with a server belongs to uid 102 (ldap), whichever container creates it first
RUN mkdir -p /backups /config /data /genconfig /restore /rbackups /rrestore /ssl-live /ssl-flat /ssl-locked \
    && chown 102:102 /backups /config /data /genconfig /restore /rbackups /rrestore /ssl-live /ssl-flat /ssl-locked
COPY make-certs.sh /usr/local/bin/make-certs.sh
USER 102
ENTRYPOINT ["sleep", "infinity"]
