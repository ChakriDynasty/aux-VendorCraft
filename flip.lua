module 'aux.tabs.vendorcraft'

local aux = require 'aux'
local gui = require 'aux.gui'
local listing = require 'aux.gui.listing'

local tab = aux.tab 'Flip'

FLIP_COLUMNS = {
	{name = 'Item', width = .36, align = 'LEFT'},
	{name = 'Qty', width = .08, align = 'CENTER'},
	{name = 'AH each', width = .14, align = 'RIGHT'},
	{name = 'Vendor', width = .14, align = 'RIGHT'},
	{name = 'Profit', width = .16, align = 'RIGHT'},
	{name = 'Per item', width = .12, align = 'RIGHT'},
}

function tab.OPEN()
	if flip_frame then flip_frame:Show() end
	load_book()
	flip_dirty = true
	refresh_flip_controls()
end

function tab.CLOSE()
	if flip_frame then flip_frame:Hide() end
end

-- Auctions cheaper than what a vendor pays. Same stored scan as Vendor.
function compute_flips()
	load_book()
	local rows = {}
	for id, auctions in book_items or EMPTY do
		local value = vendor_sell(id)
		if value and value > 0 and getn(auctions) > 0 then
			local units, cash, profit, picks, max_unit = 0, 0, 0, {}, 0
			for i = 1, getn(auctions) do
				local a = auctions[i]
				local unit = a.b / a.c
				if unit >= value then break end
				units = units + a.c
				cash = cash + a.b
				profit = profit + value * a.c - a.b
				tinsert(picks, {c = a.c, b = a.b})
				max_unit = unit
			end
			if units > 0 and profit >= (settings.min_profit or 1) then
				tinsert(rows, {
					id = id,
					name = item_name(id),
					units = units,
					cash = cash,
					profit = profit,
					value = value,
					picks = picks,
					max_unit = max_unit,
				})
			end
		end
	end
	sort(rows, function(x, y)
		if x.profit ~= y.profit then return x.profit > y.profit end
		return x.name < y.name
	end)
	return rows
end

function flip_to_plan(row)
	return {
		name = row.name,
		product = row.id,
		crafts = 1,
		yield = 1,
		value = row.value,
		verified = true,
		revenue = row.units * row.value,
		cash = row.cash,
		ah_cash = row.cash,
		profit = row.profit,
		leftover = 0,
		flip = true,
		recipe = {product = row.id, reagents = EMPTY, made = 1},
		reagents = {{
			id = row.id,
			name = row.name,
			q = 1,
			need = row.units,
			owned = 0,
			reused = 0,
			vendor = 0,
			leftover = 0,
			spare = 0,
			salvage = row.value,
			picks = row.picks,
			ah_units = row.units,
			ah_cash = row.cash,
			max_unit = row.max_unit,
		}},
		steps = EMPTY,
	}
end

function update_flip_results()
	if not flip_listing then return end
	flip_rows = compute_flips()
	local data, selection = {}, nil
	for i = 1, getn(flip_rows) do
		local row = flip_rows[i]
		if selected_flip and selected_flip.id == row.id then selection = row end
		local each = row.units > 0 and (row.cash / row.units) or 0
		tinsert(data, {
			cols = {
				{value = colored_item_name(row.id, row.name)},
				{value = tostring(row.units)},
				{value = money_text(each)},
				{value = money_text(row.value)},
				{value = money_text(row.profit, aux.color.green)},
				{value = money_text(row.profit / row.units)},
			},
			row = row,
		})
	end
	selected_flip = selection or flip_rows[1]
	flip_listing:SetData(data)
	if flip_status then
		if getn(flip_rows) == 0 then
			flip_status:SetText(book_meta and book_meta.scanned and 'No auctions cheaper than vendor in this scan.' or 'Scan the auction house on the Vendor tab first.')
		else
			local profit = 0
			for i = 1, getn(flip_rows) do
				profit = profit + flip_rows[i].profit
			end
			flip_status:SetText(format('%d items below vendor: profit %s if you buy them all and vendor them.', getn(flip_rows), money_text(profit)))
		end
	end
end

function refresh_flip_controls()
	if not flip_buy then return end
	local can = not scanning and not buying and selected_flip
	if can then flip_buy:Enable() else flip_buy:Disable() end
	if not scanning and not buying and flip_rows and getn(flip_rows) > 0 then
		flip_buy_all:Enable()
	else
		flip_buy_all:Disable()
	end
end

function aux.handle.INIT_UI()
	flip_frame = CreateFrame('Frame', nil, aux.frame)
	flip_frame:SetAllPoints()
	flip_frame:Hide()
	flip_frame:SetScript('OnUpdate', function()
		if flip_dirty then
			flip_dirty = false
			update_flip_results()
		end
		refresh_flip_controls()
	end)

	local content = CreateFrame('Frame', nil, flip_frame)
	content:SetPoint('TOP', flip_frame, 'TOP', 0, -8)
	content:SetPoint('BOTTOMLEFT', aux.frame.content, 'BOTTOMLEFT', 0, 0)
	content:SetPoint('BOTTOMRIGHT', aux.frame.content, 'BOTTOMRIGHT', 0, 0)

	local top = gui.panel(content)
	top:SetPoint('TOPLEFT', 0, 0)
	top:SetPoint('TOPRIGHT', 0, 0)
	top:SetHeight(40)

	local hint = gui.label(top, gui.font_size.small)
	hint:SetPoint('LEFT', 8, 0)
	hint:SetPoint('RIGHT', -8, 0)
	hint:SetJustifyH('LEFT')
	hint:SetText('Same scan as Vendor. Lists auctions cheaper than a vendor will pay. Buy, then sell to an NPC.')

	local body = gui.panel(content)
	body:SetPoint('TOPLEFT', top, 'BOTTOMLEFT', 0, -2.5)
	body:SetPoint('BOTTOMRIGHT', 0, 0)

	flip_listing = listing.new(body)
	flip_listing:SetColInfo(FLIP_COLUMNS)
	flip_listing:SetSelection(function(data) return data.row == selected_flip end)
	flip_listing:SetHandler('OnClick', function(st, data)
		selected_flip = data.row
		flip_listing:Update()
	end)
	flip_listing:SetHandler('OnEnter', function(st, data, row)
		item_tooltip(data.row.id, data.row.name, row)
		add_line('AH each', money_text(data.row.cash / data.row.units))
		add_line('Vendor pays', money_text(data.row.value) .. ' each')
		add_line('Profit', money_text(data.row.profit, aux.color.green))
		GameTooltip:Show()
	end)
	flip_listing:SetHandler('OnLeave', function() GameTooltip:Hide() end)

	flip_status = gui.label(flip_frame, gui.font_size.small)
	flip_status:SetPoint('TOPLEFT', aux.frame.content, 'BOTTOMLEFT', 0, -8)
	flip_status:SetWidth(250)
	flip_status:SetJustifyH('LEFT')
	flip_status:SetText('')

	flip_buy = gui.button(flip_frame)
	flip_buy:SetPoint('TOPLEFT', aux.frame.content, 'BOTTOMLEFT', 255, -6)
	gui.set_size(flip_buy, 95, 24)
	flip_buy:SetText('Buy selected')
	flip_buy:SetScript('OnClick', function()
		if selected_flip then request_buy({flip_to_plan(selected_flip)}) end
	end)

	flip_buy_all = gui.button(flip_frame)
	flip_buy_all:SetPoint('TOPLEFT', flip_buy, 'TOPRIGHT', 5, 0)
	gui.set_size(flip_buy_all, 65, 24)
	flip_buy_all:SetText('Buy all')
	flip_buy_all:SetScript('OnClick', function()
		local plans = {}
		for i = 1, getn(flip_rows or EMPTY) do
			tinsert(plans, flip_to_plan(flip_rows[i]))
		end
		request_buy(plans)
	end)
end
