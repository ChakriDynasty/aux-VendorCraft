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
	{name = 'Craft', width = .14, align = 'CENTER'},
	{name = 'AH', width = .20, align = 'CENTER'},
	{name = 'Alts', width = .16, align = 'LEFT'},
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

-- One shared AH copy for a search. Each quote clears `taken` before it runs.
function shop_market()
	if not shop_market_cache then
		shop_market_cache = build_supply(EMPTY, true, true)
	end
	return shop_market_cache
end

function clear_shop_taken(auctions)
	for _, list in auctions or EMPTY do
		for i = 1, getn(list) do
			list[i].taken = nil
		end
	end
end

function shop_owned(bag, extra)
	local owned = {}
	local mine, mail = bag and bag.mine, bag and bag.mail
	if not bag then
		mine = owned_snapshot()
		mail = mail_counts()
	end
	for id, n in mine or EMPTY do
		owned[id] = (owned[id] or 0) + n
	end
	for id, n in mail or EMPTY do
		owned[id] = (owned[id] or 0) + n
	end
	for id, n in extra or EMPTY do
		owned[id] = (owned[id] or 0) + n
	end
	return owned
end

-- Buy `missing` units from the AH, or an unlimited vendor when that is cheaper
-- or the item is not listed. Marks the chosen auctions taken so another step
-- cannot spend them again.
function shop_buy_leaf(sup, node, missing)
	node.cash = 0
	node.net = (node.owned or 0) * (node.salvage or 0)
	if missing < 1 then return end
	local src = sup.auctions[node.id] or EMPTY
	local ctx = make_ctx(node.id, 1, 0, src, nil)
	local _, spent, chosen, _, vendor, left = cover(ctx, missing, true)
	local got = missing
	if not chosen and not ctx.u and ctx.ah_units and ctx.ah_units > 0 then
		got = min(missing, ctx.ah_units)
		_, spent, chosen, _, vendor, left = cover(ctx, got, true)
		if chosen then node.short = missing - got end
	end
	if not chosen then
		node.short = missing
		return
	end
	node.picks = chosen
	node.vendor = vendor or 0
	node.vendor_price = ctx.u
	node.leftover = left or 0
	node.spare = left or 0
	node.ah_cash = spent or 0
	node.cash = (spent or 0) + node.vendor * (ctx.u or 0)
	node.net = node.net + node.cash
	for i = 1, getn(chosen) do
		local auction = chosen[i]
		node.ah_units = node.ah_units + auction.c
		node.max_unit = max(node.max_unit, auction.b / auction.c)
		auction.taken = true
	end
end

-- Bars become ore, bolts become cloth. Other crafts are left as the item
-- the recipe actually lists.
function shop_can_break_down(maker)
	if not maker then return end
	local name = fold_name(maker.name or '')
	if strfind(name, 'smelt ') or strfind(name, '^bolt of ') then
		return true
	end
end

-- Expand a crafted reagent into its own reagents, down to mats that are not
-- themselves crafted. Leather grades and cooldown recipes are already left
-- out of the maker list, same as the Vendor tab.
function shop_node(sup, id, per, need, depth, path, name)
	local have = sup.owned[id] or 0
	local use = min(need, have)
	if use > 0 then sup.owned[id] = have - use end
	local missing = need - use
	local node = {
		id = id,
		name = name or item_name(id),
		q = per,
		need = need,
		owned = use,
		have = have,
		reused = 0,
		vendor = 0,
		leftover = 0,
		spare = 0,
		salvage = vendor_sell(id) or 0,
		picks = {},
		ah_units = 0,
		ah_cash = 0,
		max_unit = 0,
		cash = 0,
		net = 0,
	}
	local maker = sup.makers[id]
	if not shop_can_break_down(maker) then maker = nil end
	-- An unlimited vendor (thread, dye, vials, salt) is a basic mat: buy it
	-- there, or on the AH only when the auction is cheaper. Do not craft it.
	local from_vendor = vendor_buy(id)
	-- Only smelts and cloth bolts are broken down. Any other recipe that
	-- happens to share an item id (Iron Lantern's bars are not bronze, and
	-- wool is not a shadewood craft) is bought as itself.
	if missing <= 0 or from_vendor or not maker or depth >= 8 or path[id] then
		if missing > 0 then shop_buy_leaf(sup, node, missing) end
		return node
	end
	local recipe = maker.recipe
	local yield = recipe.made or 1
	local batches = ceil(missing / yield)
	local children, cash = {}, 0
	path[id] = true
	for i = 1, getn(recipe.reagents or EMPTY) do
		local reagent = recipe.reagents[i]
		local rid = reagent_id(reagent)
		if rid then
			local child = shop_node(sup, rid, reagent.count or 1, batches * (reagent.count or 1), depth + 1, path, reagent.name)
			tinsert(children, child)
			cash = cash + (child.cash or 0)
		end
	end
	path[id] = nil
	node.cash = cash
	node.net = use * node.salvage + cash
	node.craft = {
		name = maker.name,
		known = maker.known,
		prof = recipe.prof,
		skill = recipe.skill,
		crafts = batches,
		yield = yield,
		units = batches * yield,
		reagents = children,
	}
	node.spare = batches * yield - missing
	node.leftover = node.spare
	return node
end

function expand_shop(sup, target, qty)
	local entries, path = {}, {}
	qty = qty or 1
	if target.kind == 'recipe' and target.recipe then
		if target.recipe.product then path[target.recipe.product] = true end
		for i = 1, getn(target.recipe.reagents or EMPTY) do
			local reagent = target.recipe.reagents[i]
			local rid = reagent_id(reagent)
			if rid then
				tinsert(entries, shop_node(sup, rid, reagent.count or 1, qty * (reagent.count or 1), 0, path, reagent.name))
			end
		end
	elseif target.id then
		tinsert(entries, shop_node(sup, target.id, 1, qty, 0, path, target.name))
	end
	return entries
end

function root_cash(entries)
	local cash = 0
	for i = 1, getn(entries) do
		cash = cash + (entries[i].cash or 0)
	end
	return cash
end

function tree_has_short(entries)
	local short = false
	each_node(entries, function(entry)
		if entry.short and entry.short > 0 then short = true end
	end)
	return short
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
	local market = shop_market()
	clear_shop_taken(market.auctions)
	local all_entries = expand_shop({
		owned = {},
		auctions = market.auctions,
		makers = market.makers,
	}, target, qty)
	clear_shop_taken(market.auctions)
	local miss_entries = expand_shop({
		owned = shop_owned(bag),
		auctions = market.auctions,
		makers = market.makers,
	}, target, qty)
	clear_shop_taken(market.auctions)
	local product, units, value, verified, source = shop_product(target, qty)
	local revenue = value * units
	local all_known = not tree_has_short(all_entries)
	local miss_known = not tree_has_short(miss_entries)
	return {
		product = product,
		units = units,
		value = value,
		verified = verified,
		source = source,
		revenue = revenue,
		all_cost = root_cash(all_entries),
		missing_cost = root_cash(miss_entries),
		all_known = all_known,
		miss_known = miss_known,
		profit = value > 0 and all_known and (revenue - root_cash(all_entries)) or nil,
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

function build_shop_plan(target, qty, extra, ignore_owned)
	qty = qty or 1
	target = target or EMPTY
	local market = shop_market()
	clear_shop_taken(market.auctions)
	local all_entries = expand_shop({
		owned = {},
		auctions = market.auctions,
		makers = market.makers,
	}, target, qty)
	local all_cost = root_cash(all_entries)
	local all_known = not tree_has_short(all_entries)
	clear_shop_taken(market.auctions)
	local owned = {}
	if not ignore_owned then
		owned = shop_owned(nil, extra)
	end
	local entries = expand_shop({
		owned = owned,
		auctions = market.auctions,
		makers = market.makers,
	}, target, qty)
	clear_shop_taken(market.auctions)
	local ah_cash, vendor_cash = 0, 0
	each_node(entries, function(entry)
		ah_cash = ah_cash + (entry.ah_cash or 0)
		vendor_cash = vendor_cash + (entry.vendor or 0) * (entry.vendor_price or 0)
	end)
	local product, units, value, verified, source = shop_product(target, qty)
	local revenue = value * units
	local recipe = target.recipe or {product = product, reagents = EMPTY, made = 1}
	return {
		name = target.name or 'Shopping',
		product = product or 0,
		crafts = qty,
		yield = units,
		value = value,
		verified = verified,
		source = source,
		revenue = revenue,
		cash = root_cash(entries),
		ah_cash = ah_cash,
		vendor_cash = vendor_cash,
		all_cost = all_cost,
		all_known = all_known,
		miss_known = not tree_has_short(entries),
		profit = value > 0 and all_known and (revenue - all_cost) or 0,
		leftover = 0,
		shop = true,
		shop_target = target,
		shop_qty = qty,
		shop_extra = extra,
		shop_ignore = ignore_owned and true or false,
		recipe = recipe,
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
	shop_market_cache = build_supply(EMPTY, true, true)
	local bag = {mine = owned_snapshot(), mail = mail_counts()}
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
	shop_market_cache = nil
	if shop_status then
		shop_status:SetText(getn(hits) == 0 and 'No recipe or item matches. Shift-click an item or type a name.' or format('%d matches — Mats is the cost of the basic materials, not the direct reagents.', getn(hits)))
	end
end

function open_shop_target(target)
	shop_mode = 'need'
	shop_target = target
	shop_matches = nil
	if shop_listing then shop_listing:SetColInfo(NEED_COLUMNS) end
	shop_market_cache = build_supply(EMPTY, true, true)
	shop_plan = build_shop_plan(target, shop_qty())
	shop_market_cache = nil
	local rows = {}
	each_node(shop_plan.reagents, function(r, depth)
		local indent = depth > 0 and (strrep('  ', depth) .. gray('> ')) or ''
		local ah = gray('-')
		if r.short and r.short > 0 then
			ah = aux.color.orange('short ' .. r.short)
		elseif r.ah_units > 0 then
			ah = format('%d (%s)', r.ah_units, money_text(r.ah_cash))
		end
		if r.vendor > 0 then
			local bit = format('vendor %d (%s)', r.vendor, money_text(r.vendor * (r.vendor_price or 0)))
			ah = r.ah_units > 0 and (ah .. ' + ' .. bit) or bit
		end
		tinsert(rows, {
			cols = {
				{value = indent .. colored_item_name(r.id, r.name)},
				{value = tostring(r.need)},
				{value = count_text(r.have)},
				{value = craft_text(r)},
				{value = ah},
				{value = alt_text(r.id)},
			},
			reagent = r,
		})
	end)
	shop_listing:SetData(rows)
	set_shop_quote({
		units = shop_plan.yield,
		value = shop_plan.value,
		verified = shop_plan.verified,
		source = shop_plan.source,
		revenue = shop_plan.revenue,
		all_cost = shop_plan.all_cost,
		missing_cost = shop_plan.cash,
		all_known = shop_plan.all_known,
		miss_known = shop_plan.miss_known,
		profit = shop_plan.value > 0 and shop_plan.all_known and (shop_plan.revenue - shop_plan.all_cost) or nil,
	})
	if shop_status then
		local buy = 0
		each_node(shop_plan.reagents, function(r)
			if not r.craft then buy = buy + max(0, r.need - (r.owned or 0)) end
		end)
		if buy == 0 then
			shop_status:SetText('You already have the basic mats for ' .. target.name .. '.')
		else
			local vendor_note = (shop_plan.vendor_cash or 0) > 0 and (' Vendor mats ' .. money_text(shop_plan.vendor_cash) .. '.') or ''
			shop_status:SetText(format('%s x%d — %d basic mats to buy.%s Indented rows are what you craft along the way.', target.name, shop_qty(), buy, vendor_note))
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
	-- A scan or a zero quote must not lock Buy. Quantity can still be changed,
	-- and the click rebuilds the calculation for whatever quantity is set.
	if shop_target and not buying then shop_buy:Enable() else shop_buy:Disable() end
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
		if buying or not shop_target then return end
		shop_market_cache = build_supply(EMPTY, true, true)
		shop_plan = build_shop_plan(shop_target, shop_qty())
		shop_market_cache = nil
		request_buy({shop_plan})
	end)
end
