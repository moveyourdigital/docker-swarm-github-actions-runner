#!/usr/bin/env bash
# Test of the GitHub App JWT in start.sh: signature and claims.
# Runs in the runner image (needs openssl, jq and sudo):
#
#   docker run --rm -v "$PWD:/src:ro" --entrypoint /src/tests/app-jwt.sh runner:test
set -euo pipefail

SRC="$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Load only the JWT functions from start.sh.
eval "$(sed -n '/^base64url() /p; /^app_jwt() {/,/^}/p' "${SRC}/start.sh")"

openssl genrsa -out "${WORK}/key.pem" 2048 2>/dev/null
openssl rsa -in "${WORK}/key.pem" -pubout -out "${WORK}/pub.pem" 2>/dev/null
export APP_ID=12345
export APP_PRIVATE_KEY_FILE="${WORK}/key.pem"

jwt="$(app_jwt)"
IFS=. read -r header payload signature <<<"${jwt}"

decode() {
  local s="$1"
  s="${s//-/+}"; s="${s//_//}"
  while (( ${#s} % 4 )); do s="${s}="; done
  printf '%s' "${s}" | openssl base64 -d -A
}

decode "${header}" | jq -e '.alg == "RS256" and .typ == "JWT"' >/dev/null || fail "header"
echo "ok: header"

now=$(date +%s)
decode "${payload}" | jq -e --argjson now "${now}" \
  '.iss == "12345" and .iat <= $now and .exp > $now and (.exp - .iat) <= 600' >/dev/null \
  || fail "claims"
echo "ok: claims (iss, iat, exp, max. 10 minutes)"

decode "${signature}" > "${WORK}/sig"
printf '%s.%s' "${header}" "${payload}" \
  | openssl dgst -sha256 -verify "${WORK}/pub.pem" -signature "${WORK}/sig" >/dev/null \
  || fail "signature"
echo "ok: RS256 signature"

echo "PASS: GitHub App JWT"
