#!/usr/bin/env bash
# Dry-run checks for setup/lab-run.sh. No cluster required.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

field() {
  local label="$1"
  local text="$2"
  printf '%s\n' "${text}" | awk -F': ' -v label="${label}" '$1 == label { print $2; exit }'
}

echo "Checking 101-01 and 101-02 against the module pages..."
python3 - "${REPO_ROOT}" <<'PY'
import subprocess, sys
from pathlib import Path

root = Path(sys.argv[1])
pages = root / "content/modules/ROOT/pages"

def dry(module):
    out = subprocess.check_output(
        ["bash", str(root / "setup/lab-run.sh"), "--module", module, "--dry-run"],
        text=True,
    )
    steps = None
    bridge = None
    for line in out.splitlines():
        if line.startswith("Steps: "):
            steps = int(line.split(": ", 1)[1])
        elif line.startswith("Bridge blocks: "):
            bridge = int(line.split(": ", 1)[1])
    if steps is None or bridge is None:
        raise SystemExit(f"missing dry-run summary for {module}\n{out}")
    return out, steps, bridge

def scored_region(text):
    if "Click each step for the full solution." in text:
        start = text.index("Click each step for the full solution.")
    else:
        start = text.index("Each title has the values for that step.")
    ends = []
    for marker in ("\n== Challenge", "\n== Debrief", "\n== Cleanup"):
        idx = text.find(marker, start)
        if idx != -1:
            ends.append(idx)
    if not ends:
        raise SystemExit("no stop heading")
    return text[start:min(ends)]

page_101_01 = pages / "101-01-default-secure-behavior.adoc"
text_101_01 = page_101_01.read_text()
out, steps, bridge = dry("101-01")
region = scored_region(text_101_01)
chunks = region.split("[%collapsible]")[1:]
if bridge != 0:
    raise SystemExit("101-01 has bridge blocks")
if not chunks or not all("role=execute" in chunk for chunk in chunks):
    raise SystemExit("101-01 collapsible is missing an execute block")
if steps != len(chunks):
    raise SystemExit(f"101-01 steps {steps} != collapsibles {len(chunks)}")
if "1. Create project 101-01-httpd-demo" not in out:
    raise SystemExit("101-01 first step title missing")

page_101_02 = pages / "101-02-projects-namespaces-boundaries.adoc"
text_101_02 = page_101_02.read_text()
out, steps, bridge = dry("101-02")
region = scored_region(text_101_02)
chunks = region.split("[%collapsible]")[1:]
total = text_101_02.count("[%collapsible]")
if bridge != 0:
    raise SystemExit("101-02 has bridge blocks")
if steps != len(chunks):
    raise SystemExit(f"101-02 steps {steps} != collapsibles before challenge {len(chunks)}")
if not steps < total:
    raise SystemExit(f"101-02 scored {steps} collapsibles, file has {total}")
if "team-payments-dev" in out:
    raise SystemExit("101-02 dry-run included the challenge solution")

scoped = []
for path in sorted(pages.glob("*.adoc")):
    text = path.read_text()
    if "Click each step for the full solution." in text or path.name.startswith("101-02-"):
        module_id = "-".join(path.name.split("-")[:2])
        scoped.append((module_id, path, text))

if len(scoped) != 38:
    raise SystemExit(f"expected 38 modules, found {len(scoped)}")

for module_id, path, text in scoped:
    out, steps, bridge = dry(module_id)
    region = scored_region(text)
    chunks = [c for c in region.split("[%collapsible]")[1:] if "role=execute" in c]
    if bridge != 0:
        raise SystemExit(f"{module_id} has bridge blocks")
    if steps != len(chunks):
        raise SystemExit(f"{module_id} steps {steps} != execute collapsibles {len(chunks)}")
    if steps < 1:
        raise SystemExit(f"{module_id} has no steps")
    needle = f":lab-run-module: {module_id}\ninclude::partial$lab-run.adoc[]"
    if needle not in text:
        raise SystemExit(f"{path.name} is missing the run button")
    if text.count("include::partial$lab-run.adoc[]") != 1:
        raise SystemExit(f"{path.name} includes the run button more than once")

challenge = text_101_02.split("== Challenge", 1)[1]
if "include::partial$lab-run.adoc[]" in challenge:
    raise SystemExit("101-02 challenge section includes the run button")

untouched = pages / "201-11-threat-modeling-control-mapping.adoc"
if "lab-run.adoc" in untouched.read_text():
    raise SystemExit("201-11 should not have a run button")

print(f"dry-run ok for {len(scoped)} modules")
PY

echo "Checking a heredoc inside 201-04 survives extraction..."
dump="$(mktemp -d)"
bash setup/lab-run.sh --module 201-04 --dry-run --dump "${dump}" >/dev/null
grep -R -q "name: build-image" "${dump}/items" || fail "201-04 lost the build-image task"
grep -R -q "USER 1001" "${dump}/items" || fail "201-04 heredoc was truncated"
grep -R -q "^EOF$" "${dump}/items" || fail "201-04 heredoc closer missing"
rm -rf "${dump}"

echo "Checking a failed step still leaves Grade: 2/3..."
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
cat > "${work}/page.adoc" <<'EOF'
[source,bash,role=execute]
----
mkdir -p "$OUT/work"
cd "$OUT/work"
echo setup > setup.txt
----

Click each step for the full solution.

.Step one
[%collapsible]
====
[source,bash,role=execute]
----
echo one > one.txt
ROUTE=from-step-one
----
====

.Step two fails
[%collapsible]
====
[source,bash,role=execute]
----
echo two > two.txt
false
----
====

.Step three uses ROUTE and can-i
[%collapsible]
====
[source,bash,role=execute]
----
test "$ROUTE" = from-step-one
test -f one.txt
oc auth can-i create pods --as=dev-user
echo three > three.txt
----
====
EOF
cat > "${work}/oc" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "auth" && "${2:-}" == "can-i" ]]; then
  echo no
  exit 1
fi
echo "unexpected: $*" >&2
exit 2
EOF
chmod +x "${work}/oc"

grade="$(
  env -i HOME="${HOME}" PATH="${work}:${PATH}" TMPDIR="${TMPDIR:-/tmp}" OUT="${work}/out" \
    bash setup/lab-run.sh --module fixture --page "${work}/page.adoc"
)"
printf '%s\n' "${grade}" | grep -q '^Failed: Step two fails$' || fail "missing failed step title"
printf '%s\n' "${grade}" | grep -q '^Grade: 2/3$' || fail "expected Grade: 2/3, got: ${grade}"
[[ -f "${work}/out/work/setup.txt" ]] || fail "setup block did not run"
[[ -f "${work}/out/work/one.txt" ]] || fail "step one did not keep its working directory"
[[ -f "${work}/out/work/three.txt" ]] || fail "later step did not see ROUTE or the can-i result"

echo "lab-run checks passed"
