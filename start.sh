#!/bin/bash -e

stdbuf -i0 -o0 -e0 echo

function restoreconfig() {
    local restored=0
    echo -n  "  --> restoring configuration ... "
    for f in /etc/ldap /var/lib/ldap; do
        if [ ! -z "$(ls -A $f.original)" ]; then
            if [ -z "$(ls -A $f)" ]; then
                echo -n "$f "
                cp -a $f.original/* $f/
                chown -R openldap.openldap $f
                restored=1
            fi
            rm -rf $f.original
        fi
    done
    echo -n "debian-script "
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
    test $restored -eq 1
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
    echo -n "  --> starting openldap in background ... "
    fixperm
    /usr/sbin/slapd -d 0 \
    -h "ldap:/// ldapi:///" \
    -g openldap -u openldap \
    -F /etc/ldap/slapd.d &
    PID=$!
    while ! pgrep slapd > /dev/null; do sleep 1; done
    sleep 5;
    if test "$PID" != "$(pgrep slapd)"; then
        echo "ERROR: failed to start openldap server" 1>&2
        exit 1
    fi
    echo "done."
}

function stopbg() {
    echo -n "  --> stopping openldap running in background ... "
    kill $PID
    while pgrep slapd > /dev/null; do sleep 1; done
    echo "done."
}

function checkConfig() {
    echo -n "  --> checking configuration ... "
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
    echo -n "  --> check certificates ... "
    if test -e /ssl/live/${DOMAIN}/chain.pem \
         -a -e /ssl/live/${DOMAIN}/privkey.pem \
         -a -e /ssl/live/${DOMAIN}/cert.pem; then
        echo "found"
        ldapmodify -Y external -H ldapi:/// > /dev/null 2> /dev/null <<EOF
dn: cn=config
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: /ssl/live/${DOMAIN}/chain.pem
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /ssl/live/${DOMAIN}/privkey.pem
-
replace: olcTLSCertificateFile
olcTLSCertificateFile: /ssl/live/${DOMAIN}/cert.pem
EOF
    else
        echo "no"
        echo "   to activate TLS/SSL, please mount /etc/letsencrypt to /ssl"
    fi
}

function setConfigPWD() {
    echo -n "  --> set cn=config password ... "
    ldapadd -Y EXTERNAL -H ldapi:/// <<EOF
dn: olcDatabase={1}hdb,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: ${PASSWD}
-

dn: olcDatabase={0}config,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: ${PASSWD}
EOF
    echo "done."
}

function disallowAnonymousBind() {
    echo -n "  --> disallow anonymous bind ... "
    ldapmodify -Y external -H ldapi:/// > /dev/null 2> /dev/null <<EOF
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
    echo -n "  --> reconfigure: ${ORGANIZATION} on ${DOMAIN} ... "
    if ldapadd -c -Y external -H ldapi:/// > /dev/null 2> /dev/null; then
        echo "done."
    else
        res=$?
        case "$res" in
            (68) echo "already configured";;
            (*) echo "failed: $res.";;
        esac
    fi <<EOF
dn: ${BASEDN}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ${ORGANIZATION}
dc: ${DOMAIN%%.*}

dn: cn=admin,${BASEDN}
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: admin
description: LDAP administrator
userPassword: ${PASSWD}
EOF
}

function backup() {
    echo -n "  --> backup ... "
    slapcat -n 0 -l /var/backups/${DATE}-startup-config.ldif && echo -n "${DATE}-startup-config.ldif "
    slapcat -n 1 -l /var/backups/${DATE}-startup-data.ldif && echo -n "${DATE}-startup-data.ldif "
    echo "done."
}

function recover() {
    echo -n "  --> recover database... "
    cd /var/lib/ldap
    db_recover -v
    echo "done."
}

function restore() {
    if ! test -e /var/restore/config.ldif -o -e /var/restore/data.ldif; then
        return 1
    else
        rm -rf /etc/ldap/slapd.d/* /var/lib/ldap/*
        echo -n "  --> restoring ... "
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
    fi
    echo "done."
    return 0
}

function multimaster() {
    if test -z "$MULTI_MASTER_REPLICATION"; then
        return
    fi
    if test -z "$SERVER_NAME" || ! [[ " ${MULTI_MASTER_REPLICATION} " =~ " ${SERVER_NAME} " ]];  then
        echo "ERROR: SERVER_NAME must be one of ${MULTI_MASTER_REPLICATION} in MULTI_MASTER_REPLICATION" 1>&2
        exit 1
    fi
    echo -n "  --> multimaster ... "
    # load module
    echo -n "module "
    ldapadd -Y EXTERNAL -H ldapi:/// <<EOF
dn: cn=module,cn=config
objectClass: olcModuleList
cn: module
olcModulePath: /usr/lib/ldap
olcModuleLoad: syncprov.la
EOF
    # config replication
    local masters=( ${MULTI_MASTER_REPLICATION} )
    local serverid=
    for ((i=0; i<${#masters[@]}; ++i)); do
        if test "${masters[$i]}" == "${SERVER_NAME}"; then
            serverid=$((i+1))
            break;
        fi
    done
    test -n "$serverid"
    echo -n "config for ${SERVER_NAME} as $serverid "
    ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: cn=config
changetype: modify
add: olcServerID
olcServerID: ${serverid}
EOF
    ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: cn=config
changetype: modify
replace: olcServerID
$(
    for ((i=0; i<${#masters[@]}; ++i)); do
      echo "olcServerID: $((i+1)) ldap://${masters[$i]}"
    done
)

dn: olcOverlay=syncprov,olcDatabase={0}config,cn=config
changetype: add
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig

dn: olcDatabase={0}config,cn=config
changetype: modify
add: olcSyncRepl
$(
    for ((i=0; i<${#masters[@]}; ++i)); do
      printf 'olcSyncRepl: rid=%03d provider=ldap://%s binddn="cn=config"\n' $((i+1)) ${masters[$i]};
      echo '  bindmethod=simple credentials=x searchbase="cn=config"'
      echo '  type=refreshAndPersist retry="5 5 300 5" timeout=1'
    done
)
-
add: olcMirrorMode
olcMirrorMode: TRUE

EOF
    # database replication
    echo -n "data "
    ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: olcOverlay=syncprov,olcDatabase={1}hdb,cn=config
changetype: add
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
EOF
    ldapmodify -Y EXTERNAL  -H ldapi:/// <<EOF
dn: olcDatabase={1}hdb,cn=config
changetype: modify
replace: olcSuffix
olcSuffix: dc=itzgeek,dc=local
-
replace: olcRootDN
olcRootDN: cn=ldapadm,dc=itzgeek,dc=local
-
replace: olcRootPW
olcRootPW: {SSHA}xtbbtC/1pJclCPzo1n3Szac9jqavSphk
-
add: olcSyncRepl
$(
    for ((i=0; i<${#masters[@]}; ++i)); do
      printf 'olcSyncRepl: rid=%03d provider=ldap://%s binddn="cn=admin,${BASEDN}"\n' $((i+1)) ${masters[$i]};
      echo '  credentials=x searchbase="${BASEDN}" type=refreshOnly'
      echo '  interval=00:00:00:10 retry="5 5 300 5" timeout=1'
    done
)
-
add: olcDbIndex
olcDbIndex: entryUUID  eq
-
add: olcDbIndex
olcDbIndex: entryCSN  eq
-
add: olcMirrorMode
olcMirrorMode: TRUE
EOF
    ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: olcDatabase={1}monitor,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to * by dn.base="gidNumber=0+uidNumber=0,cn=peercred,cn=external, cn=auth" read by dn.base="cn=admin,${BASEDN}" read by * none
EOF
    echo "done."
}

DATE=$(date '+%Y%m%d%H%m')

echo "Configuration ..."

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
export BASEDN="dc=${DOMAIN//./,dc=}"
export PASSWD="$(slappasswd -h {SSHA} -s ${PASSWORD})"

echo "==================== restore or backup ===================="
if restoreconfig; then
    restore || true
else
    restore || (recover && backup)
fi
echo "==================== startbg ===================="
startbg
echo "==================== setConfigPWD ===================="
setConfigPWD
echo "==================== reconfigure ===================="
reconfigure
echo "==================== checkConfig ===================="
checkConfig
echo "==================== checkCerts ===================="
checkCerts
echo "==================== multimaster ===================="
multimaster
echo "==================== stopbg ===================="
stopbg
echo "==================== ********** ===================="
echo "Configuration done."
echo "**** Administrator Password: ${PASSWORD}"
echo "starting slapd ..."
start
echo "Error: slapd terminated"
