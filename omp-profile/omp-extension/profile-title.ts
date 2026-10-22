/**
 * omp extension: in Tern, prefix the pane title with the omp profile,
 * `[work] <session title>`, so every split shows which profile it runs.
 *
 * omp owns the pane title. An extension title is cleared whenever omp sets
 * the session title (first reply, rename, session switch), so it is applied
 * again on session and turn events and every two seconds; omp skips writes
 * that don't change the title.
 */
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

const REAPPLY_MS = 2000;

/** `~/.omp/profiles/<name>/…` → name, `~/.omp/agent/…` → default. */
function profileFromPath(file: string | undefined): string | undefined {
	if (!file) return undefined;
	const norm = file.replaceAll("\\", "/");
	const named = /\/\.omp\/profiles\/([^/]+)\//.exec(norm);
	if (named) return named[1];
	if (norm.includes("/.omp/agent/")) return "default";
	return undefined;
}

/** The selected profile as omp resolves it: OMP_PROFILE wins when defined, then PI_PROFILE. */
function profileFromEnv(): string {
	const raw = (process.env.OMP_PROFILE !== undefined ? process.env.OMP_PROFILE : process.env.PI_PROFILE) ?? "";
	const name = raw.trim();
	return name === "" ? "default" : name;
}

export default function profileTitle(pi: ExtensionAPI) {
	if (process.env.TERM_PROGRAM?.toLowerCase() !== "tern") return;

	const apply = (ctx: ExtensionContext) => {
		if (!ctx.hasUI) return;
		const profile = profileFromPath(ctx.sessionManager.getSessionFile()) ?? profileFromEnv();
		const name = ctx.sessionManager.getSessionName()?.trim() || "omp";
		ctx.ui.setTitle(`[${profile}] ${name}`);
	};

	let timer: Timer | undefined;
	pi.on("session_start", (_event, ctx) => {
		apply(ctx);
		if (timer !== undefined) ctx.clearTimer(timer);
		timer = ctx.setInterval(() => apply(ctx), REAPPLY_MS);
	});
	pi.on("session_switch", (_event, ctx) => apply(ctx));
	pi.on("message_end", (_event, ctx) => apply(ctx));
	pi.on("turn_end", (_event, ctx) => apply(ctx));
	pi.on("agent_end", (_event, ctx) => apply(ctx));
}
