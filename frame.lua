module 'aux.tabs.vendorcraft'

local aux = require 'aux'
local gui = require 'aux.gui'
local listing = require 'aux.gui.listing'
local money = require 'aux.util.money'
local info = require 'aux.util.info'

local tab = aux.tab 'Vendor'

SKILL_COLORS = {
	optimal = {'orange', 1, .5, .25},
	medium = {'yellow', 1, 1, 0},
	easy = {'green', .25, .75, .25},
	trivial = {'gray', .5, .5, .5},
}

function tab.OPEN()
	frame:Show()
	load_book()
	if plan_stale or not results then
		request_plan()
	end
	results_dirty, status_dirty = true, true
	refresh_controls()
end

function tab.CLOSE()
	frame:Hide()
end

function colored_item_name(id, fallback)
	local name = item_name(id, fallback)
	local _, _, _, hex = GetItemQualityColor(item_quality(id))
	return (hex or '') .. name .. FONT_COLOR_CODE_CLOSE
end

function gray(text)
	return aux.color.gray(text)
end

function count_text(n, color)
	if not n or n == 0 then return gray('-') end
	return color and color(n) or tostring(n)
end

view = 'mine'
selections = {}

MINE_COLUMNS = {
	{name = 'Craft', width = .31, align = 'LEFT'},
	{name = 'Crafts', width = .07, align = 'CENTER'},
	{name = 'Mat cost', width = .14, align = 'RIGHT'},
	{name = 'Vendor', width = .14, align = 'RIGHT'},
	{name = 'Profit', width = .14, align = 'RIGHT'},
	{name = 'Per craft', width = .12, align = 'RIGHT'},
	{name = 'Spare', width = .08, align = 'CENTER'},
}

OTHER_COLUMNS = {
	{name = 'Recipe you do not know', width = .27, align = 'LEFT'},
	{name = 'Profession', width = .17, align = 'LEFT'},
	{name = 'Crafts', width = .07, align = 'CENTER'},
	{name = 'Mat cost', width = .13, align = 'RIGHT'},
	{name = 'Vendor', width = .12, align = 'RIGHT'},
	{name = 'Profit', width = .13, align = 'RIGHT'},
	{name = 'Per craft', width = .11, align = 'RIGHT'},
}

function current_results()
	if view == 'other' then return other_results end
	return results
end

function current_supply()
	if view == 'other' then return other_supply end
	return last_supply
end

-- Green: you can learn it now; yellow: your skill is too low; gray: you
-- do not have the profession.
function profession_text(plan)
	local recipe = plan.recipe
	if not recipe.prof then return gray('?') end
	local text = recipe.prof .. (recipe.skill and (' ' .. recipe.skill) or '')
	local status = learn_status(plan)
	if status == 'ready' then return aux.color.green(text) end
	if status == 'low' then return aux.color.yellow(text) end
	return gray(text)
end

function plan_row(plan)
	local name = colored_item_name(plan.product, plan.name) .. (plan.yield > 1 and gray(' x' .. plan.yield) or '')
	local crafts = plan.unlimited and (plan.crafts .. '+') or tostring(plan.crafts)
	local vendor = money_text(plan.revenue) .. (plan.verified and '' or gray('*'))
	local profit = money_text(plan.profit, aux.color.green)
	local per_craft = money_text(plan.profit / plan.crafts)
	if view == 'other' then
		return {name, profession_text(plan), crafts, money_text(plan.cash), vendor, profit, per_craft}
	end
	return {name, crafts, money_text(plan.cash), vendor, profit, per_craft, count_text(plan.leftover, aux.color.orange)}
end

function update_results()
	local rows, selection, list = {}, nil, current_results()
	for _, plan in list or EMPTY do
		if selected_plan and plan.name == selected_plan.name then selection = plan end
		local cols = {}
		for _, text in plan_row(plan) do
			tinsert(cols, {value = text})
		end
		tinsert(rows, {cols = cols, plan = plan})
	end
	selected_plan = selection or list and list[1]
	results_listing:SetData(rows)
	update_details()
	show_craft_box()
end

function switch_view()
	selections[view] = selected_plan
	if view == 'mine' then view = 'other' else view = 'mine' end
	selected_plan = selections[view]
	results_listing:SetColInfo(view == 'other' and OTHER_COLUMNS or MINE_COLUMNS)
	view_button:SetText(view == 'other' and 'My recipes' or 'Other recipes')
	results_dirty = true
	if not busy() and view_summary() then
		set_status(1, view_summary())
	end
	if view == 'other' and (unpriced_other or 0) > 0 and not unpriced_hint_shown then
		unpriced_hint_shown = true
		say(format('%d recipes you do not know could not be rated because no vendor price is known for what they make (the price tables predate newer Turtle items such as Survival). /vcraft unpriced lists them; /vcraft price sets a price.', unpriced_other))
	end
	refresh_controls()
end

-- Units crafted and batches, yellow when the recipe for that step is not known.
function craft_text(reagent)
	local craft = reagent.craft
	if not craft then return gray('-') end
	local text = format('%d (%dx)', craft.units, craft.crafts)
	if not craft.known then return aux.color.yellow(text) end
	return text
end

function update_details()
	local rows = {}
	local plan = selected_plan
	local sup = current_supply()
	each_node(plan and plan.reagents or EMPTY, function(reagent, depth)
		local alts = 0
		for _, n in sup and sup.alts[reagent.id] or EMPTY do
			alts = alts + n
		end
		local indent = depth > 0 and (strrep('   ', depth) .. gray('> ')) or ''
		tinsert(rows, {
			cols = {
				{value = indent .. colored_item_name(reagent.id, reagent.name) .. gray(' x' .. reagent.q)},
				{value = tostring(reagent.need)},
				{value = count_text(reagent.owned + (reagent.reused or 0))},
				{value = reagent.ah_units > 0 and format('AH %d (%s)', reagent.ah_units, money_text(reagent.ah_cash)) or gray('-')},
				{value = reagent.vendor > 0 and format('Vendor %d (%s)', reagent.vendor, money_text(reagent.vendor * (reagent.vendor_price or 0))) or gray('-')},
				{value = craft_text(reagent)},
				{value = count_text(reagent.spare, aux.color.orange)},
				{value = count_text(alts)},
			},
			reagent = reagent,
		})
	end)
	details_listing:SetData(rows)
	if vendor_hint then
		vendor_hint:SetText(vendor_hint_text(plan))
	end
end

function vendor_hint_text(plan)
	if not plan then return '' end
	local lines = vendor_lines(plan_vendor(plan))
	if getn(lines) == 0 then return '' end
	return 'Buy from a vendor: ' .. table.concat(lines, '; ')
end

function show_craft_box()
	if not craft_box or craft_box.focused then return end
	craft_box_updating = true
	if selected_plan then
		craft_box:SetText(tostring(selected_plan.crafts))
		if craft_max_label then
			craft_max_label:SetText('/ ' .. (selected_plan.natural_crafts or selected_plan.crafts))
		end
	else
		craft_box:SetText('')
		if craft_max_label then craft_max_label:SetText('') end
	end
	craft_box_updating = false
end

function apply_craft_box()
	if craft_box_updating or not selected_plan then return end
	local text = craft_box:GetText() or ''
	local n = tonumber(text)
	if text == '' or n == 0 then n = nil end
	set_craft_count(selected_plan.name, n)
	show_craft_box()
end

function add_line(left, right, r, g, b)
	if right then
		GameTooltip:AddDoubleLine(left, right, 1, .82, 0, 1, 1, 1)
	else
		GameTooltip:AddLine(left, r or 1, g or 1, b or 1, 1)
	end
end

function add_ah_scan_lines(id)
	load_book()
	local list = book_listing(id)
	local meta = book_meta or EMPTY
	if not meta.scanned then
		add_line('AH last scan', 'no scan yet')
		return
	end
	if getn(list) == 0 then
		add_line('AH last scan (' .. format_age(meta.scanned) .. ')', 'none listed')
		return
	end
	local units, levels, seen = 0, {}, {}
	for i = 1, getn(list) do
		units = units + list[i].c
		local unit = list[i].b / list[i].c
		local key = tostring(floor(unit + .5))
		if not seen[key] then
			seen[key] = true
			tinsert(levels, unit)
		end
	end
	add_line('AH last scan (' .. format_age(meta.scanned) .. ')', format('%s each, %d listed', money_text(levels[1]), units))
	for i = 2, min(getn(levels), 5) do
		add_line('   also', money_text(levels[i]) .. ' each', .8, .8, .8)
	end
end

function item_tooltip(id, fallback, owner)
	GameTooltip:SetOwner(owner, 'ANCHOR_RIGHT')
	if info.item(id) and GetItemInfo('item:' .. id) then
		GameTooltip:SetHyperlink('item:' .. id .. ':0:0:0')
	else
		GameTooltip:AddLine(item_name(id, fallback), 1, 1, 1)
	end
	GameTooltip:AddLine(' ')
	add_ah_scan_lines(id)
end

function show_plan_tooltip(plan, owner)
	local recipe = plan.recipe
	item_tooltip(plan.product, plan.name, owner)
	if plan.discovered then
		local status, rank = learn_status(plan)
		local needs = (recipe.prof or 'Unknown profession') .. (recipe.skill and (' ' .. recipe.skill) or '')
		if status == 'ready' then
			add_line(needs, aux.color.green('you can learn it (you have ' .. rank .. ')'))
		elseif status == 'low' then
			add_line(needs, aux.color.yellow('your skill is ' .. rank))
		else
			add_line(needs, gray('you do not have ' .. (recipe.prof or 'it')))
		end
		if plan.alt then
			add_line('Your alt ' .. plan.alt .. ' knows this recipe.', nil, .5, 1, .5)
		end
	else
		local skill = SKILL_COLORS[recipe.color or '']
		if skill then
			add_line(recipe.prof or '?', skill[1] .. ' recipe', skill[2], skill[3], skill[4])
		else
			add_line(recipe.prof or '?')
		end
	end
	add_line('Crafts', format('%d x %d = %d items', plan.crafts, plan.yield, plan.crafts * plan.yield))
	add_line('Vendor pays', money_text(plan.value) .. ' each' .. (plan.verified and '' or ' *'))
	add_line('Vendor total', money_text(plan.revenue))
	each_node(plan.reagents, function(reagent, depth)
		local parts = {}
		if reagent.ah_units > 0 then
			tinsert(parts, format('AH %d (%s)', reagent.ah_units, money_text(reagent.ah_cash)))
		end
		if reagent.vendor > 0 then
			tinsert(parts, format('Vendor %d (%s)', reagent.vendor, money_text(reagent.vendor * (reagent.vendor_price or 0))))
		end
		if getn(parts) > 0 then
			local indent = depth > 0 and strrep('  ', depth) or ''
			add_line(indent .. item_name(reagent.id, reagent.name), table.concat(parts, ', '))
		end
	end)
	local buy_lines = vendor_lines(plan_vendor(plan))
	for i = 1, getn(buy_lines) do
		add_line('Buy from a vendor: ' .. buy_lines[i])
	end
	if plan.user_limited then
		add_line(format('Craft count set to %d (automatic best is %d).', plan.crafts, plan.natural_crafts or plan.crafts), nil, .7, .7, .7)
	end
	local owned_value, spare_value = 0, 0
	each_node(plan.reagents, function(reagent)
		owned_value = owned_value + reagent.owned * reagent.salvage
		spare_value = spare_value + reagent.spare * reagent.salvage
	end)
	if owned_value > 0 then add_line('Your own mats (at vendor value)', money_text(owned_value)) end
	if spare_value > 0 then add_line('Spare mats (vendor value, credited)', money_text(spare_value)) end
	add_line('Profit', money_text(plan.profit, aux.color.green))
	if getn(plan.steps or EMPTY) > 0 then
		add_line(' ')
		add_line('Crafting steps:', nil, .7, .7, .7)
		for _, step in craft_steps(plan) do
			local learn = step.known == false and aux.color.yellow(' (recipe not known)') or ''
			add_line('   ' .. step.n .. ' x ' .. step.name .. learn, nil, .9, .9, .9)
		end
	end
	if plan.unlimited then
		add_line('All mats come from vendors, so this is capped by your max crafts setting and gold.', nil, .7, .7, .7)
	elseif plan.next_delta then
		add_line('One more craft would change profit by ' .. money_text(plan.next_delta) .. '.', nil, .7, .7, .7)
	end
	if recipe.tools then add_line('Requires: ' .. recipe.tools, nil, .7, .7, .7) end
	if not plan.verified then
		add_line('* Vendor price comes from a database. Open a merchant with the item in your bags to confirm it.', nil, .7, .7, .7)
	end
	if plan.discovered then
		add_line('Counts the auction house and vendors only, not your own mats or gold.', nil, .7, .7, .7)
	end
	GameTooltip:Show()
end

function show_reagent_tooltip(reagent, owner)
	item_tooltip(reagent.id, reagent.name, owner)
	add_line('Needed', format('%d (%d per craft)', reagent.need, reagent.q))
	if reagent.owned > 0 then
		local sup = current_supply() or EMPTY
		local mine, mail = (sup.mine or EMPTY)[reagent.id] or 0, (sup.mail or EMPTY)[reagent.id] or 0
		add_line('From your mats', format('%d (bags/bank %d, mail %d)', reagent.owned, mine, mail))
	end
	if (reagent.reused or 0) > 0 then
		add_line('Spare from another step', format('%d (bought for another line of this plan)', reagent.reused))
	end
	if reagent.ah_units > 0 then
		add_line('AH', format('%d (%s)', reagent.ah_units, money_text(reagent.ah_cash)))
		local stacks = {}
		for _, auction in reagent.picks do
			local key = auction.c .. ' at ' .. money_text(auction.b / auction.c)
			if not stacks[key] then
				stacks[key] = {count = 0, unit = auction.b / auction.c, c = auction.c}
			end
			stacks[key].count = stacks[key].count + 1
		end
		local sorted = {}
		for key, s in stacks do
			tinsert(sorted, {key = key, s = s})
		end
		sort(sorted, function(x, y) return x.s.unit < y.s.unit end)
		for i = 1, min(getn(sorted), 10) do
			local s = sorted[i].s
			add_line(format('   %d x stack of %s each', s.count, sorted[i].key), nil, .8, .8, .8)
		end
		if getn(sorted) > 10 then add_line('   ...', nil, .8, .8, .8) end
	end
	if reagent.vendor > 0 then
		add_line('Vendor', format('%d (%s)', reagent.vendor, money_text(reagent.vendor * (reagent.vendor_price or 0))))
	end
	local craft = reagent.craft
	if craft then
		add_line('Crafted', format('%d from %d x %s', craft.units, craft.crafts, craft.name))
		if craft.known then
			add_line('You know this recipe.', nil, .5, 1, .5)
		else
			local needs = craft.prof and (craft.prof .. (craft.skill and (' ' .. craft.skill) or '')) or 'a recipe you do not know'
			add_line('Needs ' .. needs .. ' to craft.', nil, 1, 1, 0)
		end
		add_line(format('Total cost of this reagent, crafting included: %s', money_text(reagent.net)), nil, .8, .8, .8)
	end
	if reagent.spare > 0 then
		add_line('Spare after crafting', format('%d (vendor pays %s each)', reagent.spare, money_text(reagent.salvage)))
	end
	local sup = current_supply()
	local alts = sup and sup.alts[reagent.id]
	if alts then
		add_line(' ')
		add_line('On your alts (Bagshui):', nil, .7, .7, .7)
		for name, n in alts do
			add_line('   ' .. name, tostring(n))
		end
	end
	GameTooltip:Show()
end

function scan_summary()
	if scanning then
		return 'Scanning...', ''
	end
	local meta = book_meta or EMPTY
	if not meta.scanned then
		return 'No scan yet', 'Press Scan AH'
	end
	local line2 = format('%d auctions', meta.auctions or 0)
	if meta.partial then
		line2 = format('partial: page %d / %d', (meta.next_page or 0) + 1, meta.total_pages or 0)
	end
	return 'Scanned ' .. format_age(meta.scanned), line2
end

function refresh_controls()
	local is_busy = busy()
	scan_button:Enable()
	if is_busy then refresh_button:Disable() else refresh_button:Enable() end
	if scanning or buying then
		stop_button:Show()
		resume_button:Hide()
	else
		stop_button:Hide()
		if book_meta and book_meta.partial and book_meta.next_page then
			resume_button:Show()
		else
			resume_button:Hide()
		end
	end
	-- Recipe scoring must not lock Buy or the craft-count box.
	local can_buy = view == 'mine' and not scanning and not buying
	if can_buy and selected_plan then buy_button:Enable() else buy_button:Disable() end
	if can_buy and results and getn(results) > 0 then buy_all_button:Enable() else buy_all_button:Disable() end
	if craft_box then craft_box:Enable() end
	local line1, line2 = scan_summary()
	scan_label:SetText(line1 .. '\n' .. gray(line2))
end

do
	local next_refresh = 0
	function on_update()
		if status_dirty then
			status_dirty = false
			status_bar:update_status(status_value or 1, status_value or 1)
			status_bar:set_text(status_text or '')
		end
		if results_dirty then
			results_dirty = false
			update_results()
		end
		-- A stale plan starts on its own. This path does not reset the item
		-- loader's one-follow-up budget; Refresh and other user actions do.
		if plan_stale and not busy() then
			plan_stale = false
			plan_requested = true
		end
		if GetTime() >= next_refresh then
			next_refresh = GetTime() + .25
			refresh_controls()
		end
	end
end

function money_box(parent, key, label_text)
	local box = gui.editbox(parent)
	gui.set_size(box, 60, 22)
	box:SetAlignment('RIGHT')
	box.formatter = function(text)
		local value = money.from_string(text)
		return value and money.to_string(value, nil, true) or text
	end
	local function show()
		box:SetText(money.to_string(settings[key], nil, true, nil, true))
	end
	box.enter = function() box:ClearFocus() end
	box.focus_loss = function()
		local value = money.from_string(box:GetText())
		if value and floor(value) ~= settings[key] then
			settings[key] = floor(value)
			request_plan()
		end
		show()
	end
	local label = gui.label(parent, gui.font_size.small)
	label:SetPoint('RIGHT', box, 'LEFT', -4, 0)
	label:SetText(label_text)
	box.label = label
	box.show = show
	return box
end

function aux.handle.INIT_UI()
	local pad = gui.is_blizzard() and 6.5 or 2.5

	frame = CreateFrame('Frame', nil, aux.frame)
	frame:SetAllPoints()
	frame:SetScript('OnUpdate', on_update)
	frame:Hide()

	frame.content = CreateFrame('Frame', nil, frame)
	frame.content:SetPoint('TOP', frame, 'TOP', 0, -8)
	frame.content:SetPoint('BOTTOMLEFT', aux.frame.content, 'BOTTOMLEFT', 0, 0)
	frame.content:SetPoint('BOTTOMRIGHT', aux.frame.content, 'BOTTOMRIGHT', 0, 0)

	-- aux's window is a fixed 768x447; this is the height between the tab
	-- strip and the bottom button row. Listings size their rows from it.
	local content_height = 447 - 8 - 35
	local top_height, results_height = 40, 222

	local top = gui.panel(frame.content)
	top:SetPoint('TOPLEFT', 0, 0)
	top:SetPoint('TOPRIGHT', 0, 0)
	top:SetHeight(top_height)

	local results_panel = gui.panel(frame.content)
	results_panel:SetPoint('TOPLEFT', top, 'BOTTOMLEFT', 0, -pad)
	results_panel:SetPoint('TOPRIGHT', top, 'BOTTOMRIGHT', 0, -pad)
	results_panel:SetHeight(results_height)

	local details_panel = gui.panel(frame.content)
	details_panel:SetPoint('TOPLEFT', results_panel, 'BOTTOMLEFT', 0, -pad)
	details_panel:SetPoint('TOPRIGHT', results_panel, 'BOTTOMRIGHT', 0, -pad)
	details_panel:SetHeight(content_height - top_height - results_height - 2 * pad)

	do
		local btn = gui.button(top)
		btn:SetPoint('LEFT', 8, 0)
		gui.set_size(btn, 90, 24)
		btn:SetText('Scan AH')
		btn:SetScript('OnClick', function() start_scan(false) end)
		scan_button = btn
	end
	do
		local btn = gui.button(top)
		btn:SetPoint('LEFT', scan_button, 'RIGHT', 5, 0)
		gui.set_size(btn, 80, 24)
		btn:SetText('Resume')
		btn:SetScript('OnClick', function() start_scan(true) end)
		btn:Hide()
		resume_button = btn
	end
	do
		local btn = gui.button(top)
		btn:SetPoint('LEFT', scan_button, 'RIGHT', 5, 0)
		gui.set_size(btn, 80, 24)
		btn:SetText('Stop')
		btn:SetScript('OnClick', function()
			if buying then stop_buying() else stop_scan() end
		end)
		btn:Hide()
		stop_button = btn
	end
	do
		local label = gui.label(top, gui.font_size.small)
		label:SetPoint('LEFT', scan_button, 'RIGHT', 95, 0)
		label:SetWidth(190)
		label:SetJustifyH('LEFT')
		scan_label = label
	end

	do
		local label = gui.label(top, gui.font_size.small)
		label:SetPoint('RIGHT', -8, 0)
		label:SetText('Use my mats')
		local checkbox = gui.checkbox(top)
		checkbox:SetPoint('RIGHT', label, 'LEFT', -2, 0)
		checkbox:SetScript('OnClick', function()
			settings.use_owned = this:GetChecked() and true or false
			request_plan()
		end)
		owned_checkbox = checkbox
	end
	reserve_box = money_box(top, 'gold_reserve', 'Keep')
	reserve_box:SetPoint('RIGHT', owned_checkbox, 'LEFT', -10, 0)
	min_profit_box = money_box(top, 'min_profit', 'Min profit')
	min_profit_box:SetPoint('RIGHT', reserve_box.label, 'LEFT', -10, 0)

	results_listing = listing.new(results_panel)
	results_listing:SetColInfo(MINE_COLUMNS)
	results_listing:SetSelection(function(data) return data.plan == selected_plan end)
	results_listing:SetHandler('OnClick', function(st, data)
		selected_plan = data.plan
		results_listing:Update()
		update_details()
		show_craft_box()
	end)
	results_listing:SetHandler('OnEnter', function(st, data, row) show_plan_tooltip(data.plan, row) end)
	results_listing:SetHandler('OnLeave', function() GameTooltip:Hide() end)

	local details_head = CreateFrame('Frame', nil, details_panel)
	details_head:SetPoint('TOPLEFT', 4, -2)
	details_head:SetPoint('TOPRIGHT', -4, -2)
	details_head:SetHeight(24)

	local details_foot = CreateFrame('Frame', nil, details_panel)
	details_foot:SetPoint('BOTTOMLEFT', 4, 2)
	details_foot:SetPoint('BOTTOMRIGHT', -4, 2)
	details_foot:SetHeight(16)

	local details_body = CreateFrame('Frame', nil, details_panel)
	details_body:SetPoint('TOPLEFT', details_head, 'BOTTOMLEFT', -4, -2)
	details_body:SetPoint('BOTTOMRIGHT', details_foot, 'TOPRIGHT', 4, 2)

	craft_box = gui.editbox(details_head)
	gui.set_size(craft_box, 52, 22)
	craft_box:SetPoint('LEFT', 48, 0)
	craft_box:SetAlignment('RIGHT')
	craft_box:SetNumeric(true)
	craft_box:EnableMouse(true)
	craft_box:SetFrameLevel((details_head:GetFrameLevel() or 1) + 8)
	craft_box.enter = function() craft_box:ClearFocus() end
	craft_box.focus_loss = function() apply_craft_box() end
	local craft_label = gui.label(details_head, gui.font_size.small)
	craft_label:SetPoint('RIGHT', craft_box, 'LEFT', -4, 0)
	craft_label:SetText('Craft')
	craft_max_label = gui.label(details_head, gui.font_size.small)
	craft_max_label:SetPoint('LEFT', craft_box, 'RIGHT', 4, 0)
	craft_max_label:SetText('')

	vendor_hint = gui.label(details_foot, gui.font_size.small)
	vendor_hint:SetPoint('LEFT', 4, 0)
	vendor_hint:SetPoint('RIGHT', -4, 0)
	vendor_hint:SetJustifyH('LEFT')
	vendor_hint:SetText('')

	details_listing = listing.new(details_body)
	details_listing:SetColInfo{
		{name = 'Reagent', width = .26, align = 'LEFT'},
		{name = 'Need', width = .06, align = 'CENTER'},
		{name = 'Have', width = .06, align = 'CENTER'},
		{name = 'AH', width = .18, align = 'CENTER'},
		{name = 'Vendor', width = .18, align = 'CENTER'},
		{name = 'Craft', width = .10, align = 'CENTER'},
		{name = 'Spare', width = .07, align = 'CENTER'},
		{name = 'Alts', width = .09, align = 'CENTER'},
	}
	details_listing:SetHandler('OnEnter', function(st, data, row) show_reagent_tooltip(data.reagent, row) end)
	details_listing:SetHandler('OnLeave', function() GameTooltip:Hide() end)

	-- The bottom row must end before aux's own Blizzard UI and Close buttons
	-- (about 150px from the right edge).
	do
		status_bar = gui.status_bar(frame)
		status_bar:SetWidth(250)
		status_bar:SetHeight(25)
		status_bar:SetPoint('TOPLEFT', aux.frame.content, 'BOTTOMLEFT', 0, -6)
		status_bar:update_status(1, 1)
		status_bar:set_text('')
	end
	do
		local btn = gui.button(frame)
		btn:SetPoint('TOPLEFT', status_bar, 'TOPRIGHT', 5, 0)
		gui.set_size(btn, 95, 24)
		btn:SetText('Buy selected')
		btn:SetScript('OnClick', function()
			apply_craft_box()
			if selected_plan then request_buy({selected_plan}) end
		end)
		buy_button = btn
	end
	do
		local btn = gui.button(frame)
		btn:SetPoint('TOPLEFT', buy_button, 'TOPRIGHT', 5, 0)
		gui.set_size(btn, 65, 24)
		btn:SetText('Buy all')
		btn:SetScript('OnClick', function() request_buy(results) end)
		buy_all_button = btn
	end
	do
		local btn = gui.button(frame)
		btn:SetPoint('TOPLEFT', buy_all_button, 'TOPRIGHT', 5, 0)
		gui.set_size(btn, 65, 24)
		btn:SetText('Refresh')
		btn:SetScript('OnClick', function() request_plan() end)
		refresh_button = btn
	end
	do
		local btn = gui.button(frame)
		btn:SetPoint('TOPLEFT', refresh_button, 'TOPRIGHT', 5, 0)
		gui.set_size(btn, 110, 24)
		btn:SetText('Other recipes')
		btn:SetScript('OnClick', switch_view)
		view_button = btn
	end
end

function aux.handle.LOAD()
	owned_checkbox:SetChecked(settings.use_owned and 1 or nil)
	reserve_box.show()
	min_profit_box.show()
end
