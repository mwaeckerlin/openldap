#!/usr/bin/env bash
# Functional e2e tests for mwaeckerlin/openldap against tests/docker-compose.yml.
# The image under test ships no LDAP search tool, so the client container
# carries the OpenLDAP client tools.
# Usage: bash tests/run.sh
set -euo pipefail

cd "$(dirname "$0")/.."
COMPOSE="tests/docker-compose.yml"

cleanup() {
    docker compose -f "$COMPOSE" down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

PASS=0
FAIL=0
_pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $1: $2"; }

BASE="dc=example,dc=com"
ADMIN="cn=admin,${BASE}"
PW="e2e-admin-password"

_dc() { docker compose -f "$COMPOSE" "$@"; }
_client() { _dc exec -T client "$@"; }
_admin() { local cmd="$1" host="$2"; shift 2; _client "$cmd" -x -H "ldap://${host}" -D "${ADMIN}" -w "${PW}" "$@"; }
_search() { local host="$1"; shift; _admin ldapsearch "$host" -LLL -b "${BASE}" "$@" 2>&1 || true; }
_logs() { _dc logs --no-color "$1" 2>&1; }

_wait_bind() {
    local host="$1" dn="$2" password="$3" tries=60
    while (( tries-- > 0 )); do
        _client ldapwhoami -x -H "ldap://${host}" -D "${dn}" -w "${password}" > /dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

_wait_exited() {
    local service="$1" tries=60 id
    id="$(_dc ps -a -q "$service")"
    while (( tries-- > 0 )); do
        [[ "$(docker inspect --format '{{.State.Status}}' "$id")" == "exited" ]] && return 0
        sleep 1
    done
    return 1
}

_exit_code() { docker inspect --format '{{.State.ExitCode}}' "$(_dc ps -a -q "$1")"; }

echo "==> Building test images..."
_dc build --quiet init overlays certs client

echo "==> Writing test certificates..."
_dc run --rm certs > /dev/null

echo "==> Starting test stack..."
_dc up -d --wait openldap generated init example open tls tls-flat
_dc up -d plain overlays client

DIRECTORY="dn: ${BASE}
objectClass: top
objectClass: dcObject
objectClass: organization
o: Example
dc: example

dn: ou=users,${BASE}
objectClass: organizationalUnit
ou: users

dn: ou=groups,${BASE}
objectClass: organizationalUnit
ou: groups

dn: uid=alice,ou=users,${BASE}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: sambaSamAccount
uid: alice
cn: Alice
sn: Example
uidNumber: 2001
gidNumber: 2001
homeDirectory: /home/alice
sambaSID: S-1-5-21-1-2-3-2001
userPassword: alice-password

dn: uid=bob,ou=users,${BASE}
objectClass: inetOrgPerson
uid: bob
cn: Bob
sn: Example
userPassword: bob-password

dn: uid=carol,ou=users,${BASE}
objectClass: inetOrgPerson
uid: carol
cn: Carol
sn: Example

dn: cn=staff,ou=groups,${BASE}
objectClass: groupOfNames
cn: staff
member: uid=alice,ou=users,${BASE}
member: uid=carol,ou=users,${BASE}
"

# F1, F2, F8: the administrator of DOMAIN writes the directory, with the default schemas nis and samba
if OUT="$(_admin ldapadd openldap <<< "${DIRECTORY}" 2>&1)"; then
    _pass "admin_adds_entries_with_default_schemas"
else
    _fail "admin_adds_entries_with_default_schemas" "${OUT}"
fi
if [[ "$(_search openldap '(uid=alice)' sambaSID)" == *"sambaSID: S-1-5-21-1-2-3-2001"* ]]; then
    _pass "admin_reads_entry"
else
    _fail "admin_reads_entry" "uid=alice not found"
fi
if _client ldapwhoami -x -H ldap://openldap -D "${ADMIN}" -w wrong-password > /dev/null 2>&1; then
    _fail "admin_wrong_password_refused" "bind with a wrong password succeeded"
else
    _pass "admin_wrong_password_refused"
fi

# F5: the default access rules
ANON="$(_client ldapsearch -x -LLL -H ldap://openldap -b "${BASE}" '(uid=alice)' dn 2>&1 || true)"
if [[ "${ANON}" != *"uid=alice"* ]]; then
    _pass "anonymous_reads_nothing"
else
    _fail "anonymous_reads_nothing" "an anonymous search returned ${ANON}"
fi
ALICE="uid=alice,ou=users,${BASE}"
if [[ "$(_client ldapsearch -x -LLL -H ldap://openldap -D "${ALICE}" -w alice-password -b "${BASE}" '(uid=bob)' cn 2>&1)" == *"cn: Bob"* ]]; then
    _pass "user_reads_other_entries"
else
    _fail "user_reads_other_entries" "alice cannot read uid=bob"
fi
if _client ldapmodify -x -H ldap://openldap -D "${ALICE}" -w alice-password > /dev/null 2>&1 <<< "dn: ${ALICE}
changetype: modify
replace: description
description: written by alice"; then
    _pass "user_writes_own_entry"
else
    _fail "user_writes_own_entry" "alice cannot change her own entry"
fi
if OUT="$(_client ldapmodify -x -H ldap://openldap -D "${ALICE}" -w alice-password 2>&1 <<< "dn: uid=bob,ou=users,${BASE}
changetype: modify
replace: description
description: written by alice")"; then
    _fail "user_cannot_write_other_entry" "alice changed uid=bob"
elif [[ "${OUT}" == *"Insufficient access"* ]]; then
    _pass "user_cannot_write_other_entry"
else
    _fail "user_cannot_write_other_entry" "unexpected answer: ${OUT}"
fi

# F7: memberOf and referential integrity
if [[ "$(_search openldap '(uid=alice)' memberOf)" == *"memberOf: cn=staff,ou=groups,${BASE}"* ]]; then
    _pass "memberof_shows_group"
else
    _fail "memberof_shows_group" "uid=alice carries no memberOf of cn=staff"
fi
_admin ldapdelete openldap "uid=carol,ou=users,${BASE}" > /dev/null 2>&1 || true
STAFF="$(_search openldap '(cn=staff)' member)"
if [[ "${STAFF}" != *"uid=carol"* && "${STAFF}" == *"uid=alice"* ]]; then
    _pass "refint_removes_deleted_member"
else
    _fail "refint_removes_deleted_member" "cn=staff after deleting carol: ${STAFF}"
fi

# F6: indexes reach the configuration and searches over them answer
CONF="$(_client cat /config/slapd.conf)"
if [[ "${CONF}" == *$'\nindex uid eq\n'* && "${CONF}" == *$'\nindex cn eq,sub\n'* ]]; then
    _pass "indexes_configured"
else
    _fail "indexes_configured" "slapd.conf carries no index lines for uid and cn"
fi
if [[ "$(_search openldap '(cn=Bo*)' uid)" == *"uid: bob"* ]]; then
    _pass "substring_search_over_index"
else
    _fail "substring_search_over_index" "(cn=Bo*) did not find bob"
fi

# F20: the database may grow to MAXSIZE, 10 GiB by default
if [[ "${CONF}" == *$'\nmaxsize 10737418240\n'* ]]; then
    _pass "maxsize_default"
else
    _fail "maxsize_default" "slapd.conf carries no maxsize 10737418240"
fi

# F21: the build argument overlays adds OpenLDAP packages to the image
if _dc cp overlays:/usr/lib/openldap/unique.so - > /dev/null 2>&1; then
    _pass "build_argument_overlays"
else
    _fail "build_argument_overlays" "unique.so missing in an image built with overlays=openldap-overlay-unique"
fi

# F13: the default debug level logs every operation
if [[ "$(_logs openldap)" == *"BIND dn=\"${ADMIN}\""* ]]; then
    _pass "debug_default_logs_operations"
else
    _fail "debug_default_logs_operations" "no BIND line of the administrator in the log"
fi

# F9: the server runs as uid 102
if [[ "$(_client stat -c %u /data/data.mdb)" == "102" ]]; then
    _pass "database_written_by_uid_102"
else
    _fail "database_written_by_uid_102" "data.mdb belongs to uid $(_client stat -c %u /data/data.mdb)"
fi
PASSWD="$(_dc cp openldap:/etc/passwd - | tar -xO)"
if [[ "$(awk -F: '$1 == "ldap" { print $3 }' <<< "$PASSWD")" == "102" ]]; then
    _pass "ldap_user_uid_102"
else
    _fail "ldap_user_uid_102" "the user ldap is not uid 102"
fi

# F3, F10: data survives a restart, and every start saves the database first
_dc restart openldap > /dev/null 2>&1
if _wait_bind openldap "${ADMIN}" "${PW}" && [[ "$(_search openldap '(uid=bob)' uid)" == *"uid: bob"* ]]; then
    _pass "data_survives_restart"
else
    _fail "data_survives_restart" "uid=bob lost after a restart"
fi
BACKUP="$(_client sh -c 'ls /backups/*-startup-data.ldif' 2>/dev/null | tail -1 || true)"
if [[ -n "${BACKUP}" && "$(_client cat "${BACKUP}")" == *"dn: uid=bob,ou=users,${BASE}"* ]]; then
    _pass "startup_backup_written"
else
    _fail "startup_backup_written" "no /var/backups/<date>-startup-data.ldif with uid=bob"
fi
if [[ "$(basename "${BACKUP}")" =~ ^[0-9]{12}-startup-data\.ldif$ ]]; then
    _pass "backup_name_carries_date_and_time"
else
    _fail "backup_name_carries_date_and_time" "backup named «${BACKUP}»"
fi

# F11: a backup in /var/restore replaces the database of a fresh server
_client cp "${BACKUP}" /rrestore/20260101000000-data.ldif
_dc up -d --wait restored
if [[ "$(_search restored '(uid=bob)' uid)" == *"uid: bob"* ]]; then
    _pass "restore_from_backup"
else
    _fail "restore_from_backup" "uid=bob missing after restore: $(_logs restored | tail -5)"
fi
if [[ -z "$(_client ls /rrestore)" && -n "$(_client sh -c 'ls /rbackups/*-restored-data.ldif' 2>/dev/null || true)" ]]; then
    _pass "restored_file_moved_to_backups"
else
    _fail "restored_file_moved_to_backups" "restore: $(_client ls /rrestore), backups: $(_client ls /rbackups)"
fi

# F11: a broken restore file stops the start and leaves the database as it was
_client sh -c 'printf "dn: uid=broken\nthis is no ldif\n" > /rrestore/broken-data.ldif'
_dc restart restored > /dev/null 2>&1 || true
if _wait_exited restored && [[ "$(_exit_code restored)" != "0" && "$(_logs restored)" == *"failed, the database stays as it was"* ]]; then
    _pass "broken_restore_refused"
else
    _fail "broken_restore_refused" "the server did not refuse the broken file: $(_logs restored | tail -5)"
fi
_client rm /rrestore/broken-data.ldif
_dc start restored > /dev/null 2>&1
if _wait_bind restored "${ADMIN}" "${PW}" && [[ "$(_search restored '(uid=bob)' uid)" == *"uid: bob"* ]]; then
    _pass "database_kept_after_broken_restore"
else
    _fail "database_kept_after_broken_restore" "uid=bob lost after the broken restore"
fi

# F11: two candidates are refused instead of guessing
_client sh -c 'cp /rbackups/*-restored-data.ldif /rrestore/a-data.ldif && cp /rrestore/a-data.ldif /rrestore/b-data.ldif'
_dc restart restored > /dev/null 2>&1 || true
if _wait_exited restored && [[ "$(_logs restored)" == *"leave exactly the one to restore"* ]]; then
    _pass "two_restore_files_refused"
else
    _fail "two_restore_files_refused" "$(_logs restored | tail -5)"
fi

# F4: a generated password is logged, kept in /etc/ldap/password and survives a restart
GENERATED="$(_logs generated | sed -n 's/.*password: \([A-Za-z0-9]\{20\}\)$/\1/p' | head -1)"
if [[ -n "${GENERATED}" ]] && _wait_bind generated "cn=admin,dc=generated,dc=example" "${GENERATED}"; then
    _pass "generated_password_logged_and_valid"
else
    _fail "generated_password_logged_and_valid" "no usable password in the log"
fi
if [[ "$(_client cat /genconfig/password)" == "${GENERATED}" ]]; then
    _pass "generated_password_stored"
else
    _fail "generated_password_stored" "/etc/ldap/password differs from the logged password"
fi
_dc restart generated > /dev/null 2>&1
if _wait_bind generated "cn=admin,dc=generated,dc=example" "${GENERATED}"; then
    _pass "generated_password_survives_restart"
else
    _fail "generated_password_survives_restart" "the password changed with the restart"
fi
if _dc exec -T generated /usr/bin/init --healthcheck; then
    _pass "healthcheck_with_stored_password"
else
    _fail "healthcheck_with_stored_password" "the check does not find the stored password"
fi

# F12: INIT_SCRIPT and CUSTOM_SCHEMAS from example/
INIT="$(_search init '(uid=user1)' userAccountControl)"
if [[ "${INIT}" == *"userAccountControl: 512"* ]]; then
    _pass "init_script_with_custom_schema"
else
    _fail "init_script_with_custom_schema" "uid=user1 with userAccountControl missing: ${INIT}"
fi
_dc restart init > /dev/null 2>&1
if _wait_bind init "${ADMIN}" "${PW}" && [[ "$(_search init '(uid=user2)' uid)" == *"uid: user2"* ]]; then
    _pass "init_script_again_on_restart"
else
    _fail "init_script_again_on_restart" "the server did not come back with the entries of INIT_SCRIPT"
fi

# F22: INIT_LDIF and CUSTOM_SCHEMA inline, from example/docker-compose.yaml as delivered
EXAMPLE_CONF="$(_dc cp example:/etc/ldap/slapd.conf - | tar -xO)"
if [[ "${EXAMPLE_CONF}" == *$'\ninclude /run/openldap/custom.schema\n'* ]]; then
    _pass "custom_schema_inline_configured"
else
    _fail "custom_schema_inline_configured" "slapd.conf of the example includes no /run/openldap/custom.schema"
fi
if [[ "${CONF}" != *"/run/openldap/custom.schema"* ]]; then
    _pass "custom_schema_default_unset"
else
    _fail "custom_schema_default_unset" "slapd.conf without CUSTOM_SCHEMA includes /run/openldap/custom.schema"
fi
_example() { _client ldapsearch -x -LLL -H ldap://example -D "${ADMIN}" -w 123 -b "${BASE}" "$@" 2>&1 || true; }
if [[ "$(_example '(uid=user1)' userAccountControl)" == *"userAccountControl: 512"* ]]; then
    _pass "init_ldif_with_inline_schema"
else
    _fail "init_ldif_with_inline_schema" "uid=user1 with userAccountControl missing: $(_logs example | tail -5)"
fi
_dc restart example > /dev/null 2>&1
if _wait_bind example "${ADMIN}" 123 && [[ "$(_example '(uid=user2)' uid)" == *"uid: user2"* ]]; then
    _pass "init_ldif_again_on_restart"
else
    _fail "init_ldif_again_on_restart" "the server did not come back with the entries of INIT_LDIF"
fi
if [[ "$(_logs openldap)" != *"applying INIT_LDIF"* ]]; then
    _pass "init_ldif_default_unset"
else
    _fail "init_ldif_default_unset" "a server without INIT_LDIF applied INIT_LDIF"
fi

# F5, F8: ACCESS_RULES and SCHEMAS of its own
_admin ldapadd open > /dev/null 2>&1 <<< "dn: ${BASE}
objectClass: dcObject
objectClass: organization
o: Example
dc: example

dn: uid=dave,${BASE}
objectClass: inetOrgPerson
objectClass: ldapPublicKey
uid: dave
cn: Dave
sn: Example
sshPublicKey: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE2e2etestkey dave" || true
if [[ "$(_client ldapsearch -x -LLL -H ldap://open -b "${BASE}" '(uid=dave)' sshPublicKey 2>&1)" == *"sshPublicKey: ssh-ed25519"* ]]; then
    _pass "custom_access_rules_and_schema"
else
    _fail "custom_access_rules_and_schema" "anonymous read of an openssh-lpk entry failed"
fi
if OUT="$(_admin ldapadd open 2>&1 <<< "dn: uid=erin,${BASE}
objectClass: inetOrgPerson
objectClass: sambaSamAccount
uid: erin
cn: Erin
sn: Example
sambaSID: S-1-5-21-1-2-3-2002")"; then
    _fail "schema_not_listed_is_not_loaded" "samba entry accepted without samba in SCHEMAS"
else
    _pass "schema_not_listed_is_not_loaded"
fi

# F14: TLS in both certificate layouts, ldaps on 636 and StartTLS on 389
for host in tls tls-flat; do
    if _client env LDAPTLS_CACERT=/ssl-live/live/example.com/chain.pem \
           ldapwhoami -x -H "ldaps://${host}:636" -D "${ADMIN}" -w "${PW}" > /dev/null 2>&1; then
        _pass "ldaps_${host}"
    else
        _fail "ldaps_${host}" "no verified ldaps bind on ${host}:636"
    fi
    if _client env LDAPTLS_CACERT=/ssl-live/live/example.com/chain.pem \
           ldapwhoami -ZZ -x -H "ldap://${host}" -D "${ADMIN}" -w "${PW}" > /dev/null 2>&1; then
        _pass "starttls_${host}"
    else
        _fail "starttls_${host}" "no StartTLS on ${host}:389"
    fi
done
if _client env LDAPTLS_CACERT=/ssl-live/live/example.com/chain.pem \
       ldapwhoami -x -H ldaps://openldap:636 -D "${ADMIN}" -w "${PW}" > /dev/null 2>&1; then
    _fail "no_ldaps_without_certificate" "openldap answers ldaps without a certificate"
else
    _pass "no_ldaps_without_certificate"
fi
TLS12="$(_client sh -c 'echo | openssl s_client -connect tls:636 -tls1_2 -CAfile /ssl-live/live/example.com/chain.pem 2>&1' || true)"
TLS11="$(_client sh -c 'echo | openssl s_client -connect tls:636 -tls1_1 2>&1' || true)"
if [[ "${TLS12}" == *"Verify return code: 0 (ok)"* && "${TLS11}" != *"Protocol  : TLSv1.1"* ]]; then
    _pass "tls_1_2_minimum"
else
    _fail "tls_1_2_minimum" "TLS 1.2 not verified or TLS 1.1 accepted"
fi
_dc up -d tls-locked > /dev/null 2>&1 || true
if _wait_exited tls-locked && [[ "$(_logs tls-locked)" == *"cannot read it"* ]]; then
    _pass "unreadable_key_named"
else
    _fail "unreadable_key_named" "$(_logs tls-locked | tail -5)"
fi

# F15: the health check of the image
_health() { docker inspect --format '{{.State.Health.Status}}' "$(_dc ps -q "$1")" 2>/dev/null || true; }
STATE=""
for _ in $(seq 1 90); do
    STATE="$(_health plain)"
    [[ "$STATE" == "healthy" ]] && break
    sleep 1
done
if [[ "$STATE" == "healthy" ]]; then
    _pass "image_healthcheck_healthy"
else
    _fail "image_healthcheck_healthy" "health state «${STATE}», expected healthy from the image's own HEALTHCHECK"
fi
if _dc exec -T -e PASSWORD=wrong-password plain /usr/bin/init --healthcheck 2>/dev/null; then
    _fail "healthcheck_refuses_wrong_password" "the check passed with a wrong password"
else
    _pass "healthcheck_refuses_wrong_password"
fi

# F16: SIGTERM reaches slapd, which stops cleanly
_dc stop plain > /dev/null 2>&1
if [[ "$(_exit_code plain)" == "0" ]]; then
    _pass "stops_cleanly"
else
    _fail "stops_cleanly" "exit code $(_exit_code plain) after docker stop"
fi

echo ""
echo "==> Functional results: ${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -ne 0 ]]; then
    _dc logs --no-color --tail 40 2>&1 || true
    exit 1
fi
