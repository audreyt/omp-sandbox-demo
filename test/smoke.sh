#!/usr/bin/env bash
# smoke.sh — verify the sandbox barrier is actually enforced by srt.
#
# This is the one verifiable end-to-end behavior that doesn't need a model API
# key (which makes it the right smoke test for a demo): if srt is installed and
# the demo's srt-settings.example.json is in place, the barrier must deny
# /etc/passwd reads (it's in denyRead) and allow /etc/hostname reads (it isn't).
# We assert both halves, because "everything is denied" is the trivial pass and
# would also pass the deny assertion.
#
# Run: ./test/smoke.sh [path/to/srt-settings.json]   (default: ../srt-settings.example.json)
# Exit: 0 on pass, non-zero on any failure.

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

# 0. Baseline: srt must be able to launch a harmless command. Without this,
# macOS sandbox-exec setup failures can look like "Operation not permitted" and
# falsely satisfy the deny canary below.
BASELINE_OUT="$(srt --settings "$SETTINGS" -- bash -c 'true' 2>&1 || true)"
if [[ -n "$BASELINE_OUT" ]]; then
  echo "FAIL: srt could not launch a baseline command. Got:" >&2
  echo "$BASELINE_OUT" | head -3 >&2
  exit 2
fi
echo "PASS: srt launches baseline command"

# 1. The DENY canary: /etc/passwd is in denyRead -> srt should produce
#    "Permission denied" (Linux/bwrap) or "Operation not permitted" (macOS/sandbox-exec).
DENY_OUT="$(srt --settings "$SETTINGS" -- bash -c 'cat /etc/passwd 2>&1' 2>&1 || true)"
if echo "$DENY_OUT" | grep -qiE "permission denied|operation not permitted"; then
  echo "PASS: /etc/passwd read denied (sandbox boundary enforced)"
else
  echo "FAIL: /etc/passwd read was NOT denied. Got:" >&2
  echo "$DENY_OUT" | head -3 >&2
  exit 2
fi

# 2. The ALLOW canary: /etc/hostname is NOT in denyRead -> srt should echo its contents.
ALLOW_OUT="$(srt --settings "$SETTINGS" -- bash -c 'cat /etc/hostname 2>&1' 2>&1 || true)"
if echo "$ALLOW_OUT" | grep -qiE "permission denied|operation not permitted|no such file"; then
  echo "FAIL: /etc/hostname read was unexpectedly denied. Got:" >&2
  echo "$ALLOW_OUT" | head -3 >&2
  exit 3
else
  echo "PASS: /etc/hostname read allowed (non-denylisted reads pass through)"
fi

# 3. The network canary: example.com is NOT in allowedDomains -> egress blocked.
#    Using curl (or wget) if available. The exact error varies ("could not resolve host",
#    "Connection refused", "Failed to connect"). We assert the connection did NOT succeed.
if command -v curl >/dev/null 2>&1; then
  NET_OUT="$(srt --settings "$SETTINGS" -- bash -c 'curl -sS --max-time 5 -o /dev/null -w "%{http_code}" https://example.com 2>&1' 2>&1 || true)"
  if echo "$NET_OUT" | grep -qiE "could not resolve|connection refused|failed to connect|name resolution|000"; then
    echo "PASS: https://example.com blocked (not in allowlist)"
  else
    echo "WARN: https://example.com was not blocked as expected. Got:" >&2
    echo "$NET_OUT" | head -3 >&2
    echo "     (your srt config or your resolver may be more permissive than the demo default)" >&2
  fi
else
  echo "note: curl not available, skipping network canary"
fi

echo
echo "smoke test passed: srt barrier is enforced, denylist works, allowlist is non-trivial."
