module 'aux.tabs.vendorcraft'

local aux = require 'aux'

-- Craft trees: a reagent that can itself be crafted (bolts from cloth, bars
-- from ore) is supplied by the AH, a vendor, your bags, or by crafting it,
-- whichever is cheapest, down to MAX_DEPTH levels.

MAX_DEPTH = 3

-- Leather upgrades (4 Light -> Medium, 5 Medium -> Heavy, ...) turn one
-- Heavy Leather into dozens of Light Leather. Treat the leather you need
-- as a base mat; do not craft it from a lower grade.
LEATHER_GRADES = {
	[2934] = true, -- Ruined Leather Scraps
	[2318] = true, -- Light Leather
	[2319] = true, -- Medium Leather
	[4234] = true, -- Heavy Leather
	[4304] = true, -- Thick Leather
	[8170] = true, -- Rugged Leather
}

function is_leather_grade(id)
	return id and LEATHER_GRADES[id]
end

-- Item id -> {name, recipe, known} for every recipe that can make it.
-- Known recipes win over database ones; cooldown recipes and leather-grade
-- upgrades are never used as a step in a tree.
function store_maker(makers, name, recipe, known)
	if not recipe or not recipe.product or not recipe_makes_item(name, recipe.product) then return end
	local reagents, yield = craft_reagents(name, recipe.product)
	if reagents then
		local copy = {
			product = recipe.product,
			reagents = reagents,
			made = yield or recipe.made,
			prof = recipe.prof,
			skill = recipe.skill,
			spell = recipe.spell,
			name = name,
		}
		recipe = copy
	end
	local old = makers[recipe.product]
	if old and old.known and not known then return end
	makers[recipe.product] = {name = name, recipe = recipe, known = known}
end

function build_makers(allow_database)
	local makers = {}
	-- Only CraftTree smelts and bolts. A learned recipe whose item link was
	-- wrong used to replace the real bar or bolt and pull in unrelated mats.
	local db = _G.CraftTreeDB
	if db then
		for itemId, rows in db do
			if type(itemId) == 'number' and not is_leather_grade(itemId) then
				for i = 1, getn(rows) do
					local row = rows[i]
					local folded = fold_name(row.name)
					if row.reagents and getn(row.reagents) > 0 and (strfind(folded, 'smelt ') or strfind(folded, '^bolt of ')) then
						local reagents = {}
						for j = 1, getn(row.reagents) do
							tinsert(reagents, {id = row.reagents[j][1], count = row.reagents[j][2] or 1})
						end
						makers[itemId] = {
							name = row.name,
							known = character.recipes[row.name] and true or false,
							recipe = {
								product = itemId,
								reagents = reagents,
								made = row.yield or 1,
								name = row.name,
								spell = row.spell,
							},
						}
					end
				end
			end
		end
		return makers
	end
	if allow_database then
		for _, recipe in unknown_recipes() or EMPTY do
			store_maker(makers, recipe.name, recipe, false)
		end
	end
	return makers
end

-- Lower bound on what one unit can cost, crafting included. `path` holds the
-- items being crafted above this one, so a conversion loop cannot recurse.
function cheapest_unit(sup, id, depth, path)
	if depth == 0 and sup.cheap[id] then return sup.cheap[id] end
	local best = vendor_buy(id) or INF
	if (sup.owned[id] or 0) > 0 then
		best = min(best, vendor_sell(id) or 0)
	end
	local first = first_open(sup.auctions[id] or EMPTY)
	if first then
		best = min(best, first.b / first.c)
	end
	local maker = sup.makers[id]
	if maker and depth < MAX_DEPTH and not path[id] then
		path[id] = true
		local sum = 0
		for _, reagent in maker.recipe.reagents do
			local rid = reagent_id(reagent)
			sum = sum + (rid and cheapest_unit(sup, rid, depth + 1, path) or INF) * reagent.count
			if sum == INF then break end
		end
		path[id] = nil
		best = min(best, sum / (maker.recipe.made or 1))
	end
	if depth == 0 then sup.cheap[id] = best end
	return best
end

-- Crafting as extra supply for item `id`: one listing per craft batch,
-- priced at the marginal cost of that batch. Marginal costs come from the
-- lower convex envelope of "cost of n batches", so they only rise and a
-- knapsack takes batches in order.
function craft_listings(sup, id, max_units, depth, path)
	local maker = sup.makers[id]
	if not maker or depth >= MAX_DEPTH or path[id] or max_units <= 0 then return EMPTY end
	local key = id .. ':' .. depth
	local cached = sup.craft_cache[key]
	if cached and cached.max_units >= max_units then return cached.list end

	local recipe = maker.recipe
	local yield = recipe.made or 1
	local batches = ceil(max_units / yield)
	local ctxs = {}
	path[id] = true
	for _, reagent in recipe.reagents do
		local rid = reagent_id(reagent)
		if not rid then
			path[id] = nil
			return EMPTY
		end
		local listing = merged_listing(sup, rid, batches * reagent.count, depth + 1, path)
		local ctx = make_ctx(rid, reagent.count, sup.owned[rid] or 0, listing, nil)
		prepare(ctx, max(0, batches * reagent.count - ctx.owned))
		tinsert(ctxs, ctx)
	end
	path[id] = nil

	local costs, possible = {[0] = 0}, 0
	for n = 1, batches do
		local total = 0
		for i = 1, getn(ctxs) do
			local c = cover(ctxs[i], n * ctxs[i].q)
			if not c then
				total = nil
				break
			end
			total = total + c
		end
		if not total then break end
		costs[n], possible = total, n
		spend(getn(ctxs) * 4)
	end

	local hull = {0}
	for n = 1, possible do
		while getn(hull) >= 2 do
			local a, b = hull[getn(hull) - 1], hull[getn(hull)]
			if (costs[b] - costs[a]) * (n - a) >= (costs[n] - costs[a]) * (b - a) then
				tremove(hull)
			else
				break
			end
		end
		tinsert(hull, n)
	end
	local list = {}
	for k = 2, getn(hull) do
		local a, b = hull[k - 1], hull[k]
		local batch_cost = (costs[b] - costs[a]) / (b - a)
		for _ = a + 1, b do
			tinsert(list, {c = yield, b = batch_cost, virtual = true, craft = maker})
		end
	end
	if not resolving then
		sup.craft_cache[key] = {max_units = max_units, list = list}
	end
	return list
end

-- The AH listing of `id` merged, cheapest per unit first, with its craft batches.
function merged_listing(sup, id, max_units, depth, path)
	local real = sup.auctions[id] or EMPTY
	local crafted = craft_listings(sup, id, max_units, depth, path)
	if getn(crafted) == 0 then return real end
	local out, i, j, nr, nc = {}, 1, 1, getn(real), getn(crafted)
	while i <= nr or j <= nc do
		if j > nc or i <= nr and real[i].b / real[i].c <= crafted[j].b / crafted[j].c then
			tinsert(out, real[i])
			i = i + 1
		else
			tinsert(out, crafted[j])
			j = j + 1
		end
	end
	return out
end

-- Decides how `need` units of `id` are supplied and returns a reagent entry;
-- crafted units get a `craft` sub-tree. Chosen auctions and owned units are
-- reserved (and recorded in `log`) so later branches cannot reuse them.
function resolve(sup, id, q, need, depth, path, log, name, cap)
	local listing = merged_listing(sup, id, need, depth, path)
	-- Spare units bought for another step of this plan are used first; they
	-- are valued like owned mats, which cancels the credit that step took.
	local surplus = sup.surplus[id] or 0
	local ctx = make_ctx(id, q, (sup.owned[id] or 0) + surplus, listing, cap)
	local _, _, picks, owned_used, vendor_units, leftover = cover(ctx, need, true)
	if not picks then return end
	local reused = min(owned_used, surplus)
	local entry = {
		id = id,
		name = name or item_name(id),
		q = q,
		need = need,
		owned = owned_used - reused,
		reused = reused,
		vendor = vendor_units,
		vendor_price = ctx.u,
		picks = {},
		ah_units = 0,
		ah_cash = 0,
		max_unit = 0,
		leftover = leftover,
		salvage = ctx.s,
	}
	if reused > 0 then
		sup.surplus[id] = surplus - reused
		tinsert(log, {surplus = id, n = -reused})
	end
	if entry.owned > 0 then
		sup.owned[id] = (sup.owned[id] or 0) - entry.owned
		tinsert(log, {id = id, owned = entry.owned})
	end
	if leftover > 0 then
		sup.surplus[id] = (sup.surplus[id] or 0) + leftover
		tinsert(log, {surplus = id, n = leftover})
	end
	local batches, maker = 0, nil
	for _, auction in ipairs(picks) do
		if auction.virtual then
			batches, maker = batches + 1, auction.craft
		else
			auction.taken = true
			tinsert(log, {auction = auction})
			tinsert(entry.picks, auction)
			entry.ah_units = entry.ah_units + auction.c
			entry.ah_cash = entry.ah_cash + auction.b
			entry.max_unit = max(entry.max_unit, auction.b / auction.c)
		end
	end
	entry.cash = entry.ah_cash + vendor_units * (ctx.u or 0)
	entry.net = (owned_used - leftover) * ctx.s + entry.cash
	if batches > 0 then
		local recipe = maker.recipe
		local subs = {}
		path[id] = true
		for _, reagent in recipe.reagents do
			local rid = reagent_id(reagent)
			local sub = rid and resolve(sup, rid, reagent.count, batches * reagent.count, depth + 1, path, log, reagent.name, nil)
			if not sub then
				path[id] = nil
				return
			end
			tinsert(subs, sub)
			entry.cash = entry.cash + sub.cash
			entry.net = entry.net + sub.net
		end
		path[id] = nil
		entry.craft = {
			name = maker.name,
			known = maker.known,
			prof = recipe.prof,
			skill = recipe.skill,
			crafts = batches,
			yield = recipe.made or 1,
			units = batches * (recipe.made or 1),
			reagents = subs,
		}
	end
	return entry
end

function undo_reservations(sup, log)
	for i = getn(log), 1, -1 do
		local change = log[i]
		if change.auction then
			change.auction.taken = nil
		elseif change.surplus then
			sup.surplus[change.surplus] = (sup.surplus[change.surplus] or 0) - change.n
		else
			sup.owned[change.id] = (sup.owned[change.id] or 0) + change.owned
		end
	end
end

-- Calls f(entry, depth) for every reagent entry in a tree, parents first.
function each_node(entries, f, depth)
	depth = depth or 0
	for _, entry in ipairs(entries) do
		f(entry, depth)
		if entry.craft then
			each_node(entry.craft.reagents, f, depth + 1)
		end
	end
end

-- Crafts to do in order: deepest intermediates first, the plan's own recipe last.
-- `n` is how many of the final recipe were actually bought for.
function craft_steps(plan, n)
	local steps = {}
	local scale = 1
	if n and plan.crafts and plan.crafts > 0 then
		scale = n / plan.crafts
	end
	local function walk(entries)
		for _, entry in ipairs(entries) do
			if entry.craft then
				walk(entry.craft.reagents)
				local crafts = entry.craft.crafts
				if scale ~= 1 then
					crafts = floor(crafts * scale + .5)
				end
				if crafts > 0 then
					tinsert(steps, {name = entry.craft.name, n = crafts, known = entry.craft.known})
				end
			end
		end
	end
	walk(plan.reagents)
	tinsert(steps, {name = plan.name, n = n or plan.crafts, yield = plan.yield, final = true, known = not plan.discovered})
	return steps
end
