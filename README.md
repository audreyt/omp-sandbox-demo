# omp-sandbox-demo v0

A working, verifiable demo of running [omp](https://github.com/can1357/oh-my-pi) under [Anthropic's `srt` sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime), so every bash command omp issues is OS-level sandboxed — and so the model *knows* it's sandboxed and doesn't blind-retry / chmod-escalate / disable-the-barrier on EPERM.

This README documents the v0 design and the findings that motivated it. Every claim below is marked **[verified]** with the command that was observed producing it during development, or **[unverified]** when not. The whole point of v0 is honesty about what actually works on omp today (v16.1.21).

## TL;DR — what this repo ships

- **`knowledge/RULES.md`** — the sandbox contract, written for `~/.omp/agent/RULES.md`. Sticky: omp re-attaches it near the current turn, so it survives long sessions that push opening context out of window. **This is the headline deliverable.** Knowledge comes FIRST; the runtime extension is a complement, not a substitute.
- **`knowledge/AGENTS.md`** — advisory background, written for `~/.omp/agent/AGENTS.md`. Opens once, explains *why* the barrier exists and *how* srt wraps omp.
- **`knowledge/APPEND_SYSTEM.md`** — the same contract as a `<system>`-prompt block, alternative to `RULES.md` for users who want prompt-level instead of file-level enforcement. **Pick ONE, not both.**
- **`extension/index.ts`** + **`extension/package.json`** — a 110-line awareness extension (`registerFlag`, `session_start` status line, `registerCommand("sandbox", ...)`). Imports `ExtensionAPI` as a type only, so omp erases it at compile time and there are zero runtime deps.
- **`scripts/run-sandboxed.sh`** — launch wrapper. `export OMP_SANDBOX=srt` + `srt --settings ~/.srt-settings.json -- omp "$@"`. The `--` is load-bearing (see [Gotchas](#gotchas)).
- **`srt-settings.example.json`** — an illustrative config (not srt's bare default — see [Gotchas](#gotchas)). Copy to `~/.srt-settings.json`. Includes `~/.omp` in `allowWrite` so omp doesn't crash at startup.
- **`test/smoke.sh`** — three assertions: denylisted path denied, non-denylisted path allowed, non-allowlisted host blocked. All were observed passing during v0 development.

## The architecture (and why it's the shape it is)

The shippable design wraps the omp *process* externally with srt — `srt -- omp` — and lets the OS barrier (bubblewrap on Linux, sandbox-exec on macOS) apply to every bash subprocess omp spawns via fork()-inheritance. The extension does NOT intercept bash, does NOT import srt's `SandboxManager` library, and does NOT need `createBashTool` (which omp v16.1.21 refactored away anyway — **[verified]**, see [What didn't work](#what-didnt-work)).

This is a deliberate departure from pi-mono's `examples/extensions/sandbox/index.ts`, which imports `SandboxManager` and wraps each bash command in-process. **[verified]** That example does NOT port to omp via the `#441` sed procedure — three independent failures, each reproduced against a running binary in an OrbStack Ubuntu 24.04 / aarch64 container with omp v16.1.21. See [What didn't work](#what-didnt-work) for the whole diagnosis, because it's what makes the launch-wrapper design not just convenient but *required*.

### Two layers, knowledge first

1. **Knowledge layer** — `RULES.md` / `AGENTS.md` / `APPEND_SYSTEM.md`. The artifact the user actually cares about. Turns "permission denied" from a model surprise into something the model treats as a sandbox signal. Without this layer, no amount of runtime enforcement helps: the model will blind-retry, then escalate to chmod/chown/mount/sudo, then conclude the path is corrupt, then disable SELinux/AppArmor.
2. **Runtime layer** — the external `srt` wrapper + the minimal awareness extension. Enforces the barrier (OS-level) and reflects sandbox state in the TUI status line + `/sandbox` slash command.

The knowledge layer is primary. The runtime layer is a complement. v0 makes this distinction explicit because three prior turns of this demo's design confused them.

## Quick start (verified against OrbStack Ubuntu 24.04 / omp v16.1.21)

```bash
# 1. Install omp + srt + Linux deps
#    macOS: brew install can1357/tap/omp; npm install -g @anthropic-ai/sandbox-runtime
#    Linux: download omp-linux-arm64 (or x64) from
#           https://github.com/can1357/oh-my-pi/releases/latest
#           npm install -g @anthropic-ai/sandbox-runtime
#           apt-get install bubblewrap socat ripgrep curl

# 2. Copy the demo's settings into place
cp srt-settings.example.json ~/.srt-settings.json

# 3. Install the awareness extension
cp -r extension ~/.omp/agent/extensions/sandbox-aware   # then:
omp plugin install ~/.omp/agent/extensions/sandbox-aware # registers in omp's tracker

# 4. Install the knowledge layer (pick ONE contract channel — RULES.md OR APPEND_SYSTEM.md):
cp knowledge/RULES.md           ~/.omp/agent/RULES.md           # file-level, sticky, re-attached
# OR — not AND:
cp knowledge/APPEND_SYSTEM.md   ~/.omp/agent/APPEND_SYSTEM.md   # prompt-level, lives in system prompt
# Advisory background, either way:
cp knowledge/AGENTS.md          ~/.omp/agent/AGENTS.md

# 5. Smoke test the barrier
./test/smoke.sh

# 6. Launch omp under srt
./scripts/run-sandboxed.sh     # interactive
./scripts/run-sandboxed.sh -p "echo \$OMP_SANDBOX"  # print mode
```

### Smoke test output [verified]

```
settings: /root/.srt-settings.demo.json
srt:      /usr/bin/srt
PASS: /etc/passwd read denied (sandbox boundary enforced)
PASS: /etc/hostname read allowed (non-denylisted reads pass through)
PASS: https://example.com blocked (not in allowlist)

smoke test passed: srt barrier is enforced, denylist works, allowlist is non-trivial.
```

### Status line + `/sandbox` command [verified]

When the extension is loaded, the TUI status line shows:

```
🔒 Sandbox: ON — 8 domains, 3 write, 4 deny-read (srt)
```

(Numbers come from your `~/.srt-settings.json` — `8 domains` is the demo's allowlist count; `3 write` is project root + /tmp + ~/.omp; `4 deny-read` is /etc/passwd + ~/.ssh + ~/.aws + ~/.gnupg.)

`/sandbox` slash command is registered — **[verified]** via `omp --mode rpc -p "noop"`: the `available_commands_update` event listed 47 commands including:

```
- sandbox | Show sandbox state. Reads OMP_SANDBOX/PI_SANDBOX and ~/.srt-settings.json. | source: extension
```

## Gotchas (each verified, then documented)

### `~/.omp` MUST be in `allowWrite`

Naive configs with only `[".", "/tmp"]` writable **[verified]** crash omp at startup with a confusing `SQLiteError: attempt to write a readonly database` on `~/.omp/agent/agent.db`, then if you widen only to `~/.omp/agent` you get `EROFS: read-only file system: open /root/.omp/logs/omp.<date>.log`. omp writes to BOTH `~/.omp/agent/` (DBs, sessions, blobs) AND `~/.omp/logs/` (the daily log). The demo config allows the whole `~/.omp` dir.

### The `--` separator is load-bearing in `srt -- omp …`

`srt --version` consumes the `--version` flag before omp's arg parser runs — **[verified] `srt omp --version` prints `1.0.0` (srt's version), not `omp/16.1.21`**. With `--`, omp's parser gets the trailing args: `srt -- omp --version` → `omp/16.1.21`. `run-sandboxed.sh` inserts the `--`.

### srt validates config with zod and `network` + `filesystem.*` are all REQUIRED

`srt` rejects config with top-level `allowedHosts` — **[verified]** error: `network: Required`. The schema requires a `network: { allowedDomains, deniedDomains }` object AND a `filesystem: { denyRead, allowWrite, denyWrite }` object. `filesystem.denyRead` is also required (the field is NOT optional). My demo's nested form is correct; the `allowedHosts` field name appears only in srt's INTERNAL `--debug` output, not the input schema.

### `srt`'s bare default blocks ALL network egress

With NO settings file, `srt --debug` reports `No config found, using default config` and `allowedHosts: []` — **[verified]**. The demo's non-empty allowlist is a deliberate relaxation so an agent can reach api.anthropic.com / github.com / npmjs.org / pypi.org out of the box. Replace it with your own.

### `srt` uses a sandbox-side mux/proxy for egress, not raw bubblewrap network rules

`srt --debug` shows `Mux proxy (HTTP+SOCKS) listening on localhost:<port>` and `socat UNIX-LISTEN:/tmp/claude-http-*.sock,fork,reuseaddr TCP:localhost:<port>`. Denied hosts fail at the proxy with `curl: (56) CONNECT tunnel failed, response 403` and curl exit `000`. Confirmed against github.com (not in demo allowlist): connection refused with HTTP 403 from the proxy.

### `OMP_*` → `PI_*` env aliasing is NOT symmetric

omp's `.env` parser mirrors `OMP_*` to `PI_*` for variables it reads from `~/.omp/agent/.env`. Variables passed in via the OS environment — `export OMP_SANDBOX=srt` or `OMP_SANDBOX=srt omp …` — are **NOT** mirrored **[verified]**: `process.env.PI_SANDBOX` is `undefined` even when `OMP_SANDBOX=srt` is in the OS env. The extension reads `OMP_SANDBOX ?? PI_SANDBOX` to cover both. Don't assume the alias is bidirectional.

### `srt` does NOT do project-local config merge

The pattern `<cwd>/.omp/sandbox.json` overriding `~/.srt-settings.json` is **[unverified, believed-false]** — that merge was the old pi-mono example extension's own `loadConfig`, not `srt`'s. `srt` reads exactly ONE config file (`~/.srt-settings.json` or whatever was passed to `--settings`). No demo artifact claims project-local merge.

### The extension is zero-runtime-deps

`@oh-my-pi/pi-coding-agent` is listed as a *type-only* import (`import type { ExtensionAPI }`) and an OPTIONAL peer dep. omp erases type-only imports at compile time, so the package is never resolved at runtime. **[verified]** the extension loads cleanly with `rm -rf node_modules` and no deps installed. This dodges the omp loader's failure mode for runtime imports of `@anthropic-ai/sandbox-runtime` (see [What didn't work](#what-didnt-work)).

### `set -u` + empty array on macOS bash 3.2 crashes the launch wrapper

\`run-sandboxed.sh\` uses \`set -euo pipefail\` and builds \`OMP_ARGS=()\` before the exec line. On **Linux** (bash 5.x) this is fine. On **macOS**, Apple ships **bash 3.2.57** as \`/bin/bash\`, where \`\\\"\${OMP_ARGS[@]}\\\"\` under \`set -u\` on an empty array throws \`OMP_ARGS[@]: unbound variable\` **[verified]** and the wrapper crashes before launching omp whenever invoked with no args. The fix is \`\${OMP_ARGS[@]+\\\"\${OMP_ARGS[@]}\\\"}\` — a no-op on empty arrays across all bash versions. Applied in this demo's \`run-sandboxed.sh\`. The same latent bug was found and fixed in the Seatbelt wrapper at [audreyt/omp-sandbox](https://github.com/audreyt/omp-sandbox).

### macOS sandbox-exec resolves symlinks against the real path

On macOS, \`srt\` uses \`sandbox-exec\` (Seatbelt) as its OS barrier. Seatbelt's path rules match the **kernel-resolved real path**, not the symlink's lexical path. The read impact differs from the [omp-sandbox](https://github.com/audreyt/omp-sandbox) Seatbelt wrapper: srt's reads are a **denylist** (\`denyRead\`), so a symlink into iCloud is NOT read-denied here — the demo's smoke test verifies "non-denylisted reads pass through." (omp-sandbox is read-**allowlist**-based, which is why [omp-sandbox PR #1](https://github.com/bnivanov/omp-sandbox/pull/1) added an \`OMP_SANDBOX_EXTRA_READ\` for symlink targets — a real read denial *there*, not here.) The one srt-relevant symlink risk is on **writes**: \`allowWrite\` IS an allowlist (\`[".", "/tmp", "~/.omp"]\`), so if \`~/.omp\` symlinks a subpath into iCloud (e.g. \`~/.omp/agent/extensions\` → \`~/Library/Mobile Documents/.../omp-sync/extensions\`), the first config/extension *write* through that symlink would be write-denied unless the resolved target is also in \`allowWrite\`. **[unverified]** — srt was not installed on the machine that produced this fix, so the macOS sandbox-exec write behavior on symlinked targets has not been reproduced here. Cross-reference: the [audreyt/omp-sandbox](https://github.com/audreyt/omp-sandbox) wrapper documents the same symlink-resolution class against its allowlist model (read + write).

## What didn't work — and why the launch-wrapper design is required

The first attempt ported pi-mono's `examples/extensions/sandbox/index.ts` to omp via the documented `#441` procedure (`sed -i 's/@mariozechner\/pi-/@oh-my-pi\/pi-/g'`). It does NOT work. Three independent failures, all reproduced in the OrbStack container against omp v16.1.21:

### 1. Wrong upstream namespace `#441` is stale

`#441`'s sed pattern targets `@mariozechner/pi-*`, but the pi-mono example file as of 2026-06-26 actually imports `@earendil-works/pi-coding-agent` (npm v0.80.2). The `@mariozechner/pi-coding-agent` (v0.73.1) is the OLDER package. Running `#441` verbatim against the current file finds NO substrings to rewrite and falsely concludes "port is omp-clean." The correct sed is `s/@earendil-works\/pi-/@oh-my-pi\/pi-/g`.

### 2. The example imports symbols omp's coding-agent no longer exports

- `createBashTool` — **[verified]** ZERO hits in both `src/` AND `dist/` of `@oh-my-pi/pi-coding-agent@16.1.21`. Not just unexported — ABSENT. omp refactored the bash-tool factory surface away.
- `BashOperations` — **[verified]** zero hits anywhere in omp coding-agent source.
- `CONFIG_DIR_NAME` — exists in `@oh-my-pi/pi-utils` (not coding-agent root). The example's `import { CONFIG_DIR_NAME } from "@oh-my-pi/pi-coding-agent"` is wrong by package.
- Only `getAgentDir` survives (re-exported from coding-agent root via `@oh-my-pi/pi-utils`).

A sed port of the example cannot work even with the namespace corrected — omp removed the central API the example is built on.

### 3. An omp extension cannot import `SandboxManager` from `@anthropic-ai/sandbox-runtime`

**[verified]** `omp` loading an extension that does `import { SandboxManager } from "@anthropic-ai/sandbox-runtime"` fails at discover/load time:

```
ResolveMessage: Cannot find module '@pondwader/socks5-server' from
'.../node_modules/@anthropic-ai/sandbox-runtime/dist/sandbox/socks-proxy.js'
```

`@pondwader/socks5-server` is a regular (declared) transitive dep of `@anthropic-ai/sandbox-runtime`. The dep is correctly installed and correctly resolvable by vanilla Node 22 and standalone Bun 1.3.14 from the same dist directory — **[verified]** both `node probe.mjs` and `bun probe.ts` from inside SRT's `dist/sandbox/` resolve the import fine. The failure is omp-specific: omp's compiled binary appears to resolve `@anthropic-ai/sandbox-runtime` against an embedded in-binary copy whose resolution context lacks `@pondwader/socks5-server`, NOT against the on-disk `node_modules`.

`#441` is a documented procedure, but `#441` itself closes saying sed is necessary-not-sufficient (the maintainer notes module-resolution failures are a known follow-up tracked in `#433`). `#433` was closed as resolved on the manifest/capability side only; no omp-maintained per-package compat layer exists. Two earlier turns of this work overstated the port's tractability; this README is the correction.

### Resolution

The launch-wrapper design sidesteps all three barriers:

1. No import of `@earendil-works/pi-*` or `@mariozechner/pi-*` at all.
2. No import of `createBashTool` / `BashOperations` — the minimal awareness extension imports `ExtensionAPI` as a type only.
3. No import of `SandboxManager` from `@anthropic-ai/sandbox-runtime` — the OS barrier is inherited from `srt` via fork(), not imposed by an omp extension.

If you genuinely want per-command policy granularity inside an omp extension (the pi-mono design's only real advantage over launch-wrapper), v0 of this demo does not provide it. The README's `## Future work` section discusses the path: bundle SRT inlined via `bun build --target=node` with `@oh-my-pi/*` external — **[verified]** this load-approach works in the container (`bun build index.ts --target=node --external @oh-my-pi/pi-coding-agent` produced a self-contained 0.84MB bundle that omp loaded successfully, with no transitive-dep resolution failures). But the launch-wrapper design is the simpler architecture for v0 and covers the common case.

## What v0 does NOT do

- **Per-command policy granularity.** The launch-wrapper design applies the same config to every bash subprocess omp spawns. Per-command toggles require in-process interception, which v0 deliberately avoids.
- **Project-local config merge.** srt reads one config file. There is no `<cwd>/.omp/sandbox.json` override pattern.
- **A `/sandbox` slash command that edits the config.** This demo's `/sandbox` is read-only — it surfaces the current `~/.srt-settings.json` and the `OMP_SANDBOX` env. Editing the boundary is the user's call, requires re-launch.
- **The `--no-sandbox` flag does NOT disable the barrier.** It is registered as a no-op (the design inherits the barrier from srt; only re-launching without srt disables it).

## Future work (sketched, not in v0)

- Cross-platform verification: this demo was built on Linux/aarch64 in OrbStack. macOS sandbox-exec + Linux x86_64 should both work (srt is cross-platform) but `#441` issue comments report macOS Seatbelt edge cases; verify before claiming.
- The bundled-SRT-as-an-extension path for per-command policy: `bun build ./extension-with-SRT.ts --target=node --external @oh-my-pi/* --external @oh-my-pi/pi-*` produced a working 0.84MB bundle in the container. If per-command granularity matters, that's the v1 architecture; v0 documents it in [What didn't work](#what-didnt-work).
- An E2E omp session test that drives a model API call under the sandbox. v0's smoke test exercises the barrier at the srt layer; an actual model session (with a valid API key in `~/.omp/agent/.env`) to confirm the barrier applies to omp-spawned bash with a real workflow is left as an exercise.

## Repo layout

```
.
├── README.md                        # this file (the spec)
├── LICENSE                          # CC0 1.0 Universal — Audrey Tang (dedicator); see canonical text at https://creativecommons.org/publicdomain/zero/1.0/legalcode
├── srt-settings.example.json        # illustrative srt config, copy to ~/.srt-settings.json
├── knowledge/
│   ├── RULES.md                     # → ~/.omp/agent/RULES.md (sticky contract)  ┐ pick ONE
│   ├── APPEND_SYSTEM.md             # → ~/.omp/agent/APPEND_SYSTEM.md (prompt)    ┘ not both
│   └── AGENTS.md                    # → ~/.omp/agent/AGENTS.md (advisory, either way)
├── extension/
│   ├── index.ts                     # awareness extension (no runtime deps)
│   └── package.json                 # omp + pi manifest, optional peer @oh-my-pi/pi-coding-agent
├── scripts/
│   └── run-sandboxed.sh             # OMP_SANDBOX=srt srt --settings ~/.srt-settings.json -- omp "$@"
└── test/
    └── smoke.sh                     # barrier canaries (deny / allow / network blocked)
```

## Verifying-it-yourself one-liners (all observed-passing in v0 dev)

```bash
# 1. omp launches under srt with arg parsing intact:
srt --settings ~/.srt-settings.json -- omp --version        # → omp/16.1.21

# 2. barrier denies the canary:
srt --settings ~/.srt-settings.json -- bash -c 'cat /etc/passwd'   # → cat: /etc/passwd: Permission denied

# 3. barrier allows non-denylisted reads:
srt --settings ~/.srt-settings.json -- bash -c 'cat /etc/hostname' # → <hostname>

# 4. barrier blocks non-allowlisted egress:
srt --settings ~/.srt-settings.json -- bash -c 'curl -sS --max-time 5 https://example.com'  # → 403 from srt proxy

# 5. extension slash command registered:
OMP_SANDBOX=srt srt --settings ~/.srt-settings.json -- omp --mode rpc -p "noop" 2>&1 | grep available_commands_update | head -1  # → includes "sandbox" command

# 6. TUI status line via extension_ui_request:
OMP_SANDBOX=srt srt --settings ~/.srt-settings.json -- omp --mode rpc -p "noop" 2>&1 | grep "Sandbox: ON"
```

## Provenance and thanks

The launch-wrapper design is the one Anthropic's own `srt` was built for — wrapping arbitrary processes at the OS level without requiring a container. The pi-mono upstream shipped a worked example of the in-process alternative; this demo's diagnosis (in [What didn't work](#what-didnt-work)) is essentially "the in-process alternative does not survive the omp v16.1.21 fork's API and loader surface as of 2026-06-26, so use the launch-wrapper that Anthropic's tool was designed to enable." The two-layer (knowledge-first, runtime-complement) framing was sharpened by an advisor review during this turn; the same review caught three load-bearing prose lies in earlier drafts (project-local config merge, `OMP_*→PI_*` env symmetry, `/sandbox` claim) which v0 has corrected.

Built and verified against omp v16.1.21 + srt 1.0.0 in OrbStack Ubuntu 24.04 / aarch64, 2026-06-26.
