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

function request_buy(plans)
	if busy() or not plans or getn(plans) == 0 then return end
	local auctions, ah_cash, profit, reagents, vendor = 0, 0, 0, {}, {}
	for _, plan in plans do
		profit = profit + plan.profit
		ah_cash = ah_cash + plan.ah_cash
		for _, reagent in plan.reagents do
			auctions = auctions + getn(reagent.picks)
			if getn(reagent.picks) > 0 then
				reagents[reagent.id] = true
			end
			if reagent.vendor > 0 then
				vendor[reagent.id] = (vendor[reagent.id] or 0) + reagent.vendor
			end
		end
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
	local reagent_count = 0
	for _ in reagents do
		reagent_count = reagent_count + 1
	end
	local text = format('Buy %d auctions of %d reagents for %s?\nExpected profit: %s', auctions, reagent_count, money_text(ah_cash), money_text(profit))
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

-- Reagents with the least spare supply near the planned price go first, so a
-- shortage shrinks the plan before the plentiful mats are bought.
function bottleneck_order(plan)
	local order = {}
	for _, reagent in plan.reagents do
		if getn(reagent.picks) > 0 then
			local spare, listing = 0, book_listing(reagent.id)
			for i = 1, getn(listing) do
				if listing[i].b / listing[i].c > reagent.max_unit then break end
				spare = spare + listing[i].c
			end
			reagent.spare_ratio = (spare - reagent.ah_units) / reagent.ah_units
			tinsert(order, reagent)
		end
	end
	sort(order, function(x, y) return x.spare_ratio < y.spare_ratio end)
	return order
end

function next_plan()
	job.plan_index = job.plan_index + 1
	local plan = job.plans[job.plan_index]
	if not plan then
		return finish_buying()
	end
	job.plan = plan
	job.n = plan.crafts
	job.order = bottleneck_order(plan)
	job.step = 0
	job.got = {}
	job.vendor_units = {}
	next_reagent()
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

function next_reagent()
	job.step = job.step + 1
	local reagent = job.order[job.step]
	if not reagent or job.n <= 0 then
		return finish_plan()
	end
	job.reagent = reagent
	job.got[reagent.id] = 0
	local picks, vendor_units
	if job.n == job.plan.crafts then
		picks, vendor_units = reagent.picks, reagent.vendor
	else
		-- The plan shrank; re-cover the smaller need from what is listed now.
		local ctx = make_ctx(reagent.id, reagent.q, reagent.owned, book_listing(reagent.id), reagent.max_unit)
		local _, _, p, _, v = cover(ctx, job.n * reagent.q, true)
		picks, vendor_units = p or {}, v or 0
	end
	job.vendor_units[reagent.id] = vendor_units
	job.owed, job.target = fingerprints(picks)
	job.pass = 1
	if job.target == 0 then
		return reagent_done()
	end
	run_buy_scan()
end

function run_buy_scan()
	local reagent = job.reagent
	local name = item_name(reagent.id, reagent.name)
	local query = filter_util.query(strlower(name) .. '/exact')
	if not query then
		tinsert(job.notes, 'Could not search for ' .. name .. '.')
		return reagent_done()
	end
	job.fresh = {}
	job.pending = nil
	set_status((job.plan_index - 1) / getn(job.plans), format('Buying %s for %s (%d / %d)', name, job.plan.name, job.got[reagent.id], job.target))
	job.scan_id = scan.start{
		type = 'list',
		ignore_owner = true,
		queries = {query},
		auto_buy_validator = buy_validator,
		on_auction = function(record)
			if record.item_id == reagent.id and record.buyout_price > 0 then
				tinsert(job.fresh, {c = record.count, b = record.buyout_price})
			end
		end,
		on_complete = reagent_scanned,
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
	local reagent = job.reagent
	if record.item_id ~= reagent.id or record.buyout_price <= 0 then return end
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
	local pending, reagent = job.pending, job.reagent
	job.pending = nil
	job.got[reagent.id] = job.got[reagent.id] + pending.c
	job.auctions = job.auctions + 1
	job.cash = job.cash + pending.b
	add_purchase(reagent.id, pending.c)
	remove_auction(reagent.id, pending.c, pending.b)
	set_status((job.plan_index - 1) / getn(job.plans), format('Buying %s for %s (%d / %d)', item_name(reagent.id, reagent.name), job.plan.name, job.got[reagent.id], job.target))
end

function reagent_scanned()
	job.scan_id = nil
	resolve_pending()
	local reagent = job.reagent
	replace_listing(reagent.id, job.fresh)
	local missing = job.target - job.got[reagent.id]
	if missing > 0 and job.pass == 1 and not job.out_of_gold then
		-- Some planned auctions are gone. Replace them from what is listed
		-- now, but never above the plan's most expensive unit for this reagent.
		local ctx = make_ctx(reagent.id, reagent.q, 0, book_listing(reagent.id), reagent.max_unit)
		local _, _, picks, _, vendor_units = cover(ctx, missing, true)
		if picks then
			job.vendor_units[reagent.id] = job.vendor_units[reagent.id] + vendor_units
			local owed, units = fingerprints(picks)
			if units > 0 then
				job.owed, job.target, job.pass = owed, job.got[reagent.id] + units, 2
				return run_buy_scan()
			end
		end
	end
	reagent_done()
end

function reagent_done()
	local reagent = job.reagent
	local need = job.n * reagent.q
	local have = min(reagent.owned, need) + job.vendor_units[reagent.id] + job.got[reagent.id]
	local possible = floor(have / reagent.q)
	if possible < job.n then
		tinsert(job.notes, format('%s: only %d of %d available at the planned price, so %s drops from %d to %d crafts.',
			item_name(reagent.id, reagent.name), have, need, job.plan.name, job.n, possible))
		job.n = possible
	end
	next_reagent()
end

function finish_plan()
	local plan = job.plan
	if job.n > 0 then
		tinsert(job.crafts, {name = plan.name, n = job.n, product = plan.product, yield = plan.yield})
		for _, reagent in plan.reagents do
			if reagent.vendor_price then
				local need = job.n * reagent.q
				local units = need - min(reagent.owned, need) - (job.got[reagent.id] or 0)
				if units > 0 then
					job.vendor[reagent.id] = (job.vendor[reagent.id] or 0) + units
				end
			end
		end
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
	for _, craft in job.crafts do
		say(format('Then craft %d x %s and sell the %d items to a vendor.', craft.n, craft.name, craft.n * craft.yield))
	end
	set_status(1, format('Bought %d auctions for %s', job.auctions, money_text(job.cash)))
	last_job = job
	job = nil
	request_plan()
end
