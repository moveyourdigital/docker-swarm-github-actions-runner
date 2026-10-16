# GitHub Actions self-hosted runner (Docker Swarm / Docker Compose)

Run GitHub Actions self-hosted runners as containers, with a private Docker
daemon in each runner. The runners use the [Sysbox](https://github.com/nestybox/sysbox)
runtime. No `privileged` mode. No access to the host `docker.sock`.

You can deploy with **Docker Compose** or with **Docker Swarm**.

> **Moving to GHCR:** the image is now published to GitHub Container Registry.
> The Docker Hub image `moveyourdigital/docker-swarm-github-actions-runner`
> does not get updates anymore. Change your image to
> `ghcr.io/moveyourdigital/docker-swarm-github-actions-runner`.

Image: `ghcr.io/moveyourdigital/docker-swarm-github-actions-runner`
(`linux/amd64`, `linux/arm64`). Tags: `latest` (branch `master`), Git tags,
and the full commit SHA. The image is rebuilt every week to get the latest
base image.

## How it works

- Each container starts its own `dockerd`, then registers as an **ephemeral** runner.
- The runner takes one job, deregisters, and the container restarts with a clean state.
- Jobs cannot see containers, networks, or images of other runners or of the host.

## Requirements

- Linux host with [Sysbox CE](https://github.com/nestybox/sysbox) installed
  (the `sysbox-runc` runtime must show in `docker info`).
- A GitHub personal access token that can manage organization self-hosted
  runners (fine-grained: *Self-hosted runners: read and write*).

## Configuration

```bash
cp .env.example .env     # set ORGANIZATION (and RUNNER_LABELS, if needed)
```

| Variable            | Description                                   | Default  |
| ------------------- | --------------------------------------------- | -------- |
| `ORGANIZATION`      | GitHub organization that owns the runners     | required |
| `RUNNER_LABELS`     | Comma-separated runner labels                 | `sysbox` |
| `ACCESS_TOKEN_FILE` | Path to the file that holds the PAT           | set in the compose files |

## Docker Compose

```bash
echo -n '<PAT>' > access-token && chmod 600 access-token
docker compose up -d
```

Scale: `docker compose up -d --scale runner=5`
Update: `docker compose pull && docker compose up -d`

The inner Docker data persists while a container lives. Images accumulate.
Run `docker compose up -d --force-recreate` on a schedule to reset them.

## Docker Swarm

> **Important:** Docker Swarm does **not** support the `runtime` option for
> services. You must set Sysbox as the **default runtime** on the node that runs
> the runners.

1. Install Sysbox on the node.
2. Label the node:

   ```bash
   docker node update --label-add sysbox=true <node-name>
   ```

3. On that node, add this to `/etc/docker/daemon.json`
   (keep the `runtimes` entry that the Sysbox installer created):

   ```json
   {
     "default-runtime": "sysbox-runc"
   }
   ```

   Then restart Docker: `sudo systemctl restart docker`.

   **Note:** all services that run on this node now use Sysbox. Use a
   dedicated node, or check that your other services work with Sysbox.

4. Create the secret and deploy:

   ```bash
   printf '%s' '<PAT>' | docker secret create github_access-token -
   set -a; . ./.env; set +a
   docker stack deploy -c docker-stack.yml runners
   ```

Scale: `docker service scale runners_runner=5`

## Use in workflows

```yaml
jobs:
  build:
    runs-on: [self-hosted, sysbox]
    steps:
      - uses: actions/checkout@v5
      - run: docker build .
```

## Troubleshooting

- The inner daemon log is in `/tmp/dockerd.log` in the runner container.
- If `dockerd` does not start, the container does not use Sysbox. Check
  `docker inspect --format '{{.HostConfig.Runtime}}' <container>`.

## Security notes

- Keep the PAT in a Docker secret or in `access-token`. Never put it in the image or in Git.
- Self-hosted runners must not run workflows from untrusted forks.
