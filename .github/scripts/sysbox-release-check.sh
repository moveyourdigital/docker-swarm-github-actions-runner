#!/usr/bin/env bash
# Opens an issue when a newer Sysbox release exists than SYSBOX_VERSION in
# .github/workflows/test.yml. Dependabot cannot update this version.
#
# Needs GH_TOKEN with "issues: write". DRY_RUN=true prints the issue only.
set -euo pipefail
cd "$(dirname "$0")/../.."

current="$(sed -n 's/^  SYSBOX_VERSION: //p' .github/workflows/test.yml)"
[[ -n "${current}" ]] || { echo "SYSBOX_VERSION not found in test.yml" >&2; exit 1; }

release="$(gh api repos/nestybox/sysbox/releases/latest)"
latest="$(jq -r '.tag_name | ltrimstr("v")' <<<"${release}")"
echo "Sysbox: current ${current}, latest ${latest}"

newest="$(printf '%s\n%s\n' "${current}" "${latest}" | sort -V | tail -n 1)"
if [[ "${latest}" == "${current}" || "${newest}" == "${current}" ]]; then
  echo "Up to date."
  exit 0
fi

title="Update Sysbox to v${latest}"
deb="sysbox-ce_${latest}.linux_amd64.deb"
sha256="$(jq -r --arg n "${deb}" '.assets[] | select(.name == $n) | .digest // "" | ltrimstr("sha256:")' <<<"${release}")"
url="$(jq -r '.html_url' <<<"${release}")"

body="A new Sysbox release exists: [v${latest}](${url}). The CI tests use v${current}.

Change these values in \`.github/workflows/test.yml\`:

\`\`\`yaml
  SYSBOX_VERSION: ${latest}
  SYSBOX_SHA256: ${sha256:-<get it from the release page>}
\`\`\`

Then open a PR. The \`sysbox\` check tests the runner image with the new version.
If it passes, update Sysbox on the runner hosts (x1-hel1) too."

if [[ "${DRY_RUN:-false}" == "true" ]]; then
  printf 'DRY_RUN: would open the issue "%s":\n\n%s\n' "${title}" "${body}"
  exit 0
fi

if [[ -n "$(gh issue list --state open --search "\"${title}\" in:title" --json number --jq '.[0].number // empty')" ]]; then
  echo "An open issue \"${title}\" exists."
  exit 0
fi

gh issue create --title "${title}" --body "${body}"
