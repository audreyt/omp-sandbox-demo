#!/usr/bin/env bash
# home-node-stat.sh — regression canary for the home-node-stat read model.
#
# The omp-sandbox macOS sibling (bnivanov/omp-sandbox) discovered a bug class
# where a `$HOME`-subtree blanket read-deny (`(deny file-read* (subpath "$HOME"))`
# followed by narrow `(subpath ...)` re-allows) breaks Go binaries that
# canonicalize paths from the root: `filepath.EvalSymlinks` / `os.MkdirAll` issue
# an explicit `stat()` on `/Users/<user>` during traversal, Seatbelt denies that
# stat (the re-allows cover only descendants, never the `$HOME` node), and any
# Go tool with a SQLite store at an allowlisted `$HOME` subdir fails with
# SQLite CANTOPEN (14). The fix is one `(allow file-read-metadata (literal
# "$HOME"))` rule. Upstream PR: https://github.com/bnivanov/omp-sandbox/pull/2
#
# This demo's srt wrapper does NOT emit SBPL — it builds srt JSON settings
# (denylist-only denyRead, no blanket $HOME deny) and delegates seatbelt
# generation to srt. srt's macOS backend therefore exposes no `$HOME`-subtree
# blanket read-deny, so the home-node-stat gap does not reproduce here today.
#
# This test pins that property. It asserts:
#   (a) stat of "$HOME" itself is allowed  (Go path canonicalization works)
#   (b) readdir of "$HOME" is allowed  (locks the read-OPEN-by-default property;
#       a future metadata-only home-node carve-out would flip just (a), forcing
#       an informed decision about whether top-level $HOME names should be
#       disclosed — same narrowness discipline as omp-sandbox PR #2 self-tests
#       #11 (stat allowed) and #12 (readdir denied), but inverted for srt's
#       read-OPEN-by-default model)
#   (c) a write to a non-allowlisted path (/etc/.<canary>) is denied  (barrier
#       is not silently disabled — failure here would turn (a)/(b) into a
#       trivial pass, the exact trap the parent smoke.sh warns about. Uses a
#       write-denial canary instead of a read-denial one because srt's macOS
#       sandbox-exec backend honors `allowWrite` (denyAllExcept for writes) but
#       does not consistently honor `denyRead` for `/etc/passwd` on macOS — a
#       read-deny canary was red-on-arrival on the platform this test exists
#       for, unable to distinguish "barrier disabled" from "srt denyRead
#       limitation". The write canary goes green exactly when the barrier is
#       operational on both Linux and macOS.)
# If srt's macOS backend ever regresses toward a `$HOME`-subtree blanket
# read-deny (or the demo wrapper introduces one), (a) and (b) both flip to FAIL
# while (c) still passes — the same diagnostic shape as the omp-sandbox bug
# class this test is the mirror of.
#
# Run: ./test/home-node-stat.sh [path/to/srt-settings.json]
#   (default: ../srt-settings.example.json)
# Exit: 0 on pass, non-zero on any failure.
#
# Verified-passing: Linux/aarch64 (OrbStack Ubuntu 24.04), srt 1.0.0, omp v16.1.21,
#   and macOS/arm64, srt 1.0.0 — settings ~= example.json. The write canary is
#   enforced by bubblewrap (Linux) and sandbox-exec (macOS) on their respective
#   backends, so all three assertions go green on both platforms. (The earlier
#   version of this test used a `/etc/passwd` read-deny canary that was red-on-
#   arrival on macOS due to srt 1.0.0's known `denyRead` non-enforcement on
#   macOS; the write-deny canary is platform-agnostic. See commit history.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${1:-${SCRIPT_DIR}/../srt-settings.example.json}"

if ! command -v srt >/dev/null 2>&1; then
  echo "FAIL: srt not on PATH (npm install -g @anthropic-ai/sandbox-runtime)" >&2
  exit 1
fi
if [[ ! -f "$SETTINGS" ]]; then
  echo "FAIL: $SETTINGS not found" >&2
  exit 1
fi

echo "settings: $SETTINGS"
echo "srt:      $(command -v srt)"
echo "home:     ${HOME:-<unset>}"

if [[ -z "${HOME:-}" || ! -d "$HOME" ]]; then
  echo "FAIL: \$HOME unset or non-existent — cannot test home-node stat" >&2
  exit 1
fi

# 0. Baseline: srt must launch a harmless command before we assert anything.
# macOS sandbox-exec setup failures surface as "Operation not permitted" and
# would otherwise falsely satisfy the deny assertion below (same trap as
# smoke.sh).
BASELINE_OUT="$(srt --settings "$SETTINGS" -- bash -c 'true' 2>&1 || true)"
if [[ -n "$BASELINE_OUT" ]]; then
  echo "FAIL: srt could not launch a baseline command. Got:" >&2
  echo "$BASELINE_OUT" | head -3 >&2
  exit 2
fi
echo "PASS: srt launches baseline command"

# 1. The home-node-stat assertion: `stat "$HOME"` MUST succeed under srt.
#    Go binaries (and most runtimes that call filepath.EvalSymlinks / os.MkdirAll
#    on a path inside $HOME) need this to canonicalize the path. A blanket
#    $HOME-subtree read-deny breaks it.
#
#    Adversarial note: `stat` passes under BOTH (allow file-read-metadata $HOME)
#    AND (allow file-read* $HOME) — it does NOT distinguish "metadata only" from
#    "data incl. readdir". So assertion (a) alone does not prove read-OPEN-by-
#    default; assertion (b) (readdir) is what locks the property in. We assert
#    (a) stat allowed, (b) readdir allowed, (c) deny still enforced — the
#    combination that pins srt's current read-OPEN-by-default model for $HOME.
STAT_OUT="$(srt --settings "$SETTINGS" -- bash -c 'stat "$HOME" >/dev/null 2>&1 && echo STAT_OK || echo STAT_DENIED' 2>&1 || true)"
case "$STAT_OUT" in
  *STAT_OK*)    echo "PASS: stat \$HOME allowed (Go path canonicalization works)" ;;
  *STAT_DENIED*)
    echo "FAIL: stat \$HOME denied — srt's read model blocks home-node stat." >&2
    echo "      A Go binary opening a file in an allowlisted \$HOME subdir would fail" >&2
    echo "      with SQLite CANTOPEN / 'mkdir <home>: file exists'. This is the" >&2
    echo "      omp-sandbox bug class — see bnivanov/omp-sandbox PR #2." >&2
    exit 3 ;;
  *)
    echo "FAIL: stat \$HOME produced unexpected output:" >&2
    echo "$STAT_OUT" | head -3 >&2
    exit 3 ;;
esac

# 2. readdir of $HOME: srt's read-OPEN-by-default means this is also allowed
#    today. We assert it explicitly so that ANY future narrowing of srt's
#    read-deny model for $HOME (toward the omp-sandbox shape) flips BOTH this
#    assertion AND assertion 1 — a single rule change cannot quietly disable
#    just one. If srt ever introduces a metadata-only home-node carve-out,
#    this assertion flips and forces an informed decision about whether
#    top-level $HOME entry names should be disclosed.
LS_OUT="$(srt --settings "$SETTINGS" -- bash -c 'ls "$HOME" >/dev/null 2>&1 && echo LS_OK || echo LS_DENIED' 2>&1 || true)"
case "$LS_OUT" in
  *LS_OK*)    echo "PASS: readdir \$HOME allowed (srt read-OPEN-by-default for \$HOME)" ;;
  *LS_DENIED*)
    echo "FAIL: readdir \$HOME denied — srt's read model no longer allows listing \$HOME." >&2
    echo "      This demo was built assuming reads work unless explicitly denylisted;" >&2
    echo "      the wrapper config or srt backend has narrowed beyond that. Review" >&2
    echo "      filesystem.denyRead in the active settings and srt's macOS backend." >&2
    exit 4 ;;
  *)
    echo "FAIL: readdir \$HOME produced unexpected output:" >&2
    echo "$LS_OUT" | head -3 >&2
    exit 4 ;;
esac

# 3. Non-trivial-pass guard: a write to a NON-allowlisted path (/etc/.<canary>)
#    MUST be denied. Without this, (a) and (b) could pass trivially under a
#    profile that had been broken to allow-all — the trap the parent smoke.sh
#    warns about. Uses a write-deny canary instead of a read-deny one because
#    srt's macOS sandbox-exec backend honors `allowWrite` (denyAllExcept for
#    writes) but does NOT consistently honor `denyRead` on macOS the way
#    bubblewrap does on Linux: a `/etc/passwd` read-deny canary was red-on-
#    arrival on the platform this test exists for, unable to distinguish
#    "barrier disabled" from "srt's macOS denyRead limitation". The write canary
#    is platform-agnostic and goes green exactly when the barrier is
#    operational. Verified: srt 1.0.0 macOS denies `echo x > /etc/.<canary>`
#    with "Operation not permitted".
_HOME_NODE_CANARY="/etc/.srt_home_node_canary.$$"
WRITE_DENY_OUT="$(srt --settings "$SETTINGS" -- bash -c "echo x > '$_HOME_NODE_CANARY' 2>&1; echo rc=\$?" 2>&1 || true)"
case "$WRITE_DENY_OUT" in
  *Operation\ not\ permitted*|*Permission\ denied*|*"rc=1"*)
    echo "PASS: non-allowlisted write denied (barrier still enforced)" ;;
  *)
    echo "FAIL: write to '$_HOME_NODE_CANARY' was NOT denied — barrier may be" >&2
    echo "      silently disabled; (a) and (b) lose their non-trivial-pass guard." >&2
    echo "Got:" >&2
    echo "$WRITE_DENY_OUT" | head -3 >&2
    exit 5 ;;
esac

echo
echo "home-node-stat test passed: srt permits home-node stat/readdir, barrier is still enforced."
