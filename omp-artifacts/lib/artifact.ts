/**
 * Pure parts of omp-artifacts: artifact ids, file names, the index kept per artifact,
 * and the HTML page the Tern viewer shows for each type.
 */

export const ARTIFACT_TYPES = ["html", "svg", "markdown", "mermaid", "code"] as const;
export type ArtifactType = (typeof ARTIFACT_TYPES)[number];

/** One saved version; `source` and `view` are file names inside the artifact's folder. */
export interface ArtifactVersion {
	version: number;
	title: string;
	type: ArtifactType;
	language?: string;
	/** The content as the model wrote it. */
	source: string;
	/** The page the viewer shows: `source` itself for html, a generated page otherwise. */
	view: string;
	/** ISO time of the save. */
	savedAt: string;
}

/** `index.json` of an artifact folder: every version, oldest first. */
export interface ArtifactIndex {
	id: string;
	versions: ArtifactVersion[];
}

const MAX_ID_LENGTH = 64;

/** A model-given id as a folder name: lowercase `[a-z0-9_-]`, dashes collapsed; empty when nothing is left. */
export function sanitizeId(raw: string): string {
	return raw
		.toLowerCase()
		.replace(/[^a-z0-9_-]+/g, "-")
		.replace(/-{2,}/g, "-")
		.slice(0, MAX_ID_LENGTH)
		.replace(/^[-_]+|[-_]+$/g, "");
}

/** A language name reduced to what a CSS class and a lookup key can hold (`C++` → `c++`, `C#` → `c#`). */
export function normalizeLanguage(raw: string | undefined): string | undefined {
	const lang = raw
		?.trim()
		.toLowerCase()
		.replace(/[^a-z0-9+#-]+/g, "");
	return lang ? lang : undefined;
}

const CODE_EXTENSIONS: Record<string, string> = {
	javascript: "js",
	js: "js",
	jsx: "jsx",
	typescript: "ts",
	ts: "ts",
	tsx: "tsx",
	python: "py",
	py: "py",
	rust: "rs",
	rs: "rs",
	go: "go",
	golang: "go",
	c: "c",
	h: "h",
	"c++": "cpp",
	cpp: "cpp",
	"c#": "cs",
	csharp: "cs",
	cs: "cs",
	java: "java",
	kotlin: "kt",
	swift: "swift",
	ruby: "rb",
	php: "php",
	shell: "sh",
	bash: "sh",
	sh: "sh",
	zsh: "sh",
	powershell: "ps1",
	pwsh: "ps1",
	ps1: "ps1",
	sql: "sql",
	json: "json",
	yaml: "yaml",
	yml: "yaml",
	toml: "toml",
	xml: "xml",
	html: "html",
	css: "css",
	scss: "scss",
	lua: "lua",
	luau: "luau",
	markdown: "md",
	md: "md",
	dockerfile: "dockerfile",
};

/** The source file's extension: fixed per type; for code the language's usual one, else `txt`. */
export function sourceExtension(type: ArtifactType, language?: string): string {
	switch (type) {
		case "html":
			return "html";
		case "svg":
			return "svg";
		case "markdown":
			return "md";
		case "mermaid":
			return "mmd";
		case "code": {
			const lang = normalizeLanguage(language);
			if (!lang) return "txt";
			return CODE_EXTENSIONS[lang] ?? (/^[a-z0-9]{1,10}$/.test(lang) ? lang : "txt");
		}
	}
}

/** File names of version `n`: the source, and the page the viewer shows. */
export function versionFiles(n: number, type: ArtifactType, language?: string): { source: string; view: string } {
	const source = `v${n}.${sourceExtension(type, language)}`;
	return { source, view: type === "html" ? source : `v${n}.view.html` };
}

function isType(value: unknown): value is ArtifactType {
	return typeof value === "string" && (ARTIFACT_TYPES as readonly string[]).includes(value);
}

/** The one object guard of this package; `lib/tern.ts` reads Tern's JSON answers with it too. */
export function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** A parsed `index.json`, or undefined when it is not one; malformed versions are dropped. */
export function parseIndex(raw: unknown): ArtifactIndex | undefined {
	if (!isRecord(raw) || typeof raw.id !== "string" || !Array.isArray(raw.versions)) return undefined;
	const valid: ArtifactVersion[] = [];
	for (const e of raw.versions) {
		if (
			!isRecord(e) ||
			typeof e.version !== "number" ||
			typeof e.title !== "string" ||
			!isType(e.type) ||
			typeof e.source !== "string" ||
			typeof e.view !== "string" ||
			typeof e.savedAt !== "string"
		) {
			continue;
		}
		valid.push({
			version: e.version,
			title: e.title,
			type: e.type,
			language: typeof e.language === "string" ? e.language : undefined,
			source: e.source,
			view: e.view,
			savedAt: e.savedAt,
		});
	}
	valid.sort((a, b) => a.version - b.version);
	return { id: raw.id, versions: valid };
}

/** What a new save needs, after inheriting title/type/language from the previous version. */
export interface VersionRequest {
	title?: string;
	type?: ArtifactType;
	language?: string;
}

/**
 * The next version's metadata, or an error message: a new artifact needs a title and a type,
 * an update inherits whatever it leaves out.
 */
export function nextVersion(
	index: ArtifactIndex | undefined,
	request: VersionRequest,
	savedAt: string,
): ArtifactVersion | string {
	const last = index?.versions.at(-1);
	const title = request.title?.trim() || last?.title;
	const type = request.type ?? last?.type;
	if (!title) return "A new artifact needs a title.";
	if (!type) return "A new artifact needs a type.";
	const language =
		type === "code" ? (normalizeLanguage(request.language) ?? (last?.type === "code" ? last.language : undefined)) : undefined;
	const version = (last?.version ?? 0) + 1;
	return { version, title, type, language, ...versionFiles(version, type, language), savedAt };
}

export function escapeHtml(text: string): string {
	return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

const BASE_CSS = `
:root { color-scheme: light dark; }
body { margin: 0; padding: 24px 32px; font: 15px/1.6 system-ui, -apple-system, "Segoe UI", sans-serif; }
pre, code { font-family: ui-monospace, "Cascadia Code", Consolas, monospace; font-size: 13px; }
article { max-width: 860px; margin: 0 auto; }
article pre { padding: 12px 16px; border-radius: 6px; background: color-mix(in srgb, currentColor 7%, transparent); overflow: auto; }
article :not(pre) > code { padding: 1px 5px; border-radius: 4px; background: color-mix(in srgb, currentColor 9%, transparent); }
article table { border-collapse: collapse; }
article th, article td { border: 1px solid color-mix(in srgb, currentColor 25%, transparent); padding: 4px 10px; }
article blockquote { margin-left: 0; padding-left: 16px; border-left: 3px solid color-mix(in srgb, currentColor 30%, transparent); }
article img { max-width: 100%; }
body.kind-svg { display: flex; justify-content: center; }
body.kind-svg svg { max-width: 100%; height: auto; }
body.kind-mermaid { display: flex; justify-content: center; }
body.kind-code { padding: 0; }
body.kind-code pre { margin: 0; padding: 16px 20px; }
body.kind-code pre code.hljs { padding: 0; background: none; }
`;

const HLJS = "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11";
const MERMAID = "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";

/** Markdown to HTML, as the viewer shows it; Bun's renderer (GFM tables, fenced code). */
export type MarkdownRenderer = (markdown: string) => string;

// `Bun.markdown` (Bun 1.3.8+; omp 18.22 runs 1.4) is missing from older bun-types; the shape is Bun's documented API.
const BUN_MARKDOWN = (Bun as unknown as { markdown: { html(md: string): string } }).markdown;
const bunMarkdown: MarkdownRenderer = markdown => BUN_MARKDOWN.html(markdown);

/** An SVG document as markup an HTML page can hold inline: without its XML prolog and doctype. */
function inlineSvg(svg: string): string {
	return svg
		.replace(/^\s*<\?xml[^>]*\?>/i, "")
		.replace(/^\s*<!DOCTYPE[^>]*>/i, "")
		.trim();
}

/**
 * The page the viewer shows for a version; undefined for html, which is shown as written.
 * Mermaid and code load mermaid / highlight.js from jsDelivr; offline, the source shows as plain text.
 */
export function viewPage(
	version: Pick<ArtifactVersion, "version" | "title" | "type" | "language">,
	content: string,
	renderMarkdown: MarkdownRenderer = bunMarkdown,
): string | undefined {
	let head = "";
	let body: string;
	switch (version.type) {
		case "html":
			return undefined;
		case "svg":
			body = inlineSvg(content);
			break;
		case "markdown":
			body = `<article>${renderMarkdown(content)}</article>`;
			break;
		case "mermaid":
			body =
				`<pre class="mermaid">${escapeHtml(content)}</pre>\n` +
				`<script type="module">import mermaid from "${MERMAID}";\n` +
				`mermaid.initialize({ startOnLoad: false, theme: matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "default" });\n` +
				`await mermaid.run();</script>`;
			break;
		case "code": {
			const lang = normalizeLanguage(version.language);
			const cls = lang ? ` class="language-${escapeHtml(lang)}"` : "";
			head =
				`<link rel="stylesheet" media="(prefers-color-scheme: light)" href="${HLJS}/styles/github.min.css">\n` +
				`<link rel="stylesheet" media="(prefers-color-scheme: dark)" href="${HLJS}/styles/github-dark.min.css">\n`;
			body =
				`<pre><code${cls}>${escapeHtml(content)}</code></pre>\n` +
				`<script src="${HLJS}/highlight.min.js"></script>\n` +
				`<script>window.hljs && hljs.highlightAll();</script>`;
			break;
		}
	}
	return (
		`<!doctype html>\n<html><head><meta charset="utf-8">\n` +
		`<meta name="viewport" content="width=device-width, initial-scale=1">\n` +
		`<title>${escapeHtml(version.title)} · v${version.version}</title>\n` +
		`<style>${BASE_CSS}</style>\n${head}</head>\n` +
		// `kind-` keeps the body out of `.mermaid`, which mermaid.run() renders.
		`<body class="kind-${version.type}">\n${body}\n</body></html>\n`
	);
}
