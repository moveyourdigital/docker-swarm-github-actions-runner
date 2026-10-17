#!/usr/bin/env bash
set -euo pipefail

: "${ORGANIZATION:?ORGANIZATION is required}"

# Authentication: a GitHub App (APP_ID and APP_PRIVATE_KEY_FILE) or a PAT
# (ACCESS_TOKEN_FILE). The GitHub App has priority.
if [[ -z "${APP_ID:-}" || -z "${APP_PRIVATE_KEY_FILE:-}" ]]; then
  : "${ACCESS_TOKEN_FILE:?set ACCESS_TOKEN_FILE, or APP_ID and APP_PRIVATE_KEY_FILE}"
fi

# A restarted container (Compose) keeps the old runtime state of dockerd.
# A stale PID file stops dockerd if a new process gets the same PID.
sudo rm -rf /var/run/docker.pid /var/run/docker.sock /var/run/docker

# It also keeps the inner Docker data (containers, volumes, images) of the
# previous job. Delete it: each job starts with a clean Docker state.
sudo mkdir -p /var/lib/docker && sudo find /var/lib/docker -mindepth 1 -delete

# Start the inner Docker daemon and wait until it is ready.
# shellcheck disable=SC2024 # the log belongs to "runner": this is intended.
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
echo "dockerd is ready."

# For tests only: keep the container up with dockerd, but do not register.
if [[ "${SKIP_REGISTRATION:-false}" == "true" ]]; then
  echo "SKIP_REGISTRATION=true: the runner does not register."
  exec sleep infinity
fi

# sudo: a Compose file secret keeps its host owner and mode (0600).

base64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# A JWT for the GitHub App, valid for 9 minutes (the maximum is 10).
app_jwt() {
  local now header payload signature
  now=$(date +%s)
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | base64url)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' \
    $((now - 60)) $((now + 540)) "${APP_ID}" | base64url)
  signature=$(printf '%s.%s' "${header}" "${payload}" \
    | sudo openssl dgst -sha256 -sign "${APP_PRIVATE_KEY_FILE}" | base64url)
  printf '%s.%s.%s' "${header}" "${payload}" "${signature}"
}

# The token for the GitHub API: a GitHub App installation token (valid for
# 1 hour), or the PAT.
api_token() {
  if [[ -n "${APP_ID:-}" && -n "${APP_PRIVATE_KEY_FILE:-}" ]]; then
    local jwt installation_id
    jwt=$(app_jwt)
    installation_id="${APP_INSTALLATION_ID:-$(curl -fsS \
      -H "Authorization: Bearer ${jwt}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/orgs/${ORGANIZATION}/installation" | jq -r .id)}"
    curl -fsS -X POST \
      -H "Authorization: Bearer ${jwt}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/app/installations/${installation_id}/access_tokens" \
      | jq -r .token
  else
    sudo cat "${ACCESS_TOKEN_FILE}"
  fi
}

# Get a short-lived registration or removal token.
github_token() {
  curl -fsS -X POST \
    -H "Authorization: Bearer $(api_token)" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${ORGANIZATION}/actions/runners/$1-token" \
    | jq -r .token
}

REG_TOKEN=$(github_token registration || true)
if [[ -z "${REG_TOKEN}" || "${REG_TOKEN}" == "null" ]]; then
  echo "Could not get a registration token. Check the PAT or GitHub App, and ORGANIZATION." >&2
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
