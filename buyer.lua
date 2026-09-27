module 'aux.tabs.vendorcraft'

local aux = require 'aux'
local scan = require 'aux.core.scan'
local filter_util = require 'aux.util.filter'

StaticPopupDialogs.AUX_VENDORCRAFT_BUY = {
	text = '%s',
	button1 = 'Buy',
	button2 = 'Cancel',
	OnAccept = function() start_buying() end,
	OnCancel = function()
		pending_plans = nil
		buy_prompt = nil
	end,
	timeout = 0,
	hideOnEscape = 1,
	showAlert = 1,
}

StaticPopupDialogs.AUX_VENDORCRAFT_SHOP_BUY = {
	text = '%s',
	button1 = 'Buy',
	button2 = 'Cancel',
	hasEditBox = 1,
	OnShow = function()
		local box = _G[this:GetName() .. 'EditBox']
		shop_popup_filling = true
		if box then
			box:SetNumeric(true)
			box:SetText(tostring(shop_qty()))
			box:SetFocus()
			box:HighlightText()
		end
		shop_popup_filling = nil
	end,
	OnAccept = function()
		shop_accept_popup()
	end,
	OnCancel = function()
		pending_plans = nil
		buy_prompt = nil
	end,
	EditBoxOnEnterPressed = function()
		shop_accept_popup()
		this:GetParent():Hide()
	end,
	EditBoxOnTextChanged = function()
		if shop_popup_filling then return end
		shop_refresh_popup_qty()
	end,
	timeout = 0,
	hideOnEscape = 1,
	showAlert = 1,
}

StaticPopupDialogs.AUX_VENDORCRAFT_OWNED = {
	text = '%s',
	button1 = 'Use my mats',
	button2 = 'Buy from AH',
	OnAccept = function()
		pending_plans = rebuild_plans_with_owned(pending_plans, pending_owned)
		pending_owned = nil
		show_buy_confirm(pending_plans)
	end,
	OnCancel = function()
		pending_owned = nil
		local plan = pending_plans and pending_plans[1]
		if plan and plan.shop then
			-- Buy the mats even when Bagshui already has them.
			pending_plans = {build_shop_plan(plan.shop_target, plan.shop_qty, nil, true)}
		end
		if pending_plans then
			show_buy_confirm(pending_plans)
		else
			buy_prompt = nil
		end
	end,
	timeout = 0,
	hideOnEscape = 1,
	showAlert = 1,
}

-- One purchase line per item in a plan's tree; an item used both directly
-- and inside a craft step gets a single line.
function plan_lines(plan)
	local lines, by_id = {}, {}
	each_node(plan.reagents, function(entry)
		if getn(entry.picks) > 0 then
			local line = by_id[entry.id]
			if not line then
				line = {id = entry.id, name = entry.name, picks = {}, ah_units = 0, max_unit = 0}
				by_id[entry.id] = line
				tinsert(lines, line)
			end
			for _, auction in entry.picks do
				tinsert(line.picks, auction)
			end
			line.ah_units = line.ah_units + entry.ah_units
			line.max_unit = max(line.max_unit, entry.max_unit)
		end
	end)
	return lines
end

function plan_vendor(plan, into, crafts)
	into = into or {}
	local n, total = crafts or plan.crafts, plan.crafts
	each_node(plan.reagents, function(entry)
		if entry.vendor > 0 then
			local count = entry.vendor
			if crafts and total and total > 0 and crafts ~= total then
				count = floor(entry.vendor * crafts / total + .5)
			end
			if count > 0 then
				into[entry.id] = (into[entry.id] or 0) + count
			end
		end
	end)
	return into
end

function request_buy(plans)
	if buying or not plans or getn(plans) == 0 then return end
	cancel_plan()
	pending_plans = plans
	buy_prompt = true
	if plans[1] and plans[1].flip then
		show_buy_confirm(plans)
		return
	end
	local owned_lines, extra = collect_owned_offer(plans)
	if getn(owned_lines) > 0 then
		pending_owned = extra
		local text
		if getn(owned_lines) == 1 then
			text = 'You have ' .. owned_lines[1] .. '.\nInclude these and not buy them from the AH?'
		else
			text = 'You have these mats:\n' .. table.concat(owned_lines, '\n') .. '\n\nInclude these and not buy them from the AH?'
		end
		StaticPopup_Show('AUX_VENDORCRAFT_OWNED', text)
		return
	end
	show_buy_confirm(plans)
end

-- Mats the shopping list can skip because this character or a Bagshui alt already has them.
function collect_shop_owned(plan)
	local mine, alts = owned_snapshot()
	local mail = mail_counts()
	local me = UnitName('player') or '?'
	local need = {}
	each_node(plan.reagents, function(entry)
		if (entry.need or 0) > 0 then
			need[entry.id] = (need[entry.id] or 0) + entry.need
		end
	end)
	local lines, extra = {}, {}
	for id, count in need do
		local room = count
		local mine_n = min(room, (mine[id] or 0) + (mail[id] or 0))
		if mine_n > 0 then
			room = room - mine_n
			tinsert(lines, format('%dx %s on %s', mine_n, item_name(id), me))
		end
		for name, n in alts[id] or EMPTY do
			if room > 0 and n > 0 then
				local use = min(n, room)
				room = room - use
				extra[id] = (extra[id] or 0) + use
				tinsert(lines, format('%dx %s on %s', use, item_name(id), name))
			end
		end
	end
	sort(lines)
	if getn(lines) > 8 then
		local more = getn(lines) - 8
		local short = {}
		for i = 1, 8 do
			tinsert(short, lines[i])
		end
		tinsert(short, '...' .. more .. ' more')
		lines = short
	end
	return lines, extra
end

-- Mats already on this character or an alt that we are about to buy on the AH.
function collect_owned_offer(plans)
	if plans[1] and plans[1].shop then
		return collect_shop_owned(plans[1])
	end
	local need, used = {}, {}
	for _, plan in plans do
		each_node(plan.reagents, function(entry)
			if entry.ah_units > 0 then
				need[entry.id] = (need[entry.id] or 0) + entry.ah_units
			end
			if (entry.owned or 0) > 0 then
				used[entry.id] = (used[entry.id] or 0) + entry.owned
			end
		end)
	end
	local mine, alts = owned_snapshot()
	local mail = mail_counts()
	local me = UnitName('player') or '?'
	local lines, extra = {}, {}
	for id, ah in need do
		local leftover = max(0, (mine[id] or 0) + (mail[id] or 0) - (used[id] or 0))
		if leftover > 0 then
			local use = min(leftover, ah - (extra[id] or 0))
			if use > 0 then
				extra[id] = (extra[id] or 0) + use
				tinsert(lines, format('%dx %s on %s', use, item_name(id), me))
			end
		end
		for name, n in alts[id] or EMPTY do
			local remain = ah - (extra[id] or 0)
			if remain > 0 and n > 0 then
				local use = min(n, remain)
				extra[id] = (extra[id] or 0) + use
				tinsert(lines, format('%dx %s on %s', use, item_name(id), name))
			end
		end
	end
	sort(lines)
	if getn(lines) > 8 then
		local more = getn(lines) - 8
		local short = {}
		for i = 1, 8 do
			tinsert(short, lines[i])
		end
		tinsert(short, '...' .. more .. ' more')
		lines = short
	end
	return lines, extra
end

function rebuild_plans_with_owned(plans, extra)
	if not plans or getn(plans) == 0 then return plans end
	if plans[1] and plans[1].shop and plans[1].shop_target then
		return {build_shop_plan(plans[1].shop_target, plans[1].shop_qty, extra)}
	end
	local recipes = {}
	for i = 1, getn(plans) do
		recipes[plans[i].name] = plans[i].recipe
	end
	local saved = settings.use_owned
	settings.use_owned = true
	local sup = build_supply(recipes, false, false, true)
	settings.use_owned = saved
	for id, n in extra or EMPTY do
		sup.owned[id] = max(sup.owned[id] or 0, n)
	end
	local out = {}
	for i = 1, getn(plans) do
		local plan = plans[i]
		local limit = plan.user_limited and plan.crafts or nil
		local again = eval_recipe(plan.name, plan.recipe, sup, limit)
		if again then
			again.natural_crafts = plan.natural_crafts or plan.crafts
			again.user_limited = plan.user_limited
			again.discovered = plan.discovered
			again.alt = plan.alt
			commit(again, sup)
			tinsert(out, again)
		else
			tinsert(out, plan)
		end
	end
	return out
end

function show_buy_confirm(plans)
	if not plans or getn(plans) == 0 then
		buy_prompt = nil
		pending_plans = nil
		return
	end
	local auctions, ah_cash, profit, items, vendor = 0, 0, 0, {}, {}
	for _, plan in plans do
		profit = profit + plan.profit
		ah_cash = ah_cash + plan.ah_cash
		for _, line in plan_lines(plan) do
			auctions = auctions + getn(line.picks)
			items[line.id] = true
		end
		plan_vendor(plan, vendor)
	end
	if auctions == 0 then
		say('Nothing to buy on the auction house for this; everything comes from your bags or a vendor.')
		print_vendor_list(vendor)
		buy_prompt = nil
		pending_plans = nil
		return
	end
	print_vendor_list(vendor)
	if GetMoney() - settings.gold_reserve < ah_cash then
		say(format('Not enough gold: the mats cost %s and you keep %s in reserve.', money_text(ah_cash), money_text(settings.gold_reserve)))
		buy_prompt = nil
		pending_plans = nil
		return
	end
	local item_count = 0
	for _ in items do
		item_count = item_count + 1
	end
	local shop_only = true
	for _, plan in plans do
		if not plan.shop then shop_only = false end
	end
	local text
	if shop_only then
		text = shop_confirm_text(plans)
	else
		text = format('Buy %d auctions of %d items for %s?\nExpected profit: %s\nMats are bought one complete craft at a time.', auctions, item_count, money_text(ah_cash), money_text(profit))
	end
	local steps = {}
	for _, plan in plans do
		if not plan.flip then
			for _, step in craft_steps(plan) do
				if not step.final then
					tinsert(steps, format('Craft %d x %s first (from the mats below, not the intermediate)', step.n, step.name))
				end
			end
		end
	end
	if getn(steps) > 0 then
		text = text .. '\n\n' .. table.concat(steps, '\n')
	end
	local lines = vendor_lines(vendor)
	if getn(lines) > 0 then
		text = text .. '\n\nYou also need from a vendor:\n' .. table.concat(lines, '\n')
	end
	pending_plans = plans
	if shop_only then
		StaticPopup_Show('AUX_VENDORCRAFT_SHOP_BUY', text)
	else
		StaticPopup_Show('AUX_VENDORCRAFT_BUY', text)
	end
end

function shop_confirm_text(plans)
	local vendor_total, mat_all, missing = 0, 0, 0
	local qty = 1
	for _, plan in plans do
		vendor_total = vendor_total + (plan.revenue or 0)
		mat_all = mat_all + (plan.all_cost or plan.cash or 0)
		missing = missing + (plan.cash or 0)
		qty = plan.shop_qty or qty
	end
	return format('Craft quantity is the box below.\n\n%d to craft.\nMissing mats %s. All mats %s.\nVendor pays %s for the finished items.\nSpread vs vendor: %s.', qty, money_text(missing), money_text(mat_all), money_text(vendor_total), money_text(plans[1] and plans[1].profit or 0))
end

function shop_popup_frame()
	for i = 1, 4 do
		local frame = _G['StaticPopup' .. i]
		if frame and frame:IsShown() and frame.which == 'AUX_VENDORCRAFT_SHOP_BUY' then
			return frame, _G['StaticPopup' .. i .. 'EditBox'], _G['StaticPopup' .. i .. 'Text']
		end
	end
end

function shop_accept_popup()
	local plan = pending_plans and pending_plans[1]
	if plan and plan.shop then
		local _, box = shop_popup_frame()
		local qty = box and tonumber(box:GetText()) or plan.shop_qty or 1
		if not qty or qty < 1 then qty = 1 end
		qty = floor(qty)
		if shop_qty_box then shop_qty_box:SetText(tostring(qty)) end
		if qty ~= plan.shop_qty then
			shop_market_cache = build_supply(EMPTY, true, true)
			plan = build_shop_plan(plan.shop_target, qty, plan.shop_extra, plan.shop_ignore)
			shop_market_cache = nil
			pending_plans = {plan}
		end
	end
	start_buying()
end

function shop_refresh_popup_qty()
	local plan = pending_plans and pending_plans[1]
	local frame, box, label = shop_popup_frame()
	if not plan or not plan.shop or not frame or not box then return end
	local qty = tonumber(box:GetText())
	if not qty or qty < 1 or qty == plan.shop_qty then return end
	qty = floor(qty)
	shop_market_cache = build_supply(EMPTY, true, true)
	local again = build_shop_plan(plan.shop_target, qty, plan.shop_extra, plan.shop_ignore)
	shop_market_cache = nil
	pending_plans = {again}
	if shop_qty_box then shop_qty_box:SetText(tostring(qty)) end
	if label then label:SetText(shop_confirm_text({again})) end
end

function vendor_lines(vendor)
	local lines = {}
	for id, count in vendor do
		local price = vendor_buy(id)
		tinsert(lines, format('%d x %s (%s)', count, item_name(id), money_text(count * (price or 0))))
	end
	sort(lines)
	return lines
end

function print_vendor_list(vendor)
	for _, line in vendor_lines(vendor) do
		say('Buy from a vendor: ' .. line)
	end
end

function start_buying()
	local plans = pending_plans
	pending_plans = nil
	buy_prompt = nil
	cancel_plan()
	if not plans or scanning or buying then return end
	buying = true
	job = {
		plans = plans,
		plan_index = 0,
		auctions = 0,
		cash = 0,
		crafts = {},
		vendor = {},
		notes = {},
	}
	job.listener = aux.event_listener('CHAT_MSG_SYSTEM', on_system_message)
	next_plan()
end

function stop_buying()
	if job and job.scan_id then
		scan.abort(job.scan_id)
	elseif buying then
		finish_buying()
	end
end

function fingerprints(picks)
	local owed, units = {}, 0
	for _, auction in picks do
		local key = auction.c .. ':' .. auction.b
		owed[key] = (owed[key] or 0) + 1
		units = units + auction.c
	end
	return owed, units
end

function next_plan()
	job.plan_index = job.plan_index + 1
	local plan = job.plans[job.plan_index]
	if not plan then
		return finish_buying()
	end
	job.original = plan
	start_rounds(plan)
end

-- Buy one complete craft-set at a time (2 gold, 5 iron, 10 copper, repeat)
-- so a sniped auction only shrinks the number of finished crafts.
function start_rounds(plan)
	job.plan = plan
	job.order = plan_lines(plan)
	for _, line in job.order do
		line.got = 0
		line.total = line.ah_units
		line.pending = {}
		for i = 1, getn(line.picks) do
			tinsert(line.pending, line.picks[i])
		end
	end
	job.round = 0
	job.complete_crafts = 0
	next_round()
end

function want_after_round(line, r)
	local n = job.plan.crafts
	if not n or n < 1 then return line.total end
	return floor(line.total * r / n)
end

function take_pending(line, want)
	local owed, units = {}, 0
	for i = 1, getn(line.pending) do
		if units >= want then break end
		local auction = line.pending[i]
		local key = auction.c .. ':' .. auction.b
		owed[key] = (owed[key] or 0) + 1
		units = units + auction.c
	end
	return owed, units
end

function remove_pending(line, count, buyout)
	for i = 1, getn(line.pending) do
		if line.pending[i].c == count and line.pending[i].b == buyout then
			tremove(line.pending, i)
			return
		end
	end
end

function next_round()
	job.round = job.round + 1
	if job.round > job.plan.crafts then
		job.complete_crafts = job.plan.crafts
		return finish_plan()
	end
	job.step = 0
	next_round_item()
end

function next_round_item()
	job.step = job.step + 1
	local line = job.order[job.step]
	if not line then
		if getn(job.order) == 0 then
			job.complete_crafts = job.plan.crafts
			return finish_plan()
		end
		job.complete_crafts = job.round
		return next_round()
	end
	local want = want_after_round(line, job.round) - line.got
	if want <= 0 then
		return next_round_item()
	end
	job.line = line
	job.want = want
	job.got = 0
	job.owed, job.target = take_pending(line, want)
	job.pass = 1
	if job.target <= 0 then
		return try_replace_or_fail()
	end
	run_buy_scan()
end

function buy_status()
	local line = job.line
	set_status((job.plan_index - 1) / getn(job.plans), format('Buying %s for %s (craft %d / %d)', item_name(line.id, line.name), job.plan.name, job.round, job.plan.crafts))
end

function run_buy_scan()
	local line = job.line
	local name = item_name(line.id, line.name)
	local query = filter_util.query(strlower(name) .. '/exact')
	if not query then
		tinsert(job.notes, 'Could not search for ' .. name .. '.')
		return fail_round()
	end
	job.fresh = {}
	job.pending = nil
	buy_status()
	job.scan_id = scan.start{
		type = 'list',
		ignore_owner = true,
		queries = {query},
		auto_buy_validator = buy_validator,
		on_auction = function(record)
			if record.item_id == line.id and record.buyout_price > 0 then
				tinsert(job.fresh, {c = record.count, b = record.buyout_price})
			end
		end,
		on_complete = line_scanned,
		on_abort = function()
			tinsert(job.notes, 'Buying was stopped.')
			finish_buying()
		end,
	}
end

-- A purchase that has not been confirmed by the time aux moves on failed.
function resolve_pending()
	local pending = job.pending
	if pending then
		job.owed[pending.key] = (job.owed[pending.key] or 0) + 1
		job.pending = nil
	end
end

function buy_validator(record)
	resolve_pending()
	local line = job.line
	if record.item_id ~= line.id or record.buyout_price <= 0 then return end
	if record.owner and record.owner == UnitName('player') then return end
	if aux.bid_in_progress() then return end
	local key = record.count .. ':' .. record.buyout_price
	if (job.owed[key] or 0) <= 0 then return end
	-- aux waits forever for a purchase it could not afford, so never ask it to.
	if GetMoney() - record.buyout_price < settings.gold_reserve then
		job.out_of_gold = true
		return
	end
	job.owed[key] = job.owed[key] - 1
	job.pending = {key = key, c = record.count, b = record.buyout_price}
	return true
end

function on_system_message()
	if not job or not job.pending or arg1 ~= ERR_AUCTION_BID_PLACED then return end
	local pending, line = job.pending, job.line
	job.pending = nil
	job.got = job.got + pending.c
	line.got = (line.got or 0) + pending.c
	job.auctions = job.auctions + 1
	job.cash = job.cash + pending.b
	add_purchase(line.id, pending.c)
	remove_auction(line.id, pending.c, pending.b)
	remove_pending(line, pending.c, pending.b)
	buy_status()
end

function try_replace_or_fail()
	local line = job.line
	local missing = want_after_round(line, job.round) - (line.got or 0)
	if missing > 0 and job.pass == 1 and not job.out_of_gold then
		local ctx = make_ctx(line.id, 1, 0, book_listing(line.id), line.max_unit)
		ctx.u = nil
		local _, _, picks = cover(ctx, missing, true)
		if picks and getn(picks) > 0 then
			for i = getn(picks), 1, -1 do
				tinsert(line.pending, 1, picks[i])
			end
			local owed, units = fingerprints(picks)
			job.owed, job.target, job.pass = owed, units, 2
			job.got = 0
			return run_buy_scan()
		end
	end
	fail_round()
end

function fail_round()
	local line, plan = job.line, job.plan
	job.complete_crafts = job.round - 1
	if job.complete_crafts < 0 then job.complete_crafts = 0 end
	tinsert(job.notes, format('%s ran out of %s at craft %d of %d; keeping %d complete set(s).',
		plan.name, item_name(line.id, line.name), job.round, plan.crafts, job.complete_crafts))
	finish_plan()
end

function line_scanned()
	job.scan_id = nil
	resolve_pending()
	local line = job.line
	replace_listing(line.id, job.fresh)
	if (line.got or 0) < want_after_round(line, job.round) then
		return try_replace_or_fail()
	end
	next_round_item()
end

function finish_plan()
	local plan = job.plan
	local n = job.complete_crafts or 0
	if plan and n > 0 and not plan.flip then
		if plan.shop then job.for_craft = true end
		for _, step in craft_steps(plan, n) do
			tinsert(job.crafts, step)
		end
		plan_vendor(plan, job.vendor, n)
	elseif plan and plan.flip then
		tinsert(job.notes, format('Sell %s to a vendor.', plan.name))
	end
	next_plan()
end

function finish_buying()
	if not job then
		buying = false
		return
	end
	if job.listener then
		aux.kill_listener(job.listener)
	end
	resolve_pending()
	buying = false
	save_book()
	say(format('Bought %d auctions for %s. They are in your mailbox.', job.auctions, money_text(job.cash)))
	if job.out_of_gold then
		tinsert(job.notes, 'Stopped buying some mats to keep your gold reserve.')
	end
	for _, note in job.notes do
		say(note)
	end
	print_vendor_list(job.vendor)
	for _, step in job.crafts do
		if step.final and job.for_craft then
			say(format('Then craft %d x %s.', step.n, step.name))
		elseif step.final then
			say(format('Then craft %d x %s and sell the %d items to a vendor.', step.n, step.name, step.n * (step.yield or 1)))
		else
			say(format('Craft %d x %s first (used in the next step).', step.n, step.name))
		end
	end
	set_status(1, format('Bought %d auctions for %s', job.auctions, money_text(job.cash)))
	last_job = job
	job = nil
	if not suppress_plan then
		request_plan()
	end
end
