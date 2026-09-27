module 'aux.tabs.vendorcraft'

local aux = require 'aux'
local scan = require 'aux.core.scan'
local filter_util = require 'aux.util.filter'

MAX_REPLANS = 3

StaticPopupDialogs.AUX_VENDORCRAFT_BUY = {
	text = '%s',
	button1 = 'Buy',
	button2 = 'Cancel',
	OnAccept = function() start_buying() end,
	OnCancel = function() pending_plans = nil end,
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

function plan_vendor(plan, into)
	into = into or {}
	each_node(plan.reagents, function(entry)
		if entry.vendor > 0 then
			into[entry.id] = (into[entry.id] or 0) + entry.vendor
		end
	end)
	return into
end

function request_buy(plans)
	if busy() or not plans or getn(plans) == 0 then return end
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
		return
	end
	if GetMoney() - settings.gold_reserve < ah_cash then
		say(format('Not enough gold: the mats cost %s and you keep %s in reserve.', money_text(ah_cash), money_text(settings.gold_reserve)))
		return
	end
	local item_count = 0
	for _ in items do
		item_count = item_count + 1
	end
	local text = format('Buy %d auctions of %d items for %s?\nExpected profit: %s', auctions, item_count, money_text(ah_cash), money_text(profit))
	local lines = vendor_lines(vendor)
	if getn(lines) > 0 then
		text = text .. '\n\nYou also need from a vendor:\n' .. table.concat(lines, '\n')
	end
	pending_plans = plans
	StaticPopup_Show('AUX_VENDORCRAFT_BUY', text)
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
	if not plans or busy() then return end
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

-- Items with the least spare supply near the planned price go first, so a
-- shortage shrinks the plan before the plentiful mats are bought.
function bottleneck_order(lines)
	for _, line in lines do
		local spare, listing = 0, book_listing(line.id)
		for i = 1, getn(listing) do
			if listing[i].b / listing[i].c > line.max_unit then break end
			spare = spare + listing[i].c
		end
		line.spare_ratio = (spare - line.ah_units) / line.ah_units
	end
	sort(lines, function(x, y) return x.spare_ratio < y.spare_ratio end)
	return lines
end

function next_plan()
	job.plan_index = job.plan_index + 1
	local plan = job.plans[job.plan_index]
	if not plan then
		return finish_buying()
	end
	job.original = plan
	job.replans = 0
	start_lines(plan)
end

function start_lines(plan)
	job.plan = plan
	job.order = bottleneck_order(plan_lines(plan))
	job.step = 0
	next_line()
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

function next_line()
	job.step = job.step + 1
	local line = job.order[job.step]
	if not line then
		return finish_plan()
	end
	job.line = line
	job.got = 0
	job.owed, job.target = fingerprints(line.picks)
	job.pass = 1
	run_buy_scan()
end

function buy_status()
	local line = job.line
	set_status((job.plan_index - 1) / getn(job.plans), format('Buying %s for %s (%d / %d)', item_name(line.id, line.name), job.plan.name, job.got, job.target))
end

function run_buy_scan()
	local line = job.line
	local name = item_name(line.id, line.name)
	local query = filter_util.query(strlower(name) .. '/exact')
	if not query then
		tinsert(job.notes, 'Could not search for ' .. name .. '.')
		return line_done()
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
	job.auctions = job.auctions + 1
	job.cash = job.cash + pending.b
	add_purchase(line.id, pending.c)
	remove_auction(line.id, pending.c, pending.b)
	buy_status()
end

function line_scanned()
	job.scan_id = nil
	resolve_pending()
	local line = job.line
	replace_listing(line.id, job.fresh)
	local missing = job.target - job.got
	if missing > 0 and job.pass == 1 and not job.out_of_gold then
		-- Some planned auctions are gone. Replace them from what is listed
		-- now, but never above the plan's most expensive unit for this item.
		local ctx = make_ctx(line.id, 1, 0, book_listing(line.id), line.max_unit)
		ctx.u = nil
		local _, _, picks = cover(ctx, missing, true)
		if picks and getn(picks) > 0 then
			local owed, units = fingerprints(picks)
			job.owed, job.target, job.pass = owed, job.got + units, 2
			return run_buy_scan()
		end
	end
	line_done()
end

function line_done()
	local line = job.line
	if job.got < job.target and job.replans < MAX_REPLANS then
		-- Short: re-plan this recipe around what is owned now (purchases so
		-- far are in the mail ledger), so the other lines shrink to match.
		job.replans = job.replans + 1
		local plan = job.plan
		local sup = build_supply({[plan.name] = plan.recipe}, false, false, true)
		local again = eval_recipe(plan.name, plan.recipe, sup, plan.crafts)
		if not again or again.profit <= 0 then
			tinsert(job.notes, format('%s: only got %d of %d, and %s no longer makes a profit; stopped buying for it.',
				item_name(line.id, line.name), job.got, job.target, plan.name))
			job.plan = nil
			return next_plan()
		end
		if again.crafts < plan.crafts then
			tinsert(job.notes, format('%s: only got %d of %d, so %s drops from %d to %d crafts.',
				item_name(line.id, line.name), job.got, job.target, plan.name, plan.crafts, again.crafts))
		end
		return start_lines(again)
	end
	next_line()
end

function finish_plan()
	local plan = job.plan
	if plan and plan.crafts > 0 then
		for _, step in craft_steps(plan) do
			tinsert(job.crafts, step)
		end
		plan_vendor(plan, job.vendor)
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
		if step.final then
			say(format('Then craft %d x %s and sell the %d items to a vendor.', step.n, step.name, step.n * (step.yield or 1)))
		else
			say(format('Craft %d x %s first (used in the next step).', step.n, step.name))
		end
	end
	set_status(1, format('Bought %d auctions for %s', job.auctions, money_text(job.cash)))
	last_job = job
	job = nil
	request_plan()
end
