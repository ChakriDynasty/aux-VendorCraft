module 'aux.tabs.vendorcraft'

local tooltip_mod = require 'aux.core.tooltip'

-- aux's "Value:" line is its own auction history, not what a vendor pays.
-- This adds the stored vendor sell price on the same tooltips aux already
-- extends: bags, paperdoll, chat links, loot, merchants, and the AH.
local orig_extend = tooltip_mod.extend_tooltip

function tooltip_mod.extend_tooltip(tooltip, link, quantity)
	orig_extend(tooltip, link, quantity)
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
