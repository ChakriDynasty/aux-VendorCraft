module 'aux.tabs.vendorcraft'

local aux = require 'aux'
local money = require 'aux.util.money'

M.VERSION = '0.4.4'

DEFAULTS = {
	min_profit = 500,
	gold_reserve = 0,
	use_owned = true,
	max_crafts = 500,
}

EMPTY = {}
INF = 1/0

function say(msg)
	DEFAULT_CHAT_FRAME:AddMessage('|cff66ccff<VendorCraft>|r ' .. msg)
end

function char_key()
	return (GetCVar('realmName') or '?') .. '|' .. (UnitName('player') or '?')
end

-- Progress for whichever job is running; the tab polls these.
function set_status(value, text)
	status_value, status_text, status_dirty = value, text, true
end

function money_text(copper, color)
	return money.to_string(floor((copper or 0) + .5), nil, true, color)
end

function link_id(link)
	if not link then return end
	local _, _, id = strfind(link, 'item:(%d+)')
	return tonumber(id)
end

function aux.handle.LOAD()
	-- SavedVariables live in the real global table, not in this module's environment.
	_G.AuxVendorCraftDB = _G.AuxVendorCraftDB or {}
	db = _G.AuxVendorCraftDB
	db.version = 1
	db.chars = db.chars or {}
	db.books = db.books or {}
	db.prices = db.prices or {}
	db.settings = db.settings or {}
	settings = db.settings
	settings.owned_skip = settings.owned_skip or {}
	settings.owned_qty = settings.owned_qty or {}
	for k, v in DEFAULTS do
		if settings[k] == nil then
			settings[k] = v
		end
	end
	local key = char_key()
	db.chars[key] = db.chars[key] or {}
	character = db.chars[key]
	character.professions = character.professions or {}
	character.recipes = character.recipes or {}
	character.mail = character.mail or {}
	character.mail.seen = character.mail.seen or {}
	character.mail.bought = character.mail.bought or {}
end

do
	local handlers = {}
	function on_tick(f)
		tinsert(handlers, f)
	end
	local ticker = CreateFrame('Frame')
	ticker:SetScript('OnUpdate', function()
		for i = 1, getn(handlers) do
			handlers[i]()
		end
	end)
end

function format_age(t)
	if not t then return 'never' end
	local s = time() - t
	if s < 90 then return 'just now' end
	if s < 5400 then return floor(s / 60 + .5) .. 'm ago' end
	if s < 129600 then return floor(s / 3600 + .5) .. 'h ago' end
	return floor(s / 86400 + .5) .. 'd ago'
end

function slash(msg)
	msg = msg or ''
	local _, _, cmd, rest = strfind(msg, '^%s*(%S*)%s*(.-)%s*$')
	cmd = strlower(cmd or '')
	if cmd == 'recipes' then
		local any
		for prof, p in character.professions do
			local n = 0
			for _, r in character.recipes do
				if r.prof == prof then n = n + 1 end
			end
			say(format('%s %d/%d: %d recipes (read %s)', prof, p.rank or 0, p.max or 0, n, format_age(p.scanned)))
			any = true
		end
		if not any then
			say('No recipes yet. Open each of your profession windows once.')
		end
	elseif cmd == 'why' then
		local needle = strlower(rest or '')
		local shown = 0
		for name, why in last_skipped or EMPTY do
			if needle == '' or strfind(strlower(name), needle, 1, true) then
				say(name .. ': ' .. why)
				shown = shown + 1
				if shown >= 20 then break end
			end
		end
		if shown == 0 then
			say('No skipped recipes match "' .. (rest or '') .. '". Profitable ones are listed in the Vendor tab.')
		end
	elseif cmd == 'forget' then
		character.professions = {}
		character.recipes = {}
		say('Forgot this character\'s recipes. Open your profession windows to read them again.')
		request_plan()
	elseif cmd == 'stats' then
		stats_report()
	elseif cmd == 'unpriced' then
		local list = unpriced_recipes(rest)
		say(format('%d recipes have no known vendor price for what they make%s:', getn(list), rest ~= '' and (' matching "' .. rest .. '"') or ''))
		for i = 1, min(getn(list), 25) do
			local r = list[i]
			say(format('   %s%s - %s%s (item %d)', r.known and '' or '|cff999999', r.name, r.prof, r.skill and (' ' .. r.skill) or '', r.product))
		end
		if getn(list) > 25 then
			say('   ...and ' .. (getn(list) - 25) .. ' more; add a word to narrow it, e.g. /vcraft unpriced survival')
		end
		if getn(list) > 0 then
			say('aux learns a price when you open a merchant with the item in your bags; or set one with /vcraft price.')
		end
	elseif cmd == 'price' then
		local id, amount
		local _, link_end = strfind(rest, '|h|r')
		if link_end then
			id, amount = link_id(rest), strsub(rest, link_end + 1)
		else
			local _, _, n, a = strfind(rest, '^(%d+)%s*(.*)$')
			id, amount = tonumber(n), a
		end
		amount = gsub(amount or '', '^%s+', '')
		if id and amount == 'clear' then
			db.prices[id] = nil
			say('Removed your vendor price for ' .. item_name(id) .. '.')
			request_plan()
		elseif id and strfind(amount, '[gscGSC]') and money.from_string(amount) then
			db.prices[id] = floor(money.from_string(amount))
			say(format('Vendor price for %s set to %s each.', item_name(id), money_text(db.prices[id])))
			request_plan()
		else
			say('Usage: /vcraft price <shift-click item, or item id> <price like 1s 20c> - or "clear" to remove it')
		end
	elseif cmd == 'max' then
		local n = tonumber(rest)
		if n and n >= 1 then
			settings.max_crafts = floor(n)
			request_plan()
		end
		say('At most ' .. settings.max_crafts .. ' crafts per recipe are planned.')
	elseif cmd == 'clear' then
		clear_book()
		say('Cleared the stored auction house scan.')
		request_plan()
	else
		say('v' .. VERSION .. ' - aux tabs: Vendor (craft flips), Flip (AH below vendor), Mats (search and buy).')
		say('/vcraft recipes - list the professions and recipes that have been read')
		say('/vcraft why [name] - why a recipe is not in the list')
		say('/vcraft stats - per profession, how many recipes were skipped and why')
		say('/vcraft unpriced [word] - recipes that cannot be rated because no vendor price is known')
		say('/vcraft price <item> <price> - set a vendor price yourself, e.g. 1s 20c')
		say('/vcraft max <n> - most crafts planned per recipe (now ' .. settings.max_crafts .. ')')
		say('/vcraft forget - forget this character\'s recipes')
		say('/vcraft clear - delete the stored auction house scan')
	end
end

_G.SLASH_AUXVENDORCRAFT1 = '/vcraft'
_G.SLASH_AUXVENDORCRAFT2 = '/auxvc'
SlashCmdList.AUXVENDORCRAFT = function(msg) slash(msg) end
