--[[
  Gear Preset Checker
  -------------------
  Save what you are wearing and carrying as a named preset, then see at a
  glance which items from that preset are missing. Useful before a boss trip
  or skilling session.

  Guideline notes for moderators:
    * Display only. The plugin never equips, withdraws or moves items, and
      sends no inputs, menu entries or server actions.
    * It reads only the player's own backpack and worn equipment, which the
      player can already see.
    * No permissions are requested.
]]

local PLUGIN_NAME = "Gear Preset Checker"

local helpers     = require("ui_helpers")
helpers.VERSION = "0.11.31"
local inventories = require("inventories")

-------------------------------------------------------------------------------
-- Saved presets
-------------------------------------------------------------------------------

local PRESETS_KEY = "presets"
local MAX_PRESETS = 5

--[[ Stored shape (arrays only, so PersistentDB serialises them cleanly):
  presets = {
    { name = "Vorago", worn = { {id=1, count=1}, ... }, pack = { ... } },
    ...
  }
  activeIndex = which preset is being checked (saved separately).
]]
local okLoad, loaded = pcall(function() return PersistentDB:GetStructuredData(PRESETS_KEY) end)
if not okLoad then helpers.log("[Gear Preset Checker] ERROR loading presets: " .. tostring(loaded)) end
local presets = (okLoad and loaded) or {}
-- Sanitise names from older saves.
for _, p in ipairs(presets) do if type(p) == "table" then p.name = helpers.cleanText(p.name, 24); if p.name == "" then p.name = "Preset" end end end
local okIdx, idx = pcall(function() return PersistentDB:GetInt("activeIndex") end)
local activeIndex = (okIdx and idx) or 1

local function save()
    pcall(function() PersistentDB:SetStructuredData(PRESETS_KEY, presets) end)
    pcall(function() PersistentDB:SetInt("activeIndex", activeIndex) end)
end

--- { [id] = count } -> { {id=, count=}, ... } for storage.
local function toList(map)
    local list = {}
    for objId, count in pairs(map) do
        table.insert(list, { id = objId, count = count })
    end
    return list
end

-------------------------------------------------------------------------------
-- Comparison
-------------------------------------------------------------------------------

--[[
  Work out what is missing from the active preset.
  An item counts as present if the player has enough of it anywhere
  (worn OR backpack). If it is in the backpack but should be worn, we
  report it as "not equipped" rather than missing.
  Returns: missing (list of strings), notEquipped (list), wornAvailable (bool)
]]
--- Whether a preset saves/checks the backpack. Older presets have no flag
-- and keep their previous behaviour (backpack included).
local function includesPack(preset) return preset == nil or preset.noPack ~= true end

local function compare(preset)
    local wornInv = inventories.worn()
    local worn = inventories.contents(wornInv)
    local pack = inventories.contents(inventories.backpack())

    local missing, notEquipped = {}, {}
    local bankInv = inventories.bank()
    local function miss(id, short)
        local inBank = inventories.total(bankInv, id) >= short
        table.insert(missing, { id = id, name = short > 1 and formatStr("{} x{}", inventories.objName(id), short) or inventories.objName(id), inBank = inBank, bankKnown = bankInv ~= nil })
    end

    for _, want in ipairs(preset.worn or {}) do
        local haveWorn = worn[want.id] or 0
        local havePack = pack[want.id] or 0
        if haveWorn >= want.count then
            -- fine
        elseif haveWorn + havePack >= want.count then
            table.insert(notEquipped, { id = want.id, name = inventories.objName(want.id) })
        else
            miss(want.id, want.count - haveWorn - havePack)
        end
    end

    for _, want in ipairs(includesPack(preset) and (preset.pack or {}) or {}) do
        local have = (pack[want.id] or 0)
        if have < want.count then
            miss(want.id, want.count - have)
        end
    end

    -- Worn items that are not part of the preset at all.
    local inPreset = {}
    for _, w in ipairs(preset.worn or {}) do inPreset[w.id] = true end
    if includesPack(preset) then
        for _, w in ipairs(preset.pack or {}) do inPreset[w.id] = true end
    end
    local extraWorn = {}
    for objId, _ in pairs(worn) do
        if not inPreset[objId] then table.insert(extraWorn, { id = objId, name = inventories.objName(objId) }) end
    end

    -- have/need per item for stackables and supplies (need > 1).
    local qty = {}
    for _, want in ipairs(preset.worn or {}) do
        if want.count > 1 then qty[want.id] = { have = (worn[want.id] or 0) + (pack[want.id] or 0), need = want.count } end
    end
    for _, want in ipairs(includesPack(preset) and (preset.pack or {}) or {}) do
        if want.count > 1 then qty[want.id] = { have = pack[want.id] or 0, need = want.count } end
    end
    return missing, notEquipped, wornInv ~= nil, extraWorn, inPreset, qty
end

-------------------------------------------------------------------------------
-- Share token (0.11.0): "GPC1|name|w|id*n,id*n|id*n,..." (w = 1 worn only)
-- Import sanitises everything: tags stripped, length capped, numbers only.
-------------------------------------------------------------------------------
local TOKEN_MAX = 1500
local function encodeList(list)
    local out = {}
    for _, it in ipairs(list or {}) do table.insert(out, math.floor(it.id) .. "*" .. math.floor(it.count)) end
    return table.concat(out, ",")
end
local function exportToken(p)
    local name = tostring(p.name or "Preset"):gsub("<[^>]*>", ""):gsub("[|]", ""):sub(1, 24)
    return "GPC1|" .. name .. "|" .. (includesPack(p) and "0" or "1") .. "|" .. encodeList(p.worn) .. "|" .. encodeList(includesPack(p) and p.pack or {})
end
local function decodeList(str)
    local list = {}
    for idS, nS in tostring(str or ""):gmatch("(%d+)%*(%d+)") do
        local id, n = tonumber(idS), tonumber(nS)
        if id and n and id >= 0 and id < 10000000 and n > 0 and n <= 2147483647 and #list < 60 then
            table.insert(list, { id = id, count = n })
        end
    end
    return list
end
local function importToken(raw)
    local t = tostring(raw or ""):gsub("<[^>]*>", ""):gsub("%s", "")
    if #t > TOKEN_MAX then return nil, "Token too long" end
    local name, w, worn, pack = t:match("^GPC1|([^|]*)|([01])|([%d%*,]*)|([%d%*,]*)$")
    if name == nil then return nil, "Not a Gear Preset token" end
    name = name:gsub("[^%w %-%_%'%(%)]", ""):sub(1, 24)
    if name == "" then name = "Imported" end
    local p = { name = name, noPack = w == "1", worn = decodeList(worn), pack = decodeList(pack) }
    if #p.worn + #p.pack == 0 then return nil, "Token has no items" end
    return p
end

-------------------------------------------------------------------------------
-- Backpack mirror (display only)
--
-- The API does not document the backpack interface's slot components, so we
-- can't safely draw on top of the real backpack. Instead the panel shows a
-- read-only 4x7 copy of the backpack, using the game's own item icons
-- (ui.Sprite:SetAssociatedObject). Items that belong to the selected preset
-- get a green frame; others are dimmed. No clicks, menus or click zones of
-- the real backpack are touched.
-------------------------------------------------------------------------------

local H = helpers
local CELL, ICON, BADGE = 28, 24, 11     -- grid cell, item sprite, status badge (set by icon size)
local SIZES = { { 22, 18, 9 }, { 28, 24, 11 }, { 36, 32, 13 } }
local view = { onlyMissing = false, iconSize = 2, amber = true, equippedOnly = false }
pcall(function()
    local v = PersistentDB:GetStructuredData("gear_view")
    if type(v) == "table" then for k, x in pairs(v) do view[k] = x end end
end)
local function saveView() pcall(function() PersistentDB:SetStructuredData("gear_view", view) end) end
local settingsUI = nil
local GRID_ROWS = 2
local MAX_CELLS = 60
helpers.freeHeight = true   -- 0.11.12: drag height sets grid rows
helpers.minGripW = 160
local headerText, summaryText, noteText, moreText = nil, nil, nil, nil
local ddHandle = nil   -- 0.11.27: preset / summary column border (helpers.columns)
local presetDD = nil   -- 0.11.26: preset picker dropdown (was Prev / Next)
local moreBtn = nil
local cells = {}       -- i -> { item = Sprite, badge = Sprite }
local editParts = {}
local tokenParts = {}
local tokenField = nil
local panelRoot = nil
local okEdit, editV = pcall(function() return PersistentDB:GetInt("editOpen") end)
local editOpen = okEdit and editV == 1

-- Inventory toggle: follows the shown preset; used for the next Save.
local newIncludePack = true
local invBtn = nil
local function invInclude()
    local p = presets[activeIndex]
    if p ~= nil then return includesPack(p) end
    return newIncludePack
end
local function invLabel() return invInclude() and "Inv: On" or "Inv: Off" end

local BADGE_RES = { missing = "st_missing", bank = "st_warn", notworn = "st_warn", ok = "st_ok" }

-- 0.11.10: the grid sets the panel width. Cells sit on a pitch of CELL + 8
-- (a slot tile behind each icon), 7 columns by default, and rows grow as
-- needed (up to MAX_CELLS) instead of a wide 2-row strip.
local DEFAULT_COLS = 7
local function pitch() return CELL + 8 end
local function gridWidth(nc)
    return 2 * H.PAD + (nc or DEFAULT_COLS) * pitch() - 8 + 4
end
local function gridCols()
    local w = gridWidth()
    pcall(function() w = panelRoot.width end)
    return math.max(1, math.min(MAX_CELLS, (w - 2 * H.PAD + 4) // pitch()))
end
local hiddenItems = {}  -- items not shown in the grid (listed in the hover box)
local gridArea = nil    -- {x, y, w, h} of the grid in panel coordinates

local hoverCell = nil   -- grid cell index under the mouse (polled)
local function refresh()
    if headerText == nil then return end
    helpers.setText(invBtn, invLabel(), "label")
    local y = H.rowY(2)
    if editOpen then
        local x = H.PAD
        for _, e in ipairs(editParts) do
            helpers.safe(function() e:SetPos(x, y); e.hidden = false end)
            pcall(function() x = x + e.width + 4 end)
        end
        y = y + H.BTN_H + 4
        x = H.PAD
        for _, e in ipairs(tokenParts) do
            helpers.safe(function() e:SetPos(x, y); e.hidden = false end)
            pcall(function() x = x + e.width + 4 end)
        end
        y = y + H.BTN_H + 4
    else
        helpers.setHidden(editParts, true)
        helpers.setHidden(tokenParts, true)
    end

    local preset = presets[activeIndex]
    local items = {}
    local summary, note = "", ""
    if preset == nil then
        helpers.setText(headerText, H.lbl("No presets saved"), "content")
        if presetDD then presetDD.hidden = true end
        if ddHandle then ddHandle:setHidden(true) end
        summary = H.lbl(editOpen and "Gear up, type a name and press Save." or "Press Edit to save your current gear.")
    else
        local missing, notEquipped, wornAvailable, extraWorn, _, qty = compare(preset)
        local status = {}
        for _, m in ipairs(missing) do status[m.id] = m.inBank and "bank" or "missing" end
        for _, m in ipairs(notEquipped) do status[m.id] = status[m.id] or "notworn" end
        local seen = {}
        for _, list in ipairs({ preset.worn or {}, includesPack(preset) and (preset.pack or {}) or {} }) do
            for _, it in ipairs(list) do
                if not seen[it.id] then
                    seen[it.id] = true
                    table.insert(items, { id = it.id, st = status[it.id] or "ok", q = qty[it.id], worn = list == preset.worn })
                end
            end
        end
        -- 0.11.13 order: main hand, off hand, body, legs, head, then the
        -- other worn slots (by slot index), then inventory (saved order).
        local PRIO = { [3] = 1, [5] = 2, [4] = 3, [7] = 4, [0] = 5 }
        local live = {}
        pcall(function() live = inventories.slotsOf(inventories.worn()) end)
        for n, it in ipairs(items) do
            it.n = n
            local sl = preset.wornSlot and preset.wornSlot["i" .. it.id]
            if sl == nil then sl = live[it.id] end
            if it.worn then it.rank = sl ~= nil and (PRIO[sl] or (10 + sl)) or 99 else it.rank = 1000 end
        end
        table.sort(items, function(a, b)
            if a.rank ~= b.rank then return a.rank < b.rank end
            return a.n < b.n
        end)
        local nMissing, nBank = 0, 0
        for _, m in ipairs(missing) do if m.inBank then nBank = nBank + 1 else nMissing = nMissing + 1 end end
        local parts = {}
        if nMissing > 0 then table.insert(parts, nMissing .. " missing") end
        if nBank > 0 then table.insert(parts, nBank .. " in bank") end
        if #notEquipped > 0 then table.insert(parts, #notEquipped .. " not worn") end
        if #extraWorn > 0 then table.insert(parts, #extraWorn .. " extra worn") end
        summary = #parts == 0 and H.col(H.C_GOOD, "All items present") or H.gold(table.concat(parts, "  -  "))
        local bankKnown = inventories.bank() ~= nil
        if nBank > 0 then
            note = nBank == #missing and "Everything missing is in your bank" or (nBank .. " of " .. #missing .. " missing items are in your bank")
        elseif bankKnown and nMissing > 0 then note = "Not in your bank either"
        elseif not bankKnown and nMissing > 0 then note = "Open your bank once to check it"
        elseif not wornAvailable then note = "Worn items unreadable; backpack only" end
        helpers.safe(function()
            if presetDD then presetDD.hidden = false; presetDD:refresh() end
            if ddHandle then ddHandle:setHidden(false) end
            helpers.setText(headerText, H.lbl(formatStr("({} of {})", activeIndex, #presets))
                .. (includesPack(preset) and "" or H.lbl(" - worn only")))
        end)
    end
    helpers.safe(function() summaryText:SetPos(H.PAD, y) end)
    helpers.setText(summaryText, summary)
    y = y + H.ROW_HEIGHT
    helpers.safe(function() noteText.hidden = note == ""; noteText:SetPos(H.PAD, y) end)
    helpers.setText(noteText, H.lbl(note))
    if note ~= "" then y = y + H.ROW_HEIGHT end

    -- Compact item grid: up to 2 rows, badge in the bottom-right corner.
    CELL, ICON, BADGE = table.unpack(SIZES[view.iconSize] or SIZES[2])
    if view.onlyMissing then
        local keep = {}
        for _, it in ipairs(items) do if it.st ~= "ok" then table.insert(keep, it) end end
        items = keep
    end
    -- 0.11.11: as many icons as fit (cols from width, rows from the
    -- dragged height); if not all fit, the last slot becomes "+N".
    local nc = gridCols()
    local below = 0
    if settingsUI ~= nil and editOpen then
        pcall(function() settingsUI.open = true; below = settingsUI:place(0) end)
    end
    -- 0.11.12 rows: expanded = all items + a Less slot; while dragging (or
    -- after a drag) rows = available height / tile; default = worn items
    -- plus one slot for +N.
    local gridTop = y + 2
    local nWorn = 0
    for _, it in ipairs(items) do if it.worn then nWorn = nWorn + 1 end end
    local nr
    local eqOnly = view.equippedOnly == true and nWorn < #items
    local expanded = view.expanded and not view.equippedOnly
    if eqOnly then
        -- 0.11.14 Equipped only: worn items (slot order) then +N inventory.
        nr = math.max(1, math.ceil((nWorn + 1) / nc))
    elseif helpers.isResizing() then
        local bh = helpers.boxHeight() or 0
        nr = math.max(1, math.floor((bh - helpers.GRIP_STRIP - gridTop - below) / pitch()))
        if view.rows ~= nr or view.expanded then view.rows = nr; view.expanded = false; saveView() end
    elseif expanded then
        nr = math.max(1, math.ceil((#items + 1) / nc))
    elseif view.rows ~= nil then
        nr = view.rows
    else
        local need = nWorn < #items and nWorn + 1 or #items
        nr = math.max(1, math.ceil(math.max(1, need) / nc))
    end
    local cap = math.min(MAX_CELLS, nc * nr)
    local shown = math.min(#items, cap)
    if eqOnly then
        shown = math.min(nWorn, MAX_CELLS - 1)
    elseif expanded then
        shown = math.min(#items, MAX_CELLS - 1)
    elseif #items > cap then shown = cap - 1 end
    hiddenItems = {}
    for i = shown + 1, #items do table.insert(hiddenItems, items[i]) end
    if shown > 0 then y = y + 2 end
    for i = 1, MAX_CELLS do
        local c, it = cells[i], items[i]
        local vis = it ~= nil and i <= shown
        helpers.safe(function()
            local gx = H.PAD + 2 + ((i - 1) % nc) * pitch()
            local gy = y + 2 + ((i - 1) // nc) * pitch()
            local tsz = ICON + 6
            if c.tile then
                c.tile.hidden = not vis; c.tileEdge.hidden = not vis
                if vis then
                    c.tile:SetSize(tsz, tsz); c.tile:SetPos(gx - 3, gy - 3)
                    c.tileEdge:SetSize(tsz, tsz); c.tileEdge:SetPos(gx - 3, gy - 3)
                end
            end
            if c.item then
                c.item.hidden = not vis
                if vis then c.item:SetAssociatedObject(it.id); c.item:SetSize(ICON, ICON); c.item:SetPos(gx, gy) end
            end
            c.it = vis and it or nil
            -- Red tint on short items (cross badge stays too).
            if c.item and vis then
                local short = it.q ~= nil and it.q.have < it.q.need or it.st == "missing"
                pcall(function() c.item.colour = short and Vector4.new(1.0, 0.55, 0.50, 1.0) or Vector4.new(1, 1, 1, 1) end)
            end
            if c.qty then
                -- 0.11.1: quantity only while hovered or pinned (click the icon).
                local q = vis and it.q or nil
                local pinned = q ~= nil and preset ~= nil and preset.pinned ~= nil and preset.pinned["i" .. it.id] == true
                c.qty.hidden = q == nil or not (pinned or hoverCell == i)
                if q ~= nil then
                    local short = q.have < q.need
                    c.qty.content = helpers.col(short and H.C_BAD or H.C_VALUE, q.have .. "/" .. q.need)
                    c.qty:SetSize(CELL + 8, 12)
                    c.qty:SetPos(gx - 2, gy - 2)
                end
            end
            if c.badge then
                local amberOff = vis and not view.amber and (it.st == "bank" or it.st == "notworn")
                c.badge.hidden = (not vis) or amberOff
                pcall(function() c.badge:SetSize(BADGE, BADGE) end)
                if vis then
                    helpers.setImage(c.badge, BADGE_RES[it.st])
                    c.badge:SetPos(gx + ICON - BADGE + 2, gy + ICON - BADGE + 2)
                end
            end
        end)
    end
    local more = #items - shown
    -- +N (collapsed, overflow) or Less (expanded) sits in the next slot.
    local showBtn = more > 0 or (expanded and #items > 0)
    helpers.safe(function()
        moreText.hidden = true
        moreBtn.hidden = not showBtn
        if showBtn then
            local label = (expanded and more <= 0) and "Less" or ("+" .. more)
            helpers.setText(moreBtn, label, "label")
            local bw = math.max(ICON + 6, helpers.textWidthOf(H.FONT, label) + 10)
            moreBtn:SetSize(bw, ICON + 6)
            moreBtn:SetPos(H.PAD + 2 + (shown % nc) * pitch() - 3, y + 2 + (shown // nc) * pitch() - 3)
            moreBtn:MoveToFront()
        end
    end)
    local slots = shown + (showBtn and 1 or 0)
    local usedRows = math.max(0, math.ceil(slots / nc))
    if helpers.isResizing() and not eqOnly then usedRows = math.max(usedRows, nr) end
    gridArea = { x = H.PAD, y = y, w = nc * pitch(), h = usedRows * pitch() + 2 }
    y = y + usedRows * pitch()
    if settingsUI ~= nil then
        settingsUI.open = editOpen
        y = settingsUI:place(y)
    end
    helpers.fitHeight(y + H.PAD)
end

local function buildPanel(root)
    panelRoot = root
    -- Row 1: [Farming v]  (1 of 2)   (0.11.26: dropdown instead of Prev / Next)
    local y1 = H.rowY(1)
    local ddCols = helpers.columns("presetRow", { preset = { w = 170, min = 90, max = 320 } }, nil)
    local DD_W = ddCols:get("preset")
    presetDD = helpers.dropdown(root, H.PAD, y1, DD_W, 18, { name = "preset",
        options = function() local L = {}; for i, p in ipairs(presets) do L[i] = tostring(p.name or ("Preset " .. i)) end; return L end,
        get = function() return activeIndex end,
        set = function(i) if presets[i] then activeIndex = i; save() end end,
        onChange = function() refresh() end,
        tip = "Pick which saved preset to check." })
    headerText = ui.Text.new(root)
    headerText:SetPos(H.PAD + DD_W + 6, y1)
    headerText:SetSize(-(2 * H.PAD + DD_W + 6), H.ROW_HEIGHT, 1.0, 0.0)
    headerText.font = H.FONT
    headerText:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    helpers.shadow(headerText)
    helpers.track(headerText, "content", 0)
    ddHandle = ddCols:handle(root, "preset", 1, "Drag to resize the preset picker column (Settings > Column widths > Reset).")
    local function applyDD()
        local w = ddCols:get("preset")
        presetDD.w = w
        presetDD:SetPos(H.PAD, y1); presetDD:refresh()
        helpers.safe(function()
            headerText:SetPos(H.PAD + w + 6, y1)
            headerText:SetSize(-(2 * H.PAD + w + 6), H.ROW_HEIGHT, 1.0, 0.0)
        end)
        ddHandle:place(H.PAD + w + 3, y1, H.ROW_HEIGHT)
    end
    ddCols.onChange = function() pcall(applyDD) end
    pcall(applyDD)

    -- Edit row (hidden unless Edit is on): name field, Save, Delete.
    local nameField = helpers.input(root, H.PAD, 0, 104, 18, "Preset name")
    local saveBtn = helpers.button(root, 0, 0, 46, 18, "Save", function()
        local name = helpers.cleanText(nameField.content, 24)   -- no tags/control chars, max 24
        if name == "" then name = "Preset " .. (#presets + 1) end
        local snapshot = {
            name = name,
            worn = toList(inventories.contents(inventories.worn())),
            wornSlot = {},
            pack = {},
            noPack = not invInclude(),
        }
        pcall(function()
            for objId, sl in pairs(inventories.slotsOf(inventories.worn())) do snapshot.wornSlot["i" .. objId] = sl end
        end)
        if not snapshot.noPack then
            snapshot.pack = toList(inventories.contents(inventories.backpack()))
        end
        local slot = nil
        for i, p in ipairs(presets) do
            if p.name == name then slot = i end
        end
        if slot == nil then
            if #presets >= MAX_PRESETS then
                helpers.showToast("Max 5 presets. Delete one first.", 5)
                return
            end
            table.insert(presets, snapshot)
            slot = #presets
        else
            presets[slot] = snapshot
        end
        activeIndex = slot
        save(); refresh()
    end)
    local delBtn = helpers.button(root, 0, 0, 52, 18, "Delete", function()
        if presets[activeIndex] ~= nil then
            table.remove(presets, activeIndex)
            if activeIndex > #presets then activeIndex = math.max(1, #presets) end
            save(); refresh()
        end
    end)
    invBtn = helpers.button(root, 0, 0, 56, 18, invLabel(), function()
        local p = presets[activeIndex]
        if p ~= nil then
            p.noPack = includesPack(p)       -- flip this preset's setting
            if not p.noPack and (p.pack == nil or #p.pack == 0) then
                helpers.showToast("Backpack on: press Save to capture it", 5)
            end
        else
            newIncludePack = not newIncludePack
        end
        save(); refresh()
    end)
    tokenField = helpers.input(root, H.PAD, 0, 150, 18, "Paste a preset token")
    pcall(function() tokenField:Setup(ui.TextContentVisibilityMode.VISIBLE, ui.InputFieldFilterMode.NONE, TOKEN_MAX) end)
    local expBtn = helpers.button(root, 0, 0, 52, 18, "Export", function()
        local p = presets[activeIndex]
        if p == nil then helpers.showToast("Save a preset first", 4); return end
        helpers.safe(function() tokenField.content = exportToken(p) end)
        helpers.showToast("Token is in the box: select it and copy (Ctrl+C)", 6)
    end)
    local impBtn = helpers.button(root, 0, 0, 52, 18, "Import", function()
        local okI, p, err = pcall(importToken, helpers.cleanText(tokenField.content, 4000))
        if not okI then p, err = nil, "Bad token" end
        if p == nil then helpers.showToast(err, 5); return end
        local slot = nil
        for i, q in ipairs(presets) do if q.name == p.name then slot = i end end
        if slot == nil and #presets >= MAX_PRESETS then helpers.showToast("Max " .. MAX_PRESETS .. " presets. Delete one first.", 5); return end
        if slot == nil then table.insert(presets, p); slot = #presets else presets[slot] = p end
        activeIndex = slot
        save(); refresh()
        helpers.showToast("Imported " .. p.name, 4)
    end)
    tokenParts = { tokenField, expBtn, impBtn }
    editParts = { nameField, saveBtn, delBtn, invBtn }
    local items = helpers.commonItems(function() refresh() end)
    local function vbool(key, label, a, b)
        table.insert(items, { label = label, options = { a, b },
            get = function() return view[key] and 1 or 2 end,
            set = function(i) view[key] = i == 1; saveView(); refresh() end })
    end
    vbool("onlyMissing", "Grid shows", "Missing", "All")
    vbool("equippedOnly", "Equipped only", "On", "Off")
    table.insert(items, { label = "Icon size", options = { "Small", "Medium", "Large" },
        get = function() return view.iconSize or 2 end,
        set = function(i) view.iconSize = i; saveView(); refresh() end })
    vbool("amber", "Amber badges", "On", "Off")
    settingsUI = helpers.newSettings(root, items, 8)
    settingsUI.onChange = function() refresh() end
    helpers.editToggle(root, function() return editOpen end, function(v)
        editOpen = v
        pcall(function() PersistentDB:SetInt("editOpen", v and 1 or 0) end)
        refresh()
    end)

    summaryText = helpers.textRow(root, 0, "")
    noteText = helpers.textRow(root, 0, "")
    moreText = helpers.textRow(root, 0, "")
    pcall(function() moreText.hidden = true end)
    -- 0.11.12: +N expands to show every item; Less restores the previous size.
    moreBtn = helpers.button(root, 0, 0, 30, 18, "+0", function()
        if view.equippedOnly then return end   -- +N here only lists inventory (hover)
        view.expanded = not view.expanded
        saveView(); refresh()
    end)
    helpers.safe(function() moreBtn.hidden = true end)
    helpers.onResizeEnd = function() refresh() end

    cells = {}
    for i = 1, MAX_CELLS do
        local c = {}
        -- 0.11.10 slot tile: #3A3328 at 60% with a 1 px darker border.
        pcall(function()
            local t = ui.Rectangle.new(root)
            t.fill = true
            t.colour = Vector4.new(0x3A/255, 0x33/255, 0x28/255, 0.6)
            t.hidden = true
            c.tile = t
            local e = ui.Rectangle.new(root)
            e.fill = false        -- outline only = 1 px border
            e.colour = Vector4.new(0x1A/255, 0x16/255, 0x10/255, 1.0)
            e.hidden = true
            c.tileEdge = e
        end)
        pcall(function()
            local sp = ui.Sprite.new(root)
            sp:SetSize(ICON, ICON)
            sp.hidden = true
            c.item = sp
            helpers.blockClicks(sp)
            -- Click pins/unpins this item's have/need (saved in the preset).
            sp:Subscribe(ui.Hook.ONCLICK, "pinQty", function()
                pcall(helpers.raiseWindow)
                local p, it = presets[activeIndex], c.it
                if p == nil or it == nil or it.q == nil then return end
                p.pinned = p.pinned or {}
                local k = "i" .. it.id
                p.pinned[k] = (p.pinned[k] ~= true) or nil
                save(); refresh()
            end)
        end)
        pcall(function()
            local t = ui.Text.new(root)
            t.font = (pcall(function() return id.Font.P11_FULL end) and id.Font.P11_FULL) or H.FONT
            t:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.TOPLEFT)
            helpers.shadow(t)
            t.hidden = true
            c.qty = t
        end)
        c.badge = helpers.imageButton(root, 0, 0, BADGE, "st_ok", nil)
        helpers.safe(function() c.badge.hidden = true end)
        cells[i] = c
    end
    refresh()
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------


-- Re-check whenever the server updates an inventory (backpack or worn).
helpers.subscribe(PLUGIN_NAME, "InventoryUpdated", "gpcInv", function() refresh() end)
helpers.subscribe(PLUGIN_NAME, "InventoryAdded", "gpcInvAdded", function() refresh() end)


-------------------------------------------------------------------------------
-- Window: shown immediately on enable (official tutorial pattern)
-------------------------------------------------------------------------------

local window = nil

--- Create the window and fill it. Safe to call repeatedly; it only does work
-- until the window exists. Retried once per second from the Logic tick
-- because the game window may not exist yet (e.g. enabled from the lobby).
local function tryCreateWindow()
    if window ~= nil then return end
    CELL, ICON, BADGE = table.unpack(SIZES[view.iconSize] or SIZES[2])
    local titleW = 30 + helpers.textWidthOf(helpers.TITLE_FONT, PLUGIN_NAME) + 126 + 4
    local defW = math.floor(math.max(gridWidth(), titleW))
    window = helpers.createWindow(PLUGIN_NAME, defW, 200, 0.7, 0.15)
    if window ~= nil then
        if not view.w01110 then   -- one-off: snap old wide panels to the grid width
            helpers.setWidth(defW)
            view.w01110 = true; saveView()
        end
        local ok, err = pcall(buildPanel, window)
        helpers.raiseGrip()
        if not ok then
            helpers.log("[" .. PLUGIN_NAME .. "] ERROR building panel: " .. tostring(err))
        end
    end
end

tryCreateWindow()

local retryTicks = 0
helpers.subscribe(PLUGIN_NAME, "Logic", "windowRetry", function()
    if window == nil then
        retryTicks = retryTicks + 1
        if retryTicks >= 50 then
            retryTicks = 0
            tryCreateWindow()
        end
    end
end)

table.insert(helpers.onLogin, function() refresh() end)

-- Hover polling for quantities (same method as the ellipsis hover box).
local hoverTicks = 0
helpers.subscribe(PLUGIN_NAME, "Logic", "gpcHover", function()
    hoverTicks = hoverTicks + 1
    if hoverTicks < 4 then return end
    hoverTicks = 0
    local mx, my = helpers.mouseUI()
    local found = nil
    if mx ~= nil then
        for i, c in ipairs(cells) do
            if c.it ~= nil and c.it.q ~= nil and helpers.isOver(c.item, mx, my) then found = i; break end
        end
    end
    if found ~= hoverCell then hoverCell = found; refresh() end
end)

-- 0.11.11: hover box for hidden icons. Same approach as the full-text hover
-- box: polled mouse position, a click-through GroupBox on the top plugin
-- layer, placed just below-right of the cursor and kept on screen.
local HB_MAX, HB_COLS = 48, 6
local hb = nil
local function ensureHB()
    if hb ~= nil then return true end
    return pcall(function()
        local top = helpers.ensureHoverLayer()
        local box = ui.GroupBox.new(top)
        box.stylesheetID = id.StyleSheet.DEFAULT
        box:SetHeaderLayout(0, 0, 0, 0, 0)
        pcall(function() box.colour = Vector4.new(0.62, 0.60, 0.58, helpers.OPACITY[helpers.common.opacity] or 0.82) end)
        pcall(function() box.clickthrough = true end)
        pcall(function() box.enabled = false end)
        box.hidden = true
        hb = { box = box, cells = {} }
        for i = 1, HB_MAX do
            local c = {}
            pcall(function()
                local t = ui.Rectangle.new(box); t.fill = true
                t.colour = Vector4.new(0x3A/255, 0x33/255, 0x28/255, 0.6); t.hidden = true
                pcall(function() t.clickthrough = true end); c.tile = t
            end)
            pcall(function()
                local sp = ui.Sprite.new(box); sp.hidden = true
                pcall(function() sp.clickthrough = true end); c.item = sp
            end)
            pcall(function()
                local b = ui.Sprite.new(box); b.hidden = true
                pcall(function() b.clickthrough = true end); c.badge = b
            end)
            hb.cells[i] = c
        end
    end)
end
local function hideHB() if hb ~= nil then pcall(function() hb.box.hidden = true end) end end
local hbKey = nil
local function showHB(mx, my)
    if #hiddenItems == 0 or not ensureHB() then hideHB(); return end
    pcall(function()
        local n = math.min(#hiddenItems, HB_MAX)
        local cols = math.min(n, HB_COLS)
        local rows = math.ceil(n / cols)
        local p = pitch()
        local key = n .. ":" .. ICON .. ":" .. tostring(hiddenItems[1].id) .. ":" .. tostring(hiddenItems[n].id)
        if key ~= hbKey then
            hbKey = key
            for i = 1, HB_MAX do
                local c, it = hb.cells[i], hiddenItems[i]
                local vis = it ~= nil and i <= n
                local gx = 8 + ((i - 1) % cols) * p
                local gy = 8 + ((i - 1) // cols) * p
                pcall(function() c.tile.hidden = not vis; if vis then c.tile:SetSize(ICON + 6, ICON + 6); c.tile:SetPos(gx - 3, gy - 3) end end)
                pcall(function()
                    c.item.hidden = not vis
                    if vis then
                        c.item:SetAssociatedObject(it.id); c.item:SetSize(ICON, ICON); c.item:SetPos(gx, gy)
                        local short = (it.q ~= nil and it.q.have < it.q.need) or it.st == "missing"
                        c.item.colour = short and Vector4.new(1.0, 0.55, 0.50, 1.0) or Vector4.new(1, 1, 1, 1)
                    end
                end)
                pcall(function()
                    local amberOff = vis and not view.amber and (it.st == "bank" or it.st == "notworn")
                    c.badge.hidden = (not vis) or amberOff
                    if vis and not amberOff then
                        helpers.setImage(c.badge, BADGE_RES[it.st])
                        c.badge:SetSize(BADGE, BADGE)
                        c.badge:SetPos(gx + ICON - BADGE + 2, gy + ICON - BADGE + 2)
                    end
                end)
            end
            hb.box:SetSize(cols * p - 8 + 16, rows * p - 8 + 16)
        end
        local pw, ph = 99999, 99999
        pcall(function() pw = hb.box.parent.width; ph = hb.box.parent.height end)
        local x = math.min(mx + 14, pw - hb.box.width - 2)
        local yy = my + 18
        if yy + hb.box.height > ph - 2 then yy = math.max(2, my - hb.box.height - 6) end
        hb.box:SetPos(math.floor(math.max(2, x)), math.floor(yy))
        hb.box.hidden = false
        hb.box:MoveToFront()
    end)
end

local lastW, lastWantH = nil, nil
helpers.subscribe(PLUGIN_NAME, "Logic", "gpcHoverBox", function()
    if panelRoot == nil then return end
    -- Reflow on every size change (width or dragged height).
    local w = nil
    pcall(function() w = panelRoot.width end)
    local bh = helpers.boxHeight()
    if w ~= lastW or (helpers.isResizing() and bh ~= lastWantH) then
        lastW, lastWantH = w, bh
        refresh()
    end
    local mx, my = helpers.mouseUI()
    local over = false
    if mx ~= nil and #hiddenItems > 0 and gridArea ~= nil then
        over = helpers.isOver(moreBtn, mx, my)
        if not over then
            pcall(function()
                local g = panelRoot.xyGlobal
                over = mx >= g.x + gridArea.x and mx < g.x + gridArea.x + gridArea.w
                    and my >= g.y + gridArea.y and my < g.y + gridArea.y + gridArea.h
                    and not panelRoot.hidden and panelRoot.visibleGlobal ~= false
            end)
        end
    end
    if over then showHB(mx, my) else hideHB() end
end)
helpers.installRibbon(PLUGIN_NAME)
helpers.log("[" .. PLUGIN_NAME .. "] loaded")

function PluginShutdown()
    save()
    helpers.destroyToast()
    if hb ~= nil then pcall(function() hb.box:Destroy() end); hb = nil end
    helpers.destroyWindow()
end
