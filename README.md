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
- A way to manage organization self-hosted runners, one of:
  - a GitHub App (recommended, see [GitHub App](#github-app)), or
  - a personal access token (fine-grained: *Self-hosted runners: read and write*).

## Configuration

```bash
cp .env.example .env     # set ORGANIZATION (and RUNNER_LABELS, if needed)
```

| Variable            | Description                                   | Default  |
| ------------------- | --------------------------------------------- | -------- |
| `ORGANIZATION`      | GitHub organization that owns the runners     | required |
| `RUNNER_LABELS`     | Comma-separated runner labels                 | `sysbox` |
| `ACCESS_TOKEN_FILE` | Path to the file that holds the PAT           | set in the compose files |
| `APP_ID`            | GitHub App ID (with `APP_PRIVATE_KEY_FILE`, replaces the PAT) | none |
| `APP_PRIVATE_KEY_FILE` | Path to the GitHub App private key (`.pem`) | none |
| `APP_INSTALLATION_ID` | GitHub App installation ID. If not set, the runner gets it from the API. | none |

## Docker Compose

```bash
echo -n '<PAT>' > access-token && chmod 600 access-token
docker compose up -d
```

Scale: `docker compose up -d --scale runner=5`
Update: `docker compose pull && docker compose up -d`

Compose restarts the same container after each job. `start.sh` deletes the
inner Docker data (containers, volumes, images) at each start, so jobs do not
share Docker state. Images are not cached between jobs.

## GitHub App

A GitHub App belongs to the organization, not to a user, and has no
expiration date. Use it instead of a PAT.

1. In the organization: **Settings → Developer settings → GitHub Apps →
   New GitHub App**.
   - Webhook: off.
   - Permissions: **Organization → Self-hosted runners: Read and write**. No
     other permissions.
   - Where can this GitHub App be installed: **Only on this account**.
2. Note the **App ID**. Generate a **private key** (a `.pem` file).
3. **Install App** on the organization.
4. Docker Compose: save the key as `app-key.pem` (`chmod 600`), and create
   `docker-compose.override.yml`:

   ```yaml
   secrets:
     github_app-key:
       file: ./app-key.pem   # Never commit this file.

   services:
     runner:
       secrets: !override [github_app-key]
       environment:
         APP_ID: "123456"
         APP_PRIVATE_KEY_FILE: /run/secrets/github_app-key
   ```

   Then: `docker compose up -d --force-recreate`. You can then delete
   `access-token` and revoke the PAT.

   Docker Swarm: create the secret with
   `docker secret create github_app-key app-key.pem`, and make the same changes
   in `docker-stack.yml`.

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

## Tests

The `Test` workflow installs Sysbox on a GitHub-hosted runner and runs:

- `tests/compose-smoke.sh`: inner `dockerd`, `docker run`, `docker build`,
  isolation from the host, and a clean state after a restart.
- `tests/app-jwt.sh`: the GitHub App JWT (claims and RS256 signature).
- `tests/swarm-smoke.sh`: `docker-stack.yml` on a one-node Swarm, the node
  label constraint, and the inner `dockerd` under the default runtime.

The tests do not register runners. `SKIP_REGISTRATION=true` keeps a runner
container up after `dockerd` starts. Use it for tests only.

To run a test on a host with Sysbox:

```bash
docker build -t runner:test .
IMAGE=runner:test tests/compose-smoke.sh
```

## Security notes

- Keep the PAT or the GitHub App private key in a Docker secret or in an untracked
  file. Never put it in the image or in Git.
- Self-hosted runners must not run workflows from untrusted forks.
