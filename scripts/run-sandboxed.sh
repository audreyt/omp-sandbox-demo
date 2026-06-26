#!/usr/bin/env bash
# run-sandboxed.sh — launch omp under srt with the demo's settings.
#
# Verifies srt is on PATH, picks a settings file (--settings arg or ~/.srt-settings.json),
# sets OMP_SANDBOX=srt so the omp sandbox-aware extension can reflect state in the TUI,
# and passes through -- before omp so omp's arg parser gets the trailing args correctly
# (without --, srt --version would consume flags intended for omp; verified in the demo).
#
# The OS barrier (bubblewrap on Linux, sandbox-exec on macOS) applies to every bash
# subprocess omp spawns, by process inheritance from fork(). The omp-aware extension
# is awareness-only — it does NOT intercept bash, does NOT import SandboxManager,
# does NOT need createBashTool (which is absent from omp v16.1.21 anyway).
#
# Usage:
#   ./scripts/run-sandboxed.sh                    # launches omp interactively
#   ./scripts/run-sandboxed.sh -p "echo hi"       # omp print mode
#   ./scripts/run-sandboxed.sh --settings /path/to/alt.json -- omp --no-lsp "hi"
#   ./scripts/run-sandboxed.sh --self-test        # verify barrier + omp boots, exit 0/1
#   ./scripts/run-sandboxed.sh --print-settings    # print the resolved srt config (`--print-profile` alias)
#
# Env-var config (optional; generated only when no explicit/default settings file exists):
#   OMP_SANDBOX_WORKSPACE     launch cwd/workspace root (default $PWD)
#   OMP_SANDBOX_EXTRA_WRITE   colon-separated extra writable paths (leading ~ → $HOME)
#   OMP_SANDBOX_DENY_READ     colon-separated extra read-denied paths, appended to defaults
#   OMP_SANDBOX_ALLOW_DOMAINS colon-separated allowed network domains (default: demo list)
#   OMP_SANDBOX_DENY_DOMAINS  colon-separated denied network domains
#   OMP_SANDBOX_YOLO=1        pass --auto-approve to omp (opt-in; does not affect settings)
#
# Settings precedence: --settings <path> > existing ~/.srt-settings.json > env-generated
# temp settings > srt's bare default (all egress blocked). This preserves drop-in
# compatibility for users who already have ~/.srt-settings.json, while still allowing
# no-JSON env-var generation on fresh installs.
#
# All args after the optional --settings/--self-test/--print-settings/--print-profile are forwarded to omp via `--`.

set -euo pipefail
ORIGINAL_PWD="$PWD"

SETTINGS="${HOME}/.srt-settings.json"
OMP_ARGS=()
DO_SELF_TEST=0
DO_PRINT_SETTINGS=0
USE_ENV_CONFIG=0

# Detect env-config mode: any boundary-shaping OMP_SANDBOX_* var set means
# generate-on-the-fly. OMP_SANDBOX_YOLO is intentionally excluded — it is
# orthogonal (it feeds --auto-approve at launch, not the settings file) and
# triggering generation on YOLO alone would silently override an existing
# ~/.srt-settings.json, breaking drop-in compatibility.
# Precedence: --settings <path> > existing ~/.srt-settings.json > env-generated > srt default.
for _v in OMP_SANDBOX_WORKSPACE OMP_SANDBOX_EXTRA_WRITE OMP_SANDBOX_DENY_READ \
          OMP_SANDBOX_ALLOW_DOMAINS OMP_SANDBOX_DENY_DOMAINS; do
  if [ -n "${!_v:-}" ]; then USE_ENV_CONFIG=1; break; fi
done
# Even with env vars set, an explicit --settings (USE_ENV_CONFIG=0, set below)
# wins, and an existing ~/.srt-settings.json at the default path wins too.
if [ "$SETTINGS" = "$HOME/.srt-settings.json" ] && [ -f "$SETTINGS" ]; then
  USE_ENV_CONFIG=0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --settings)
      SETTINGS="$2"; shift 2; USE_ENV_CONFIG=0 ;;   # explicit file wins over env-config
    --settings=*)
      SETTINGS="${1#--settings=}"; shift; USE_ENV_CONFIG=0 ;;
    --self-test)
      DO_SELF_TEST=1; shift; ;;
    --print-settings|--print-profile)
      DO_PRINT_SETTINGS=1; shift; ;;
    --)
      shift; OMP_ARGS+=("$@"); break; ;;
    *)
      OMP_ARGS+=("$1"); shift; ;;
  esac
done
# Resolve explicit relative --settings before we potentially cd to the workspace.
case "$SETTINGS" in
  "~"*) SETTINGS="${HOME}${SETTINGS#\~}" ;;
esac
case "$SETTINGS" in
  /*) ;;
  *) SETTINGS="${ORIGINAL_PWD}/${SETTINGS}" ;;
esac


# For --print-settings we neither launch srt nor omp — the printed config is the
# only output. Skip the srt/omp/Linux-dep gate so review works on a bare checkout.
# (--self-test still needs srt + omp; it falls through to the gate.)
if [ "$DO_PRINT_SETTINGS" = 0 ]; then
  if ! command -v srt >/dev/null 2>&1; then
    echo "srt not found on PATH. Install with: npm install -g @anthropic-ai/sandbox-runtime" >&2
    exit 1
  fi
  if ! command -v omp >/dev/null 2>&1; then
    echo "omp not found on PATH. Install omp from https://github.com/can1357/oh-my-pi/releases" >&2
    exit 1
  fi

  # Linux needs bubblewrap + socat on PATH so srt can build its mux/HTTP bridge.
  if [[ "$(uname -s)" == "Linux" ]]; then
    for dep in bwrap socat; do
      if ! command -v "$dep" >/dev/null 2>&1; then
        echo "warning: $dep not on PATH. srt on Linux needs bubblewrap + socat (apt-get install bubblewrap socat)." >&2
      fi
    done
  fi
fi

WORKSPACE_RAW="${OMP_SANDBOX_WORKSPACE:-$PWD}"
case "$WORKSPACE_RAW" in "~"*) WORKSPACE_RAW="${HOME}${WORKSPACE_RAW#\~}" ;; esac
if [ ! -d "$WORKSPACE_RAW" ]; then
  echo "run-sandboxed.sh: error: workspace '$WORKSPACE_RAW' does not exist" >&2
  exit 1
fi
WORKSPACE="$(cd "$WORKSPACE_RAW" && pwd -P)"
if [ "$WORKSPACE" = "/" ] || [ "$WORKSPACE" = "$HOME" ]; then
  echo "run-sandboxed.sh: warning: workspace is '$WORKSPACE' — this grants broad project access" >&2
fi

# --- generate settings from env vars when requested ---
GENERATED_SETTINGS=""
cleanup_generated() { [ -n "$GENERATED_SETTINGS" ] && rm -f "$GENERATED_SETTINGS" 2>/dev/null || true; }

if [ "$USE_ENV_CONFIG" = 1 ]; then
  GENERATED_SETTINGS="$(mktemp -t omp-sandbox-settings.XXXXXX.json)"
  trap cleanup_generated EXIT

  # JSON-string-escape a value (backslash + double-quote). Reject newlines:
  # they make config review ambiguous and are not useful for sandbox paths/domains.
  esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  normalize_path() {
    local _v="$1"
    case "$_v" in *$'\n'*)
      echo "run-sandboxed.sh: error: path contains a newline and cannot be used in generated settings: $_v" >&2
      exit 1
      ;;
    esac
    case "$_v" in "~"*) _v="${HOME}${_v#\~}" ;; esac
    printf '%s' "$_v"
  }
  append_write_path() {
    local _v _ev
    _v="$(normalize_path "$1")"
    _ev="$(esc "$_v")"
    _w_lines+=("    \"$_ev\",")
  }
  append_deny_read_path() {
    local _v _ev
    _v="$(normalize_path "$1")"
    _ev="$(esc "$_v")"
    _dr_lines+=("    \"$_ev\",")
  }

  # Build writable-paths array: workspace + required omp/runtime paths + extras.
  _w_lines=()
  append_write_path "$WORKSPACE"
  append_write_path "/tmp"
  append_write_path "$HOME/.omp"
  if [ -n "${OMP_SANDBOX_EXTRA_WRITE:-}" ]; then
    IFS=':' read -ra _ew <<< "$OMP_SANDBOX_EXTRA_WRITE"
    for _p in "${_ew[@]}"; do [ -n "$_p" ] && append_write_path "$_p"; done
  fi

  # Build deny-read array. These defaults match srt-settings.example.json and keep
  # --self-test's /etc/passwd canary coherent; OMP_SANDBOX_DENY_READ appends extras.
  _dr_lines=()
  append_deny_read_path "/etc/passwd"
  _dr_lines+=("    \"~/.ssh\",")
  _dr_lines+=("    \"~/.aws\",")
  _dr_lines+=("    \"~/.gnupg\",")
  if [ -n "${OMP_SANDBOX_DENY_READ:-}" ]; then
    IFS=':' read -ra _dr <<< "$OMP_SANDBOX_DENY_READ"
    for _p in "${_dr[@]}"; do [ -n "$_p" ] && append_deny_read_path "$_p"; done
  fi

  # Build allowed-domains array (default = demo list).
  _ad_lines=()
  _ad="${OMP_SANDBOX_ALLOW_DOMAINS:-api.anthropic.com:github.com:*.github.com:raw.githubusercontent.com:registry.npmjs.org:registry.yarnpkg.com:pypi.org:*.pypi.org}"
  IFS=':' read -ra _adarr <<< "$_ad"
  for _d in "${_adarr[@]}"; do
    [ -n "$_d" ] || continue
    _ed="$(esc "$_d")"
    _ad_lines+=("    \"$_ed\",")
  done

  # Build denied-domains array (no default).
  _dd_lines=()
  if [ -n "${OMP_SANDBOX_DENY_DOMAINS:-}" ]; then
    IFS=':' read -ra _ddarr <<< "$OMP_SANDBOX_DENY_DOMAINS"
    for _d in "${_ddarr[@]}"; do
      [ -n "$_d" ] || continue
      _ed="$(esc "$_d")"
      _dd_lines+=("    \"$_ed\",")
    done
  fi

  # Emit a JSON array body from a lines array, stripping the trailing comma on the last.
  emit_array_body() {
    local _n=${#@} _i=1 _line
    [ "$_n" = 0 ] && { echo; return; }
    for _line in "$@"; do
      if [ "$_i" = "$_n" ]; then
        printf '%s\n' "${_line%,}"   # last: drop trailing comma
      else
        printf '%s\n' "$_line"
      fi
      _i=$((_i+1))
    done
  }

  {
    printf '{\n'
    printf '  "network": {\n'
    printf '    "allowedDomains": [\n'
    emit_array_body "${_ad_lines[@]}"
    printf '    ],\n'
    if [ "${#_dd_lines[@]}" = 0 ]; then
      printf '    "deniedDomains": []\n'
    else
      printf '    "deniedDomains": [\n'
      emit_array_body "${_dd_lines[@]}"
      printf '    ]\n'
    fi
    printf '  },\n'
    printf '  "filesystem": {\n'
    if [ "${#_dr_lines[@]}" = 0 ]; then
      printf '    "denyRead": [],\n'
    else
      printf '    "denyRead": [\n'
      emit_array_body "${_dr_lines[@]}"
      printf '    ],\n'
    fi
    printf '    "allowWrite": [\n'
    emit_array_body "${_w_lines[@]}"
    printf '    ],\n'
    printf '    "denyWrite": [".env", ".env.*", "*.pem", "*.key"]\n'
    printf '  }\n'
    printf '}\n'
  } > "$GENERATED_SETTINGS"
  SETTINGS="$GENERATED_SETTINGS"
fi

if [ "$DO_PRINT_SETTINGS" = 1 ]; then
  echo "settings: $SETTINGS"
  if [ -f "$SETTINGS" ]; then cat "$SETTINGS"; else echo "(missing)"; fi
  cleanup_generated
  exit 0
fi
# From here on, relative paths in omp commands resolve inside the configured workspace.
cd "$WORKSPACE"


if [ "$DO_SELF_TEST" = 1 ]; then
  echo "settings: $SETTINGS"
  echo "srt:      $(command -v srt)"
  echo "omp:      $(command -v omp)"
  echo "workspace: $WORKSPACE"
  echo
  _fail=0
  # 0. Baseline: srt must be able to launch a harmless command. Without this,
  # macOS sandbox-exec setup failures can look like "Operation not permitted" and
  # falsely satisfy the deny canary below.
  _baseline_out="$(srt --settings "$SETTINGS" -- bash -c 'true' 2>&1 || true)"
  if [ -n "$_baseline_out" ]; then
    echo "FAIL: srt could not launch a baseline command. Got:"
    printf '%s\n' "$_baseline_out" | head -3
    cleanup_generated
    exit 1
  fi
  echo "PASS: srt launches baseline command"


  # 1. DENY canary: /etc/passwd is in denyRead → srt should produce Permission denied.
  if [ -f "$SETTINGS" ]; then
    _deny_out="$(srt --settings "$SETTINGS" -- bash -c 'cat /etc/passwd 2>&1' 2>&1 || true)"
    if printf '%s\n' "$_deny_out" | grep -qiE "permission denied|operation not permitted"; then
      echo "PASS: /etc/passwd read denied (sandbox boundary enforced)"
    else
      echo "FAIL: /etc/passwd read was NOT denied. Got:"; printf '%s\n' "$_deny_out" | head -3
      _fail=1
    fi
  else
    echo "SKIP: /etc/passwd deny (no settings file)"
  fi

  # 2. ALLOW canary: /etc/hostname is NOT denylisted → should pass through.
  if [ -f "$SETTINGS" ]; then
    _allow_out="$(srt --settings "$SETTINGS" -- bash -c 'cat /etc/hostname 2>&1' 2>&1 || true)"
    if printf '%s\n' "$_allow_out" | grep -qiE "permission denied|operation not permitted|no such file"; then
      echo "FAIL: /etc/hostname read was unexpectedly denied. Got:"; printf '%s\n' "$_allow_out" | head -3
      _fail=1
    else
      echo "PASS: /etc/hostname read allowed (non-denylisted reads pass through)"
    fi
  else
    echo "SKIP: /etc/hostname allow (no settings file)"
  fi

  # 3. NETWORK canary: example.com is NOT allowlisted → egress blocked.
  if [ -f "$SETTINGS" ] && command -v curl >/dev/null 2>&1; then
    _net_out="$(srt --settings "$SETTINGS" -- bash -c 'curl -sS --max-time 5 -o /dev/null -w "%{http_code}" https://example.com 2>&1' 2>&1 || true)"
    if printf '%s\n' "$_net_out" | grep -qiE "could not resolve|connection refused|failed to connect|name resolution|000"; then
      echo "PASS: https://example.com blocked (not in allowlist)"
    else
      echo "WARN: https://example.com not blocked. Got:"; printf '%s\n' "$_net_out" | head -3
    fi
  else
    echo "note: skipping network canary (no settings file or curl unavailable)"
  fi

  # 4. omp boots under the barrier — the headlining assertion the prior demo lacked.
  if _omp_ver="$(srt --settings "$SETTINGS" -- omp --version 2>&1)" && \
     printf '%s\n' "$_omp_ver" | grep -q -- '^omp/'; then
    echo "PASS: omp boots under sandbox ($_omp_ver)"
  else
    echo "FAIL: omp does NOT boot under sandbox. Got:"; printf '%s\n' "$_omp_ver" | head -5 >&2
    _fail=1
  fi

  # 5. --auto-approve accepted by the installed omp (catches flag drift).
  if srt --settings "$SETTINGS" -- omp --auto-approve --version 2>&1 | grep -q -- '^omp/'; then
    echo "PASS: --auto-approve flag accepted by omp"
  else
    echo "FAIL: --auto-approve flag rejected by omp (flag drift)"
    _fail=1
  fi

  # 6. OMP_SANDBOX env marker visible inside the sandbox.
  _env_out="$(OMP_SANDBOX=srt srt --settings "$SETTINGS" -- /usr/bin/env 2>/dev/null || true)"
  if printf '%s\n' "$_env_out" | grep -qx 'OMP_SANDBOX=srt'; then
    echo "PASS: OMP_SANDBOX env marker set inside sandbox"
  else
    echo "FAIL: OMP_SANDBOX env marker not visible inside sandbox"
    _fail=1
  fi

  cleanup_generated
  exit "$_fail"
fi

if [ "$USE_ENV_CONFIG" = 0 ] && [ ! -f "$SETTINGS" ]; then
  echo "note: $SETTINGS not found — srt will use its default config ({ \"allowedHosts\": [] }, all egress blocked)." >&2
  echo "      copy srt-settings.example.json from this repo to ~/.srt-settings.json," >&2
  echo "      or set OMP_SANDBOX_WORKSPACE / OMP_SANDBOX_ALLOW_DOMAINS env vars to generate a config." >&2
fi

# OMP_SANDBOX is set in the OS env so the awareness extension sees it. (OMP_*→PI_*
# aliasing does NOT apply to OS env vars — only to .env-read vars. The extension reads
# process.env.OMP_SANDBOX ?? process.env.PI_SANDBOX to cover both.)
# OMP_SANDBOX_SETTINGS points the extension at the exact settings file this wrapper
# passed to srt (including --settings overrides and generated temp settings).
export OMP_SANDBOX=srt
export OMP_SANDBOX_SETTINGS="$SETTINGS"

LAUNCH_ARGS=()
if [ "${OMP_SANDBOX_YOLO:-0}" = 1 ]; then
  LAUNCH_ARGS+=(--auto-approve)
fi

# The `--` before omp is load-bearing: it tells srt to stop parsing flags and forward
# the rest to omp's arg parser. Without it, srt --version consumes omp's --version.
exec srt --settings "$SETTINGS" -- omp "${LAUNCH_ARGS[@]}" "${OMP_ARGS[@]}"
