import { describe, expect, test } from "bun:test";
import { nextVersion, parseIndex, sanitizeId, sourceExtension, viewPage } from "../lib/artifact.ts";
import { ownerPlace, parseBlocks, parseServedPath, pickViewer, servedPath } from "../lib/tern.ts";

const NOW = "2026-11-17T10:00:00.000Z";

describe("sanitizeId", () => {
	test("keeps kebab-case and folds the rest", () => {
		expect(sanitizeId("pricing-page")).toBe("pricing-page");
		expect(sanitizeId("  My Chart: v2!! ")).toBe("my-chart-v2");
		expect(sanitizeId("../../etc/passwd")).toBe("etc-passwd");
		expect(sanitizeId("éàñ")).toBe("");
		expect(sanitizeId("a".repeat(100))).toHaveLength(64);
	});
});

describe("sourceExtension", () => {
	test("per type, and per language for code", () => {
		expect(sourceExtension("markdown")).toBe("md");
		expect(sourceExtension("mermaid")).toBe("mmd");
		expect(sourceExtension("code", "Python")).toBe("py");
		expect(sourceExtension("code", "C++")).toBe("cpp");
		expect(sourceExtension("code", "C#")).toBe("cs");
		expect(sourceExtension("code", "zig")).toBe("zig");
		expect(sourceExtension("code", "objective-c")).toBe("txt");
		expect(sourceExtension("code")).toBe("txt");
	});
});

describe("nextVersion", () => {
	test("a new artifact needs a title and a type", () => {
		expect(nextVersion(undefined, { type: "html" }, NOW)).toBe("A new artifact needs a title.");
		expect(nextVersion(undefined, { title: "x" }, NOW)).toBe("A new artifact needs a type.");
		expect(nextVersion(undefined, { title: "Page", type: "html" }, NOW)).toEqual({
			version: 1,
			title: "Page",
			type: "html",
			language: undefined,
			source: "v1.html",
			view: "v1.html",
			savedAt: NOW,
		});
	});

	test("an update inherits what it leaves out, and a type change drops the language", () => {
		const first = nextVersion(undefined, { title: "Script", type: "code", language: "Python" }, NOW);
		if (typeof first === "string") throw new Error(first);
		const index = { id: "script", versions: [first] };
		const second = nextVersion(index, {}, NOW);
		expect(second).toMatchObject({ version: 2, title: "Script", type: "code", language: "python", source: "v2.py", view: "v2.view.html" });
		const third = nextVersion({ id: "script", versions: [first] }, { type: "markdown", title: "  " }, NOW);
		expect(third).toMatchObject({ version: 2, title: "Script", type: "markdown", language: undefined, source: "v2.md" });
	});
});

describe("parseIndex", () => {
	test("drops malformed versions and sorts the rest", () => {
		const v = (n: number) => ({ version: n, title: "t", type: "svg", source: `v${n}.svg`, view: `v${n}.view.html`, savedAt: NOW });
		const parsed = parseIndex({ id: "a", versions: [v(2), { ...v(3), type: "pdf" }, null, v(1)] });
		expect(parsed?.versions.map(x => x.version)).toEqual([1, 2]);
		expect(parseIndex({ id: "a" })).toBeUndefined();
		expect(parseIndex([])).toBeUndefined();
	});
});

describe("viewPage", () => {
	const page = (type: "svg" | "markdown" | "mermaid" | "code" | "html", content: string, language?: string) =>
		viewPage({ version: 3, title: "A <b> & c", type, language }, content, md => `<p>${md}</p>`);

	test("html is shown as written", () => {
		expect(page("html", "<p>x</p>")).toBeUndefined();
	});

	test("code and mermaid sources cannot break out of the page", () => {
		const code = page("code", "x = '</script><script>alert(1)</script>'", "Python") ?? "";
		expect(code).toContain('<code class="language-python">x = \'&lt;/script&gt;&lt;script&gt;');
		expect(code).not.toContain("<script>alert(1)");
		expect(page("mermaid", "graph TD; A-->B</pre>")).toContain("A--&gt;B&lt;/pre&gt;</pre>");
		expect(code).toContain("<title>A &lt;b&gt; &amp; c · v3</title>");
	});

	test("svg goes inline without its XML prolog and doctype", () => {
		const svg = page("svg", '<?xml version="1.0"?>\n<!DOCTYPE svg>\n<svg xmlns="http://www.w3.org/2000/svg"/>') ?? "";
		expect(svg).toContain('<body class="kind-svg">\n<svg xmlns');
		expect(svg).not.toContain("<?xml");
	});

	test("markdown goes through the renderer", () => {
		expect(page("markdown", "# hi")).toContain("<article><p># hi</p></article>");
	});
});

describe("served paths", () => {
	test("round-trip, and only plain file names below the key", () => {
		const p = servedPath("tok", "k1", "my-chart", "v2.view.html");
		expect(p).toBe("/tok/k1/my-chart/v2.view.html");
		expect(parseServedPath(p)).toEqual({ token: "tok", key: "k1", rest: ["my-chart", "v2.view.html"] });
		expect(parseServedPath("/tok/k1/..%5C..%5Csecret.txt")).toBeUndefined();
		expect(parseServedPath("/tok/k1/a/../../x")).toBeUndefined();
		expect(parseServedPath("/tok/k1/a/C%3A")).toBeUndefined();
		expect(parseServedPath("/tok/k1/%E0%A4%A")).toBeUndefined();
		expect(parseServedPath("/tok/k1")).toBeUndefined();
	});
});

describe("viewer lookup", () => {
	const blocks = parseBlocks({
		blocks: [
			{ block: 7, url: "https://example.com/", owner: null },
			{ block: 8, url: "http://localhost:4000/tok/k1/a/v1.html", owner: null },
			{ block: 9, url: "http://127.0.0.1:51234/old-token/k1/chart/v2.view.html", owner: null },
			{ block: "bad" },
		],
	});

	test("reuses the remembered block while it exists", () => {
		expect(pickViewer(blocks, 7, "k1")?.block).toBe(7);
	});

	test("else finds this session's viewer from an earlier run by its folder key", () => {
		expect(pickViewer(blocks, 42, "k1")?.block).toBe(9);
		expect(pickViewer(blocks, undefined, "k2")).toBeUndefined();
	});
});

describe("ownerPlace", () => {
	const inspect = (sessionShown: boolean, tabShown: boolean) => ({
		sessions: [
			{ shown: !sessionShown, tabs: [{ shown: true, blocks: [{ id: 1, focused: true }] }] },
			{
				shown: sessionShown,
				tabs: [
					{ shown: false, blocks: [{ id: 5, focused: true }] },
					{ shown: tabShown, blocks: [{ id: 10, focused: false }, { id: 11, focused: true }] },
				],
			},
		],
	});

	test("visible only when both its session and its tab are shown", () => {
		expect(ownerPlace(inspect(true, true), 10)).toEqual({ visible: true, focused: 11 });
		expect(ownerPlace(inspect(false, true), 10)).toEqual({ visible: false, focused: 11 });
		expect(ownerPlace(inspect(true, false), 10)).toEqual({ visible: false, focused: 11 });
		expect(ownerPlace(inspect(true, true), 99)).toBeUndefined();
	});
});
