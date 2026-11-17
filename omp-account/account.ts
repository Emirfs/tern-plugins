/**
 * omp extension: choose which OAuth account of the current model's provider this
 * conversation uses, and show it in the status line.
 *
 * `/hesap` lists the provider's accounts (`/hesap 2`, `/hesap inohom` pick one
 * directly; `/hesap oto` hands the choice back to omp). The choice is an explicit
 * session pin, so omp's account ranking never moves it; it is also written to the
 * session file and applied again when the session is resumed (omp restores its own
 * pin only as an automatic one, which ranking may move after an idle hour).
 * Models stay the provider's own: `/model` is unchanged.
 */
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

const ENTRY = "account-choice";
const STATUS_KEY = "account";
const AUTO_WORDS: Record<string, true> = { oto: true, auto: true, otomatik: true };

/** The fields this extension reads from omp's `authStorage.oauth.accounts()` rows. */
interface Account {
	credentialId: number;
	accountId?: string;
	email?: string;
	projectId?: string;
	orgId?: string;
	orgName?: string;
	active: boolean;
}

/** What the session file remembers per provider: the account, or `auto`. */
interface Choice {
	provider: string;
	auto?: boolean;
	credentialId?: number;
	email?: string;
	accountId?: string;
	orgId?: string;
}

function accountsOf(ctx: ExtensionContext, provider: string): Account[] {
	try {
		return ctx.modelRegistry.authStorage.oauth.accounts(provider, ctx.sessionManager.getSessionId());
	} catch {
		return [];
	}
}

/** Short name for the status line: the e-mail's domain without its TLD (gmail, inohom), else the org. */
function shortName(a: Account): string {
	const domain = a.email?.split("@")[1];
	if (domain) {
		const parts = domain.split(".");
		return parts.length > 1 ? parts.slice(0, -1).join(".") : domain;
	}
	return a.orgName ?? a.accountId ?? a.projectId ?? "?";
}

/** Full name for lists: e-mail, plus the organization unless it is Anthropic's personal default. */
function longName(a: Account): string {
	const base = a.email ?? a.accountId ?? a.projectId ?? `#${a.credentialId}`;
	return a.orgName && a.orgName !== base && !a.orgName.endsWith("'s Organization") ? `${base} · ${a.orgName}` : base;
}

/** The stored account a saved choice names: same credential row, else the same identity. */
function findChoice(accounts: Account[], choice: Choice): Account | undefined {
	return (
		accounts.find(a => a.credentialId === choice.credentialId) ??
		accounts.find(a =>
			choice.email !== undefined
				? a.email?.toLowerCase() === choice.email.toLowerCase() && a.orgId === choice.orgId
				: choice.accountId !== undefined && a.accountId === choice.accountId,
		)
	);
}

function isChoiceEntry(entry: unknown, provider: string): entry is { data: Choice } {
	if (!entry || typeof entry !== "object") return false;
	const e = entry as { type?: unknown; customType?: unknown; data?: { provider?: unknown } };
	return e.type === "custom" && e.customType === ENTRY && e.data?.provider === provider;
}

/** The last choice the session file holds for `provider`. */
function savedChoice(ctx: ExtensionContext, provider: string): Choice | undefined {
	let found: Choice | undefined;
	for (const entry of ctx.sessionManager.getEntries()) {
		if (isChoiceEntry(entry, provider)) found = entry.data;
	}
	return found;
}

function pin(ctx: ExtensionContext, provider: string, account: Account): boolean {
	try {
		return ctx.modelRegistry.authStorage.sessions.pin(provider, ctx.sessionManager.getSessionId(), account.credentialId);
	} catch {
		return false;
	}
}

function updateStatus(ctx: ExtensionContext): void {
	const provider = ctx.model?.provider;
	const accounts = provider ? accountsOf(ctx, provider) : [];
	if (!provider || accounts.length < 2) {
		ctx.ui.setStatus(STATUS_KEY, undefined);
		return;
	}
	const choice = savedChoice(ctx, provider);
	const chosen = choice && !choice.auto ? findChoice(accounts, choice) : undefined;
	const active = chosen ?? accounts.find(a => a.active);
	const name = active ? shortName(active) : "henüz yok";
	ctx.ui.setStatus(STATUS_KEY, chosen ? `hesap: ${name}` : `hesap: ${name} (oto)`);
}

/** Apply the session's saved choice for the current provider again (resume, model switch, idle pin). */
function reapply(ctx: ExtensionContext): void {
	const provider = ctx.model?.provider;
	const choice = provider ? savedChoice(ctx, provider) : undefined;
	if (provider && choice && !choice.auto) {
		const accounts = accountsOf(ctx, provider);
		const account = findChoice(accounts, choice);
		if (account && !account.active) pin(ctx, provider, account);
	}
	updateStatus(ctx);
}

export default function account(pi: ExtensionAPI): void {
	pi.registerCommand("hesap", {
		description: "Bu sohbetin hesabı: /hesap (liste), /hesap 2, /hesap inohom, /hesap oto",
		handler: async (args, ctx) => {
			const provider = ctx.model?.provider;
			if (!provider) {
				ctx.ui.notify("Önce bir model seç.", "warning");
				return;
			}
			const accounts = accountsOf(ctx, provider);
			if (accounts.length === 0) {
				ctx.ui.notify(`${provider} için kayıtlı OAuth hesabı yok; /login ile ekle.`, "warning");
				return;
			}
			if (!ctx.isIdle()) {
				ctx.ui.notify("Yanıt sürerken hesap değiştirilemez; bitince tekrar dene.", "warning");
				return;
			}

			const arg = args.trim();
			let target: Account | "auto" | undefined;
			if (AUTO_WORDS[arg.toLowerCase()]) {
				target = "auto";
			} else if (arg) {
				const n = Number(arg);
				const hits =
					Number.isInteger(n) && n >= 1 && n <= accounts.length
						? [accounts[n - 1]]
						: accounts.filter(a => longName(a).toLowerCase().includes(arg.toLowerCase()));
				if (hits.length !== 1) {
					ctx.ui.notify(
						hits.length === 0
							? `"${arg}" ile eşleşen hesap yok.`
							: `"${arg}" birden çok hesapla eşleşiyor; numarasını yaz.`,
						"warning",
					);
					return;
				}
				target = hits[0];
			} else {
				const saved = savedChoice(ctx, provider);
				const chosen = saved && !saved.auto ? findChoice(accounts, saved) : undefined;
				const options = accounts.map((a, i) => ({
					label: `${i + 1}. ${longName(a)}`,
					description: a === chosen ? "seçili" : !chosen && a.active ? "omp şu an bunu kullanıyor" : undefined,
				}));
				options.push({ label: "Otomatik", description: chosen ? "hesabı omp seçer" : "seçili: hesabı omp seçer" });
				const picked = await ctx.ui.select(`${provider}: bu sohbetin hesabı`, options);
				if (picked === undefined) return;
				const index = options.findIndex(o => o.label === picked);
				target = index < accounts.length ? accounts[index] : "auto";
			}

			if (target === "auto") {
				ctx.modelRegistry.authStorage.sessions.release(provider, ctx.sessionManager.getSessionId());
				pi.appendEntry<Choice>(ENTRY, { provider, auto: true });
				ctx.ui.notify("Hesabı artık omp seçiyor.", "info");
			} else {
				if (!pin(ctx, provider, target)) {
					ctx.ui.notify(`${longName(target)} bu sohbete sabitlenemedi.`, "error");
					return;
				}
				pi.appendEntry<Choice>(ENTRY, {
					provider,
					credentialId: target.credentialId,
					email: target.email,
					accountId: target.accountId,
					orgId: target.orgId,
				});
				ctx.ui.notify(`Bu sohbet ${longName(target)} hesabını kullanıyor.`, "info");
			}
			updateStatus(ctx);
		},
	});

	pi.on("session_start", (_event, ctx) => reapply(ctx));
	pi.on("session_switch", (_event, ctx) => reapply(ctx));
	// Every prompt: the model (so the provider) may have changed, and an idle pin may have gone cold.
	pi.on("before_agent_start", (_event, ctx) => {
		reapply(ctx);
	});
	pi.on("agent_end", (_event, ctx) => updateStatus(ctx));
}
