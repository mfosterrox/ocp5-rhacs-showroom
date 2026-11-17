#!/usr/bin/env bash
# Refresh vendor/security-response from a fork of jmhbnz/workshops.
# Copies an allowlist only. Does not modify Showroom AsciiDoc pages.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${ROOT}/vendor/security-response"
UPSTREAM_SLUG="${UPSTREAM_SLUG:-jmhbnz/workshops}"
BRANCH="${BRANCH:-main}"

if [[ -n "${SECURITY_RESPONSE_REPO:-}" ]]; then
  SOURCE_SLUG="${SECURITY_RESPONSE_REPO}"
else
  GH_USER="$(gh api user --jq .login)"
  PARENT="$(gh api "repos/${GH_USER}/workshops" --jq .parent.full_name 2>/dev/null || true)"
  if [[ "${PARENT}" == "${UPSTREAM_SLUG}" ]]; then
    SOURCE_SLUG="${GH_USER}/workshops"
  else
    SOURCE_SLUG="${UPSTREAM_SLUG}"
  fi
fi

if [[ "${SOURCE_SLUG}" != "${UPSTREAM_SLUG}" ]]; then
  echo "==> Updating fork ${SOURCE_SLUG} from ${UPSTREAM_SLUG}"
  gh repo sync "${SOURCE_SLUG}" --source "${UPSTREAM_SLUG}" --branch "${BRANCH}"
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

echo "==> Sparse clone ${SOURCE_SLUG} (${BRANCH})"
git clone --filter=blob:none --sparse --depth 1 --branch "${BRANCH}" \
  "https://github.com/${SOURCE_SLUG}.git" "${WORKDIR}/workshops"
# Non-cone patterns so the exploit walkthrough and payload are never checked out.
git -C "${WORKDIR}/workshops" sparse-checkout set --no-cone --skip-checks \
  LICENSE \
  data/security-new/exercise1.mdx \
  data/security-new/exercise2.mdx \
  data/security-new/exercise3.mdx \
  data/security-new/exercise5.mdx \
  data/security-new/meta.json \
  data/security-new/setup/app-template.yaml \
  data/security-new/setup/exercise4/k8s \
  data/security-new/setup/exercise4/edge-server \
  data/security-new/setup/exercise4/socketio-server \
  public/static/images/fsi-security

SHA="$(git -C "${WORKDIR}/workshops" rev-parse HEAD)"
SRC_NEW="${WORKDIR}/workshops/data/security-new"
SRC_EX4="${SRC_NEW}/setup/exercise4"

rm -rf "${DEST}"
mkdir -p \
  "${DEST}/data/security-new/setup/exercise4/k8s" \
  "${DEST}/images/fsi-security"

for file in exercise1.mdx exercise2.mdx exercise3.mdx exercise5.mdx meta.json; do
  cp "${SRC_NEW}/${file}" "${DEST}/data/security-new/${file}"
done

cp "${SRC_NEW}/setup/app-template.yaml" "${DEST}/data/security-new/setup/app-template.yaml"

if [[ -d "${SRC_EX4}/k8s" ]]; then
  cp "${SRC_EX4}/k8s/"*.yaml "${DEST}/data/security-new/setup/exercise4/k8s/"
fi

while IFS= read -r -d '' path; do
  rel="${path#"${SRC_EX4}/"}"
  case "${rel}" in
    exploit/*) continue ;;
  esac
  base="$(basename "${path}")"
  case "${base}" in
    Containerfile|Containerfile.*|requirements.txt|requirements-*.txt) ;;
    *) continue ;;
  esac
  mkdir -p "${DEST}/data/security-new/setup/exercise4/$(dirname "${rel}")"
  cp "${path}" "${DEST}/data/security-new/setup/exercise4/${rel}"
done < <(find "${SRC_EX4}" -type f -print0)

cp -R "${WORKDIR}/workshops/public/static/images/fsi-security/." "${DEST}/images/fsi-security/"
cp "${WORKDIR}/workshops/LICENSE" "${DEST}/LICENSE"

FETCHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "${DEST}/UPSTREAM" <<EOF
source: https://github.com/${SOURCE_SLUG}
upstream: https://github.com/${UPSTREAM_SLUG}
branch: ${BRANCH}
commit: ${SHA}
fetched: ${FETCHED}
EOF

cat > "${DEST}/README.md" <<EOF
# Security response upstream snapshot

Filtered copy of the OpenShift security response workshop from [jmhbnz/workshops](https://github.com/${UPSTREAM_SLUG}).

Refresh this directory with:

\`\`\`bash
updates/sync-security-response.sh
\`\`\`

The script updates the GitHub fork from \`${UPSTREAM_SLUG}\` when \`gh\` can see that fork, then copies an allowlist. It does not change pages under \`content/modules/security-response\`. After a refresh, review this snapshot and edit those pages by hand.

This snapshot omits \`exercise4.mdx\` and \`setup/exercise4/exploit/\` (the live exploit walkthrough and payload). See \`UPSTREAM\` for the fetched commit.

The files in this directory are GPL-3.0. See \`LICENSE\`. The rest of the roadshow repository stays under the Apache-2.0 license at the repository root.
EOF

if find "${DEST}" \( -name 'poc.py' -o -name 'payload.bin' -o -name 'exercise4.mdx' -o -type d -name 'exploit' \) | grep -q .; then
  echo "Refusing to keep excluded exploit files in ${DEST}" >&2
  exit 1
fi

echo "==> Snapshot ${SHA} written to vendor/security-response"
echo "    Showroom pages were not modified."
