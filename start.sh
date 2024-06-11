#!/bin/bash

ORGANIZATION=$ORGANIZATION
REG_TOKEN=$(curl -sX POST -H "Authorization: token $(cat $ACCESS_TOKEN_FILE)" https://api.github.com/orgs/${ORGANIZATION}/actions/runners/registration-token | jq .token --raw-output)

cd /home/docker/actions-runner

echo "Configuring ephemeral runner..."
./config.sh --url https://github.com/${ORGANIZATION} --token ${REG_TOKEN} --ephemeral --disableupdate

cleanup() {
  echo "Removing runner..."
  ./config.sh remove --token ${REG_TOKEN}
}

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

echo "Beginning run script..."
./run.sh & wait $!
