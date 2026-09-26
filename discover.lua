module 'aux.tabs.vendorcraft'

local aux = require 'aux'

-- Recipes this character does not know, from CraftTree's database (AtlasLoot
-- data): each is scored on its own against the auction house alone.

function craft_database_loaded()
	return _G.CraftTreeDB ~= nil
end

-- Product id -> name of another character (on any realm) whose recipes
-- VendorCraft has read and who can make it.
function alt_crafters()
	local crafters, me = {}, char_key()
	for key, char in db.chars do
		if key ~= me then
			local _, _, name = strfind(key, '|(.+)$')
			for _, recipe in char.recipes or EMPTY do
				if recipe.product then
					crafters[recipe.product] = name or key
				end
			end
		end
	end
	return crafters
end

function unknown_recipes()
	local database = _G.CraftTreeDB
	if not database then return end
	local sources = _G.CraftTreeSources or EMPTY
	local known_products, known_names = {}, {}
	for name, recipe in character.recipes do
		known_names[name] = true
		if recipe.product then
			known_products[recipe.product] = true
		end
	end
	local recipes = {}
	for product, variants in database do
		if not known_products[product] then
			local source = sources[product]
			local _, _, skill = strfind(source and source.skill or '', '(%d+)')
			skill = tonumber(skill)
			for _, variant in variants do
				if variant.name and not known_names[variant.name] and variant.reagents and getn(variant.reagents) > 0 then
					local reagents = {}
					for _, pair in variant.reagents do
						tinsert(reagents, {id = pair[1], count = pair[2] or 1})
					end
					recipes[variant.name .. '#' .. (variant.spell or product)] = {
						name = variant.name,
						product = product,
						made = max(1, variant.yield or 1),
						reagents = reagents,
						prof = source and source.profession,
						skill = skill,
						cooldown = has_cooldown(variant.name) or nil,
					}
				end
			end
		end
	end
	return recipes
end

function discover_all()
	local recipes = unknown_recipes()
	if not recipes then return end
	local sup = build_supply(recipes, true)
	local crafters = alt_crafters()
	local total, done = 0, 0
	for _ in recipes do
		total = total + 1
	end
	local plans, unpriced = {}, 0
	for _, recipe in recipes do
		done = done + 1
		if math.mod(done, 25) == 0 then
			set_status(done / total, format('Checking recipes you do not know %d / %d', done, total))
		end
		local plan, _, no_price = eval_recipe(recipe.name, recipe, sup)
		if plan and plan.profit >= settings.min_profit then
			plan.discovered = true
			plan.alt = crafters[recipe.product]
			tinsert(plans, plan)
		elseif no_price then
			unpriced = unpriced + 1
		end
		spend(20)
	end
	sort(plans, function(x, y)
		if x.profit ~= y.profit then return x.profit > y.profit end
		return x.name < y.name
	end)
	return plans, sup, total, unpriced
end

-- Recipes (known ones first) whose crafted item has no vendor price from
-- any source, optionally filtered by recipe name or profession.
function unpriced_recipes(filter)
	filter = filter and strlower(filter) or ''
	local list = {}
	local function consider(name, recipe, known)
		if recipe.product and not vendor_sell(recipe.product) then
			local prof = recipe.prof or '?'
			if filter == '' or strfind(strlower(name), filter, 1, true) or strfind(strlower(prof), filter, 1, true) then
				tinsert(list, {name = name, prof = prof, skill = recipe.skill, product = recipe.product, known = known})
			end
		end
	end
	for name, recipe in character.recipes do
		consider(name, recipe, true)
	end
	for _, recipe in unknown_recipes() or EMPTY do
		consider(recipe.name, recipe, false)
	end
	sort(list, function(x, y)
		if x.known ~= y.known then return x.known end
		if x.prof ~= y.prof then return x.prof < y.prof end
		return (x.skill or 0) < (y.skill or 0)
	end)
	return list
end

-- How this character stands with a discovered recipe's profession.
-- Returns 'ready', 'low' (has the profession, skill too low) or 'none'.
function learn_status(plan)
	local recipe = plan.recipe
	-- The database names specializations ("Blacksmithing: Weaponsmith") and
	-- calls Mining "Smelting"; the character's list uses the skill line name.
	local base = recipe.prof and gsub(recipe.prof, ':.*$', '')
	local profession = base and (character.professions[base] or character.professions[PROFESSION_ALIASES[base] or ''])
	if not profession then return 'none' end
	if recipe.skill and (profession.rank or 0) < recipe.skill then return 'low', profession.rank end
	return 'ready', profession.rank
end
