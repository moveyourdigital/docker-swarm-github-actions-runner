# GitHub Actions self-hosted Docker Swarm runner

This Docker image runs a self-hosted GitHub Actions Runner.

**Note:** this image starts up [ephemeral runners](https://docs.github.com/en/actions/hosting-your-own-runners/autoscaling-with-self-hosted-runners#using-ephemeral-runners-for-autoscaling) so they get deregistered after each job finishes.

### Usage
1. Clone this repository
2. Copy `.env.example` to `.env`
3. Fill up `ORGANIZATION` with your organization name
4. Get a [GitHub access token](https://github.com/settings/tokens)
5. Create a secret `access-token` (or whatever) with your newly created token
6. Point `ACCESS_TOKEN_FILE` to the secret path `/run/secrets/access-token`
7. Run

If you wish to run it locally, use docker compose and create a file named `access-token` in the root of this project with the token in it.