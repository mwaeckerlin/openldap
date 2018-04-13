#!/bin/sh -e

function error() {
    echo "ERROR: $*" 1>&2
    exit
}

# variables
DATE=$(date '+%Y%m%d%H%m')
if test -z "${DOMAIN}"; then
    error "Specifying a domain is mandatory, use -e DOMAIN=example.org"
fi
#if test -z "${ORGANIZATION}"; then
#    error "Specifying an organization is mandatory, use -e ORGANIZATION=\"Example Organization\""
#fi
if test -z "${PASSWORD}"; then
    if test -e /etc/ldap/password; then
        export PASSWORD="$(cat /etc/ldap/password)"
    else
	apk update --no-cache > /dev/null
	apk add --no-cache pwgen > /dev/null
        export PASSWORD=$(pwgen 20 1)
	apk del --purge pwgen > /dev/null
	/cleanup.sh
	echo "password: $PASSWORD"
        echo "$PASSWORD" > /etc/ldap/password
	chmod go= /etc/ldap/password
    fi
fi
export BASEDN="dc=${DOMAIN//./,dc=}"
export PASSWD="$(slappasswd -h {SSHA} -s ${PASSWORD})"

# configure
cat > /tmp/update-config.sed <<EOF
/^\s*suffix\b/csuffix\t\t"${BASEDN}"
/^\s*rootdn\b/crootdn\t\t"cn=admin,${BASEDN}"
/^\s*rootpw\b/crootpw\t\t${PASSWD}
/^\s*directory\b/cdirectory /var/lib/ldap
s/^\s*access/# &/
s/# \?\(\s*\(access to \*\|by self write\|by users read\|by anonymous auth\)\)/\1/
EOF
sed -f /tmp/update-config.sed /etc/openldap/slapd.conf > /etc/ldap/slapd.conf
if test "$MEMBEROF" -eq 1; then
    cat >> /etc/ldap/slapd.conf <<EOF
moduleload refint
overlay refint
refint_attributes member
refint_nothing "cn=admin,${BASEDN}"
moduleload memberof
overlay memberof
memberof-group-oc groupOfNames
memberof-member-ad member
memberof-memberof-ad memberOf
memberof-refint true
EOF
fi
rm /tmp/update-config.sed
for schema in $SCHEMAS; do
    echo "include /etc/openldap/schema/${schema}.schema" >> /etc/ldap/slapd.conf
done
if test -e /ssl/live/${DOMAIN}/chain.pem \
        -a -e /ssl/live/${DOMAIN}/privkey.pem \
        -a -e /ssl/live/${DOMAIN}/cert.pem; then
    cat >> /etc/ldap/slapd.conf <<EOF
TLSCipherSuite HIGH:MEDIUM:-SSLv2:-SSLv3
TLSCertificateFile /ssl/live/${DOMAIN}/cert.pem
TLSCertificateKeyFile /ssl/live/${DOMAIN}/privkey.pem
TLSCACertificateFile /ssl/live/${DOMAIN}/chain.pem
# apk add ca-certificates +:
#TLSCACertificatePath /usr/share/ca-certificates/mozilla
EOF
    SSL_HOSTS=" ldaps:/// ldapi:///"
else
    SSL_HOSTS=""
fi

# backup status quo
if test -n "$(ls -A /var/lib/ldap)"; then
    slapcat -f /etc/ldap/slapd.conf > /var/backups/${DATE}-startup-data.ldif
fi

# restore if required
if test -e /var/restore/*data.ldif; then
    rm -r /var/lib/ldap/* || true
    slapadd -f /etc/ldap/slapd.conf -l /var/restore/*data.ldif 2> /dev/null
    mv /var/restore/*data.ldif /var/backups/${DATE}-restored-data.ldif
fi

# run
chown -R ${USER}.${GROUP} /var/lib/ldap /etc/ldap
chmod 700 /var/lib/ldap
/usr/sbin/slapd -u $USER -g $GROUP -d ${DEBUG} -h "ldap:///${SSL_HOSTS}" -f /etc/ldap/slapd.conf

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
