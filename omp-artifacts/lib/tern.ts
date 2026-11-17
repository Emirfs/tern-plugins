/**
 * Pure parts of showing artifacts in Tern: the address layout of the local server that hands pages to
 * Tern's browser, and readers of Tern's JSON answers (`tern browser '{"op":"blocks"}'`,
 * `tern inspect --json`) that find the viewer block and the block to focus again after opening one.
 */
import { isRecord } from "./artifact.ts";

/** A browser block of the window; `owner` is the block a picture in picture floats over, null when docked. */
export interface BrowserBlock {
	block: number;
	url: string;
	owner: number | null;
}

/** The blocks of a `blocks` answer (`{ blocks: [...] }`); malformed entries are skipped. */
export function parseBlocks(answer: unknown): BrowserBlock[] {
	if (!isRecord(answer) || !Array.isArray(answer.blocks)) return [];
	const blocks: BrowserBlock[] = [];
	for (const raw of answer.blocks) {
		if (!isRecord(raw) || typeof raw.block !== "number") continue;
		blocks.push({
			block: raw.block,
			url: typeof raw.url === "string" ? raw.url : "about:blank",
			owner: typeof raw.owner === "number" ? raw.owner : null,
		});
	}
	return blocks;
}

/** Address path of a served file: `/<token>/<key>/<id>/<file>`; `key` names a session's artifacts folder. */
export function servedPath(token: string, key: string, id: string, file: string): string {
	return `/${[token, key, id, file].map(encodeURIComponent).join("/")}`;
}

/** The parts of a served path; undefined unless it has a token, a key and plain file names below them. */
export function parseServedPath(pathname: string): { token: string; key: string; rest: string[] } | undefined {
	let parts: string[];
	try {
		parts = pathname.split("/").slice(1).map(decodeURIComponent);
	} catch {
		return undefined;
	}
	const [token, key, ...rest] = parts;
	if (!token || !key || rest.length === 0 || rest.some(p => p === "" || p === "." || p === ".." || /[\\/:]/.test(p))) {
		return undefined;
	}
	return { token, key, rest };
}

/**
 * The viewer to reuse: the block this process opened (`remembered`) while it still exists, else a block
 * showing a page of the session's folder `key` from a local server (an earlier omp run of this session).
 */
export function pickViewer(blocks: readonly BrowserBlock[], remembered: number | undefined, key: string): BrowserBlock | undefined {
	const mine = remembered === undefined ? undefined : blocks.find(b => b.block === remembered);
	if (mine) return mine;
	return blocks.find(b => {
		const url = URL.parse(b.url);
		return url?.hostname === "127.0.0.1" && parseServedPath(url.pathname)?.key === key;
	});
}

/**
 * Where `owner` sits in `tern inspect --json`: whether its tab is on screen (its session shown and the
 * tab shown), and the block focused in that tab. Undefined when no tab holds `owner`.
 */
export interface OwnerPlace {
	/** Its session and tab are on screen. */
	visible: boolean;
	/** The block focused in its tab. */
	focused: number | undefined;
}

export function ownerPlace(inspect: unknown, owner: number): OwnerPlace | undefined {
	if (!isRecord(inspect) || !Array.isArray(inspect.sessions)) return undefined;
	for (const session of inspect.sessions) {
		if (!isRecord(session) || !Array.isArray(session.tabs)) continue;
		for (const tab of session.tabs) {
			if (!isRecord(tab) || !Array.isArray(tab.blocks)) continue;
			const blocks = tab.blocks.filter(isRecord);
			if (!blocks.some(b => b.id === owner)) continue;
			const focused = blocks.find(b => b.focused === true)?.id;
			return {
				visible: session.shown === true && tab.shown === true,
				focused: typeof focused === "number" ? focused : undefined,
			};
		}
	}
	return undefined;
}
