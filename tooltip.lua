module 'aux.tabs.vendorcraft'

local aux = require 'aux'

-- aux's "Value:" line is its auction history. This adds what a vendor pays.
-- The public aux tooltip function cannot be replaced, so the game tooltip
-- methods are wrapped after aux has installed its own hooks.

function add_vendor_line(tooltip, link, quantity)
	if not tooltip or not tooltip.AddLine or not link then return end
	local id = link_id(link)
	if not id then return end
	local price, verified = vendor_sell(id)
	if not price or price <= 0 then return end
	quantity = quantity or 1
	local text = 'Vendor pays ' .. money_text(price)
	if quantity > 1 then
		text = text .. ' each (' .. money_text(price * quantity) .. ')'
	end
	if not verified then
		text = text .. gray(' *')
	end
	tooltip:AddLine(text, 1, .82, 0)
	tooltip:Show()
end

wrapped_tips = {}

function wrap_tooltip(name, fetch)
	local orig = GameTooltip[name]
	if not orig or wrapped_tips[name] == orig then return end
	local function hooked(self, a, b)
		remember_tip(fetch(a, b))
		-- The paperdoll uses the return value. If it is missing, the slot
		-- name ("Legs") replaces the item tooltip.
		local r1, r2, r3 = orig(self, a, b)
		remember_tip(fetch(a, b))
		return r1, r2, r3
	end
	wrapped_tips[name] = hooked
	GameTooltip[name] = hooked
end

function tip_item()
	local lib = _G.pfUI and _G.pfUI.api and _G.pfUI.api.libtooltip
	if lib and lib.itemLink then
		return lib.itemLink, lib.itemCount
	end
	return vendor_tip_link, vendor_tip_count
end

function remember_tip(link, quantity)
	if link then
		vendor_tip_link = link
		vendor_tip_count = quantity
	end
end

function apply_vendor_hooks()
	wrap_tooltip('SetHyperlink', function(itemstring)
		return itemstring, 1
	end)
	wrap_tooltip('SetBagItem', function(bag, slot)
		local _, quantity = GetContainerItemInfo(bag, slot)
		return GetContainerItemLink(bag, slot), quantity
	end)
	wrap_tooltip('SetInventoryItem', function(unit, slot)
		return GetInventoryItemLink(unit, slot), 1
	end)
	wrap_tooltip('SetAuctionItem', function(kind, index)
		local _, _, quantity = GetAuctionItemInfo(kind, index)
		return GetAuctionItemLink(kind, index), quantity
	end)
	wrap_tooltip('SetLootItem', function(slot)
		local _, _, quantity = GetLootSlotInfo(slot)
		return GetLootSlotLink(slot), quantity
	end)
	wrap_tooltip('SetQuestItem', function(kind, slot)
		local _, _, quantity = GetQuestItemInfo(kind, slot)
		return GetQuestItemLink(kind, slot), quantity
	end)
	wrap_tooltip('SetQuestLogItem', function(kind, slot)
		return GetQuestLogItemLink(kind, slot), 1
	end)
	wrap_tooltip('SetMerchantItem', function(slot)
		local _, _, _, quantity = GetMerchantItemInfo(slot)
		return GetMerchantItemLink(slot), quantity
	end)
	wrap_tooltip('SetInboxItem', function(index)
		local name, _, quantity = GetInboxItem(index)
		local id = name and info_item_id(name)
		return id and ('item:' .. id) or nil, quantity
	end)
	wrap_tooltip('SetTradeSkillItem', function(skill, slot)
		if slot then
			local _, _, quantity = GetTradeSkillReagentInfo(skill, slot)
			return GetTradeSkillReagentItemLink(skill, slot), quantity
		end
		return GetTradeSkillItemLink(skill), 1
	end)
	wrap_tooltip('SetCraftItem', function(skill, slot)
		if slot then
			local _, _, quantity = GetCraftReagentInfo(skill, slot)
			return GetCraftReagentItemLink(skill, slot), quantity
		end
		return GetCraftItemLink(skill), 1
	end)
	wrap_tooltip('SetCraftSpell', function(slot)
		return GetCraftItemLink(slot), 1
	end)
	wrap_tooltip('SetAuctionSellItem', function()
		local name, _, quantity = GetAuctionSellItemInfo()
		local id = name and info_item_id(name)
		return id and ('item:' .. id) or nil, quantity
	end)

	if not item_ref_hooked then
		item_ref_hooked = true
		local orig_ref = _G.SetItemRef
		_G.SetItemRef = function(link, text, button)
			orig_ref(link, text, button)
			if link and not IsShiftKeyDown() and not IsControlKeyDown() then
				add_vendor_line(ItemRefTooltip, link, 1)
			end
		end
	end
end

function aux.handle.LOAD2()
	if vendor_tooltip_hooked then return end
	vendor_tooltip_hooked = true
	apply_vendor_hooks()

	local watcher = CreateFrame('Frame')
	watcher:SetScript('OnUpdate', function()
		apply_vendor_hooks()
		if GameTooltip:IsVisible() then
			local link, count = tip_item()
			if link and link ~= vendor_tip_shown then
				vendor_tip_shown = link
				add_vendor_line(GameTooltip, link, count)
			end
		else
			vendor_tip_shown = nil
			vendor_tip_link = nil
		end
	end)
end

function info_item_id(name)
	local info = require 'aux.util.info'
	return info.item_id(name)
end
