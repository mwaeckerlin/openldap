#! /bin/bash

export BASEDN="dc=${DOMAIN//./,dc=}"
test -e /running && \
    ldapsearch -Q -LLL -Y EXTERNAL -H ldapi:/// -b "cn=admin,$BASEDN" dn 2> /dev/null > /dev/null
