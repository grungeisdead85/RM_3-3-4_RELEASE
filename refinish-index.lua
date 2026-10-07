-- refinish-index.lua
-- STATE MANAGER: Deep RAM Verification
if _G.refinish_ram_loaded == nil or _G.refinish_ram_loaded == false then
    for _, mat in ipairs(df.global.world.raws.inorganics.all) do
        if string.find(mat.id, "REFINISH_STEEL_MAT_") then
            _G.refinish_ram_loaded = true
            break
        end
    end
end

if _G.refinish_ram_loaded then
    print("Refinish Metal: Materials already indexed. Skipping.")
    if _G.refinish_log_event then _G.refinish_log_event("INDEX: Materials already indexed. Skipping.") end -- ADDED LOG
    return
end

-- ==========================================
-- SCRIPT LOGIC: MATERIAL BUILDER
-- ==========================================
if not _G.refinish_blueprint or not _G.refinish_blueprint.materials then
    print("Refinish Metal ERROR: Blueprint not found in memory. Run 'refinish-scan' first.")
    if _G.refinish_log_event then _G.refinish_log_event("INDEX ERROR: Blueprint not found in memory. Run 'refinish-scan' first.") end -- ADDED LOG
    return
end

local raws = df.global.world.raws.inorganics.all

-- 1. Build a high-speed lookup dictionary of all vanilla metals
-- This prevents an O(N^2) lag spike when generating hundreds of materials
local source_metals = {}
for _, mat in ipairs(raws) do
    source_metals[mat.id] = mat
end

local count = 0

-- 2. Build from the Blueprint

-- Build a sorted injection list so mat_index positions are identical
-- every cycle. pairs() gives no order guarantee: without this,
-- items point at wrong materials after a hotsave rebuild.
local sorted_mats = {}
for mat_id, data in pairs(_G.refinish_blueprint.materials) do
    table.insert(sorted_mats, { id = mat_id, data = data })
end
table.sort(sorted_mats, function(a, b) return a.id < b.id end)

for _, entry in ipairs(sorted_mats) do
    local mat_id = entry.id
    local data = entry.data
    -- rest of the existing loop body unchanged
    
    -- 3. Dynamically fetch the correct base metal to clone using our blueprint breadcrumb
    local source_metal = source_metals[data.base_metal_id]
    
    if not source_metal then
        print("Refinish Metal ERROR: Could not find base metal " .. tostring(data.base_metal_id) .. " to clone for " .. mat_id)
        if _G.refinish_log_event then _G.refinish_log_event("INDEX ERROR: Missing base metal " .. tostring(data.base_metal_id)) end
    else
        -- Create a blank object and deep-copy the base metal's integers into it
        local m = df.inorganic_raw:new()
        m:assign(source_metal) 

        -- 4. The Critical Missing Pointers
        m.id = mat_id
        m.material.id = mat_id

        -- 5. Manually Re-Inject the BitArray Flags (Fixes the forge/anvil issue)
        m.material.flags.IS_METAL = true
        m.material.flags.ITEMS_METAL = true
        m.material.flags.ITEMS_HARD = true
        m.material.flags.ITEMS_BARRED = true
        m.material.flags.ITEMS_SCALED = true
        m.material.flags.ITEMS_WEAPON = true
        m.material.flags.ITEMS_WEAPON_RANGED = true
        m.material.flags.ITEMS_AMMO = true
        m.material.flags.ITEMS_DIGGER = true
        m.material.flags.ITEMS_ARMOR = true
        m.material.flags.ITEMS_ANVIL = true

        -- 6. Overwrite Colors and Names
        m.material.state_name.Solid = data.adj_name
        m.material.state_adj.Solid = data.adj_name
        m.material.state_name.Liquid = "molten " .. data.adj_name
        m.material.state_adj.Liquid = "molten " .. data.adj_name
        m.material.state_name.Gas = "boiling " .. data.adj_name
        m.material.state_adj.Gas = "boiling " .. data.adj_name

        -- Push the Steam Graphics State Colors
        m.material.state_color.Solid = data.color_idx
        m.material.state_color.Liquid = data.color_idx
        m.material.state_color.Gas = data.color_idx

        -- Push the Classic ASCII fallback colors (using color_idx as the basic_id)
        m.material.build_color[0] = data.color_idx 
        m.material.build_color[1] = 0        
        m.material.build_color[2] = 1        
        m.material.basic_color[0] = data.color_idx
        m.material.basic_color[1] = 1

        -- Visual Hints for the Graphics Engine
        m.material.tile_color[0] = data.color_idx 
        m.material.tile_color[1] = 0        
        m.material.tile_color[2] = 1 
        m.material.tile = 219
        m.material.item_symbol = 7

        -- Final Material Value Math
        m.material.material_value = data.mat_value

        -- 7. Dynamically Inject into the absolute end of the raws
        raws:insert(#raws, m)
        count = count + 1
    end
end

print("Refinish Metal: Indexed " .. count .. " custom materials into RAM.")
if _G.refinish_log_event then _G.refinish_log_event("INDEX: Successfully built and injected " .. count .. " custom materials into RAM.") end -- ADDED LOG

-- Toggle state manager at the absolute end of the file
_G.refinish_ram_loaded = true