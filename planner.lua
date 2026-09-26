module 'aux.tabs.vendorcraft'

local aux = require 'aux'
local info = require 'aux.util.info'

YIELD_OPS = 200000

do
	local ops = 0
	-- Counts work done; hands control back to the game once per YIELD_OPS
	-- when running inside the planner coroutine.
	function spend(n)
		ops = ops + n
		if ops >= YIELD_OPS then
			ops = 0
			if planner_running then
				coroutine.yield()
			end
		end
	end
end

-- Supply of one reagent: owned units, an unlimited vendor (if any), and the
-- AH listing trimmed to auctions cheaper than both the vendor and `cap`.
-- `listing` must be sorted cheapest per unit first.
function make_ctx(id, q, owned, listing, cap)
	local ctx = {id = id, q = q, owned = owned or 0}
	ctx.s = vendor_sell(id) or 0
	ctx.u = vendor_buy(id)
	local a, n, units = {}, 0, 0
	for i = 1, getn(listing) do
		local auction = listing[i]
		if not auction.taken then
			local unit = auction.b / auction.c
			if cap and unit > cap or ctx.u and unit >= ctx.u then
				break
			end
			n = n + 1
			a[n] = auction
			units = units + auction.c
		end
	end
	ctx.a, ctx.n, ctx.ah_units = a, n, units
	return ctx
end

-- 0/1 knapsack over "units bought, capped at K". g[j] is the cheapest spend,
-- net of the vendor value of every unit, for exactly j units (j == K means K
-- or more); gb and gn carry the real buyout total and unit count behind it.
-- With `track`, choices[i][j] = k records that auction i moved k to j.
function knapsack(ctx, K, track)
	local a, s = ctx.a, ctx.s
	local g, gb, gn = {[0] = 0}, {[0] = 0}, {[0] = 0}
	for j = 1, K do
		g[j] = INF
	end
	local choices = track and {}
	for i = 1, ctx.n do
		local c, b = a[i].c, a[i].b
		-- An auction worth more at a vendor than it costs is a flip of its
		-- own; it is not bought just to be resold.
		local w = b - s * c
		if w < 0 then w = 0 end
		local chosen = track and {}
		for k = K - 1, 0, -1 do
			local gk = g[k]
			if gk < INF then
				local j = k + c
				if j > K then j = K end
				if gk + w < g[j] then
					g[j], gb[j], gn[j] = gk + w, gb[k] + b, gn[k] + c
					if chosen then chosen[j] = k end
				end
			end
		end
		if choices then choices[i] = chosen end
		spend(K + 1)
	end
	return g, gb, gn, choices
end

-- Best end state for `need` units: at least `need` from the AH (spares
-- credited at the vendor price), or fewer plus the rest from a vendor.
-- Returns the knapsack index, vendor units, net cost and gold spent.
function best_end(ctx, g, gb, gn, need, j_ah, j_vendor)
	local s, u = ctx.s, ctx.u
	local pick, vendor_units, score
	if j_ah and g[j_ah] < INF then
		pick, vendor_units, score = j_ah, 0, g[j_ah] + s * need
	end
	if u and j_vendor and g[j_vendor] < INF then
		local v = g[j_vendor] + s * j_vendor + (need - j_vendor) * u
		if not score or v < score then
			pick, vendor_units, score = j_vendor, need - j_vendor, v
		end
	end
	if not pick then return end
	if vendor_units > 0 then
		local cash = gb[pick] + vendor_units * u
		return pick, vendor_units, cash, cash
	end
	return pick, 0, gb[pick] - s * (gn[pick] - need), gb[pick]
end

-- Precomputes the cost of every quantity up to K so a recipe can try each
-- craft count cheaply.
function prepare(ctx, K)
	local g, gb, gn = knapsack(ctx, K)
	ctx.K, ctx.g, ctx.gb, ctx.gn = K, g, gb, gn
	-- at_least[k]: cheapest index j >= k; ties go to fewer units.
	local at_least, best = {}, nil
	for k = K, 0, -1 do
		if g[k] < INF and (not best or g[k] <= g[best]) then best = k end
		at_least[k] = best
	end
	ctx.at_least = at_least
	if ctx.u then
		-- up_to[k]: cheapest exact index j <= k to top up with vendor units.
		local up_to, jv, sv = {}, nil, nil
		for k = 0, K - 1 do
			if g[k] < INF then
				local v = g[k] + (ctx.s - ctx.u) * k
				if not sv or v < sv then jv, sv = k, v end
			end
			up_to[k] = jv
		end
		ctx.up_to = up_to
	end
end

-- Cost of R units of a reagent. Owned units are used first and valued at what
-- a vendor would pay for them; bought units are whole auctions, and any spare
-- units are credited at the vendor sell price.
-- Returns net cost and gold spent; with `want` also the auctions to buy,
-- owned units used, vendor units to buy, and spare units.
function cover(ctx, R, want)
	local own = min(R, ctx.owned)
	local need = R - own
	local net = own * ctx.s
	if need <= 0 then
		if want then return net, 0, {}, own, 0, 0 end
		return net, 0
	end
	if want then
		local g, gb, gn, choices = knapsack(ctx, need, true)
		local j_vendor
		if ctx.u then
			local sv
			for k = 0, need - 1 do
				if g[k] < INF then
					local v = g[k] + (ctx.s - ctx.u) * k
					if not sv or v < sv then j_vendor, sv = k, v end
				end
			end
		end
		local pick, vendor_units, cost, cash = best_end(ctx, g, gb, gn, need, need, j_vendor)
		if not pick then return end
		local picks, k = {}, pick
		for i = ctx.n, 1, -1 do
			local from = choices[i][k]
			if from then
				tinsert(picks, ctx.a[i])
				k = from
			end
		end
		local leftover = vendor_units == 0 and gn[pick] - need or 0
		return net + cost, cash, picks, own, vendor_units, leftover
	end
	if not ctx.K or need > ctx.K then
		prepare(ctx, need)
	end
	local _, _, cost, cash = best_end(ctx, ctx.g, ctx.gb, ctx.gn, need, ctx.at_least[need], ctx.up_to and ctx.up_to[need - 1])
	if not cost then return end
	return net + cost, cash
end

function reagent_id(reagent)
	return reagent.id or reagent.name and info.item_id(reagent.name)
end

function first_open(listing)
	for i = 1, getn(listing) do
		if not listing[i].taken then return listing[i] end
	end
end

-- Best number of crafts for one recipe against the remaining supply.
function eval_recipe(name, recipe, sup)
	if not recipe.product then
		return nil, 'the crafted item is not known yet (reopen the profession window)'
	end
	local value, verified = vendor_sell(recipe.product)
	if not value then
		-- Third return marks recipes that could not be rated at all.
		return nil, 'no vendor price is known for ' .. item_name(recipe.product, name) .. ' (see /vcraft price)', true
	end
	if value <= 0 then
		return nil, 'vendors do not buy ' .. item_name(recipe.product, name)
	end
	local yield = recipe.made or 1
	local revenue = yield * value

	local parts, min_cost = {}, 0
	for i = 1, getn(recipe.reagents) do
		local reagent = recipe.reagents[i]
		local id = reagent_id(reagent)
		if not id then
			return nil, 'unknown reagent ' .. (reagent.name or '?')
		end
		local owned = sup.owned[id] or 0
		local listing = sup.auctions[id] or EMPTY
		local cheapest = vendor_buy(id) or INF
		if owned > 0 then
			cheapest = min(cheapest, vendor_sell(id) or 0)
		end
		local first = first_open(listing)
		if first then
			cheapest = min(cheapest, first.b / first.c)
		end
		if cheapest == INF then
			return nil, 'no ' .. (reagent.name or item_name(id)) .. ' on the auction house'
		end
		parts[i] = {id = id, q = reagent.count, name = reagent.name, owned = owned, listing = listing, cheapest = cheapest}
		min_cost = min_cost + cheapest * reagent.count
	end
	if revenue - min_cost < 1 then
		return nil, 'even the cheapest mats cost more than the vendor pays'
	end

	-- A unit priced above `cap` makes a craft lose money even when every
	-- other reagent comes at its cheapest, so pricier auctions are ignored.
	local ctxs, nmax, limited = {}, settings.max_crafts, false
	for i = 1, getn(parts) do
		local p = parts[i]
		local cap = (revenue - (min_cost - p.cheapest * p.q)) / p.q
		local ctx = make_ctx(p.id, p.q, p.owned, p.listing, cap)
		ctx.name = p.name
		ctxs[i] = ctx
		if not ctx.u then
			nmax = min(nmax, floor((ctx.owned + ctx.ah_units) / ctx.q))
			limited = true
		end
	end
	if recipe.cooldown then
		nmax = min(nmax, 1)
	end
	if nmax < 1 then
		return nil, 'not enough cheap mats for one craft'
	end
	for i = 1, getn(ctxs) do
		prepare(ctxs[i], max(0, nmax * ctxs[i].q - ctxs[i].owned))
	end

	local best_n, best_profit, profits, broke = 0, 0, {}, false
	for n = 1, nmax do
		local cost, cash = 0, 0
		for i = 1, getn(ctxs) do
			local c, k = cover(ctxs[i], n * ctxs[i].q)
			if not c then
				cost = nil
				break
			end
			cost, cash = cost + c, cash + k
		end
		if not cost then break end
		if cash > sup.budget then
			broke = true
			break
		end
		local profit = n * revenue - cost
		profits[n] = profit
		if profit > best_profit then
			best_n, best_profit = n, profit
		end
		spend(getn(ctxs) * 4)
	end
	if best_n == 0 then
		if broke and not profits[1] then
			return nil, 'not enough gold for one craft'
		end
		return nil, 'no quantity makes a profit'
	end

	local plan = {
		name = name,
		recipe = recipe,
		product = recipe.product,
		value = value,
		verified = verified,
		yield = yield,
		crafts = best_n,
		unlimited = not limited and best_n == nmax,
		revenue = best_n * revenue,
		cash = 0,
		ah_cash = 0,
		vendor_cash = 0,
		leftover = 0,
		reagents = {},
	}
	local net_total = 0
	for i = 1, getn(ctxs) do
		local ctx = ctxs[i]
		local need = best_n * ctx.q
		local net, cash, picks, owned_used, vendor_units, leftover = cover(ctx, need, true)
		local ah_units, max_unit = 0, 0
		for _, auction in ipairs(picks) do
			ah_units = ah_units + auction.c
			max_unit = max(max_unit, auction.b / auction.c)
		end
		local vendor_cash = vendor_units * (ctx.u or 0)
		tinsert(plan.reagents, {
			id = ctx.id,
			name = ctx.name or item_name(ctx.id),
			q = ctx.q,
			need = need,
			owned = owned_used,
			vendor = vendor_units,
			vendor_price = ctx.u,
			picks = picks,
			ah_units = ah_units,
			ah_cash = cash - vendor_cash,
			max_unit = max_unit,
			leftover = leftover,
			net = net,
			salvage = ctx.s,
		})
		net_total = net_total + net
		plan.cash = plan.cash + cash
		plan.ah_cash = plan.ah_cash + cash - vendor_cash
		plan.vendor_cash = plan.vendor_cash + vendor_cash
		plan.leftover = plan.leftover + leftover
	end
	plan.profit = plan.revenue - net_total
	if profits[best_n + 1] then
		plan.next_delta = profits[best_n + 1] - best_profit
	end
	return plan
end

-- `market_only` ignores your own mats and gold: supply is the AH and vendors.
function build_supply(recipes, market_only)
	local ids = {}
	for _, recipe in recipes do
		for _, reagent in recipe.reagents do
			local id = reagent_id(reagent)
			if id then ids[id] = true end
		end
	end
	local mine, alts, source = owned_snapshot()
	local mail = mail_counts()
	local owned = {}
	if settings.use_owned and not market_only then
		for id in ids do
			owned[id] = (mine[id] or 0) + (mail[id] or 0)
		end
	end
	load_book()
	local auctions = {}
	for id in ids do
		local list = book_items[id]
		if list then
			local copy = {}
			for i = 1, getn(list) do
				copy[i] = {c = list[i].c, b = list[i].b}
			end
			auctions[id] = copy
		end
	end
	return {
		owned = owned,
		auctions = auctions,
		budget = market_only and INF or max(0, GetMoney() - settings.gold_reserve),
		mine = mine,
		alts = alts,
		mail = mail,
		owned_source = source,
	}
end

function commit(plan, sup)
	for _, reagent in plan.reagents do
		for _, auction in reagent.picks do
			auction.taken = true
		end
		if sup.owned[reagent.id] then
			sup.owned[reagent.id] = sup.owned[reagent.id] - reagent.owned
		end
	end
	sup.budget = sup.budget - plan.cash
end

function shares_reagent(a, b)
	for _, x in a.reagents do
		for _, y in b.reagents do
			if x.id == y.id then return true end
		end
	end
end

-- Take the most profitable recipe, reserve its auctions and mats, and repeat
-- with what is left, so recipes that share a reagent are not double counted.
function plan_all()
	local recipes = character.recipes
	local sup = build_supply(recipes)
	local names = {}
	for name in recipes do
		tinsert(names, name)
	end
	sort(names)
	local total = getn(names)
	local plans, skipped, current = {}, {}, {}

	for i = 1, total do
		local name = names[i]
		set_status(i / total, format('Checking recipes %d / %d', i, total))
		local plan, why = eval_recipe(name, recipes[name], sup)
		if plan and plan.profit >= settings.min_profit then
			current[name] = plan
		elseif plan then
			skipped[name] = 'best profit ' .. money_text(plan.profit) .. ' is below your minimum profit'
		else
			skipped[name] = why
		end
		spend(50)
	end

	while true do
		local best
		for _, plan in current do
			if not best or plan.profit > best.profit or plan.profit == best.profit and plan.name < best.name then
				best = plan
			end
		end
		if not best then break end
		current[best.name] = nil
		commit(best, sup)
		tinsert(plans, best)
		-- Only recipes that compete for the same mats, or that the remaining
		-- gold no longer covers, need a second look.
		for name, plan in current do
			if shares_reagent(plan, best) or plan.cash > sup.budget then
				local again, why = eval_recipe(name, recipes[name], sup)
				if again and again.profit >= settings.min_profit then
					current[name] = again
				else
					current[name] = nil
					skipped[name] = again and 'what is left after better crafts is below your minimum profit' or why
				end
			end
		end
	end
	return plans, skipped, sup, total
end

function plan_everything()
	local plans, skipped, sup, total = plan_all()
	local other, other_sup, other_total, other_unpriced = discover_all()
	return {
		plans = plans, skipped = skipped, sup = sup, total = total,
		other = other, other_sup = other_sup, other_total = other_total, other_unpriced = other_unpriced,
	}
end

function request_plan()
	plan_requested = true
end

function busy()
	return scanning or buying or plan_co
end

function summarize(run)
	local profit, cash = 0, 0
	for _, plan in run.plans do
		profit, cash = profit + plan.profit, cash + plan.cash
	end
	if getn(run.plans) > 0 then
		summary_mine = format('%d profitable crafts: profit %s for %s of mats', getn(run.plans), money_text(profit), money_text(cash))
	elseif run.total == 0 then
		summary_mine = 'No recipes yet - open each profession window once'
	else
		summary_mine = format('No profitable crafts in %d recipes - /vcraft why <name>', run.total)
	end
	unpriced_other = run.other_unpriced or 0
	if not run.other then
		summary_other = 'Enable the CraftTree addon for the recipe database'
	elseif unpriced_other > 0 then
		summary_other = format('%d profitable, %d unpriced', getn(run.other), unpriced_other)
	elseif getn(run.other) > 0 then
		summary_other = format('%d recipes you do not know could make a profit', getn(run.other))
	else
		summary_other = format('None of %d recipes you do not know make a profit', run.other_total or 0)
	end
end

function view_summary()
	if view == 'other' then return summary_other end
	return summary_mine
end

on_tick(function()
	if plan_requested and not plan_co and not buying and db then
		plan_requested, plan_stale = false, false
		plan_co = coroutine.create(plan_everything)
	end
	if not plan_co then return end
	planner_running = true
	local ok, run = coroutine.resume(plan_co)
	planner_running = false
	if not ok then
		plan_co = nil
		set_status(1, 'Planning failed - see chat')
		say('Planning failed: ' .. tostring(run))
	elseif coroutine.status(plan_co) == 'dead' then
		plan_co = nil
		results, last_skipped, last_supply = run.plans, run.skipped, run.sup
		other_results, other_supply = run.other, run.other_sup
		results_dirty = true
		summarize(run)
		set_status(1, view_summary())
	end
end)
