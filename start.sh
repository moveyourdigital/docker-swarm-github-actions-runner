#!/usr/bin/env bash
set -euo pipefail

: "${ORGANIZATION:?ORGANIZATION is required}"
: "${ACCESS_TOKEN_FILE:?ACCESS_TOKEN_FILE is required}"

# Start the inner Docker daemon and wait until it is ready.
sudo dockerd >/tmp/dockerd.log 2>&1 &
for _ in $(seq 60); do
  docker info >/dev/null 2>&1 && break
  sleep 1
done
if ! docker info >/dev/null 2>&1; then
  echo "dockerd did not start. Is the Sysbox runtime in use?" >&2
  cat /tmp/dockerd.log >&2
  exit 1
fi

# Get a short-lived registration token with the PAT.
REG_TOKEN=$(curl -fsS -X POST \
  -H "Authorization: Bearer $(cat "${ACCESS_TOKEN_FILE}")" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/orgs/${ORGANIZATION}/actions/runners/registration-token" \
  | jq -r .token)
if [[ -z "${REG_TOKEN}" || "${REG_TOKEN}" == "null" ]]; then
  echo "Could not get a registration token. Check the PAT and ORGANIZATION." >&2
  exit 1
fi

# Ephemeral: the runner takes one job, then deregisters itself.
./config.sh \
  --url "https://github.com/${ORGANIZATION}" \
  --token "${REG_TOKEN}" \
  --name "$(hostname)" \
  --labels "${RUNNER_LABELS:-sysbox}" \
  --ephemeral --unattended --replace

exec ./run.sh
