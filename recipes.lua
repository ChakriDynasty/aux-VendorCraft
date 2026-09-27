module 'aux.tabs.vendorcraft'

local aux = require 'aux'
local info = require 'aux.util.info'

-- Recipes with a long cooldown can be crafted at most once per plan.
COOLDOWN_PATTERNS = {'^Transmute', '^Mooncloth$', '^Refined Deeprock Salt$'}

-- Trade skill windows whose title differs from the skill line name.
PROFESSION_ALIASES = {Smelting = 'Mining'}

-- Craft windows that may not have a line of their own in the skills list.
NEVER_PRUNE = {Poisons = true}

do
	local by_name, source
	-- Product id and yield for a recipe name, from Atlas-CFM only.
	function atlas_product(name)
		local list = atlas_recipe_list()
		if not list then return end
		if source ~= list then
			source, by_name = list, {}
			for _, recipe in list do
				if recipe.name and not by_name[recipe.name] then
					by_name[recipe.name] = {recipe.product, recipe.made}
				end
			end
		end
		local entry = by_name[name]
		if entry then
			return entry[1], entry[2]
		end
	end
end

function has_cooldown(name)
	for _, pattern in COOLDOWN_PATTERNS do
		if strfind(name, pattern) then return true end
	end
end

function read_recipe(index, name, color, profession)
	local product = link_id(GetTradeSkillItemLink(index))
		or info.item_id(name)
		or atlas_product(name)
	local min_made, max_made = GetTradeSkillNumMade(index)
	local reagents = {}
	local complete = product and true
	for r = 1, GetTradeSkillNumReagents(index) do
		local reagent_name, _, count = GetTradeSkillReagentInfo(index, r)
		local id = link_id(GetTradeSkillReagentItemLink(index, r))
			or (reagent_name and info.item_id(reagent_name))
		if not id or not count then
			complete = false
		end
		tinsert(reagents, {id = id, count = count or 1, name = reagent_name})
	end
	if getn(reagents) == 0 then
		return
	end
	return {
		prof = profession,
		product = product,
		made = max(1, min_made or 1),
		made_max = max_made,
		reagents = reagents,
		complete = complete or nil,
		color = color,
		tools = GetTradeSkillTools(index),
		cooldown = has_cooldown(name) or nil,
	}
end

-- Rank plus every stored recipe, so an identical profession window does not
-- start another plan.
function recipe_fingerprint(profession)
	local prof = character.professions[profession]
	local names = {}
	for name, recipe in character.recipes do
		if recipe.prof == profession then
			tinsert(names, name)
		end
	end
	sort(names)
	local parts = {tostring(prof and prof.rank or 0)}
	for i = 1, getn(names) do
		local recipe = character.recipes[names[i]]
		local bit = names[i] .. '=' .. (recipe.product or 0) .. 'x' .. (recipe.made or 1) .. ':' .. (recipe.color or '')
		local reagents = recipe.reagents or EMPTY
		for r = 1, getn(reagents) do
			local reagent = reagents[r]
			bit = bit .. ',' .. (reagent.id or 0) .. ':' .. (reagent.count or 1)
		end
		tinsert(parts, bit)
	end
	return table.concat(parts, '|')
end

function dump_trade_skill(expand)
	local profession, rank, max_rank = GetTradeSkillLine()
	if not profession or profession == 'UNKNOWN' then return end
	local n = GetNumTradeSkills()
	if not n or n == 0 then return end

	if expand then
		for i = 1, n do
			local _, kind, _, expanded = GetTradeSkillInfo(i)
			if kind == 'header' and not expanded then
				-- Same as clicking "All"; collapsed groups would hide recipes.
				ExpandTradeSkillSubClass(0)
				return true
			end
		end
	end

	local before = recipe_fingerprint(profession)
	character.professions[profession] = {rank = rank, max = max_rank, scanned = time()}
	for i = 1, n do
		local name, kind = GetTradeSkillInfo(i)
		if name and kind ~= 'header' then
			-- Recipes are merged, never removed here: a filtered or collapsed
			-- list only hides recipes, it does not unlearn them.
			local recipe = read_recipe(i, name, kind, profession)
			-- The list can shift mid-read; keep the row only when it is
			-- still this recipe, and never replace a complete one with a
			-- half-read one (that flips the fingerprint every tick).
			if recipe and GetTradeSkillInfo(i) == name then
				local old = character.recipes[name]
				if not old or recipe.complete or not old.complete then
					character.recipes[name] = recipe
				end
			end
		end
	end
	if recipe_fingerprint(profession) ~= before then
		plan_stale = true
	end
end

-- Enchanting and Poisons use the Craft API, whose links are spells rather
-- than items, so a craft counts only when its name is an item (a wand, rod,
-- oil or poison). Plain enchants cannot be sold to a vendor.
function dump_craft()
	local profession, rank, max_rank = GetCraftDisplaySkillLine()
	if not profession then return end
	local n = GetNumCrafts()
	if not n or n == 0 then return end
	local before = recipe_fingerprint(profession)
	character.professions[profession] = {rank = rank, max = max_rank, scanned = time()}
	for i = 1, n do
		local name, _, kind = GetCraftInfo(i)
		if name and kind ~= 'header' then
			local product, yield = atlas_product(name)
			product = product or info.item_id(name)
			if product then
				local reagents, complete = {}, true
				for r = 1, GetCraftNumReagents(i) do
					local reagent_name, _, count = GetCraftReagentInfo(i, r)
					local id = link_id(GetCraftReagentItemLink(i, r))
						or (reagent_name and info.item_id(reagent_name))
					if not id or not count then
						complete = false
					end
					tinsert(reagents, {id = id, count = count or 1, name = reagent_name})
				end
				if getn(reagents) > 0 then
					local old = character.recipes[name]
					if not old or complete or not old.complete then
						character.recipes[name] = {
							prof = profession,
							product = product,
							made = max(1, yield or 1),
							reagents = reagents,
							complete = complete or nil,
							color = kind,
							cooldown = has_cooldown(name) or nil,
						}
					end
				end
			end
		end
	end
	if recipe_fingerprint(profession) ~= before then
		plan_stale = true
	end
end

-- Drop professions this character no longer has.
function prune_professions()
	local n = GetNumSkillLines()
	if not n or n < 5 then return end
	local known = {}
	for i = 1, n do
		local name, is_header, is_expanded = GetSkillLineInfo(i)
		if is_header and not is_expanded then
			-- A collapsed header hides its skills, so absence proves nothing.
			return
		end
		if name and not is_header then
			known[name] = true
		end
	end
	for profession in character.professions do
		if not known[profession] and not known[PROFESSION_ALIASES[profession] or ''] and not NEVER_PRUNE[profession] then
			character.professions[profession] = nil
			for name, recipe in character.recipes do
				if recipe.prof == profession then
					character.recipes[name] = nil
				end
			end
			plan_stale = true
		end
	end
end

do
	local dump_pending, expand_pending, prune_pending, craft_pending
	function aux.handle.LOAD()
		aux.event_listener('TRADE_SKILL_SHOW', function()
			dump_pending, expand_pending = true, true
		end)
		aux.event_listener('TRADE_SKILL_UPDATE', function()
			dump_pending = true
		end)
		aux.event_listener('CRAFT_SHOW', function()
			craft_pending = true
		end)
		aux.event_listener('CRAFT_UPDATE', function()
			craft_pending = true
		end)
		aux.event_listener('SKILL_LINES_CHANGED', function()
			prune_pending = true
		end)
	end
	on_tick(function()
		if dump_pending then
			dump_pending = false
			local expanded = dump_trade_skill(expand_pending)
			expand_pending = false
			if expanded then
				dump_pending = true
			end
		end
		if craft_pending then
			craft_pending = false
			dump_craft()
		end
		if prune_pending then
			prune_pending = false
			prune_professions()
		end
	end)
end
