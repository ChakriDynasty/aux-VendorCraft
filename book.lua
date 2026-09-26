module 'aux.tabs.vendorcraft'

local aux = require 'aux'
local scan = require 'aux.core.scan'

-- book_items[item_id] = list of {c = stack size, b = buyout}, cheapest per unit first.

function book_key()
	return (GetCVar('realmName') or '?') .. '|' .. (UnitFactionGroup('player') or '?')
end

function stored_book()
	local key = book_key()
	db.books[key] = db.books[key] or {items = {}}
	return db.books[key]
end

function sort_listing(list)
	sort(list, function(x, y)
		local ux, uy = x.b / x.c, y.b / y.c
		if ux ~= uy then return ux < uy end
		return x.c < y.c
	end)
end

function load_book()
	if book_items then return end
	local stored = stored_book()
	book_items = {}
	book_meta = {
		scanned = stored.scanned,
		partial = stored.partial,
		auctions = stored.auctions or 0,
		next_page = stored.next_page,
		total_pages = stored.total_pages,
	}
	for id, packed in stored.items or EMPTY do
		local list = {}
		for c, b in string.gfind(packed, '(%d+):(%d+)') do
			tinsert(list, {c = tonumber(c), b = tonumber(b)})
		end
		book_items[tonumber(id) or id] = list
	end
end

function save_book()
	local stored = stored_book()
	local items = {}
	for id, list in book_items do
		local parts = {}
		for i = 1, getn(list) do
			tinsert(parts, list[i].c .. ':' .. list[i].b)
		end
		if getn(parts) > 0 then
			items[id] = table.concat(parts, ';')
		end
	end
	stored.items = items
	stored.scanned = book_meta.scanned
	stored.partial = book_meta.partial
	stored.auctions = book_meta.auctions
	stored.next_page = book_meta.next_page
	stored.total_pages = book_meta.total_pages
end

function clear_book()
	db.books[book_key()] = nil
	book_items = nil
	load_book()
end

function book_listing(id)
	load_book()
	return book_items[id] or EMPTY
end

function replace_listing(id, list)
	load_book()
	sort_listing(list)
	book_items[id] = list
end

function remove_auction(id, count, buyout)
	local list = book_items and book_items[id]
	if not list then return end
	for i = 1, getn(list) do
		if list[i].c == count and list[i].b == buyout then
			tremove(list, i)
			return
		end
	end
end

function stop_scan()
	if scan_id then
		scan.abort(scan_id)
	end
end

function start_scan(resume)
	if scanning or buying then return end
	load_book()
	local first_page = 0
	if resume and book_meta.partial and book_meta.next_page then
		first_page = book_meta.next_page
	else
		book_items = {}
		book_meta = {scanned = time(), partial = true, auctions = 0}
	end

	scanning = true
	local me = UnitName('player')
	local started = GetTime()
	local page_index, pages_done = first_page, 0

	local function add_auction(record)
		if record.buyout_price <= 0 or record.suffix_id ~= 0 then return end
		if record.owner and record.owner == me then return end
		local list = book_items[record.item_id]
		if not list then
			list = {}
			book_items[record.item_id] = list
		end
		tinsert(list, {c = record.count, b = record.buyout_price})
		book_meta.auctions = book_meta.auctions + 1
	end

	scan_id = scan.start{
		type = 'list',
		ignore_owner = true,
		-- Empty strings rather than nil, as the stock browse UI sends; some
		-- servers ignore queries with nil in the text slots.
		queries = {{blizzard_query = {name = '', min_level = '', max_level = '', first_page = first_page}}},
		on_scan_start = function()
			set_status(0, first_page > 0 and 'Resuming scan...' or 'Starting auction house scan...')
		end,
		on_page_loaded = function(page, _, last_page)
			page_index = first_page + page - 1
			book_meta.total_pages = last_page + 1
			local text = format('Scanning page %d / %d', page_index + 1, book_meta.total_pages)
			if pages_done > 0 then
				local left = (GetTime() - started) / pages_done * (book_meta.total_pages - page_index)
				text = text .. format(' - about %d min left', ceil(left / 60))
			end
			set_status(page_index / max(1, book_meta.total_pages), text)
		end,
		on_page_scanned = function()
			pages_done = pages_done + 1
			book_meta.next_page = page_index + 1
		end,
		on_auction = add_auction,
		on_complete = function() finish_scan(true) end,
		on_abort = function() finish_scan(false) end,
	}
end

function finish_scan(complete)
	scanning = false
	scan_id = nil
	if complete then
		book_meta.partial = nil
		book_meta.next_page = nil
	end
	for _, list in book_items do
		sort_listing(list)
	end
	save_book()
	if complete then
		set_status(1, format('Scan complete: %d auctions with a buyout', book_meta.auctions))
	else
		set_status(1, format('Scan stopped at page %d of %d - press Resume to continue', (book_meta.next_page or 0) + 1, book_meta.total_pages or 0))
	end
	request_plan()
end
