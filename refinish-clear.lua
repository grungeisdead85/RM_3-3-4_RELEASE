-- refinish-clear.lua
-- STATE MANAGER: Deep RAM Verification
if _G.refinish_ram_loaded == nil or _G.refinish_ram_loaded == true then
    local actually_loaded = false
    for _, mat in ipairs(df.global.world.raws.inorganics.all) do
        if string.find(mat.id, "REFINISH_STEEL_MAT_") then
            actually_loaded = true
            break
        end
    end
    if not actually_loaded then _G.refinish_ram_loaded = false end
end

-- THE FIX: Safely restore vanilla nomenclature before wiping the blueprint
if _G.refinish_blueprint and _G.refinish_blueprint.original_names then
    local names_restored = 0
    local raws = df.global.world.raws.inorganics.all
    for _, mat in ipairs(raws) do
        local original = _G.refinish_blueprint.original_names[mat.id]
        if original then
            mat.material.state_name[3] = original.name
            mat.material.state_adj[3] = original.adj
            names_restored = names_restored + 1
        end
    end
    if names_restored > 0 then
        print("Refinish Metal: Restored original nomenclature for " .. names_restored .. " base materials.")
        if _G.refinish_log_event then _G.refinish_log_event("CLEAR MATS: Restored original nomenclature for " .. names_restored .. " base materials.") end -- ADDED LOG
    end
end

-- Destroy the blueprint memory cache so the scanner is forced to read new settings
_G.refinish_blueprint = nil

if not _G.refinish_ram_loaded then
    print("Refinish Metal: Materials already cleared. Skipping.")
    if _G.refinish_log_event then _G.refinish_log_event("CLEAR MATS: Materials already cleared. Skipping.") end -- ADDED LOG
    return
end

-- ==========================================
-- SCRIPT LOGIC
-- ==========================================
local raws = df.global.world.raws.inorganics.all
local count = 0

-- Iterate backwards to safely remove items from the vector without shifting targets
for i = #raws - 1, 0, -1 do
    if string.find(raws[i].id, "REFINISH_STEEL_") then
        raws[i]:delete() -- This frees the physical RAM
        raws:erase(i)    -- This removes it from the list
        count = count + 1
    end
end

if count > 0 then
    print("Refinish Metal: Cleared " .. count .. " custom indices. RAM safely compressed.")
    if _G.refinish_log_event then _G.refinish_log_event("CLEAR MATS: Cleared " .. count .. " custom indices. RAM safely compressed.") end -- ADDED LOG
else
    print("Refinish Metal: No custom materials found. Memory is pristine.")
    if _G.refinish_log_event then _G.refinish_log_event("CLEAR MATS: No custom materials found to clear. Memory is pristine.") end -- ADDED LOG
end

-- Toggle state manager at the absolute end of the file
_G.refinish_ram_loaded = false