module 'aux.tabs.vendorcraft'

local aux = require 'aux'
local info = require 'aux.util.info'

do
	local caches = {}
	-- pfUI's tables hold "sell,buy" strings per item id.
	local function parse(prices, id)
		local cache = caches[prices]
		if not cache then
			cache = {}
			caches[prices] = cache
		end
		local entry = cache[id]
		if entry == nil then
			entry = false
			local raw = prices[id]
			if raw then
				local _, _, sell, buy = strfind(raw, '(%d+),(%d+)')
				if sell then
					entry = {tonumber(sell), tonumber(buy)}
				end
			end
			cache[id] = entry
		end
		if entry then
			return entry[1], entry[2]
		end
	end

	-- pfUI's Turtle module puts its (newer) table in pfUI's private
	-- environment; the global one is the vanilla table.
	function pfui_turtle_prices()
		local env = _G.pfUI and _G.pfUI.env
		local prices = env and rawget(env, 'pfSellData')
		if prices and prices ~= _G.pfSellData then return prices end
	end

	-- Sell and buy price from pfUI; third return is true for the Turtle table.
	function pf_prices(id)
		local turtle = pfui_turtle_prices()
		if turtle then
			local sell, buy = parse(turtle, id)
			if sell then return sell, buy, true end
		end
		if _G.pfSellData then
			return parse(_G.pfSellData, id)
		end
	end
end

-- ClassicAPI (a client DLL) exposes the sell price the server sent with each
-- item: exact, and it covers custom items the static tables lack.
function classic_api()
	local api = _G.C_Item
	return api and api.GetItemSellPriceByID and api.IsItemDataCachedByID and api.RequestLoadItemDataByID and true
end

do
	-- Items not yet in the client cache are loaded a few at a time so the
	-- server is never flooded; plans refresh as prices arrive.
	local queue, queued, failed = {}, {}, {}
	local next_request, arrived, last_refresh = 0, false, 0

	function queue_item_load(id)
		if queued[id] or failed[id] then return end
		queued[id] = true
		tinsert(queue, id)
	end

	function items_loading()
		return getn(queue)
	end

	function aux.handle.LOAD()
		if not classic_api() then return end
		aux.event_listener('ITEM_DATA_LOAD_RESULT', function()
			if arg1 and not arg2 then failed[arg1] = true end
			arrived = true
		end)
		aux.event_listener('GET_ITEM_INFO_RECEIVED', function()
			arrived = true
		end)
	end

	on_tick(function()
		if getn(queue) > 0 and GetTime() >= next_request then
			next_request = GetTime() + .05
			_G.C_Item.RequestLoadItemDataByID(tremove(queue, 1))
		end
		if arrived and (getn(queue) == 0 or GetTime() - last_refresh > 20) then
			arrived, last_refresh = false, GetTime()
			plan_stale = true
		end
	end)
end

-- Price a vendor pays for one unit. Second return is true when it comes from
-- the game itself (ClassicAPI), a real merchant on this server (learned by
-- aux) or /vcraft price, rather than a static table. Third return names the
-- source.
function vendor_sell(id)
	if classic_api() then
		if _G.C_Item.IsItemDataCachedByID(id) then
			local price = _G.C_Item.GetItemSellPriceByID(id)
			if price then
				return price, true, 'game'
			end
		else
			queue_item_load(id)
		end
	end
	local learned = info.merchant_info(id)
	if learned then
		return learned, true, 'merchant'
	end
	local manual = db.prices[id]
	if manual then
		return manual, true, 'manual'
	end
	local octo = OCTO_PRICES[id]
	if octo then
		return octo[1], true, 'Octo database'
	end
	local pf, _, turtle = pf_prices(id)
	if pf and turtle then
		return pf, false, 'pfUI Turtle table'
	end
	local shagu = _G.ShaguTweaks and _G.ShaguTweaks.SellValueDB and _G.ShaguTweaks.SellValueDB[id]
	if shagu then
		return shagu, false, 'ShaguTweaks'
	end
	if pf then
		return pf, false, 'pfUI vanilla table'
	end
end

-- An NPC with stock 0 in pfQuest's item table sells the item without limit.
function sold_by_vendor(id)
	local items = _G.pfDB and _G.pfDB.items and _G.pfDB.items.data
	local vendors = items and items[id] and items[id].V
	if vendors then
		for _, stock in vendors do
			if stock == 0 then return true end
		end
	end
	return false
end

-- Unit price when the item can be bought from a vendor without a stock limit, else nil.
function vendor_buy(id)
	local _, learned, limited = info.merchant_info(id)
	if learned and not limited then
		return learned, true
	end
	if sold_by_vendor(id) then
		local _, pf = pf_prices(id)
		if pf and pf > 0 then
			return pf, false
		end
		local octo = OCTO_PRICES[id]
		if octo and octo[2] and octo[2] > 0 then
			return octo[2], false
		end
	end
end

function item_name(id, fallback)
	local item_info = info.item(id)
	return item_info and item_info.name or fallback or ('item:' .. id)
end

function item_quality(id)
	local item_info = info.item(id)
	return item_info and item_info.quality or 1
end

-- Counts on this character (bags + bank) and per alt, from Bagshui's catalog.
-- Falls back to this character's bags when Bagshui is not running.
function owned_snapshot()
	local mine, alts = {}, {}
	local me = UnitName('player')
	local catalog = _G.Bagshui and _G.Bagshui.components and _G.Bagshui.components.Catalog
	local realm_totals = catalog and catalog.initialized and catalog.totals
		and catalog.totals[_G.Bagshui.currentRealm or GetCVar('realmName')]
	if realm_totals and realm_totals._sortedCharacterList then
		for _, name in ipairs(realm_totals._sortedCharacterList) do
			local counts = realm_totals['==Total' .. name]
			if counts then
				for item_string, count in counts do
					local _, _, id = strfind(item_string, '^item:(%d+)')
					id = tonumber(id)
					if id and type(count) == 'number' and count > 0 then
						if name == me then
							mine[id] = (mine[id] or 0) + count
						else
							alts[id] = alts[id] or {}
							alts[id][name] = (alts[id][name] or 0) + count
						end
					end
				end
			end
		end
		return mine, alts, 'bagshui'
	end
	for bag = 0, 4 do
		for slot = 1, GetContainerNumSlots(bag) do
			local id = link_id(GetContainerItemLink(bag, slot))
			if id then
				local _, count = GetContainerItemInfo(bag, slot)
				mine[id] = (mine[id] or 0) + (count or 1)
			end
		end
	end
	return mine, alts, 'bags'
end

-- aux buyouts arrive by mail, which Bagshui does not track. The inbox is read
-- whenever it is open; purchases made since the last read are added on top.
function mail_counts()
	local counts = {}
	for id, n in character.mail.seen do
		counts[id] = n
	end
	for id, n in character.mail.bought do
		counts[id] = (counts[id] or 0) + n
	end
	return counts
end

function add_purchase(id, count)
	character.mail.bought[id] = (character.mail.bought[id] or 0) + count
end

function read_inbox()
	local seen = {}
	for i = 1, GetInboxNumItems() do
		local name, _, count = GetInboxItem(i)
		local id = name and info.item_id(name)
		if id then
			seen[id] = (seen[id] or 0) + (count or 1)
		end
	end
	character.mail.seen = seen
	character.mail.bought = {}
	plan_stale = true
end

do
	local inbox_dirty
	function aux.handle.LOAD()
		aux.event_listener('MAIL_INBOX_UPDATE', function() inbox_dirty = true end)
	end
	on_tick(function()
		if inbox_dirty then
			inbox_dirty = false
			read_inbox()
		end
	end)
end
