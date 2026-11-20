--!strict
-- The Jira key is visible in the title; the numeric Jira id lives in the baseline.
local Sync = {}

export type Issue = {
	id: string, key: string, title: string, due: string,
	status: string, status_name: string, lane: string,
}
export type Card = { id: string, text: string, title: string, due: string, lane: string, key: string? }
export type Change = { issue: Issue, card: Card, field: string, before: string, value: string }
export type LocalEdit = { issue: Issue, card: Card?, title: string?, due: string?, lane: string? }

function Sync.cards(board: BoardSnapshot): ({ Card }, { [string]: string })
	local cards, lanes = {}, {}
	for _, lane in board.lanes do
		local name = lane.title or ""
		if lanes[name] then
			lanes[name] = "" -- Ambiguous by title; never resolve it arbitrarily.
		else
			lanes[name] = lane.id
		end
		for _, row in lane.cards do
			local key, title = string.match(row.text, "^%[([A-Z][A-Z0-9_]*%-%d+)%] (.+)$")
			table.insert(cards, {
				id = row.id, text = row.text, title = title or row.text, due = row.due or "", key = key,
				lane = if row.done then "Done" else name,
			})
		end
	end
	return cards, lanes
end

function Sync.title(key: string, title: string): string
	return `[{key}] {title}`
end

function Sync.plan(issues: { Issue }, cards: { Card }, base: { [string]: Issue }): ({ LocalEdit }, { Change }, { string }, { [string]: Issue })
	local localEdits: { LocalEdit } = {}
	local changes: { Change } = {}
	local conflicts: { string } = {}
	local newBase = table.clone(base)
	local byKey: { [string]: Card } = {}
	local duplicate: { [string]: boolean } = {}
	for _, card in cards do
		if card.key then
			duplicate[card.key] = byKey[card.key] ~= nil
			byKey[card.key] = card
		end
	end
	for _, remote in issues do
		local key = remote.key
		local previous = base[remote.id]
		local card = byKey[if previous then previous.key else key]
		if (previous and duplicate[previous.key]) or duplicate[key] or
			(previous and previous.key ~= key and byKey[key] ~= nil) then
			table.insert(conflicts, `{key}: the same Jira key is on more than one card on the board.`)
			continue
		end
		if not card then
			if not previous then
				table.insert(localEdits, {issue = remote, title = remote.title, due = remote.due, lane = remote.lane})
				newBase[remote.id] = table.clone(remote)
			end
			continue -- Local removal never deletes or updates a Jira issue.
		end
		if not previous and (card.title ~= remote.title or card.due ~= remote.due or card.lane ~= remote.lane) then
			-- A card with no sync history: it is unknown which side is right, so report the difference field by field.
			local diffs: { string } = {}
			if card.title ~= remote.title then table.insert(diffs, `title “{card.title}” / “{remote.title}”`) end
			if card.due ~= remote.due then table.insert(diffs, `due date “{card.due}” / “{remote.due}”`) end
			if card.lane ~= remote.lane then table.insert(diffs, `column “{card.lane}” / “{remote.lane}”`) end
			table.insert(conflicts, `{key}: card on the board is not synced (board / Jira): {table.concat(diffs, ", ")}. Sync the board to Jira, or delete the card and refresh.`)
			continue
		end
		local nextBase = table.clone(previous or remote)
		nextBase.key = key
		local edit: LocalEdit = { issue = remote, card = card }
		if card.key ~= key then
			edit.title = card.title
		end
		for _, field in { "title", "due", "status" } do
			local localField = if field == "status" then "lane" else field
			local value = (card :: any)[localField]
			local target = (remote :: any)[localField]
			local before = (nextBase :: any)[localField]
			if value == before or value == target then
				if value ~= target then
					(edit :: any)[localField] = target
				end
				(nextBase :: any)[localField] = target
				if field == "status" then
					nextBase.status, nextBase.status_name = remote.status, remote.status_name
				end
			elseif (nextBase :: any)[field] ~= (remote :: any)[field] then
				local label = if field == "title" then "title" elseif field == "due" then "due date" else "status"
				local remoteValue = if field == "status" then remote.status_name else target
				table.insert(conflicts, `{key} · {label}: “{value}” on the board, “{remoteValue}” in Jira.`)
			elseif field ~= "status" or value == "Todo" or value == "Doing" or value == "Done" then
				local change: Change = {issue = remote, card = card, field = field :: string, before = (remote :: any)[field], value = value :: string}
				table.insert(changes, change)
			end
		end
		if edit.title ~= nil or edit.due ~= nil or edit.lane ~= nil then
			table.insert(localEdits, edit)
		end
		newBase[remote.id] = nextBase
	end
	return localEdits, changes, conflicts, newBase
end

return Sync
