#!/bin/bash -ex

if test -e /firstrun; then
    if test -z "${DOMAIN}"; then
        echo "Specifying a domain is mandatory, use -e DOMAIN=example.org" 1>&2
        exit 1
    fi
    if test -z "${ORGANIZATION}"; then
        echo "Specifying am organization is mandatory, use -e ORGANIZATION=\"Example Organization\"" 1>&2
        exit 1
    fi
    if test -z "${PASSWORD}"; then
        export PASSWORD=$(pwgen 20 1)
        echo "Administrator Password: $PASSWORD"
    fi
    echo "Configuration ..."
    (
        echo "slapd slapd/internal/generated_adminpw password ${PASSWORD}"
        echo "slapd slapd/internal/adminpw password ${PASSWORD}"
        echo "slapd slapd/password1 password ${PASSWORD}"
        echo "slapd slapd/password2 password ${PASSWORD}"
        echo "slapd shared/organization string ${ORGANIZATION}"
        echo "slapd slapd/purge_database boolean false"
        echo "slapd slapd/backend select HDB"
        echo "slapd slapd/allow_ldap_v2 boolean false"
        echo "slapd slapd/domain string ${DOMAIN}"
    ) | debconf-set-selections
    dpkg-reconfigure -f noninteractive slapd
    /usr/sbin/slapd -d ${DEBUG} \
        -h "ldap:/// ldapi:///" \
        -g openldap -u openldap \
        -F /etc/ldap/slapd.d &
    PID=$!
    sleep 5
    (
        echo "dn: cn=config"
        echo "changetype: modify"
        echo
        echo "dn: olcDatabase={0}config,cn=config"
        echo "changetype: modify"
        echo "add: olcRootDN"
        echo "olcRootDN: cn=admin,cn=config"
        echo
        echo "dn: olcDatabase={0}config,cn=config"
        echo "changetype: modify"
        echo "add: olcRootPW"
        echo "olcRootPW: $(slappasswd -s '${PASSWORD}')"
        echo
        echo "dn: olcDatabase={0}config,cn=config"
        echo "changetype: modify"
        echo "delete: olcAccess"
        echo "echo "dn: cn=config""
        #echo "changetype: modify"
        #echo
        #echo "dn: olcDatabase={0}config,cn=config"
        #echo "changetype: modify"
        #echo "replace: olcRootPW"
        #echo "olcRootPW: $(slappasswd -s '${PASSWORD}')"
    )  | ldapmodify -Y external -H ldapi:///
    kill $PID
    rm /firstrun
    echo "Configuration done."
fi
echo "starting slapd ..."
/usr/sbin/slapd -d ${DEBUG} \
    -h "ldap:/// ldapi:///" \
    -g openldap -u openldap \
    -F /etc/ldap/slapd.d
