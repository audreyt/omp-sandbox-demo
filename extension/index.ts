/**
 * omp sandbox-aware extension — runtime awareness for the launch-wrapper design.
 *
 * Architecture: srt wraps the omp *process* externally (`srt -- omp …`). The OS
 * (Seatbelt on macOS, bubblewrap on Linux) enforces the boundary on every bash
 * subprocess omp spawns — so this extension does NOT intercept bash, does NOT
 * import SandboxManager from @anthropic-ai/sandbox-runtime (that import fails
 * under omp's loader; see README "Known-fragile" section), and does NOT try to
 * replace the built-in bash tool. Its only job is to make the *model* aware of
 * the sandbox: read OMP_SANDBOX (mirrored to PI_SANDBOX by omp's env aliasing),
 * reflect sandbox state in the TUI status line, and expose `/sandbox` so the
 * user (and the model) can introspect what's enforced without re-reading the
 * settings file.
 *
 * This is the runtime complement to the knowledge layer
 * (knowledge/RULES.md + knowledge/AGENTS.md + knowledge/APPEND_SYSTEM.md). The
 * knowledge layer is what makes the *model* not blind-retry / escalate on EPERM;
 * this extension is what makes the *user session* show the sandbox state.
 */

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

const SETTINGS_FILE = process.env.OMP_SANDBOX_SETTINGS ?? join(homedir(), ".srt-settings.json");

interface SrtSettings {
	network?: { allowedDomains?: string[]; deniedDomains?: string[] };
	filesystem?: {
		denyRead?: string[];
		allowWrite?: string[];
		denyWrite?: string[];
	};
}

function readSettings(): SrtSettings {
	if (!existsSync(SETTINGS_FILE)) return {};
	try {
		return JSON.parse(readFileSync(SETTINGS_FILE, "utf-8"));
	} catch (e) {
		console.error(`[sandbox-aware] could not parse ${SETTINGS_FILE}: ${e}`);
		return {};
	}
}

export default function (pi: ExtensionAPI) {
	// omp mirrors OMP_* → PI_* at env parse time, so either works. The launch
	// wrapper (scripts/run-sandboxed.sh) sets OMP_SANDBOX=srt.
	const sandboxEnv = process.env.OMP_SANDBOX ?? process.env.PI_SANDBOX;
	const sandboxActive = sandboxEnv === "srt";

	// Flag kept for parity with the contract surface; under the launch-wrapper
	// design this does NOT disable the OS barrier (only re-launching without
	// srt does). Documented as a no-op in /sandbox output to avoid surprise.
	pi.registerFlag("no-sandbox", {
		description:
			"No-op under srt launch-wrapper: the barrier is process-inherited from srt. Re-launch without srt to actually disable.",
		type: "boolean",
		default: false,
	});

	pi.on("session_start", async (_event, ctx) => {
		if (!sandboxActive) {
			ctx.ui.setStatus(
				"sandbox",
				ctx.ui.theme.fg("subtle", "🔒 Sandbox: OFF (launch without srt)"),
			);
			return;
		}

		const settings = readSettings();
		const net = settings.network?.allowedDomains?.length ?? 0;
		const write = settings.filesystem?.allowWrite?.length ?? 0;
		const denyRead = settings.filesystem?.denyRead?.length ?? 0;
		ctx.ui.setStatus(
			"sandbox",
			ctx.ui.theme.fg("accent", `🔒 Sandbox: ON — ${net} domains, ${write} write, ${denyRead} deny-read (srt)`),
		);
	});

	pi.registerCommand("sandbox", {
		description: "Show sandbox state. Reads OMP_SANDBOX/PI_SANDBOX and the active srt settings file.",
		handler: async (_args, ctx) => {
			if (!sandboxActive) {
				ctx.ui.notify("Sandbox OFF (launch without srt to run unbarriered).", "info");
				return;
			}
			const noSandbox = pi.getFlag("no-sandbox") as boolean;
			const settings = readSettings();
			const lines = [
				"Sandbox state:",
				`  env OMP_SANDBOX/PI_SANDBOX: ${sandboxEnv}`,
				`  --no-sandbox flag: ${noSandbox ? "set (no-op under srt launch-wrapper)" : "unset"}`,
				`  settings file: ${SETTINGS_FILE}${existsSync(SETTINGS_FILE) ? "" : " (missing — srt default config in effect)"}`,
				"",
				"Network:",
				`  allowed: ${settings.network?.allowedDomains?.join(", ") || "(srt default)"}`,
				`  denied:  ${settings.network?.deniedDomains?.join(", ") || "(none)"}`,
				"",
				"Filesystem:",
				`  denyRead:   ${settings.filesystem?.denyRead?.join(", ") || "(none)"}`,
				`  allowWrite: ${settings.filesystem?.allowWrite?.join(", ") || "(none)"}`,
				`  denyWrite:  ${settings.filesystem?.denyWrite?.join(", ") || "(none)"}`,
				"",
				"Note: under the launch-wrapper design the barrier is enforced by the OS",
				"on every bash subprocess omp spawns. To change the boundary, edit",
				"the settings file shown above and re-launch with scripts/run-sandboxed.sh.",
				"There is no <cwd>/.omp/sandbox.json project-local merge. The --no-sandbox",
				"flag is a no-op here — only re-launching without srt actually disables the barrier.",
			];
			ctx.ui.notify(lines.join("\n"), "info");
		},
	});
}
