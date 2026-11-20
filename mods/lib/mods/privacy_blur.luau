--!strict
-- Screen-recording mode: blurs the known places of e-mails, account names, paths and
-- titles, and unblurs them under the pointer. CSS can't look for a secret inside
-- text: it only covers the places below entirely; an e-mail or token written in the
-- body of a terminal or a chat stays readable.

local schema = require("../schema")

-- Target group → selectors. Tern's internal classes and the data-roles of omp surfaces.
local TARGETS: { [string]: { string } } = {
	tabs = {
		"#tabbar .tt .tx",
		"#tabbar .tn-session-tab .nm",
		"#sidebar .nav-row .lbl",
		".pk-card .pk-bt",
	},
	heads = {
		".tn-head .tn-title",
		".tn-head .tn-cwd",
		".tn-head .tn-git",
	},
	status = {
		"#widgetbar .wg-row",
		"[data-role='omp.composer.extras']",
		"[data-role^='omp.status.']",
		"[data-role='omp.app.git.where']",
	},
	usage = {
		".sf-main[data-surface='plugin.omp-usage.accounts']",
		"[data-role='omp.overlay.usage'] .sf-ov-body",
		"[data-role^='omp.usage.provider']",
	},
	accounts = {
		"#tabbar .tn-peers",
		".tn-signin-card",
		"[data-role='omp.info.identity']",
		"[data-role='omp.app.git.author']",
		"[data-role='omp.app.git.avatar']",
		"[data-role^='omp.login.']",
	},
}
local ORDER = { "tabs", "heads", "status", "usage", "accounts" }

local mod: schema.Mod = {
	id = "privacy-blur",
	defaults = { strength = 6, hover = true, tabs = true, heads = true, status = true, usage = true, accounts = true },
	fields = {
		{ key = "strength", kind = "number", min = 2, max = 16, step = 1, unit = "px" },
		{ key = "hover", kind = "bool" },
		{ key = "tabs", kind = "bool" },
		{ key = "heads", kind = "bool" },
		{ key = "status", kind = "bool" },
		{ key = "usage", kind = "bool" },
		{ key = "accounts", kind = "bool" },
	},
	css = function(s, _env)
		local sel = {}
		for _, group in ORDER do
			if s[group] then
				for _, x in TARGETS[group] do
					table.insert(sel, x)
				end
			end
		end
		if #sel == 0 then
			return nil
		end
		local list = table.concat(sel, ",\n")
		local css = {
			`{list} \{ filter: blur({schema.num(s.strength)}px) !important; transition: filter 0.15s ease; }`,
		}
		if s.hover then
			local hovered = {}
			for _, x in sel do
				table.insert(hovered, x .. ":hover")
			end
			table.insert(css, `{table.concat(hovered, ",\n")} \{ filter: none !important; }`)
		end
		return table.concat(css, "\n")
	end,
}

return mod
