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
	-- server is never flooded. A finished plan is refreshed at most once
	-- after this queue has gone idle. Later cache fills do not start another
	-- plan. Nothing here marks the plan stale while a plan is running.
	local queue, queued, failed, pending, missing_price = {}, {}, {}, {}, {}
	local next_request, arrived, missing_arrived, followup_done = 0, false, false, false

	function queue_item_load(id)
		if queued[id] or failed[id] then return end
		queued[id] = true
		tinsert(queue, id)
	end

	function items_loading()
		return getn(queue)
	end

	-- vendor_sell queued a load and no source had a price yet.
	function note_uncached(id)
		missing_price[id] = true
	end

	-- The next user-requested plan may be followed by one cache refresh.
	function allow_price_followup()
		followup_done = false
	end

	local function loads_idle()
		if getn(queue) > 0 then return false end
		for _ in pending do
			return false
		end
		return true
	end

	local function note_loaded(id, success)
		if id and not success then
			failed[id] = true
		end
		if id then
			pending[id] = nil
		end
		if id and success and missing_price[id] and _G.C_Item and _G.C_Item.IsItemDataCachedByID(id) then
			local price = _G.C_Item.GetItemSellPriceByID(id)
			if price ~= nil then
				missing_price[id] = nil
				missing_arrived = true
			end
		end
		arrived = true
	end

	function aux.handle.LOAD()
		if not classic_api() then return end
		aux.event_listener('ITEM_DATA_LOAD_RESULT', function()
			note_loaded(arg1, arg2)
		end)
		-- This event does not report failure; a missing arg2 must not blacklist the item.
		aux.event_listener('GET_ITEM_INFO_RECEIVED', function()
			note_loaded(arg1, true)
		end)
	end

	on_tick(function()
		if getn(queue) > 0 and GetTime() >= next_request then
			next_request = GetTime() + .05
			local id = tremove(queue, 1)
			pending[id] = true
			_G.C_Item.RequestLoadItemDataByID(id)
		end
		-- Leave arrivals pending while a plan is running, while another plan
		-- is about to start, or while loads are still in flight.
		if busy() or plan_requested or not loads_idle() then return end
		if not arrived and not missing_arrived then return end
		arrived, missing_arrived = false, false
		-- One automatic replan after the cache goes idle. Each plan queues
		-- more items, so treating every newly arrived price as a reason to
		-- start again loops forever over the recipe list.
		if not followup_done then
			followup_done = true
			if reset_atlas_cache then reset_atlas_cache() end
			plan_stale = true
		end
	end)
end

-- Price a vendor pays for one unit. Second return is true when it comes from
-- the game itself (ClassicAPI), a real merchant on this server (learned by
-- aux) or /vcraft price, rather than a static table. Third return names the
-- source.
function vendor_sell(id)
	local waiting
	if classic_api() then
		if _G.C_Item.IsItemDataCachedByID(id) then
			local price = _G.C_Item.GetItemSellPriceByID(id)
			if price then
				return price, true, 'game'
			end
		else
			queue_item_load(id)
			waiting = true
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
	if waiting then
		note_uncached(id)
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
-- A zero or missing price is not a vendor.
function vendor_buy(id)
	local _, learned, limited = info.merchant_info(id)
	if learned and not limited and learned > 0 then
		return learned, true
	end
	local scraped = VENDOR_BUY[id]
	if scraped and scraped > 0 then
		return scraped, false
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
	local changed
	for id, n in seen do
		if character.mail.seen[id] ~= n then changed = true end
	end
	for id in character.mail.seen do
		if seen[id] == nil then changed = true end
	end
	for _ in character.mail.bought do
		changed = true
		break
	end
	character.mail.seen = seen
	character.mail.bought = {}
	-- An unchanged inbox must not start another plan.
	if changed then
		plan_stale = true
	end
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
