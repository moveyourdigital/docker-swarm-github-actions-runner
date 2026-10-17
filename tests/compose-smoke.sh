#!/usr/bin/env bash
# Smoke test of one runner container (the Compose mode).
# Needs the Sysbox runtime on the host. Does not register a runner.
#
#   IMAGE=runner:test tests/compose-smoke.sh
#
# RUN_OPTS replaces "--runtime sysbox-runc". To test this script on a host
# without Sysbox: RUN_OPTS="--privileged -v /var/lib/docker"
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/moveyourdigital/docker-swarm-github-actions-runner:latest}"
RUN_OPTS="${RUN_OPTS:---runtime sysbox-runc}"
NAME="runner-smoke-$$"

cleanup() { docker rm -f -v "${NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; docker logs --tail 30 "${NAME}" >&2 || true; exit 1; }

# Wait until "dockerd is ready." shows $1 times in the container log.
wait_ready() {
  for _ in $(seq 90); do
    [[ "$(docker logs "${NAME}" 2>&1 | grep -c '^dockerd is ready.$')" -ge "$1" ]] && return 0
    sleep 1
  done
  fail "dockerd is not ready (start $1)"
}

# shellcheck disable=SC2086
docker run -d --name "${NAME}" ${RUN_OPTS} \
  -e ORGANIZATION=test -e ACCESS_TOKEN_FILE=/dev/null -e SKIP_REGISTRATION=true \
  "${IMAGE}" >/dev/null

wait_ready 1
echo "ok: inner dockerd starts"

docker exec "${NAME}" docker run --rm hello-world | grep -q 'Hello from Docker!' \
  || fail "docker run hello-world"
echo "ok: docker run"

docker exec "${NAME}" sh -c 'printf "FROM alpine\nRUN echo ok\n" | docker build -q -t smoke -' >/dev/null \
  || fail "docker build"
echo "ok: docker build"

docker exec "${NAME}" docker run -d --name leak-check alpine sleep 300 >/dev/null
[[ -z "$(docker ps -aq --filter name=leak-check)" ]] || fail "the host sees the inner container"
echo "ok: the host does not see the inner containers"

# A restarted container must start dockerd again (stale PID file) and
# start with no inner Docker data (containers, images).
docker restart "${NAME}" >/dev/null
wait_ready 2
echo "ok: inner dockerd starts after a restart"

[[ "$(docker exec "${NAME}" docker ps -aq | wc -l)" -eq 0 ]] || fail "inner containers stay after a restart"
[[ "$(docker exec "${NAME}" docker images -q | wc -l)" -eq 0 ]] || fail "inner images stay after a restart"
echo "ok: no inner Docker data after a restart"

echo "PASS: compose smoke test"
