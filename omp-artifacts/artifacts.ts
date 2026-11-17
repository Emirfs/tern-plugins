/**
 * omp extension: Claude-style artifacts. The model calls the `artifact` tool to create or update a named
 * piece of standalone content (an HTML page, an SVG, markdown, a mermaid diagram, a code file); every call
 * is a new version on disk under the session's artifacts folder. Inside Tern the artifact shows in one
 * browser block docked beside the conversation, reused for every later artifact and version; elsewhere the
 * tool reports the file's path. `/artifacts` lists the session's artifacts and shows any version again.
 */
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { Text } from "@oh-my-pi/pi-tui";
import {
	ARTIFACT_TYPES,
	type ArtifactIndex,
	type ArtifactType,
	type ArtifactVersion,
	isRecord,
	nextVersion,
	parseIndex,
	sanitizeId,
	viewPage,
} from "./lib/artifact.ts";
import { type OwnerPlace, ownerPlace, parseBlocks, parseServedPath, pickViewer, servedPath } from "./lib/tern.ts";

/** Folder inside the session's artifacts directory (beside omp's own `N.tool.log` spills). */
const ROOT_NAME = "omp-artifacts";
const INDEX_FILE = "index.json";
const TERN_TIMEOUT_MS = 15_000;

const DESCRIPTION = `Create or update an artifact: standalone content shown to the user in a viewer beside the conversation.

Use it for substantial, self-contained content the user will look at, reuse or iterate on (roughly 15+ lines): a web page or interactive demo, an SVG image, a diagram, a document, a complete code file. Keep short snippets, explanations and answers in the reply.

Every call saves a new version. To change an artifact, call again with the same id and the complete new content (never a diff or a fragment); title and type may be omitted on updates.

Types:
- html: one self-contained page (inline CSS and JS; libraries only from https CDNs).
- svg: one <svg> document with xmlns.
- markdown: a document.
- mermaid: diagram source, without \`\`\` fences.
- code: a source file; set language.

After the call, mention the artifact briefly instead of repeating its content.`;

interface ArtifactDetails {
	id: string;
	version: number;
	type: ArtifactType;
	title: string;
	path: string;
	viewPath: string;
	/** The Tern browser block showing it, when shown. */
	block?: number;
	reused?: boolean;
}

/** Where this session's artifacts live: a folder in omp's artifacts directory, else (no session file) in temp. */
function artifactsRoot(ctx: ExtensionContext): string {
	const dir = ctx.sessionManager.getArtifactsDir();
	return dir ? path.join(dir, ROOT_NAME) : path.join(os.tmpdir(), ROOT_NAME, ctx.sessionManager.getSessionId());
}

async function readIndex(dir: string): Promise<ArtifactIndex | undefined> {
	try {
		return parseIndex(JSON.parse(await Bun.file(path.join(dir, INDEX_FILE)).text()));
	} catch {
		return undefined;
	}
}

/** Every artifact of the session that has a version, the most recently saved first. */
async function listArtifacts(root: string): Promise<ArtifactIndex[]> {
	let names: string[];
	try {
		names = await fs.readdir(root);
	} catch {
		return [];
	}
	const indexes = await Promise.all(names.map(name => readIndex(path.join(root, name))));
	const found = indexes.filter((i): i is ArtifactIndex => i !== undefined && i.versions.length > 0);
	const lastSave = (i: ArtifactIndex): string => i.versions[i.versions.length - 1].savedAt;
	return found.sort((a, b) => lastSave(b).localeCompare(lastSave(a)));
}

/** Writes version files first and the index last, through a rename, so the index never names a missing file. */
async function saveVersion(
	dir: string,
	id: string,
	request: { title?: string; type?: ArtifactType; language?: string },
	content: string,
): Promise<ArtifactVersion> {
	const index = await readIndex(dir);
	const next = nextVersion(index, request, new Date().toISOString());
	if (typeof next === "string") throw new Error(next);
	await fs.mkdir(dir, { recursive: true });
	await Bun.write(path.join(dir, next.source), content);
	const page = viewPage(next, content);
	if (page !== undefined) await Bun.write(path.join(dir, next.view), page);
	const updated: ArtifactIndex = { id, versions: [...(index?.versions ?? []), next] };
	const indexPath = path.join(dir, INDEX_FILE);
	const temp = `${indexPath}.tmp-${crypto.randomUUID()}`;
	await Bun.write(temp, `${JSON.stringify(updated, null, "\t")}\n`);
	await fs.rename(temp, indexPath);
	return next;
}

/** One save or viewer change at a time: parallel calls would race for version numbers and open two viewers. */
let queue: Promise<unknown> = Promise.resolve();
function serialized<T>(fn: () => Promise<T>): Promise<T> {
	const run = queue.then(fn, fn);
	queue = run.catch(() => undefined);
	return run;
}

/** The Tern pane this omp runs in, or undefined outside Tern. */
function ternPane(): number | undefined {
	if (process.env.TERM_PROGRAM !== "tern") return undefined;
	const pane = process.env.TERN_PANE;
	return pane && /^\d+$/.test(pane) ? Number(pane) : undefined;
}

/** The viewer block this process opened, per omp pane. */
const viewers = new Map<number, number>();

/**
 * Tern's browser on Windows gets `file://` pages as application/octet-stream and shows nothing, so pages
 * reach it from a server on 127.0.0.1, started at the first show and never keeping omp alive. A random
 * token in every address keeps other local programs from reading the session's artifacts.
 */
const TOKEN = crypto.randomUUID();
/** The session artifact folders the server hands out, by key. */
const served = new Map<string, string>();
let serverPort: number | undefined;

function serverOrigin(): string {
	if (serverPort === undefined) {
		const server = Bun.serve({
			hostname: "127.0.0.1",
			port: 0,
			async fetch(request) {
				const parts = parseServedPath(new URL(request.url).pathname);
				const root = parts?.token === TOKEN ? served.get(parts.key) : undefined;
				if (!parts || !root) return new Response("Not found", { status: 404 });
				// parseServedPath admits plain file names only, so the join stays inside `root`.
				const file = Bun.file(path.join(root, ...parts.rest));
				if (!(await file.exists())) return new Response("Not found", { status: 404 });
				return new Response(file, { headers: { "Cache-Control": "no-store" } });
			},
		});
		server.unref();
		serverPort = server.port;
	}
	return `http://127.0.0.1:${serverPort}`;
}

/** Tern's CLI: the one that started this pane (`TERN_EXE`), else from PATH. */
const TERN_EXE = process.env.TERN_EXE || "tern";

async function tern(pi: ExtensionAPI, args: string[]): Promise<string> {
	const result = await pi.exec(TERN_EXE, args, { timeout: TERN_TIMEOUT_MS });
	if (result.code !== 0) {
		throw new Error(`tern ${args[0]}: ${(result.stderr || result.stdout).trim() || `exit ${result.code}`}`);
	}
	return result.stdout;
}

/** One `tern browser` op: its `ok` answer, or an error carrying Tern's message. */
async function browserOp(pi: ExtensionAPI, op: Record<string, unknown>): Promise<unknown> {
	const result = await pi.exec(TERN_EXE, ["browser", JSON.stringify(op)], { timeout: TERN_TIMEOUT_MS });
	let answer: unknown;
	try {
		answer = JSON.parse(result.stdout);
	} catch {
		answer = undefined;
	}
	if (isRecord(answer) && "ok" in answer) return answer.ok;
	const message = isRecord(answer) && isRecord(answer.error) ? answer.error.message : undefined;
	throw new Error(
		`tern browser ${String(op.op)}: ${typeof message === "string" ? message : (result.stderr || result.stdout).trim() || `exit ${result.code}`}`,
	);
}

/**
 * Show `url` in the pane's viewer: navigate the existing one, else open a new browser block docked to the
 * right of the pane. The block opens as a picture in picture and is then docked with `tern dock`, because
 * `how: "beside"` focuses it and makes the window switch to this session even when it runs in the
 * background; the block focused before gets the focus back when its tab is on screen.
 */
async function showInTern(pi: ExtensionAPI, pane: number, url: string, key: string): Promise<{ block: number; reused: boolean }> {
	const blocks = parseBlocks(await browserOp(pi, { op: "blocks" }));
	const viewer = pickViewer(blocks, viewers.get(pane), key);
	if (viewer) {
		// A Tern web view never reloads an unchanged address on `goto`.
		await browserOp(
			pi,
			viewer.url === url ? { op: "nav", block: viewer.block, go: "reload" } : { op: "goto", block: viewer.block, url },
		);
		viewers.set(pane, viewer.block);
		return { block: viewer.block, reused: true };
	}
	let place: OwnerPlace | undefined;
	try {
		place = ownerPlace(JSON.parse(await tern(pi, ["inspect", "--json"])), pane);
	} catch {
		place = undefined;
	}
	const opened = await browserOp(pi, { op: "open", owner: pane, url });
	if (!isRecord(opened) || typeof opened.block !== "number") throw new Error("tern browser open: no block in its answer");
	const block = opened.block;
	viewers.set(pane, block);
	await tern(pi, ["dock", String(block), "right"]);
	if (place?.visible && place.focused !== undefined) await tern(pi, ["focus", String(place.focused)]);
	return { block, reused: false };
}

function typeLabel(v: ArtifactVersion): string {
	return v.type === "code" && v.language ? `code (${v.language})` : v.type;
}

function when(iso: string): string {
	const d = new Date(iso);
	const pad = (n: number): string => String(n).padStart(2, "0");
	return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export default function artifacts(pi: ExtensionAPI): void {
	const z = pi.zod;

	/** Show a saved version in Tern; a line for the user or the model saying what happened. */
	async function present(
		root: string,
		id: string,
		version: ArtifactVersion,
	): Promise<{ note: string; block?: number; reused?: boolean }> {
		const viewPath = path.join(root, id, version.view);
		const pane = ternPane();
		if (pane === undefined) return { note: `Not running inside Tern; the user can open ${viewPath} in a browser.` };
		try {
			const key = Bun.hash(root).toString(36);
			served.set(key, root);
			const url = serverOrigin() + servedPath(TOKEN, key, id, version.view);
			const shown = await showInTern(pi, pane, url, key);
			return { note: "Shown in the Tern viewer beside the conversation.", ...shown };
		} catch (error) {
			const reason = error instanceof Error ? error.message : String(error);
			return { note: `Could not show it in Tern (${reason}); the file is ${viewPath}.` };
		}
	}

	const parameters = z.object({
		id: z.string().describe("Stable kebab-case identifier, e.g. `pricing-page`. Reuse it to update the artifact."),
		title: z.string().optional().describe("Short human-readable title. Required for a new artifact."),
		type: z.enum([...ARTIFACT_TYPES]).optional().describe("Content type. Required for a new artifact."),
		language: z.string().optional().describe("Programming language, for type `code` (e.g. `python`)."),
		content: z.string().describe("The complete content of this version."),
	});

	pi.registerTool<typeof parameters, ArtifactDetails>({
		name: "artifact",
		label: "Artifact",
		description: DESCRIPTION,
		parameters,
		approval: "write",
		loadMode: "essential",
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			const id = sanitizeId(params.id);
			if (!id) throw new Error(`Artifact id ${JSON.stringify(params.id)} has no usable characters; use kebab-case.`);
			const root = artifactsRoot(ctx);
			return serialized(async () => {
				const version = await saveVersion(
					path.join(root, id),
					id,
					{ title: params.title, type: params.type, language: params.language },
					params.content,
				);
				const shown = await present(root, id, version);
				const sourcePath = path.join(root, id, version.source);
				const details: ArtifactDetails = {
					id,
					version: version.version,
					type: version.type,
					title: version.title,
					path: sourcePath,
					viewPath: path.join(root, id, version.view),
					block: shown.block,
					reused: shown.reused,
				};
				const text = `Saved artifact "${id}" v${version.version} (${typeLabel(version)}): ${sourcePath}\n${shown.note}`;
				return { content: [{ type: "text" as const, text }], details };
			});
		},
		renderCall(args, _options, theme) {
			const parts = [theme.fg("toolTitle", theme.bold("artifact")), theme.fg("accent", args.id ?? "…")];
			if (args.type) parts.push(theme.fg("muted", args.type === "code" && args.language ? `code (${args.language})` : args.type));
			if (args.title) parts.push(args.title);
			if (typeof args.content === "string") parts.push(theme.fg("dim", `${args.content.split("\n").length} lines`));
			return new Text(parts.join(" "), 0, 0);
		},
	});

	async function showVersion(ctx: ExtensionContext, root: string, artifact: ArtifactIndex, version: ArtifactVersion): Promise<void> {
		const shown = await serialized(() => present(root, artifact.id, version));
		const level = shown.block === undefined && ternPane() !== undefined ? "error" : "info";
		ctx.ui.notify(`${artifact.id} v${version.version}: ${shown.note}`, level);
	}

	async function openSource(ctx: ExtensionContext, file: string): Promise<void> {
		try {
			await tern(pi, ["open", "--split", "right", file]);
		} catch (error) {
			ctx.ui.notify(`Could not open ${file}: ${error instanceof Error ? error.message : String(error)}`, "error");
		}
	}

	pi.registerCommand("artifacts", {
		description: "This session's artifacts: /artifacts (pick one and a version to show), /artifacts <id> [vN]",
		handler: async (args, ctx) => {
			const root = artifactsRoot(ctx);
			const all = await listArtifacts(root);
			if (all.length === 0) {
				ctx.ui.notify("No artifacts in this session yet.", "info");
				return;
			}

			const [idArg, versionArg] = args.trim().split(/\s+/).filter(Boolean);
			if (idArg) {
				const artifact = all.find(a => a.id === sanitizeId(idArg));
				if (!artifact) {
					ctx.ui.notify(`No artifact "${idArg}". This session has: ${all.map(a => a.id).join(", ")}.`, "warning");
					return;
				}
				const last = artifact.versions[artifact.versions.length - 1];
				const n = versionArg === undefined ? last.version : Number(versionArg.replace(/^v/i, ""));
				const version = artifact.versions.find(v => v.version === n);
				if (!version) {
					ctx.ui.notify(`${artifact.id} has no version ${versionArg} (v1–v${last.version}).`, "warning");
					return;
				}
				await showVersion(ctx, root, artifact, version);
				return;
			}

			if (!ctx.hasUI) {
				const lines = all.map(a => {
					const last = a.versions[a.versions.length - 1];
					return `${a.id}: ${last.title} (${typeLabel(last)}, v${last.version})`;
				});
				ctx.ui.notify(lines.join("\n"), "info");
				return;
			}

			const artifactOptions = all.map(a => {
				const last = a.versions[a.versions.length - 1];
				return {
					label: `${last.title} (${a.id})`,
					description: `${typeLabel(last)} · ${a.versions.length === 1 ? "1 version" : `${a.versions.length} versions`} · ${when(last.savedAt)}`,
				};
			});
			const pickedArtifact = await ctx.ui.select("Artifacts in this session", artifactOptions);
			if (pickedArtifact === undefined) return;
			const artifact = all[artifactOptions.findIndex(o => o.label === pickedArtifact)];
			if (!artifact) return;

			const newestFirst = [...artifact.versions].reverse();
			const latest = newestFirst[0];
			const versionOptions = newestFirst.map(v => ({
				label: `v${v.version}: ${v.title}`,
				description: `${v === latest ? "latest · " : ""}${typeLabel(v)} · ${when(v.savedAt)}`,
			}));
			const sourceLabel = `Edit the source of v${latest.version} in a file block`;
			if (ternPane() !== undefined) versionOptions.push({ label: sourceLabel, description: latest.source });
			if (versionOptions.length === 1) {
				await showVersion(ctx, root, artifact, latest);
				return;
			}
			const pickedVersion = await ctx.ui.select(`${artifact.id}: version to show`, versionOptions);
			if (pickedVersion === undefined) return;
			if (pickedVersion === sourceLabel) {
				await openSource(ctx, path.join(root, artifact.id, latest.source));
				return;
			}
			const version = newestFirst[versionOptions.findIndex(o => o.label === pickedVersion)];
			if (version) await showVersion(ctx, root, artifact, version);
		},
	});
}
