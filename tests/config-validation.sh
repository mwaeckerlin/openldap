#!/usr/bin/env bash
# Config validation: init must refuse every environment value it cannot use.
#
# Every value ends up in slapd.conf or on the command line of slapd. A line
# break would add directives of its own (a second rootpw, an include), a
# malformed value would stop slapd with an unclear parser error. The image is
# shell-free, so the checks run from outside through `--healthcheck`, which
# validates first and never needs a server; `--network none` pins that, and
# `--pull=never` keeps a stale registry image from being tested.
#
# Usage: tests/config-validation.sh IMAGE

set -uo pipefail

IMAGE="${1:-mwaeckerlin/openldap}"

PASS=0
FAIL=0
declare -a FAILED_NAMES

_pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
_fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "  FAIL  $1: $2"; }

_image_exists() {
    if docker image inspect "${IMAGE}" > /dev/null 2>&1; then
        return 0
    fi
    _fail "image_exists" "image not built — run 'npm run build' first"
    return 1
}

_run() {
    timeout 30 docker run --rm --pull=never --network none "$@" "${IMAGE}" --healthcheck 2>&1
}

# A malformed value must abort with a message that names the variable.
_reject() {
    local name="$1" var="$2" value="$3" expected="${4:-invalid $2}"
    local out rc
    out=$(_run -e DOMAIN=example.com -e "${var}=${value}")
    rc=$?
    if [[ ${rc} -ne 0 && "${out}" == *"${expected}"* ]]; then
        _pass "reject_${name}"
    else
        _fail "reject_${name}" "value not rejected (rc=${rc}): ${out}"
    fi
}

# A usable value must pass validation; the bind itself fails, no server runs.
_accept() {
    local name="$1"
    shift
    local out
    out=$(_run -e DOMAIN=example.com "$@")
    if [[ "${out}" == *"invalid "* || "${out}" == *"ERROR"* ]]; then
        _fail "accept_${name}" "valid value rejected: ${out}"
    else
        _pass "accept_${name}"
    fi
}

echo "==> Config validation: unusable environment must be refused"

_image_exists || { echo ""; echo "==> Config validation results: 0 passed, 1 failed"; exit 1; }

_reject domain_missing          DOMAIN         ""                                   "Specifying a domain is mandatory"
_reject domain_bad              DOMAIN         "exa mple.com"
_reject domain_injection        DOMAIN         $'example.com\nrootpw secret'
_reject domain_empty_label      DOMAIN         "example..com"
_reject password_line_break     PASSWORD       $'secret\nrootpw other'
_reject debug_bad               DEBUG          "256;stats"
_reject maxsize_bad             MAXSIZE        "10G"
_reject access_rules_injection  ACCESS_RULES   $'access to * by * read\nrootpw secret'
_reject access_rules_bad        ACCESS_RULES   "allow everything"
_reject indexes_injection       INDEXES        $'index uid eq\nrootpw secret'
_reject indexes_bad             INDEXES        "uid eq"
_reject memberof_bad            MEMBEROF       "yes"
_reject schemas_unknown         SCHEMAS        "cosine no-such-schema"
_reject schemas_path            SCHEMAS        "cosine ../../etc/passwd"
_reject custom_schemas_relative CUSTOM_SCHEMAS "schemas"
_reject init_script_relative    INIT_SCRIPT    "init.ldif"

_accept defaults
_accept explicit_values \
    -e PASSWORD='S3cr3t with spaces, "quotes" and \backslash' \
    -e DEBUG=stats \
    -e MAXSIZE=1073741824 \
    -e ACCESS_RULES='access to attrs=userPassword by self write by anonymous auth by * none access to * by users read' \
    -e INDEXES=' index uid eq index cn eq,sub' \
    -e MEMBEROF=1 \
    -e CUSTOM_SCHEMAS=/var/schemas \
    -e INIT_SCRIPT=/var/init/init.ldif
_accept every_shipped_schema \
    -e SCHEMAS='cosine inetorgperson nis samba openssh-lpk ldapns misc openldap collective corba duaconf dyngroup java'

echo ""
echo "==> Config validation results: ${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -gt 0 ]]; then
    echo "==> Failed checks: ${FAILED_NAMES[*]}"
    exit 1
fi
