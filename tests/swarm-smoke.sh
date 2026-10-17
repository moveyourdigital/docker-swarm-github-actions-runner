#!/usr/bin/env bash
# Smoke test of the Swarm deploy (docker-stack.yml) on a single node.
# Needs "default-runtime": "sysbox-runc" on the host. Uses a dummy PAT,
# so the runner stops at the registration step and does not register.
#
#   IMAGE=runner:test tests/swarm-smoke.sh
#
# The script starts a Swarm if none is active, and leaves it at the end.
set -euo pipefail
cd "$(dirname "$0")/.."

export IMAGE="${IMAGE:-ghcr.io/moveyourdigital/docker-swarm-github-actions-runner:latest}"
export ORGANIZATION=test
STACK="runner-smoke"
SERVICE="${STACK}_runner"
SECRET="github_access-token"

INIT_SWARM=false
if [[ "$(docker info --format '{{.Swarm.LocalNodeState}}')" != "active" ]]; then
  docker swarm init --advertise-addr 127.0.0.1 >/dev/null
  INIT_SWARM=true
fi
NODE="$(docker info --format '{{.Swarm.NodeID}}')"

cleanup() {
  docker stack rm "${STACK}" >/dev/null 2>&1 || true
  for _ in $(seq 30); do
    [[ -z "$(docker ps -aq --filter "label=com.docker.stack.namespace=${STACK}")" ]] && break
    sleep 1
  done
  docker secret rm "${SECRET}" >/dev/null 2>&1 || true
  docker node update --label-rm sysbox "${NODE}" >/dev/null 2>&1 || true
  if [[ "${INIT_SWARM}" == "true" ]]; then docker swarm leave --force >/dev/null || true; fi
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  docker service ps --no-trunc "${SERVICE}" >&2 || true
  docker service logs --tail 30 "${SERVICE}" >&2 || true
  exit 1
}

# Print the current states of the service tasks, one per line.
task_states() { docker service ps "${SERVICE}" --format '{{.CurrentState}}' | awk '{print $1}'; }

printf 'dummy' | docker secret create "${SECRET}" - >/dev/null
docker stack deploy --detach=true -c docker-stack.yml "${STACK}" >/dev/null

# Without the node label, the 3 tasks stay "Pending".
for _ in $(seq 30); do
  [[ "$(task_states | grep -c '^Pending$')" -eq 3 ]] && break
  sleep 1
done
sleep 5
[[ "$(task_states | grep -c '^Pending$')" -eq 3 ]] || fail "tasks are not Pending without the node label"
task_states | grep -qv '^Pending$' && fail "a task started on a node without the sysbox label"
echo "ok: no task starts without the node label (3 Pending)"

docker node update --label-add sysbox=true "${NODE}" >/dev/null

# With the label, the tasks start. The inner dockerd starts, then the
# dummy PAT stops the runner at the registration step.
for _ in $(seq 120); do
  logs="$(docker service logs --raw "${SERVICE}" 2>&1 || true)"
  if grep -q 'Could not get a registration token' <<<"${logs}"; then break; fi
  if grep -q 'dockerd did not start' <<<"${logs}"; then fail "inner dockerd did not start"; fi
  sleep 2
done
grep -q '^dockerd is ready.$' <<<"${logs}" || fail "inner dockerd is not ready"
grep -q 'Could not get a registration token' <<<"${logs}" || fail "no registration step"
echo "ok: tasks start on the labelled node, inner dockerd starts"
echo "ok: the runner stops at the registration step (dummy PAT)"

[[ "$(docker service inspect --format '{{.Spec.Mode.Replicated.Replicas}}' "${SERVICE}")" -eq 3 ]] \
  || fail "replicas is not 3"
echo "ok: 3 replicas"

echo "PASS: swarm smoke test"
