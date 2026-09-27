module 'aux.tabs.vendorcraft'

local aux = require 'aux'

-- Recipes this character does not know, from Atlas-CFM. Each is scored on
-- its own against the auction house alone. CraftTree is not a recipe source.

function craft_database_loaded()
	return atlas_available()
end

-- Atlas-CFM (the Turtle WoW loot database) keeps the current reagent lists.
function atlas_available()
	local cfm = _G.AtlasCFM
	return cfm and cfm.SpellDB and cfm.SpellDB.craftspells and true
end

-- Longer prefixes first, so "Dragonscale" is not read as plain leatherworking.
PROFESSION_PREFIXES = {
	{'Dragonscale', 'Dragonscale Leatherworking'},
	{'Elemental', 'Elemental Leatherworking'},
	{'Tribal', 'Tribal Leatherworking'},
	{'Leather', 'Leatherworking'},
	{'Armorsmith', 'Blacksmithing: Armorsmith'},
	{'Weaponsmith', 'Blacksmithing: Weaponsmith'},
	{'Axesmith', 'Blacksmithing: Master Axesmith'},
	{'Hammersmith', 'Blacksmithing: Master Hammersmith'},
	{'Swordsmith', 'Blacksmithing: Master Swordsmith'},
	{'Smithing', 'Blacksmithing'},
	{'Goblin', 'Goblin Engineering'},
	{'Gnomish', 'Gnomish Engineering'},
	{'Engineering', 'Engineering'},
	{'Goldsmith', 'Jewelcrafting: Goldsmithing'},
	{'Gemology', 'Jewelcrafting: Gemology'},
	{'Jewelcrafting', 'Jewelcrafting'},
	{'FirstAid', 'First Aid'},
	{'Smelting', 'Smelting'},
	{'Mining', 'Mining'},
	{'Tailoring', 'Tailoring'},
	{'Alchemy', 'Alchemy'},
	{'Enchanting', 'Enchanting'},
	{'Cooking', 'Cooking'},
	{'Survival', 'Survival'},
	{'Poison', 'Poisons'},
}

function profession_of(table_key)
	for _, row in PROFESSION_PREFIXES do
		if strfind(table_key, '^' .. row[1]) then return row[2] end
	end
end

function turtle_row(row)
	if not row.servers then return end
	for _, server in row.servers do
		if server and strfind(server, 'Turtle') then return true end
	end
end

-- spell id -> {prof, skill, yield} from Atlas-CFM's crafting lists.
function atlas_spell_info()
	local info, data = {}, _G.AtlasCFMLoot_Data or EMPTY
	local function add(row, prof, override)
		if not row.id or not prof then return end
		if info[row.id] and not override then return end
		local skill = row.skill
		if type(skill) == 'table' then skill = skill[1] end
		info[row.id] = {prof = prof, skill = skill, yield = row.quantity or (info[row.id] and info[row.id].yield) or 1}
	end
	for key, rows in data do
		local prof = profession_of(key)
		if prof and type(rows) == 'table' then
			for _, row in rows do
				if type(row) == 'table' and row.id and not turtle_row(row) then
					add(row, prof)
				end
			end
		end
	end
	for key, rows in data do
		local prof = profession_of(key)
		if prof and type(rows) == 'table' then
			for _, row in rows do
				if type(row) == 'table' and row.id and turtle_row(row) then
					add(row, prof, true)
				end
			end
		end
	end
	return info
end

function fold_name(s)
	s = strlower(s or '')
	s = gsub(s, '^pattern: ', '')
	s = gsub(s, '^plans: ', '')
	s = gsub(s, '^recipe: ', '')
	s = gsub(s, '^formula: ', '')
	s = gsub(s, '^schematic: ', '')
	s = gsub(s, '^manual: ', '')
	return s
end

function names_equal(a, b)
	return a and b and fold_name(a) == fold_name(b)
end

function is_process(name)
	local s = fold_name(name)
	return strfind(s, '^smelt ') or strfind(s, '^transmute') or strfind(s, 'reloaded') or strfind(s, '^create ')
end

function cached_item_id(name)
	local ids = aux.account_data and aux.account_data.item_ids
	return name and ids and ids[strlower(name)]
end

function spell_title(spell, data)
	if type(data.name) == 'string' and data.name ~= '' then
		return data.name
	end
	return SPELL_NAMES and SPELL_NAMES[spell]
end

-- Atlas-CFM reuses some item ids (Scroll of Thorns is stored as the same
-- id as Dragonscale Leggings). Keep a recipe only when the spell name
-- matches the item, or when it is a known process for that item (smelt,
-- transmute). Otherwise try aux's name cache, then skip.
function pick_product(title, item, owners)
	local seen = item and item_name(item)
	local loaded = seen and not strfind(seen, '^item:')
	if item and not loaded and queue_item_load then
		queue_item_load(item)
	end
	if title and loaded and names_equal(title, seen) then
		return item, title
	end
	if title then
		local by_name = cached_item_id(title)
		if by_name then
			return by_name, title
		end
	end
	if item and owners[item] and owners[item] > 1 then
		if is_process(title) then
			return item, title or seen
		end
		return
	end
	if item then
		return item, title or seen
	end
end

function reset_atlas_cache()
	atlas_recipes = nil
end

-- The whole database, keyed like unknown_recipes. Nil when Atlas-CFM is absent.
function atlas_recipe_list()
	if atlas_recipes then return atlas_recipes end
	if not atlas_available() then return end
	local info = atlas_spell_info()
	local rows, owners = {}, {}
	for spell, data in _G.AtlasCFM.SpellDB.craftspells do
		local raw = data.reagents_TURTLE1 or data.reagents_TURTLE or data.reagents
		if data.item and raw and getn(raw) > 0 then
			tinsert(rows, {spell = spell, data = data, raw = raw, title = spell_title(spell, data)})
			owners[data.item] = (owners[data.item] or 0) + 1
		end
	end
	local recipes = {}
	for i = 1, getn(rows) do
		local row = rows[i]
		local product, name = pick_product(row.title, row.data.item, owners)
		if name and product and not strfind(name, '^Enchant ') then
			local reagents = {}
			for _, pair in row.raw do
				if pair[1] then
					tinsert(reagents, {id = pair[1], count = pair[2] or 1})
				end
			end
			if getn(reagents) > 0 then
				local about = info[row.spell] or EMPTY
				recipes[name .. '#' .. row.spell] = {
					name = name,
					product = product,
					made = max(1, about.yield or 1),
					reagents = reagents,
					prof = about.prof,
					skill = about.skill,
					cooldown = has_cooldown(name) or nil,
				}
			end
		end
	end
	atlas_recipes = recipes
	return recipes
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
	local atlas = atlas_recipe_list()
	if not atlas then return end
	local known_products, known_names = {}, {}
	for name, recipe in character.recipes do
		known_names[name] = true
		if recipe.product then known_products[recipe.product] = true end
	end
	local recipes = {}
	for key, recipe in atlas do
		if not known_products[recipe.product] and not known_names[recipe.name] then
			recipes[key] = recipe
		end
	end
	return recipes
end

function discover_all()
	local recipes = unknown_recipes()
	if not recipes then return end
	local sup = build_supply(recipes, true, true)
	local crafters = alt_crafters()
	local total, done = 0, 0
	for _ in recipes do
		total = total + 1
	end
	-- outcome[key] = {profession, category, missing reagent id}; sources
	-- counts where each product's vendor price came from (for /vcraft stats).
	local plans, unpriced, outcome, sources = {}, 0, {}, {}
	for key, recipe in recipes do
		done = done + 1
		if math.mod(done, 25) == 0 then
			set_status(done / total, format('Checking recipes you do not know %d / %d', done, total))
		end
		local _, _, source = vendor_sell(recipe.product)
		sources[source or 'none'] = (sources[source or 'none'] or 0) + 1
		local plan, _, category, missing = eval_recipe(recipe.name, recipe, sup)
		if plan and plan.profit >= settings.min_profit then
			plan.discovered = true
			plan.alt = crafters[recipe.product]
			tinsert(plans, plan)
			outcome[key] = {recipe.prof, 'ok'}
		else
			outcome[key] = {recipe.prof, plan and 'loss' or category, missing}
			if category == 'price' then
				unpriced = unpriced + 1
			end
		end
		spend(20)
	end
	sort(plans, function(x, y)
		if x.profit ~= y.profit then return x.profit > y.profit end
		return x.name < y.name
	end)
	return plans, sup, total, unpriced, outcome, sources
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

function report_outcomes(title, outcomes)
	local by_prof, missing = {}, {}
	for _, outcome in outcomes or EMPTY do
		local prof = outcome[1] and gsub(outcome[1], ':.*$', '') or 'Unknown profession'
		local row = by_prof[prof]
		if not row then
			row = {total = 0}
			by_prof[prof] = row
		end
		row.total = row.total + 1
		row[outcome[2]] = (row[outcome[2]] or 0) + 1
		if outcome[3] then
			missing[outcome[3]] = (missing[outcome[3]] or 0) + 1
		end
	end
	local profs = {}
	for prof in by_prof do
		tinsert(profs, prof)
	end
	sort(profs)
	say(title .. ':')
	if getn(profs) == 0 then
		say('   none')
	end
	for _, prof in ipairs(profs) do
		local row = by_prof[prof]
		local other = (row.novendor or 0) + (row.gold or 0) + (row.unknown or 0)
		say(format('   %s (%d): %d / %d / %d / %d / %d', prof, row.total, row.ok or 0, row.price or 0, row.mats or 0, row.loss or 0, other))
	end
	local list = {}
	for id, n in missing do
		tinsert(list, {id = id, n = n})
	end
	sort(list, function(x, y) return x.n > y.n end)
	if getn(list) > 0 then
		local parts = {}
		for i = 1, min(8, getn(list)) do
			tinsert(parts, item_name(list[i].id) .. ' (' .. list[i].n .. ')')
		end
		say('   Mats most often missing from the AH: ' .. table.concat(parts, ', '))
	end
end

function stats_report()
	local run = last_run
	if not run then
		say('No plan yet. Open the Vendor tab at the auction house first.')
		return
	end
	if classic_api() then
		local loading = items_loading()
		say('Vendor prices: exact, from the game (ClassicAPI)' .. (loading > 0 and format('; %d items still loading', loading) or '') .. '.')
	else
		local tables = pfui_turtle_prices() and 'pfUI Turtle table' or 'pfUI vanilla table'
		if _G.ShaguTweaks and _G.ShaguTweaks.SellValueDB then
			tables = tables .. ', ShaguTweaks'
		end
		say('Vendor prices: from price tables (' .. tables .. ') and what aux learned at merchants. Install ClassicAPI for exact prices of every item.')
	end
	if run.sources then
		local parts = {}
		for source, n in run.sources do
			tinsert(parts, n .. ' ' .. source)
		end
		sort(parts)
		say('Where the database products\' vendor prices came from: ' .. table.concat(parts, ', ') .. '.')
	end
	local meta = book_meta or EMPTY
	if meta.scanned then
		local partial = meta.partial and format(', partial: stopped at page %d of %d', (meta.next_page or 0) + 1, meta.total_pages or 0) or ''
		say(format('Auction house scan: %d auctions, %s%s.', meta.auctions or 0, format_age(meta.scanned), partial))
	else
		say('No auction house scan yet.')
	end
	say('Per profession: profitable / no vendor price / a mat missing from the AH / not profitable / other')
	report_outcomes('Your recipes', run.outcome)
	report_outcomes('Recipes you do not know', run.other_outcome)
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
