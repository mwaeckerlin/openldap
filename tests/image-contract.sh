#!/usr/bin/env bash
# Image contract: the shipped image must be headless.
#
# A production image must contain nothing that lets an attacker who
# reaches code execution pivot: no shell, no perl, no busybox. The
# image ships the service binary, its libraries and its configuration
# — nothing else. The check runs the interpreter as the container
# entrypoint: a headless image has no `ls` either, so a missing tool
# must be detected from outside.
#
# Usage: tests/image-contract.sh IMAGE...

set -uo pipefail

PASS=0
FAIL=0
declare -a FAILED_NAMES

_pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
_fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "  FAIL  $1: $2"; }

_image_exists() {
    local image="$1"
    if docker image inspect "${image}" > /dev/null 2>&1; then
        return 0
    fi
    _fail "${image}_image_exists" "image not built — run 'npm run build' first"
    return 1
}

_no_interpreter() {
    local image="$1" path="$2" name="$3"
    shift 3
    if docker run --rm --pull=never --entrypoint "${path}" "${image}" "$@" > /dev/null 2>&1; then
        _fail "${image}_no_${name}" "${path} exists — image is not headless"
    else
        _pass "${image}_no_${name}"
    fi
}

echo "==> Image contract: headless images"

for image in "$@"; do
    _image_exists "${image}" || continue
    _no_interpreter "${image}" /bin/sh      sh      -c :
    _no_interpreter "${image}" /bin/bash    bash    -c :
    _no_interpreter "${image}" /bin/busybox busybox ls /
    _no_interpreter "${image}" /usr/bin/perl perl   -e 1
done

echo ""
echo "==> Image contract results: ${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -gt 0 ]]; then
    echo "==> Failed contracts: ${FAILED_NAMES[*]}"
    exit 1
fi
