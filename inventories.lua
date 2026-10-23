--[[
  inventories.lua
  Finds the player's backpack and worn-equipment inventories and turns them
  into simple { [objId] = count } tables.

  config.Inv.INV (the backpack) is used in the official Inventory docs.
  The worn-equipment inventory's config name is NOT listed in the docs, so
  we try a few likely names inside pcall. Confirm the real name on a
  developer world with `pan Inv` and put it first in WORN_CANDIDATES.
]]

local inventories = {}

-- Candidate config names for worn equipment (unconfirmed; see note above).
local WORN_CANDIDATES = { "WORN", "WORNITEMS", "EQUIPMENT" }

--- Look up an InvType by config name without erroring if it doesn't exist.
local function findInvType(name)
    local ok, cfg = pcall(function() return config.Inv[name] end)
    if ok then return cfg end
    return nil
end

--- Return the Inv for a config name, or nil if missing/invalid right now.
local function findInv(name)
    local cfg = findInvType(name)
    if cfg == nil then return nil end
    local ok, inv = pcall(Inventory.Find, cfg)
    if ok and inv ~= nil and inv.isValid then
        return inv
    end
    return nil
end

--- Backpack Inv or nil.
function inventories.backpack()
    return findInv("INV")
end

--- Worn equipment Inv or nil (nil also if no candidate name is right).
function inventories.worn()
    for _, name in ipairs(WORN_CANDIDATES) do
        local inv = findInv(name)
        if inv ~= nil then return inv end
    end
    return nil
end

--- Bank Inv (config.Inv.BANK) or nil; usually only populated after the
-- bank has been opened this session.
function inventories.bank()
    return findInv("BANK")
end

--- Count of objId in inv: Inv:GetTotal when available, else slot scan.
function inventories.total(inv, objId)
    if inv == nil then return 0 end
    local ok, n = pcall(function() return inv:GetTotal(objId) end)
    if ok and type(n) == "number" then return n end
    --- 0.11.13: { [objId] = wornSlotIndex } (RS3 equipment slots: 0 head,
-- 3 main hand, 4 body, 5 off hand, 7 legs). Uses the slot's own index field
-- when the API exposes one, else the GetSlots key (shifted if 1-based).
function inventories.slotsOf(inv)
    local result = {}
    if inv == nil then return result end
    local ok, slots = pcall(function() return inv:GetSlots() end)
    if not ok or slots == nil then return result end
    local zeroBased = slots[0] ~= nil
    for k, slot in pairs(slots) do
        pcall(function()
            if slot ~= nil and slot.obj ~= nil and slot.count > 0 then
                local idx = nil
                pcall(function() idx = slot.slot end)
                if type(idx) ~= "number" then pcall(function() idx = slot.index end) end
                if type(idx) ~= "number" then idx = zeroBased and k or (k - 1) end
                if result[slot.obj.id] == nil then result[slot.obj.id] = idx end
            end
        end)
    end
    return result
end

return inventories.contents(inv)[objId] or 0
end

--- Convert an Inv into { [objId] = totalCount }. Returns {} for nil.
function inventories.contents(inv)
    local result = {}
    if inv == nil then return result end
    local slots = inv:GetSlots() or {}
    for _, slot in pairs(slots) do
        if slot ~= nil and slot.obj ~= nil and slot.count > 0 then
            local objId = slot.obj.id
            result[objId] = (result[objId] or 0) + slot.count
        end
    end
    return result
end

--- Display name for an object id (falls back to "Item #id").
function inventories.objName(objId)
    local ok, name = pcall(function() return config.Obj.FromID(objId).name end)
    if ok and name ~= nil and name ~= "" then return name end
    return "Item #" .. tostring(objId)
end

--- 0.11.13: { [objId] = wornSlotIndex } (RS3 equipment slots: 0 head,
-- 3 main hand, 4 body, 5 off hand, 7 legs). Uses the slot's own index field
-- when the API exposes one, else the GetSlots key (shifted if 1-based).
function inventories.slotsOf(inv)
    local result = {}
    if inv == nil then return result end
    local ok, slots = pcall(function() return inv:GetSlots() end)
    if not ok or slots == nil then return result end
    local zeroBased = slots[0] ~= nil
    for k, slot in pairs(slots) do
        pcall(function()
            if slot ~= nil and slot.obj ~= nil and slot.count > 0 then
                local idx = nil
                pcall(function() idx = slot.slot end)
                if type(idx) ~= "number" then pcall(function() idx = slot.index end) end
                if type(idx) ~= "number" then idx = zeroBased and k or (k - 1) end
                if result[slot.obj.id] == nil then result[slot.obj.id] = idx end
            end
        end)
    end
    return result
end

return inventories
