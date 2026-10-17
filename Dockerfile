# Official runner image: kept up to date by GitHub.
FROM ghcr.io/actions/actions-runner:latest

USER root

# dockerd runs INSIDE the container. This needs the Sysbox runtime on the host.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl jq git git-lfs iptables openssl \
 && curl -fsSL https://get.docker.com | sh \
 && usermod -aG docker runner \
 && rm -rf /var/lib/apt/lists/*

COPY --chmod=755 start.sh /start.sh

# The base image gives the "runner" user passwordless sudo (used to start dockerd).
USER runner
ENTRYPOINT ["/start.sh"]
