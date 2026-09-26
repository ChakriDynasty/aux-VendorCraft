module 'aux.tabs.vendorcraft'

local aux = require 'aux'
local info = require 'aux.util.info'

do
	local cache = {}
	-- pfUI's table holds "sell,buy" strings per item id.
	function pf_prices(id)
		local entry = cache[id]
		if entry == nil then
			entry = false
			local raw = _G.pfSellData and _G.pfSellData[id]
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
end

-- Price a vendor pays for one unit. Second return is true when aux learned it
-- from a real merchant on this server, or you set it with /vcraft price,
-- rather than it coming from a static database.
function vendor_sell(id)
	local learned = info.merchant_info(id)
	if learned then
		return learned, true
	end
	local manual = db.prices[id]
	if manual then
		return manual, true
	end
	local shagu = _G.ShaguTweaks and _G.ShaguTweaks.SellValueDB and _G.ShaguTweaks.SellValueDB[id]
	if shagu then
		return shagu, false
	end
	local pf = pf_prices(id)
	if pf then
		return pf, false
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
