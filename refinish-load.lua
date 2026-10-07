-- refinish-load.lua
-- ==========================================
-- UNIVERSAL STATE MANAGER
-- ==========================================
if _G.refinish_ram_loaded == nil or _G.refinish_data_loaded == nil then
    _G.refinish_ram_loaded = false
    _G.refinish_data_loaded = false
    
    local inorganics = df.global.world.raws.inorganics.all
    
    -- STATE 1: Native RAM Check
    for _, mat in ipairs(inorganics) do
        if string.find(mat.id, "REFINISH_STEEL_") then
            _G.refinish_ram_loaded = true
            break
        end
    end
    
    -- STATE 2: Native Data Check (CRASH-PROOF)
    if _G.refinish_ram_loaded then
        for _, item in ipairs(df.global.world.items.all) do
            -- FIX 1: Verify item is Inorganic before checking index
            if item:getActualMaterial() == 0 then
                local ok, m_idx = pcall(function() return item.mat_index end)
                if ok and type(m_idx) == 'number' and m_idx >= 0 and m_idx < #inorganics then
                    if string.find(inorganics[m_idx].id, "REFINISH_STEEL_") then
                        _G.refinish_data_loaded = true
                        break
                    end
                end
            end
        end
    end
end

if not _G.refinish_ram_loaded then
    print("Refinish Metal ERROR: Cannot load data. RAM is not indexed. Run refinish-index first.")
    if _G.refinish_log_event then _G.refinish_log_event("LOAD ERROR: Cannot load data. RAM is not indexed. Run refinish-index first.") end
    return
end
if _G.refinish_data_loaded then
    print("Refinish Metal: Data already loaded. Skipping duplicate command.")
    if _G.refinish_log_event then _G.refinish_log_event("LOAD: Data already loaded. Skipping duplicate command.") end
    return
end

-- ==========================================
-- SCRIPT LOGIC
-- ==========================================
local json = require('json')
local THEME = reqscript('refinish-theme').get_current_theme()

local function restore_logic()
    if _G.refinish_log_event then _G.refinish_log_event("LOAD/RESTORE: Sequence initiated. Searching for persistent JSON payload.") end
    local payload = dfhack.persistent.getSiteData("REFINISH_STEEL_PAYLOAD")
    
    if not payload or payload == "" then
        print("Refinish Metal: No saved persistent data found for this fortress. Starting fresh.")
        if _G.refinish_log_event then _G.refinish_log_event("LOAD/RESTORE: No saved persistent data found for this fortress. Starting fresh.") end
        return
    end

    local data = json.decode(payload)
    if not data then
        print("Refinish Metal ERROR: Persistent payload could not be decoded.")
        if _G.refinish_log_event then _G.refinish_log_event("LOAD ERROR: Persistent payload could not be decoded.") end
        return
    end

    -- ==========================================
    -- SITE ID VALIDATION (ANTI-GHOSTING)
    -- ==========================================
    local current_site_id = df.global.plotinfo.site_id
    if data.site_id and data.site_id ~= current_site_id then
        print(string.format("Refinish Metal: Ignored stale payload from a different Site ID (%s). Starting fresh.", tostring(data.site_id)))
        if _G.refinish_log_event then _G.refinish_log_event(string.format("LOAD: Ignored stale payload from previous Site ID (%s).", tostring(data.site_id))) end
        return
    end

    -- THE SAFE OPTIMIZATION: Build the Lookup Dictionary once to eliminate load lag
    local mat_lookup = {}
    local base_idx_map = {}
    local raws = df.global.world.raws.inorganics.all
    for i, mat in ipairs(raws) do
        mat_lookup[mat.id] = i
        base_idx_map[mat.id] = i
    end

    -- THE ARCHITECTURAL SHIFT: Dynamic Wash Targets
    local custom_to_base_idx = {}
    if _G.refinish_blueprint and _G.refinish_blueprint.materials then
        for custom_id, b_data in pairs(_G.refinish_blueprint.materials) do
            local b_idx = base_idx_map[b_data.base_metal_id]
            if b_idx then custom_to_base_idx[custom_id] = b_idx end
        end
    end
    local FALLBACK_SAFE_INDEX = base_idx_map["STEEL"] or 0

    local count = 0
    local amnesia_shells_fixed = 0
    
    -- BUILD ITEM LOOKUP: Index the entire world items array ONCE by ID.
    -- Replaces df.item.find() which performs an individual search through
    -- the full items array for every single saved object; catastrophically
    -- expensive at 10,000+ items. This reduces the restore loop from O(N*M)
    -- to O(N+M): one pass to build the dict, one pass to consume it.
    local item_lookup = {}
    for _, item in ipairs(df.global.world.items.all) do
        item_lookup[item.id] = item
    end

    for _, saved_obj in ipairs(data.items or {}) do
        -- O(1) hash lookup instead of O(M) search per item
        local item = item_lookup[saved_obj.id]
        local custom_mat_id = saved_obj.mat
        local target_idx = mat_lookup[custom_mat_id]
        
        -- Verify item is Inorganic before restoring custom metal
        if item and target_idx and item:getActualMaterial() == 0 then
            item.mat_index = target_idx
            count = count + 1

            -- THE AMNESIA FIX: Sync shells built while unloaded
            if item.flags.construction then
                local pos = item.pos
                local cons = dfhack.constructions.findAtTile(pos)
                
                local expected_wash_idx = custom_to_base_idx[custom_mat_id] or FALLBACK_SAFE_INDEX
                
                if cons and cons.mat_type == 0 and cons.mat_index == expected_wash_idx then
                    cons.mat_type = 0
                    cons.mat_index = target_idx
                    amnesia_shells_fixed = amnesia_shells_fixed + 1
                    
                    local pos_above = {x = pos.x, y = pos.y, z = pos.z + 1}
                    local cons_above = dfhack.constructions.findAtTile(pos_above)
                    
                    if cons_above and cons_above.mat_type == 0 and cons_above.mat_index == expected_wash_idx then
                        cons_above.mat_type = 0
                        cons_above.mat_index = target_idx
                        amnesia_shells_fixed = amnesia_shells_fixed + 1
                    end
                end
            end
        end
    end

    if amnesia_shells_fixed > 0 then
        print("Refinish Metal: Synced " .. amnesia_shells_fixed .. " architecture shells built during unloaded state.")
        if _G.refinish_log_event then _G.refinish_log_event("LOAD/RESTORE: Synced " .. amnesia_shells_fixed .. " architecture shells built during unloaded state.") end
    end

    -- BUILD BUILDING LOOKUP: Same pattern as items; one pass, O(1) access.
    local bld_lookup = {}
    for _, bld in ipairs(df.global.world.buildings.all) do
        bld_lookup[bld.id] = bld
    end

    for _, saved_obj in ipairs(data.buildings or {}) do
        local bld = bld_lookup[saved_obj.id]
        local target_idx = mat_lookup[saved_obj.mat]
        -- FIX 3: Verify building is Inorganic before restoring custom metal
        if bld and target_idx and bld.mat_type == 0 then
            bld.mat_index = target_idx
            count = count + 1
        end
    end

    -- PROTECTED CONSTRUCTIONS RESTORE
    if data.constructions then
        local ok, err = pcall(function()
            for _, saved_c in ipairs(data.constructions) do
                local target_idx = mat_lookup[saved_c.mat]
                local pos = {
                    x = tonumber(saved_c.x), 
                    y = tonumber(saved_c.y), 
                    z = tonumber(saved_c.z)
                }
                local c = dfhack.constructions.findAtTile(pos)
                
                -- FIX 4: Verify construction is currently Inorganic before restoring
                if c and target_idx and c.mat_type == 0 then
                    c.mat_type = 0
                    c.mat_index = target_idx
                    count = count + 1
                end
            end
        end)
        if not ok then 
            print("Refinish Metal Warning (Load): Shells skipped. " .. tostring(err)) 
            if _G.refinish_log_event then _G.refinish_log_event("LOAD WARNING: Shells skipped. " .. tostring(err)) end
        end
    end

    print("Refinish Metal: Successfully restored " .. count .. " objects from native persistent memory.")
    if _G.refinish_log_event then _G.refinish_log_event("LOAD/RESTORE: Sequence complete. Successfully restored " .. count .. " objects.") end
    
    if not _G.refinish_silent_load then
        local msg_setting = dfhack.persistent.getSiteData('refinish_config_msg')
        if not msg_setting or msg_setting == "" then msg_setting = 'GUIDED' end

        if msg_setting == 'PASSIVE' then
            dfhack.gui.showAnnouncement('Refinish Metal: Data injection complete.', THEME.PRI, true)
        elseif msg_setting == 'DEBUG' then
            dfhack.gui.showAnnouncement('Refinish Metal: ' .. count .. ' items loaded.', THEME.PRI, true)
        end
    end
end

restore_logic()

_G.refinish_data_loaded = true