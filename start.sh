#!/bin/bash -e

function restoreconfig() {
    echo -n  "  restoring configuration ... "
    for f in /etc/ldap /var/lib/ldap; do
        if [ ! -z "$(ls -A $f.original)" ]; then
            if [ -z "$(ls -A $f)" ]; then
                cp -a $f.original/* $f/
                chown -R openldap.openldap $f
            fi
            rm -rf $f.original
        fi
    done
    echo "done."
}

function fixperm() {
    test -d /var/lib/ldap || mkdir -p /var/lib/ldap
    test -d /etc/ldap/slapd.d || mkdir -p /etc/ldap/slapd.d
    chown -R openldap /var/lib/ldap /etc/ldap/slapd.d
}

function start() {
    fixperm
    /usr/sbin/slapd -d ${DEBUG} \
    -h "ldap:/// ldapi:///" \
    -g openldap -u openldap \
    -F /etc/ldap/slapd.d
}

function startbg() {
    echo -n "  starting openldap in background ... "
    fixperm
    /usr/sbin/slapd -d 0 \
    -h "ldap:/// ldapi:///" \
    -g openldap -u openldap \
    -F /etc/ldap/slapd.d &
    PID=$!
    sleep 5
    while ! pgrep slapd > /dev/null; do sleep 1; done
    echo "done."
}

function stopbg() {
    echo -n "  stopping openldap running in background ... "
    kill $PID
    while pgrep slapd > /dev/null; do sleep 1; done
    echo "done."
}

function checkConfig() {
    echo -n "  checking configuration ... "
    if ! ldapsearch -Q -LLL -Y EXTERNAL -H ldapi:/// -b cn=config dn 2>/dev/null >/dev/null; then
        echo "error."
        echo "Error: cn=config not found" 1>&2
        exit 1
    fi
    echo "ready."
}

function checkCerts() {
    local certfile=
    local keyfile=
    echo -n "  check certificates ... "
    if test -e /ssl/live/${DOMAIN}/chain.pem \
         -a -e /ssl/live/${DOMAIN}/privkey.pem \
         -a -e /ssl/live/${DOMAIN}/cert.pem; then
        echo "found"
        ldapmodify -Y external -H ldapi:/// > /dev/null <<EOF
dn: cn=config
add: olcTLSCACertificateFile
olcTLSCACertificateFile: /ssl/live/${DOMAIN}/chain.pem
-
add: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /ssl/live/${DOMAIN}/privkey.pem
-
add: olcTLSCertificateFile
olcTLSCertificateFile: /ssl/live/${DOMAIN}/cert.pem
EOF
    else
        echo "no"
        echo "   to activate TLS/SSL, please mount /etc/letsencrypt to /ssl"
    fi
}

function setConfigPWD() {
    echo -n "  set cn=config password ... "
    ldapmodify -Y external -H ldapi:/// > /dev/null <<EOF
dn: olcDatabase={0}config,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: ${PASSWORD}
EOF
    echo "done."
}

function disallowAnonymousBind() {
    echo -n "  disallow anonymous bind ... "
    ldapmodify -Y external -H ldapi:/// > /dev/null <<EOF
dn: cn=config
changetype: modify
add: olcDisallows
olcDisallows: bind_anon

dn: olcDatabase={-1}frontend,cn=config
changetype: modify
add: olcRequires
olcRequires: authc
EOF
    echo "done."
}

function reconfigure() {
    echo -n "   reconfigure: ${ORGANIZATION} on ${DOMAIN} ... "
    debconf-set-selections <<EOF
slapd slapd/internal/generated_adminpw password ${PASSWORD}
slapd slapd/internal/adminpw password ${PASSWORD}
slapd slapd/password1 password ${PASSWORD}
slapd slapd/password2 password ${PASSWORD}
slapd shared/organization string ${ORGANIZATION}
slapd slapd/purge_database boolean false
slapd slapd/backend select HDB
slapd slapd/allow_ldap_v2 boolean false
slapd slapd/domain string ${DOMAIN}
EOF
    dpkg-reconfigure -f noninteractive slapd > /dev/null
    echo "done."
}

function backup() {
    echo -n "   backup ... "
    slapcat -n 0 -l /var/backups/${DATE}-startup-config.ldif && echo -n "${DATE}-startup-config.ldif "
    slapcat -n 1 -l /var/backups/${DATE}-startup-data.ldif && echo -n "${DATE}-startup-data.ldif "
    echo "done."
}

function restore() {
    if ! test -e /var/restore/config.ldif -o -e /var/restore/data.ldif; then
        return 1
    fi
    rm -rf /etc/ldap/slapd.d/* /var/lib/ldap/*
    reconfigure
    echo -n "   restoring ... "
    if test -e /var/restore/config.ldif; then
        echo -n "config "
        slapadd -c -n 0 -F /etc/ldap/slapd.d -l /var/restore/config.ldif
        mv /var/restore/config.ldif /var/backups/${DATE}-restored-config.ldif
    else
        slapadd -c -n 0 -F /etc/ldap/slapd.d -l /var/backups/${DATE}-startup-config.ldif
    fi
    if test -e /var/restore/data.ldif; then
        echo -n "data "
        slapadd -c -n 1 -F /etc/ldap/slapd.d -l /var/restore/data.ldif
        mv /var/restore/data.ldif /var/backups/${DATE}-restored-data.ldif
    else
        slapadd -c -n 1 -F /etc/ldap/slapd.d -l /var/backups/${DATE}-startup-data.ldif
    fi
    chown -R openldap.openldap /etc/ldap/slapd.d
    echo "done."
}

DATE=$(date '+%Y%m%d%H%m')

echo "Configuration ..."
restoreconfig

if test -z "${DOMAIN}"; then
    echo "ERROR: Specifying a domain is mandatory, use -e DOMAIN=example.org" 1>&2
    exit 1
fi
if test -z "${ORGANIZATION}"; then
    echo "ERROR: Specifying an organization is mandatory, use -e ORGANIZATION=\"Example Organization\"" 1>&2
    exit 1
fi
if test -z "${PASSWORD}"; then
    if test -e /etc/ldap/password; then
        export PASSWORD="$(</etc/ldap/password)"
    else
        export PASSWORD=$(pwgen 20 1)
        cat > /etc/ldap/password <<<"$PASSWORD"
    fi
fi

backup
restore || reconfigure
startbg
checkConfig
setConfigPWD
checkCerts
stopbg
echo "Configuration done."
echo "**** Administrator Password: ${PASSWORD}"
echo "starting slapd ..."
start
echo "Error: slapd terminated"
