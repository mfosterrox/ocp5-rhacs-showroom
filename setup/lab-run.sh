#!/usr/bin/env bash
# Run a module's solution commands and print Grade: N/M.
# Usage: bash setup/lab-run.sh --module 101-01
#
# N is how many solution steps finished. M is the number of collapsible
# solution steps in the module. Setup commands that appear before the
# hands-on cue run first and are not part of the score.
# Run this once, before lab-cleanup.sh. Cleanup does not grade.
#
# Do not source ~/.bashrc here: on lab bastions it often calls `exit` for
# non-interactive shells and aborts this script with no output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODULE=""
PAGE=""
DUMP=""
DRY_RUN=0
ENV_DELTA=""
PWD_FILE=""

usage() {
  cat <<'EOF'
Usage: lab-run.sh --module MODULE [--dry-run] [--dump DIR] [--page FILE]

Run the solution steps for a hands-on module and print Grade: N/M.
N is how many steps finished. M is how many solution steps the module has.

  --module MODULE   Module id, for example 101-01 or virt-00
  --dry-run         Print the steps without running them
  --dump DIR        Copy the extracted scripts into DIR
  --page FILE       Read this AsciiDoc file instead of looking up MODULE
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --module)
      [[ $# -ge 2 ]] || { echo "Missing value for --module" >&2; exit 1; }
      MODULE=$2
      shift 2
      ;;
    --page)
      [[ $# -ge 2 ]] || { echo "Missing value for --page" >&2; exit 1; }
      PAGE=$2
      shift 2
      ;;
    --dump)
      [[ $# -ge 2 ]] || { echo "Missing value for --dump" >&2; exit 1; }
      DUMP=$2
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${MODULE}" ]]; then
  echo "Error: --module is required" >&2
  usage
  exit 1
fi

if [[ -n "${PAGE}" ]]; then
  if [[ ! "${MODULE}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Error: unsupported module id '${MODULE}'" >&2
    exit 1
  fi
  if [[ ! -f "${PAGE}" ]]; then
    echo "Error: page not found: ${PAGE}" >&2
    exit 1
  fi
else
  if [[ ! "${MODULE}" =~ ^(101|201|301)-[0-9]{2}$ && ! "${MODULE}" =~ ^virt-[0-9]{2}$ ]]; then
    echo "Error: unsupported module id '${MODULE}'" >&2
    usage
    exit 1
  fi
  shopt -s nullglob
  pages=( "${REPO_ROOT}/content/modules/ROOT/pages/${MODULE}-"*.adoc )
  shopt -u nullglob
  if [[ ${#pages[@]} -ne 1 ]]; then
    echo "Error: expected one page for ${MODULE}, found ${#pages[@]}" >&2
    exit 1
  fi
  PAGE="${pages[0]}"
fi

skip_var() {
  case "$1" in
    BASH*|COMP_*|DIRSTACK|EPOCHREALTIME|EPOCHSECONDS|FUNCNAME|GROUPS|HOSTNAME|HOSTTYPE|IFS|LINENO|MACHTYPE|OLDPWD|OPTARG|OPTERR|OPTIND|OSTYPE|PIPESTATUS|PPID|PWD|RANDOM|SECONDS|SHELLOPTS|SHLVL|SRANDOM|UID|EUID|HOME|USER|LOGNAME|SHELL|TERM|_|ec|_labrun_*)
      return 0
      ;;
  esac
  return 1
}

dump_env() {
  local _labrun_name
  local IFS=$' \t\n'
  for _labrun_name in $(compgen -v || true); do
    skip_var "${_labrun_name}" && continue
    declare -p "${_labrun_name}" 2>/dev/null || true
  done
}

apply_env_delta() {
  local _labrun_before="$1"
  local _labrun_after="$2"
  local _labrun_dest="$3"
  awk 'NR==FNR { old[$0]=1; next } !($0 in old) && $0 ~ /^declare / { print }' \
    "${_labrun_before}" "${_labrun_after}" > "${_labrun_dest}"
  if [[ ! -s "${_labrun_dest}" ]]; then
    echo ':' > "${_labrun_dest}"
  fi
}

run_bash_file() {
  local _labrun_script="$1"
  local _labrun_before _labrun_after _labrun_pwd _labrun_rc
  _labrun_before="$(mktemp)"
  _labrun_after="$(mktemp)"
  _labrun_pwd="$(mktemp)"
  dump_env > "${_labrun_before}"
  (
    trap 'ec=$?; set +e; dump_env > "'"${_labrun_after}"'"; pwd > "'"${_labrun_pwd}"'"; exit "$ec"' EXIT
    oc() {
      if [[ "${1:-}" == "auth" && "${2:-}" == "can-i" ]]; then
        set +e
        command oc "$@"
        local _labrun_oc_rc=$?
        set -e
        if [[ ${_labrun_oc_rc} -le 1 ]]; then
          return 0
        fi
        return "${_labrun_oc_rc}"
      fi
      command oc "$@"
    }
    set -e
    # shellcheck disable=SC1090
    source "${_labrun_script}"
  )
  _labrun_rc=$?
  apply_env_delta "${_labrun_before}" "${_labrun_after}" "${ENV_DELTA}"
  if [[ -s "${_labrun_pwd}" ]]; then
    cat "${_labrun_pwd}" > "${PWD_FILE}"
  else
    : > "${PWD_FILE}"
  fi
  rm -f "${_labrun_before}" "${_labrun_after}" "${_labrun_pwd}"
  return "${_labrun_rc}"
}

extract_page() {
  local _labrun_page="$1"
  local _labrun_out="$2"
  mkdir -p "${_labrun_out}/items"
  awk -v out="${_labrun_out}" '
    function emit_item(type, title, script,   base, path) {
      seq++
      base = sprintf("%s/items/%04d", out, seq)
      path = base ".type"
      printf "%s\n", type > path
      close(path)
      path = base ".title"
      printf "%s\n", title > path
      close(path)
      path = base ".sh"
      printf "%s", script > path
      close(path)
    }

    function end_listing() {
      if (listing_kind == "execute") {
        if (!scoring) {
          emit_item("setup", "", buf)
        } else if (in_collapsible) {
          step_buf = step_buf buf
          step_has = 1
        } else {
          emit_item("bridge", "", buf)
        }
      }
      buf = ""
      listing_kind = ""
      in_listing = 0
      pending_source = ""
    }

    BEGIN {
      scoring = 0
      stopped = 0
      in_listing = 0
      listing_kind = ""
      pending_source = ""
      in_collapsible = 0
      expect_open = 0
      step_has = 0
      step_buf = ""
      step_title = ""
      pending_title = ""
      buf = ""
      seq = 0
    }

    {
      raw = $0
      sub(/\r$/, "", raw)
      line = raw
      sub(/[[:space:]]+$/, "", line)
      if (stopped) {
        next
      }

      if (in_listing) {
        if (line == "----") {
          end_listing()
        } else if (listing_kind == "execute") {
          buf = buf raw "\n"
        }
        next
      }

      if (line ~ /^\[source,/) {
        if (line ~ /source,bash/ && line ~ /role=execute/) {
          pending_source = "execute"
        } else {
          pending_source = "other"
        }
        next
      }

      if (line == "----" && pending_source != "") {
        in_listing = 1
        listing_kind = pending_source
        buf = ""
        next
      }

      if (pending_source != "" && line != "") {
        pending_source = ""
      }

      if (!scoring) {
        if (line == "Click each step for the full solution." || index(line, "Each title has the values for that step") > 0) {
          scoring = 1
        }
        next
      }

      if (line ~ /^== Challenge([[:space:]:]|$)/ || line ~ /^== Debrief([[:space:]:]|$)/ || line ~ /^== Cleanup([[:space:]:]|$)/) {
        stopped = 1
        next
      }

      if (line ~ /^\.[^.]/) {
        pending_title = line
        sub(/^\./, "", pending_title)
        sub(/^[[:space:]]+/, "", pending_title)
        next
      }

      if (line ~ /^\[%collapsible/) {
        step_title = pending_title
        step_buf = ""
        step_has = 0
        expect_open = 1
        in_collapsible = 0
        next
      }

      if (line == "====") {
        if (expect_open && !in_collapsible) {
          in_collapsible = 1
          expect_open = 0
        } else if (in_collapsible) {
          if (step_has) {
            if (step_title == "") {
              step_title = sprintf("Step %d", seq + 1)
            }
            emit_item("step", step_title, step_buf)
          }
          in_collapsible = 0
          expect_open = 0
          step_buf = ""
          step_has = 0
        }
      }
    }
  ' "${_labrun_page}"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lab-run.XXXXXX")"
ENV_DELTA="${WORK}/env.delta"
PWD_FILE="${WORK}/pwd"
trap 'rm -rf "${WORK}"' EXIT

extract_page "${PAGE}" "${WORK}"

if [[ -n "${DUMP}" ]]; then
  mkdir -p "${DUMP}"
  rm -rf "${DUMP}/items"
  cp -R "${WORK}/items" "${DUMP}/items"
fi

shopt -s nullglob
item_scripts=( "${WORK}/items/"*.sh )
shopt -u nullglob

setup_count=0
bridge_count=0
step_count=0
for item_script in "${item_scripts[@]+"${item_scripts[@]}"}"; do
  item_type="$(cat "${item_script%.sh}.type")"
  case "${item_type}" in
    setup) setup_count=$((setup_count + 1)) ;;
    bridge) bridge_count=$((bridge_count + 1)) ;;
    step) step_count=$((step_count + 1)) ;;
    *)
      echo "Error: unknown extracted block type '${item_type}'" >&2
      exit 1
      ;;
  esac
done

if [[ "${step_count}" -eq 0 ]]; then
  echo "Error: no solution steps found in ${PAGE}" >&2
  exit 1
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "Module: ${MODULE}"
  echo "Setup blocks: ${setup_count}"
  echo "Bridge blocks: ${bridge_count}"
  echo "Steps: ${step_count}"
  shown=0
  for item_script in "${item_scripts[@]+"${item_scripts[@]}"}"; do
    item_type="$(cat "${item_script%.sh}.type")"
    [[ "${item_type}" == "step" ]] || continue
    shown=$((shown + 1))
    printf '%d. %s\n' "${shown}" "$(cat "${item_script%.sh}.title")"
  done
  exit 0
fi

echo "Running ${MODULE}. Finished steps are scored as Grade: N/${step_count}."
echo "Run this once, before cleanup."

passed=0
total=0
failed_file="${WORK}/failed.txt"
: > "${failed_file}"

for item_script in "${item_scripts[@]+"${item_scripts[@]}"}"; do
  item_base="${item_script%.sh}"
  item_type="$(cat "${item_base}.type")"
  item_title="$(cat "${item_base}.title")"
  case "${item_type}" in
    setup)
      echo "==> Setup (not scored)"
      set +e
      run_bash_file "${item_script}"
      set -e
      # shellcheck disable=SC1090
      source "${ENV_DELTA}" || true
      if [[ -s "${PWD_FILE}" ]]; then
        cd "$(cat "${PWD_FILE}")" || true
      fi
      ;;
    bridge)
      echo "==> Extra command (not scored)"
      set +e
      run_bash_file "${item_script}"
      set -e
      # shellcheck disable=SC1090
      source "${ENV_DELTA}" || true
      if [[ -s "${PWD_FILE}" ]]; then
        cd "$(cat "${PWD_FILE}")" || true
      fi
      ;;
    step)
      total=$((total + 1))
      echo "==> ${total}/${step_count} ${item_title}"
      set +e
      run_bash_file "${item_script}"
      item_rc=$?
      set -e
      # shellcheck disable=SC1090
      source "${ENV_DELTA}" || true
      if [[ -s "${PWD_FILE}" ]]; then
        cd "$(cat "${PWD_FILE}")" || true
      fi
      if [[ "${item_rc}" -eq 0 ]]; then
        passed=$((passed + 1))
      else
        printf 'Failed: %s\n' "${item_title}" >> "${failed_file}"
      fi
      ;;
  esac
done

if [[ -s "${failed_file}" ]]; then
  cat "${failed_file}"
fi
echo "Grade: ${passed}/${total}"
