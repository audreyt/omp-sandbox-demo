# Sandbox contract — applies when OMP_SANDBOX=srt is in your `~/.omp/agent/.env` (or in the launch env)

You are running omp under `@anthropic-ai/sandbox-runtime` (`srt`). Bash commands you issue are wrapped by `srt` and enforced by the OS (Seatbelt/sandbox-exec on macOS, bubblewrap on Linux). Without this rule, you would blind-retry sandbox failures and escalate to chmod/mount/disable.

> Note on `OMP_*` → `PI_*`: omp's `.env` parser aliases `OMP_*` to `PI_*` only for variables it reads from `.env`. Variables passed in through the OS environment (`OMP_SANDBOX=srt omp …`, or your shell export) are NOT mirrored — `process.env.PI_SANDBOX` will be `undefined` even when `OMP_SANDBOX` is set. Code that branches on the sandbox env should read `process.env.OMP_SANDBOX ?? process.env.PI_SANDBOX`; don't assume the alias is symmetric. Verified against omp v16.1.21 in an OrbStack Ubuntu 24.04 container.

## Boundary

> These are the values used in this demo's `srt-settings.example.json`. They are an illustrative config, NOT `srt`'s built-in default — `srt`'s bare default (with no settings file) is `{ "allowedHosts": [] }`, i.e. **all network egress blocked**. The demo ships a non-empty allowlist purely so an agent can reach API registries and source hosts out of the box. Treat the entries below as the demo's chosen config, edit or replace them, and confirm with `/sandbox` (if the extended session exposes it) or by reading `~/.srt-settings.json`.

- **Writable paths**: project root, `/tmp`, `~/.omp` (the whole dir — omp writes `agent.db`, `models.db`, and `logs/omp.<date>.log` here at startup; narrower `~/.omp/agent`-only allows deny the log path and crash omp with `SQLiteError: read-only database` / `EROFS: read-only file system`).
- **Readable paths**: project tree and standard system paths. `~/.ssh`, `~/.aws`, `~/.gnupg` are denied read in this demo's config.
- **Network allowlist in this demo's config**: `api.anthropic.com`, `github.com`, `*.github.com`, `raw.githubusercontent.com`, `registry.npmjs.org`, `registry.yarnpkg.com`, `pypi.org`, `*.pypi.org`. All other egress blocked. `srt`'s default has none — every host must be added.

## When `bash` fails with EPERM or "network unreachable" / "could not resolve host" / "connection refused"

That signal IS the sandbox boundary, not disk corruption and not a transient error. Treat it as follows, in order:

1. **Stop.** Do not retry the same command — the second attempt will fail identically.
2. **Do not** escalate with `chmod`, `chown`, `mount`, `sudo`, `sysctl`, `--no-sandbox`, or `kill`.
3. **Do not** conclude the path is corrupt or the binary is broken.
4. **Surface it to the user**, naming the denied resource, and ask them to widen `~/.srt-settings.json`. Offer the exact allow/deny delta.
5. Continue with work that does not cross the boundary.

If the model is genuinely uncertain whether a failure is the sandbox or a real error, run a non-crossing probe (e.g. `ls /tmp` or `true`) — if that succeeds, the machine is fine and the earlier failure was the sandbox.

## Network egress that needs an un-allowlisted host

Do NOT attempt to widen the network by writing random `~/.srt-settings.json` deltas. Tell the user:
> "The sandbox blocks egress to `<host>`. To allow it, add `<host>` to `network.allowedDomains` in `~/.srt-settings.json` and relaunch. Otherwise I can proceed without it via `<alternative>`."

Prefer the alternative (e.g. fetch from an allowlisted mirror, vendor a tarball, use a local cache) over asking the user to widen egress.

## What never to do

- Do not try to disable the sandbox from inside a session. Under the launch-wrapper design, `--no-sandbox` is a no-op (the barrier is process-inherited from `srt`); the only way to actually disable is to re-launch without `srt`. Don't suggest it.
- Do not write credentials into the sandbox's writable paths to "make them visible" — that defeats the sandbox.
- Do not spawn child processes outside the sandbox (e.g. `npx srt ...`, `docker run ...`) to bypass the wrapper.
- Do not edit `~/.srt-settings.json` on the model's own initiative. Propose the change; the user applies it.

## Config resolution

`srt` reads exactly one config file: `~/.srt-settings.json` by default, or any path you pass to `srt --settings <path>`. There is NO project-local override and NO `<cwd>/.omp/sandbox.json` merge — that pattern was the old pi-mono example extension's own `loadConfig`, not `srt`-the-CLI's behavior. Verified by reading `srt --help` and observing `srt --debug` with no settings file (`No config found at .../.srt-settings.json, using default config` + `{ "allowedHosts": [] }`).

If a sandbox boundary seems wrong, the config in effect is the file `srt --settings <path>` was invoked with (or `~/.srt-settings.json` if none given). That's where to propose edits. The launch wrapper `scripts/run-sandboxed.sh` pins the path; changing it requires re-launch.
