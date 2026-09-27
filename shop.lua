module 'aux.tabs.vendorcraft'

local aux = require 'aux'
local gui = require 'aux.gui'
local listing = require 'aux.gui.listing'

local tab = aux.tab 'Mats'

MATCH_COLUMNS = {
	{name = 'Name', width = .34, align = 'LEFT'},
	{name = 'Type', width = .10, align = 'LEFT'},
	{name = 'Vendor', width = .18, align = 'RIGHT'},
	{name = 'Mats', width = .20, align = 'RIGHT'},
	{name = 'Spread', width = .18, align = 'RIGHT'},
}

NEED_COLUMNS = {
	{name = 'Reagent', width = .34, align = 'LEFT'},
	{name = 'Need', width = .08, align = 'CENTER'},
	{name = 'Have', width = .08, align = 'CENTER'},
	{name = 'Missing', width = .10, align = 'CENTER'},
	{name = 'AH', width = .20, align = 'CENTER'},
	{name = 'Alts', width = .20, align = 'LEFT'},
}

function tab.OPEN()
	if shop_frame then shop_frame:Show() end
	refresh_shop_controls()
end

function tab.CLOSE()
	if shop_frame then shop_frame:Hide() end
end

function tab.CLICK_LINK(item_info)
	if shop_name_box and item_info and item_info.name then
		shop_name_box:SetText(item_info.name)
		run_shop_search()
	end
end

function shop_qty()
	local n = shop_qty_box and tonumber(shop_qty_box:GetText())
	if not n or n < 1 then return 1 end
	return floor(n)
end

function find_shop_targets(text)
	local q = strlower(text or '')
	q = gsub(q, '^%s+', '')
	q = gsub(q, '%s+$', '')
	if q == '' then return {} end
	local hits, seen = {}, {}
	local function add(kind, name, recipe, id)
		local key = kind .. ':' .. (id or name)
		if seen[key] then return end
		seen[key] = true
		tinsert(hits, {kind = kind, name = name, recipe = recipe, id = id})
	end
	local exact = cached_item_id(q)
	if exact then
		add('item', item_name(exact, text), nil, exact)
	end
	for name, recipe in character.recipes or EMPTY do
		if strfind(strlower(name), q, 1, true) then
			add('recipe', name, recipe, recipe.product)
		end
	end
	local atlas = atlas_recipe_list()
	if atlas then
		for _, recipe in atlas do
			if recipe.name and strfind(strlower(recipe.name), q, 1, true) then
				add('recipe', recipe.name, recipe, recipe.product)
			end
		end
	end
	load_book()
	for id in book_items or EMPTY do
		local n = item_name(id)
		if n and not strfind(n, '^item:') and strfind(strlower(n), q, 1, true) then
			add('item', n, nil, id)
		end
	end
	sort(hits, function(a, b)
		local ae, be = strlower(a.name) == q, strlower(b.name) == q
		if ae ~= be then return ae end
		if a.kind ~= b.kind then return a.kind == 'recipe' end
		return a.name < b.name
	end)
	return hits
end

function alt_text(id)
	local _, alts = owned_snapshot()
	local parts = {}
	for name, n in alts[id] or EMPTY do
		tinsert(parts, name .. ' ' .. n)
	end
	sort(parts)
	if getn(parts) == 0 then return gray('-') end
	return table.concat(parts, ', ')
end

-- AH + unlimited-vendor cost of `count` units from the last scan.
-- Fourth return is false when the scan cannot cover that many.
function shop_buy_cost(id, count)
	if not count or count < 1 then return 0, 0, 0, true end
	local list = book_listing(id)
	local copy = {}
	for i = 1, getn(list) do
		copy[i] = {c = list[i].c, b = list[i].b}
	end
	local ctx = make_ctx(id, 1, 0, copy, nil)
	local _, spent, chosen, _, vendor = cover(ctx, count, true)
	if not chosen then return nil, nil, 0, false end
	local vendor_cash = (vendor or 0) * (ctx.u or 0)
	return (spent or 0) + vendor_cash, spent or 0, vendor or 0, true
end

function shop_product(target, qty)
	qty = qty or 1
	local product = target.id
	local yield = 1
	if target.recipe then
		product = target.recipe.product or target.id
		yield = target.recipe.made or 1
	end
	local units = target.kind == 'item' and qty or qty * yield
	if not product then
		return nil, units, 0, nil, nil
	end
	local value, verified, source = vendor_sell(product)
	return product, units, value or 0, verified, source
end

function shop_quote(target, qty, bag)
	qty = qty or 1
	local mine, mail
	if bag then
		mine, mail = bag.mine, bag.mail
	else
		mine = owned_snapshot()
		mail = mail_counts()
	end
	local needs = build_shop_needs(target, qty)
	local all_cost, missing_cost, all_known, miss_known = 0, 0, true, true
	for i = 1, getn(needs) do
		local need = needs[i]
		local have = (mine[need.id] or 0) + (mail[need.id] or 0)
		local missing = max(0, need.count - have)
		local full, _, _, ok = shop_buy_cost(need.id, need.count)
		if ok and full then
			all_cost = all_cost + full
		else
			all_known = false
		end
		if missing > 0 then
			local miss, _, _, mok = shop_buy_cost(need.id, missing)
			if mok and miss then
				missing_cost = missing_cost + miss
			else
				miss_known = false
			end
		end
	end
	local product, units, value, verified, source = shop_product(target, qty)
	local revenue = value * units
	return {
		product = product,
		units = units,
		value = value,
		verified = verified,
		source = source,
		revenue = revenue,
		all_cost = all_cost,
		missing_cost = missing_cost,
		all_known = all_known,
		miss_known = miss_known,
		profit = value > 0 and all_known and (revenue - all_cost) or nil,
	}
end

function format_shop_quote(quote)
	if not quote then return '' end
	local vendor
	if quote.value > 0 then
		vendor = format('Vendor %s each (%s for %d)%s', money_text(quote.value), money_text(quote.revenue), quote.units, quote.verified and '' or '*')
	else
		vendor = 'No vendor price'
	end
	local mats
	if quote.all_known then
		mats = 'Mats ' .. money_text(quote.all_cost)
		if quote.missing_cost > 0 and quote.missing_cost ~= quote.all_cost then
			mats = mats .. ' (missing ' .. money_text(quote.missing_cost) .. ')'
		elseif quote.missing_cost == 0 and quote.all_cost > 0 then
			mats = mats .. ' (you have them)'
		end
	elseif quote.miss_known and quote.missing_cost > 0 then
		mats = 'Missing mats ' .. money_text(quote.missing_cost) .. ' (some unpriced)'
	else
		mats = 'Mats unknown — scan AH'
	end
	if quote.profit then
		local color = quote.profit >= 0 and aux.color.green or aux.color.orange
		return vendor .. '  ·  ' .. mats .. '  ·  Spread ' .. money_text(quote.profit, color)
	end
	return vendor .. '  ·  ' .. mats
end

function show_shop_quote_tooltip(quote, id, name, owner)
	if id then
		item_tooltip(id, name, owner)
	else
		GameTooltip:SetOwner(owner, 'ANCHOR_RIGHT')
		GameTooltip:AddLine(name or 'Item', 1, 1, 1)
		GameTooltip:AddLine(' ')
	end
	if not quote then
		GameTooltip:Show()
		return
	end
	if quote.value > 0 then
		add_line('Vendor pays', money_text(quote.value) .. ' each' .. (quote.verified and '' or ' *'))
		add_line('Vendor total', money_text(quote.revenue) .. ' for ' .. quote.units)
		if quote.source then add_line('Vendor source', quote.source) end
	else
		add_line('Vendor pays', 'unknown')
	end
	if quote.all_known then
		add_line('Mats if you buy all', money_text(quote.all_cost))
	else
		add_line('Mats if you buy all', 'unknown — scan AH or a vendor')
	end
	if quote.missing_cost > 0 then
		add_line('Missing mats', quote.miss_known and money_text(quote.missing_cost) or (money_text(quote.missing_cost) .. ' + unpriced'))
	else
		add_line('Missing mats', 'none')
	end
	if quote.profit then
		add_line('Spread vs vendor', money_text(quote.profit, quote.profit >= 0 and aux.color.green or aux.color.orange))
	end
	if quote.value > 0 and not quote.verified then
		add_line('* Vendor price comes from a database. Open a merchant with the item in your bags to confirm it.', nil, .7, .7, .7)
	end
	GameTooltip:Show()
end

function set_shop_quote(quote)
	if shop_quote_label then
		shop_quote_label:SetText(format_shop_quote(quote))
	end
end

function build_shop_needs(target, qty)
	qty = qty or 1
	local needs = {}
	if target.kind == 'item' and target.id then
		tinsert(needs, {id = target.id, count = qty, name = target.name})
		return needs
	end
	local recipe = target.recipe
	if not recipe then return needs end
	for i = 1, getn(recipe.reagents or EMPTY) do
		local reagent = recipe.reagents[i]
		local id = reagent_id(reagent)
		if id then
			tinsert(needs, {id = id, count = (reagent.count or 1) * qty, name = reagent.name or item_name(id)})
		end
	end
	return needs
end

function build_shop_plan(needs, extra)
	extra = extra or EMPTY
	local mine, alts = owned_snapshot()
	local mail = mail_counts()
	local entries, cash, ah_cash, all_cost, all_known = {}, 0, 0, 0, true
	for i = 1, getn(needs) do
		local need = needs[i]
		local have = (mine[need.id] or 0) + (mail[need.id] or 0) + (extra[need.id] or 0)
		local missing = max(0, need.count - have)
		local listing = book_listing(need.id)
		local copy = {}
		for j = 1, getn(listing) do
			copy[j] = {c = listing[j].c, b = listing[j].b}
		end
		local ctx = make_ctx(need.id, 1, 0, copy, nil)
		local picks, vendor_units, leftover, line_cash, line_ah, max_unit = {}, 0, 0, 0, 0, 0
		if missing > 0 then
			local _, spent, chosen, _, vendor, left = cover(ctx, missing, true)
			picks = chosen or {}
			vendor_units = vendor or 0
			leftover = left or 0
			line_cash = spent or 0
			for j = 1, getn(picks) do
				line_ah = line_ah + picks[j].c
				max_unit = max(max_unit, picks[j].b / picks[j].c)
			end
		end
		local full_cash, _, _, full_ok = shop_buy_cost(need.id, need.count)
		if full_ok and full_cash then
			all_cost = all_cost + full_cash
		else
			all_known = false
		end
		cash = cash + line_cash
		ah_cash = ah_cash + line_cash
		tinsert(entries, {
			id = need.id,
			name = need.name or item_name(need.id),
			q = need.count,
			need = need.count,
			owned = min(have, need.count),
			have = have,
			reused = 0,
			vendor = vendor_units,
			vendor_price = ctx.u,
			leftover = leftover,
			spare = leftover,
			salvage = ctx.s,
			picks = picks,
			ah_units = line_ah,
			ah_cash = line_cash,
			max_unit = max_unit,
			alts = alts[need.id],
		})
	end
	local title = shop_target and shop_target.name or 'Shopping'
	local product, units, value, verified = 0, 1, 0, nil
	if shop_target then
		product, units, value, verified = shop_product(shop_target, shop_qty())
	end
	local revenue = value * units
	return {
		name = title,
		product = product,
		crafts = 1,
		yield = units,
		value = value,
		verified = verified,
		revenue = revenue,
		cash = cash,
		ah_cash = ah_cash,
		all_cost = all_cost,
		all_known = all_known,
		profit = value > 0 and all_known and (revenue - all_cost) or 0,
		leftover = 0,
		shop = true,
		shop_needs = needs,
		recipe = {product = product, reagents = EMPTY, made = 1},
		reagents = entries,
		steps = EMPTY,
	}
end

function show_shop_matches(hits)
	shop_mode = 'match'
	shop_matches = hits
	shop_target = nil
	shop_plan = nil
	set_shop_quote(nil)
	if shop_listing then shop_listing:SetColInfo(MATCH_COLUMNS) end
	local mine = owned_snapshot()
	local bag = {mine = mine, mail = mail_counts()}
	local qty = shop_qty()
	local rows = {}
	for i = 1, min(getn(hits), 80) do
		local hit = hits[i]
		local quote = shop_quote(hit, qty, bag)
		local vendor = quote.value > 0 and money_text(quote.revenue) or gray('?')
		local mats = quote.all_known and money_text(quote.all_cost) or gray('?')
		local spread = gray('-')
		if quote.profit then
			spread = money_text(quote.profit, quote.profit >= 0 and aux.color.green or aux.color.orange)
		end
		tinsert(rows, {
			cols = {
				{value = hit.id and colored_item_name(hit.id, hit.name) or hit.name},
				{value = hit.kind == 'recipe' and 'Recipe' or 'Item'},
				{value = vendor},
				{value = mats},
				{value = spread},
			},
			hit = hit,
			quote = quote,
		})
	end
	shop_listing:SetData(rows)
	if shop_status then
		shop_status:SetText(getn(hits) == 0 and 'No recipe or item matches. Shift-click an item or type a name.' or format('%d matches — Vendor is sell price, Mats is AH/vendor buy cost, Spread is vendor minus mats.', getn(hits)))
	end
end

function open_shop_target(target)
	shop_mode = 'need'
	shop_target = target
	shop_matches = nil
	if shop_listing then shop_listing:SetColInfo(NEED_COLUMNS) end
	local needs = build_shop_needs(target, shop_qty())
	shop_plan = build_shop_plan(needs)
	local rows = {}
	for i = 1, getn(shop_plan.reagents) do
		local r = shop_plan.reagents[i]
		local missing = max(0, r.need - r.owned)
		local ah = r.ah_units > 0 and format('%d (%s)', r.ah_units, money_text(r.ah_cash)) or gray('-')
		if r.vendor > 0 then
			ah = ah .. ' + vendor ' .. r.vendor
		end
		tinsert(rows, {
			cols = {
				{value = colored_item_name(r.id, r.name) .. gray(' x' .. r.need)},
				{value = tostring(r.need)},
				{value = count_text(r.have)},
				{value = missing > 0 and aux.color.orange(missing) or gray('-')},
				{value = ah},
				{value = alt_text(r.id)},
			},
			reagent = r,
		})
	end
	shop_listing:SetData(rows)
	local quote = shop_quote(target, shop_qty())
	set_shop_quote(quote)
	if shop_status then
		local missing = 0
		for i = 1, getn(shop_plan.reagents) do
			missing = missing + max(0, shop_plan.reagents[i].need - shop_plan.reagents[i].owned)
		end
		if missing == 0 then
			shop_status:SetText('You already have everything for ' .. target.name .. '.')
		else
			shop_status:SetText(format('%s x%d — missing %d. Buy missing, or use mats you already have.', target.name, shop_qty(), missing))
		end
	end
end

function run_shop_search()
	if not shop_name_box then return end
	local text = shop_name_box:GetText() or ''
	local hits = find_shop_targets(text)
	if getn(hits) == 1 then
		open_shop_target(hits[1])
	else
		show_shop_matches(hits)
	end
end

function refresh_shop_controls()
	if not shop_buy then return end
	local can = not scanning and not buying and shop_plan and shop_plan.ah_cash
	if can and shop_plan.ah_cash > 0 then shop_buy:Enable() else shop_buy:Disable() end
end

function aux.handle.INIT_UI()
	shop_frame = CreateFrame('Frame', nil, aux.frame)
	shop_frame:SetAllPoints()
	shop_frame:Hide()
	shop_frame:SetScript('OnUpdate', function()
		refresh_shop_controls()
	end)

	local content = CreateFrame('Frame', nil, shop_frame)
	content:SetPoint('TOP', shop_frame, 'TOP', 0, -8)
	content:SetPoint('BOTTOMLEFT', aux.frame.content, 'BOTTOMLEFT', 0, 0)
	content:SetPoint('BOTTOMRIGHT', aux.frame.content, 'BOTTOMRIGHT', 0, 0)

	local top = gui.panel(content)
	top:SetPoint('TOPLEFT', 0, 0)
	top:SetPoint('TOPRIGHT', 0, 0)
	top:SetHeight(62)

	local name_label = gui.label(top, gui.font_size.small)
	name_label:SetPoint('TOPLEFT', 8, -12)
	name_label:SetText('Item / recipe')

	shop_name_box = gui.editbox(top)
	gui.set_size(shop_name_box, 220, 22)
	shop_name_box:SetPoint('LEFT', name_label, 'RIGHT', 6, 0)
	shop_name_box.enter = function()
		shop_name_box:ClearFocus()
		run_shop_search()
	end

	local qty_label = gui.label(top, gui.font_size.small)
	qty_label:SetPoint('LEFT', shop_name_box, 'RIGHT', 10, 0)
	qty_label:SetText('Qty')

	shop_qty_box = gui.editbox(top)
	gui.set_size(shop_qty_box, 44, 22)
	shop_qty_box:SetPoint('LEFT', qty_label, 'RIGHT', 4, 0)
	shop_qty_box:SetAlignment('RIGHT')
	shop_qty_box:SetNumeric(true)
	shop_qty_box:SetText('1')
	shop_qty_box.enter = function()
		shop_qty_box:ClearFocus()
		if shop_target then open_shop_target(shop_target) else run_shop_search() end
	end
	shop_qty_box.focus_loss = function()
		if shop_target then open_shop_target(shop_target) end
	end

	local search_btn = gui.button(top)
	search_btn:SetPoint('LEFT', shop_qty_box, 'RIGHT', 8, 0)
	gui.set_size(search_btn, 70, 24)
	search_btn:SetText('Search')
	search_btn:SetScript('OnClick', run_shop_search)

	shop_quote_label = gui.label(top, gui.font_size.small)
	shop_quote_label:SetPoint('BOTTOMLEFT', 8, 8)
	shop_quote_label:SetPoint('BOTTOMRIGHT', -8, 8)
	shop_quote_label:SetJustifyH('LEFT')
	shop_quote_label:SetText('Vendor and mat cost show after you search.')

	local body = gui.panel(content)
	body:SetPoint('TOPLEFT', top, 'BOTTOMLEFT', 0, -2.5)
	body:SetPoint('BOTTOMRIGHT', 0, 0)

	shop_listing = listing.new(body)
	shop_listing:SetColInfo(MATCH_COLUMNS)
	shop_listing:SetHandler('OnClick', function(st, data)
		if data.hit then
			open_shop_target(data.hit)
		end
	end)
	shop_listing:SetHandler('OnEnter', function(st, data, row)
		if data.reagent then
			show_reagent_tooltip(data.reagent, row)
		elseif data.hit then
			show_shop_quote_tooltip(data.quote, data.hit.id, data.hit.name, row)
		end
	end)
	shop_listing:SetHandler('OnLeave', function() GameTooltip:Hide() end)

	shop_status = gui.label(shop_frame, gui.font_size.small)
	shop_status:SetPoint('TOPLEFT', aux.frame.content, 'BOTTOMLEFT', 0, -8)
	shop_status:SetWidth(250)
	shop_status:SetJustifyH('LEFT')
	shop_status:SetText('Search a recipe or item. Shift-click a link to fill the box.')

	shop_buy = gui.button(shop_frame)
	shop_buy:SetPoint('TOPLEFT', aux.frame.content, 'BOTTOMLEFT', 255, -6)
	gui.set_size(shop_buy, 110, 24)
	shop_buy:SetText('Buy missing')
	shop_buy:SetScript('OnClick', function()
		if shop_plan then request_buy({shop_plan}) end
	end)
end
