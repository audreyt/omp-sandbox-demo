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
#
# All args after the optional --settings <path> are forwarded to omp via `--`.

set -euo pipefail

SETTINGS="${HOME}/.srt-settings.json"
OMP_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --settings)
      SETTINGS="$2"; shift 2; ;;
    --settings=*)
      SETTINGS="${1#--settings=}"; shift; ;;
    --)
      shift; OMP_ARGS+=("$@"); break; ;;
    *)
      OMP_ARGS+=("$1"); shift; ;;
  esac
done

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

if [[ ! -f "$SETTINGS" ]]; then
  echo "note: $SETTINGS not found — srt will use its default config ({ \"allowedHosts\": [] }, all egress blocked)." >&2
  echo "      copy srt-settings.example.json from this repo to ~/.srt-settings.json if you want the demo's allowlist." >&2
fi

# OMP_SANDBOX is set in the OS env so the awareness extension sees it. (OMPI_*→PI_*
# aliasing does NOT apply to OS env vars — only to .env-read vars. The extension reads
# process.env.OMP_SANDBOX ?? process.env.PI_SANDBOX to cover both.)
export OMP_SANDBOX=srt

# The `--` before omp is load-bearing: it tells srt to stop parsing flags and forward
# the rest to omp's arg parser. Without it, srt --version consumes omp's --version.
exec srt --settings "$SETTINGS" -- omp ${OMP_ARGS[@]+"${OMP_ARGS[@]}"}
