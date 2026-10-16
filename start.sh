#!/usr/bin/env bash
set -euo pipefail

: "${ORGANIZATION:?ORGANIZATION is required}"
: "${ACCESS_TOKEN_FILE:?ACCESS_TOKEN_FILE is required}"

# A restarted container (Compose) keeps the old runtime state of dockerd.
# A stale PID file stops dockerd if a new process gets the same PID.
sudo rm -rf /var/run/docker.pid /var/run/docker.sock /var/run/docker

# It also keeps the inner Docker data (containers, volumes, images) of the
# previous job. Delete it: each job starts with a clean Docker state.
sudo mkdir -p /var/lib/docker && sudo find /var/lib/docker -mindepth 1 -delete

# Start the inner Docker daemon and wait until it is ready.
sudo dockerd >/tmp/dockerd.log 2>&1 &
for _ in $(seq 60); do
  docker info >/dev/null 2>&1 && break
  sleep 1
done
if ! docker info >/dev/null 2>&1; then
  echo "dockerd did not start. Check the log below and the Sysbox runtime." >&2
  cat /tmp/dockerd.log >&2
  exit 1
fi

# Get a short-lived registration or removal token with the PAT.
# sudo: a Compose file secret keeps its host owner and mode (0600).
github_token() {
  curl -fsS -X POST \
    -H "Authorization: Bearer $(sudo cat "${ACCESS_TOKEN_FILE}")" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${ORGANIZATION}/actions/runners/$1-token" \
    | jq -r .token
}

REG_TOKEN=$(github_token registration || true)
if [[ -z "${REG_TOKEN}" || "${REG_TOKEN}" == "null" ]]; then
  echo "Could not get a registration token. Check the PAT and ORGANIZATION." >&2
  exit 1
fi

# A restarted container (Compose) keeps its old local configuration.
# Remove it. "--replace" then replaces the old server-side registration.
rm -f .runner .credentials .credentials_rsaparams

# Ephemeral: the runner takes one job, then deregisters itself.
./config.sh \
  --url "https://github.com/${ORGANIZATION}" \
  --token "${REG_TOKEN}" \
  --name "$(hostname)" \
  --labels "${RUNNER_LABELS:-sysbox}" \
  --ephemeral --unattended --replace

# On container stop, remove the registration. Else an idle runner stays in
# the list as "offline". A busy runner cannot be removed: GitHub then
# removes it after the job.
deregister() {
  echo "Stopping. Removing the runner registration..."
  ./config.sh remove --token "$(github_token remove)" || true
  kill -TERM "${RUNNER_PID}" 2>/dev/null || true
  exit 143
}
trap deregister TERM INT

./run.sh &
RUNNER_PID=$!
wait "${RUNNER_PID}"
