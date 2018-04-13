#! /bin/bash

if test -z "${PASSWORD}"; then
    if test -e /etc/ldap/password; then
        export PASSWORD="$(cat /etc/ldap/password)"
    else
	exit 1
    fi
fi
export BASEDN="dc=${DOMAIN//./,dc=}"
ldapsearch -H ldap:/// -x -D "cn=admin,$BASEDN" -w "${PASSWORD}" 2> /dev/null > /dev/null
case "$?" in
    (0) exit 0;;  # found
    (32) exit 0;; # running, but not yet initialized
    (*) exit 1;;  # failed
esac
