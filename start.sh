#!/bin/bash -e
rm /running || true

if test -t 1; then

    # see if it supports colors...
    ncolors=$(tput colors)

    if test -n "$ncolors" && test $ncolors -ge 8; then
        bold="$(tput bold)"
        underline="$(tput smul)"
        standout="$(tput smso)"
        normal="$(tput sgr0)"
        black="$(tput setaf 0)"
        red="$(tput setaf 1)"
        green="$(tput setaf 2)"
        yellow="$(tput setaf 3)"
        blue="$(tput setaf 4)"
        magenta="$(tput setaf 5)"
        cyan="$(tput setaf 6)"
        white="$(tput setaf 7)"
    fi
fi

stdbuf -i0 -o0 -e0 echo

function error() {
    echo "${bold}${red}error${normal}"
    echo "${bold}${red}ERROR: $*${normal}" 1>&2
    exit 1
}

function section() {
    echo "${bold}${white}$*${normal}"
}

function log() {
    echo -n "${bold}${yellow}$*${normal}"
}

function logdone() {
    if test -z "$*"; then
        echo "${bold}${green}done.${normal}"
    else
        echo "${bold}${green}$*${normal}"
    fi
}

function logerror() {
    if test -z "$*"; then
        echo "${bold}${red}error.${normal}"
    else
        echo "${bold}${red}$*${normal}"
    fi
}

function restoreconfig() {
    log  "  --> restoring configuration ... "
    for f in /etc/ldap /var/lib/ldap; do
        chown -R openldap.openldap $f
    done
    logdone
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
    log "  --> starting openldap in background ... "
    fixperm
    /usr/sbin/slapd -d 0 \
    -h "ldap:/// ldapi:///" \
    -g openldap -u openldap \
    -F /etc/ldap/slapd.d &
    PID=$!
    sleep 5
    for ((i=0; i<10; ++i)); do
        if pgrep slapd > /dev/null; then
            break
        fi
        log ". "
        sleep 1;
    done
    sleep 5
    if test "$PID" != "$(pgrep slapd)"; then
        error "failed to start openldap server"
    fi
    logdone
}

function stopbg() {
    log "  --> stopping openldap running in background ... "
    kill $PID
    while pgrep slapd > /dev/null; do sleep 1; done
    logdone
}

function checkConfig() {
    log "  --> checking configuration ... "
    if ! ldapsearch -Q -LLL -Y EXTERNAL -H ldapi:/// -b cn=config dn 2>/dev/null >/dev/null; then
        error "failed to create config"
    fi
    logdone
}

function debian-script() {
    log "debian-script "
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
    dpkg-reconfigure -f noninteractive slapd 2> /dev/null > /dev/null
    logdone
}

function checkCerts() {
    local certfile=
    local keyfile=
    log "  --> check certificates ... "
    if test -e /ssl/live/${DOMAIN}/chain.pem \
            -a -e /ssl/live/${DOMAIN}/privkey.pem \
            -a -e /ssl/live/${DOMAIN}/cert.pem; then
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
        logdone "configured."
    else
        logerror "not configured."
        section "   to activate TLS/SSL, please mount /etc/letsencrypt to /ssl"
    
    fi
}

function setConfigPWD() {
    log "  --> set cn=config password ... "
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
    logdone
}

function disallowAnonymousBind() {
    log "  --> disallow anonymous bind ... "
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
    logdone
}

function reconfigure() {
    log "  --> reconfigure: ${ORGANIZATION} on ${DOMAIN} ... "
    if ldapadd -c -Y external -H ldapi:/// > /dev/null 2> /dev/null; then
        logdone
    else
        res=$?
        case "$res" in
            (68) logdone "already configured";;
            (*) logerror "failed: $res.";;
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
    log "  --> backup ... "
    slapcat -n 0 -l /var/backups/${DATE}-startup-config.ldif && log "${DATE}-startup-config.ldif "
    slapcat -n 1 -l /var/backups/${DATE}-startup-data.ldif && log "${DATE}-startup-data.ldif "
    logdone
}

function recover() {
    log "  --> recover database... "
    cd /var/lib/ldap
    db_recover -v
    logdone
}

function restore() {
    if ! test -e /var/restore/*config.ldif -o -e /var/restore/*data.ldif; then
        return 1
    else
        log "  --> restoring ... "
        if test -e /var/restore/*config.ldif; then
            log "config "
            rm -rf /etc/ldap/slapd.d/*
            slapadd -c -n 0 -F /etc/ldap/slapd.d -l /var/restore/*config.ldif ${MULTI_MASTER_REPLICATION:+-w}
            chown -R openldap.openldap /etc/ldap/slapd.d
            mv /var/restore/*config.ldif /var/backups/${DATE}-restored-config.ldif
        fi
        if test -e /var/restore/*data.ldif; then
            log "data "
            rm -rf /var/lib/ldap/*
            slapadd -c -n 1 -F /etc/ldap/slapd.d -l /var/restore/*data.ldif ${MULTI_MASTER_REPLICATION:+-w}
            mv /var/restore/*data.ldif /var/backups/${DATE}-restored-data.ldif
        fi
        logdone
    fi
    return 0
}

function multimaster() {
    if test -z "$MULTI_MASTER_REPLICATION"; then
        return
    fi
    if test -z "$SERVER_NAME" || ! [[ " ${MULTI_MASTER_REPLICATION} " =~ " ${SERVER_NAME} " ]];  then
        error "SERVER_NAME must be one of ${MULTI_MASTER_REPLICATION} in MULTI_MASTER_REPLICATION"
    fi
    log "  --> multimaster ... "
    # load module
    log "module "
    ldapadd -c -Y external -H ldapi:/// > /dev/null 2> /dev/null <<EOF
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
    log "config for ${SERVER_NAME} as $serverid "
    log "first "
    ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: cn=config
changetype: modify
add: olcServerID
olcServerID: ${serverid}
EOF
    log "second "
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
    log "data "
    log "first "
    ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: olcOverlay=syncprov,olcDatabase={1}hdb,cn=config
changetype: add
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
EOF
    log "second "
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
    log "access "
    ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: olcDatabase={1}monitor,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to * by dn.base="gidNumber=0+uidNumber=0,cn=peercred,cn=external, cn=auth" read by dn.base="cn=admin,${BASEDN}" read by * none
EOF
    logdone
}

function memberof() {
    log "  --> memberof ... "
    if ! ldapsearch -Q -LLL -Y EXTERNAL -H ldapi:/// -b olcOverlay={0}memberof,olcDatabase={1}hdb,cn=config 2> /dev/null > /dev/null; then
        log "module "
        ldapadd -c -Y external -H ldapi:/// > /dev/null 2> /dev/null <<EOF
dn: cn=module,cn=config
cn: module
objectClass: olcModuleList
olcModuleLoad: memberof
olcModulePath: /usr/lib/ldap

dn: olcOverlay={0}memberof,olcDatabase={1}hdb,cn=config
objectClass: olcConfig
objectClass: olcMemberOf
objectClass: olcOverlayConfig
objectClass: top
olcOverlay: memberof
olcMemberOfDangling: ignore
olcMemberOfRefInt: TRUE
olcMemberOfGroupOC: groupOfNames
olcMemberOfMemberAD: member
olcMemberOfMemberOfAD: memberOf
EOF
        log "refint "
        ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: cn=module{1},cn=config
add: olcmoduleload
olcmoduleload: refint
EOF
        ldapadd -c -Y external -H ldapi:/// > /dev/null 2> /dev/null <<EOF
dn: olcOverlay={1}refint,olcDatabase={1}hdb,cn=config
objectClass: olcConfig
objectClass: olcOverlayConfig
objectClass: olcRefintConfig
objectClass: top
olcOverlay: {1}refint
olcRefintAttribute: memberof member manager owner
EOF
        logdone
    else
        logdone "already configured"
    fi
}

DATE=$(date '+%Y%m%d%H%m')

section "Configuration ..."

if test -z "${DOMAIN}"; then
    error "Specifying a domain is mandatory, use -e DOMAIN=example.org"
fi
if test -z "${ORGANIZATION}"; then
    error "Specifying an organization is mandatory, use -e ORGANIZATION=\"Example Organization\""
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

section "==================== restore or backup ===================="
debian-script
restoreconfig
restore || (recover && backup)
section "==================== startbg ===================="
startbg
section "==================== reconfigure ===================="
reconfigure
section "==================== checkConfig ===================="
checkConfig
section "==================== setConfigPWD ===================="
setConfigPWD
section "==================== memberof ===================="
memberof
section "==================== checkCerts ===================="
checkCerts
section "==================== multimaster ===================="
multimaster
section "==================== stopbg ===================="
stopbg
section "==================== ********** ===================="
section "Configuration done."
section "**** Administrator Password: ${PASSWORD}"
section "starting slapd ..."
touch /running
start
error "slapd terminated"
