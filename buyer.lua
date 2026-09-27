module 'aux.tabs.vendorcraft'

local aux = require 'aux'
local scan = require 'aux.core.scan'
local filter_util = require 'aux.util.filter'

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
	print_vendor_list(vendor)
	if GetMoney() - settings.gold_reserve < ah_cash then
		say(format('Not enough gold: the mats cost %s and you keep %s in reserve.', money_text(ah_cash), money_text(settings.gold_reserve)))
		return
	end
	local item_count = 0
	for _ in items do
		item_count = item_count + 1
	end
	local text = format('Buy %d auctions of %d items for %s?\nExpected profit: %s\nMats are bought one complete craft at a time.', auctions, item_count, money_text(ah_cash), money_text(profit))
	local steps = {}
	for _, plan in plans do
		for _, step in craft_steps(plan) do
			if not step.final then
				tinsert(steps, format('Craft %d x %s first (from the mats below, not the intermediate)', step.n, step.name))
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
	if plan and n > 0 then
		for _, step in craft_steps(plan, n) do
			tinsert(job.crafts, step)
		end
		plan_vendor(plan, job.vendor, n)
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
