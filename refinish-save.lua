-- refinish-save.lua
-- ==========================================
-- UNIVERSAL STATE MANAGER
-- ==========================================
if _G.refinish_ram_loaded == nil or _G.refinish_data_loaded == nil then
    _G.refinish_ram_loaded = false
    _G.refinish_data_loaded = false
    
    local inorganics = df.global.world.raws.inorganics.all
    
    for _, mat in ipairs(inorganics) do
        if string.find(mat.id, "REFINISH_STEEL_") then
            _G.refinish_ram_loaded = true
            break
        end
    end
    
    if _G.refinish_ram_loaded then
        for _, item in ipairs(df.global.world.items.all) do
            -- FIX: Verify the item is Inorganic before checking its index against the inorganics array
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

-- ==========================================
-- SCRIPT LOGIC
-- ==========================================
if not _G.refinish_data_loaded then
    print("Refinish Metal: Data already washed. Skipping save sequence.")
    if _G.refinish_log_event then _G.refinish_log_event("SAVE/WASH: Data already washed. Skipping save sequence.") end
    return
end

local json = require('json')

local function save_and_wash()
    if _G.refinish_log_event then _G.refinish_log_event("SAVE/WASH: Sequence initiated. Scanning for active modded materials.") end
    
    -- 1. READ OLD DATA FOR PRESERVATION
    local old_payload = dfhack.persistent.getSiteData("REFINISH_STEEL_PAYLOAD")
    local old_data = {items = {}, buildings = {}, constructions = {}}
    if old_payload and old_payload ~= "" then
        local ok, parsed = pcall(json.decode, old_payload)
        if ok and parsed then 
            -- THE FIX: Anti-Ghosting Protocol
            -- Prevent old world data from being laundered into the new save
            local current_site_id = df.global.plotinfo.site_id
            if parsed.site_id and parsed.site_id ~= current_site_id then
                if _G.refinish_log_event then _G.refinish_log_event(string.format("SAVE/WASH: Ignored stale payload from previous Site ID (%s). Purging ghost data.", tostring(parsed.site_id))) end
                print(string.format("Refinish Metal: Purged stale ghost data from a previous world (Site ID %s).", tostring(parsed.site_id)))
            else
                old_data = parsed 
            end
        end
    end

    local old_items_map = {}
    for _, obj in ipairs(old_data.items or {}) do old_items_map[obj.id] = obj.mat end
    
    local old_bld_map = {}
    for _, obj in ipairs(old_data.buildings or {}) do old_bld_map[obj.id] = obj.mat end
    
    local old_cons_map = {}
    for _, obj in ipairs(old_data.constructions or {}) do 
        old_cons_map[obj.x .. "_" .. obj.y .. "_" .. obj.z] = obj.mat 
    end

    -- ==========================================
    -- SITE ID STAMPING
    -- ==========================================
    local saved_data = {
        site_id = df.global.plotinfo.site_id,
        items = {}, 
        buildings = {}, 
        constructions = {}
    }

    local count = 0
    local shell_count = 0
    local inorganics = df.global.world.raws.inorganics.all

    -- THE ARCHITECTURAL SHIFT: Dynamic Wash Targets
    local base_idx_map = {}
    for i, mat in ipairs(inorganics) do base_idx_map[mat.id] = i end

    local mat_to_wash_idx = {}
    if _G.refinish_blueprint and _G.refinish_blueprint.materials then
        for custom_id, b_data in pairs(_G.refinish_blueprint.materials) do
            local b_idx = base_idx_map[b_data.base_metal_id]
            if b_idx then mat_to_wash_idx[custom_id] = b_idx end
        end
    end
    -- Failsafe: Revert to Steel if blueprint is inexplicably missing
    local FALLBACK_SAFE_INDEX = base_idx_map["STEEL"] or 0

    local processed_items = {}
    local processed_blds = {}
    local processed_cons = {}

    -- 2. TARGETED STRIKE: Active Items on the Map
    for _, item in ipairs(df.global.world.items.all) do
        -- FIX: Ignore organic items (wood, leather, etc) whose indexes happen to overlap with our injected metals
        if item:getActualMaterial() == 0 then
            local ok, m_index = pcall(function() return item.mat_index end)
            if ok and type(m_index) == 'number' and m_index >= 0 and m_index < #inorganics then
                local mat_str = inorganics[m_index].id
                
                if string.find(mat_str, "REFINISH_STEEL_") then
                    local wash_idx = mat_to_wash_idx[mat_str] or FALLBACK_SAFE_INDEX
                    table.insert(saved_data.items, {id = tonumber(item.id), mat = mat_str})
                    processed_items[item.id] = true
                    item.mat_index = wash_idx
                    count = count + 1

                    local pos = item.pos
                    local cons = dfhack.constructions.findAtTile(pos)
                    
                    if cons and cons.mat_type == 0 then
                        local ok_c, c_idx = pcall(function() return cons.mat_index end)
                        if ok_c and type(c_idx) == 'number' and c_idx >= 0 and c_idx < #inorganics then
                            local c_mat_str = inorganics[c_idx].id
                            if string.find(c_mat_str, "REFINISH_STEEL_") then
                                local c_wash_idx = mat_to_wash_idx[c_mat_str] or FALLBACK_SAFE_INDEX
                                table.insert(saved_data.constructions, {x = pos.x, y = pos.y, z = pos.z, mat = c_mat_str})
                                processed_cons[pos.x .. "_" .. pos.y .. "_" .. pos.z] = true
                                cons.mat_type = 0
                                cons.mat_index = c_wash_idx
                                shell_count = shell_count + 1

                                local pos_above = {x = pos.x, y = pos.y, z = pos.z + 1}
                                local cons_above = dfhack.constructions.findAtTile(pos_above)
                                if cons_above and cons_above.mat_type == 0 and cons_above.mat_index == c_idx then
                                    table.insert(saved_data.constructions, {x = pos_above.x, y = pos_above.y, z = pos_above.z, mat = c_mat_str})
                                    processed_cons[pos_above.x .. "_" .. pos_above.y .. "_" .. pos_above.z] = true
                                    cons_above.mat_type = 0
                                    cons_above.mat_index = c_wash_idx
                                    shell_count = shell_count + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- 3. TARGETED STRIKE: Active Buildings
    for _, bld in ipairs(df.global.world.buildings.all) do
        -- FIX: Verify building is Inorganic before checking index
        if bld.mat_type == 0 then
            local ok, m_index = pcall(function() return bld.mat_index end)
            if ok and type(m_index) == 'number' and m_index >= 0 and m_index < #inorganics then
                local mat_str = inorganics[m_index].id
                if string.find(mat_str, "REFINISH_STEEL_") then
                    local wash_idx = mat_to_wash_idx[mat_str] or FALLBACK_SAFE_INDEX
                    table.insert(saved_data.buildings, {id = tonumber(bld.id), mat = mat_str})
                    processed_blds[bld.id] = true
                    bld.mat_index = wash_idx
                    count = count + 1
                end
            end
        end
    end

    -- 4. THE PRESERVATION PROTOCOL (Unconditional Failsafe)
    local preserved_count = 0
    
    -- HELPER: Dynamically extract the expected index even in dormant mode
    local inorgs = df.global.world.raws.inorganics.all
    local function get_dormant_wash_idx(mat_str)
        if mat_to_wash_idx[mat_str] then return mat_to_wash_idx[mat_str] end
        
        local base_id = nil
        if string.find(mat_str, "_MAT_SPECIFIC_") then
            base_id = string.match(mat_str, "_MAT_SPECIFIC_([^_]+)_")
        elseif string.find(mat_str, "_MAT_COLOUR_") then
            -- Extracts the text immediately preceding _MV (e.g., "GOLD" from "_GOLD_MV10")
            base_id = string.match(mat_str, "_([^_]+)_MV%d")
        end
        
        if base_id then
            for i, mat in ipairs(inorgs) do
                if mat.id == base_id then return i end
            end
        end
        return FALLBACK_SAFE_INDEX
    end

    for _, item in ipairs(df.global.world.items.all) do
        -- FIX: Verify item is Inorganic
        if not processed_items[item.id] and item:getActualMaterial() == 0 then
            local old_mat = old_items_map[item.id]
            if old_mat and string.find(old_mat, "REFINISH_STEEL_") then
                local ok, m_index = pcall(function() return item.mat_index end)
                local expected_wash_idx = get_dormant_wash_idx(old_mat)
                
                if ok and type(m_index) == 'number' and m_index == expected_wash_idx then
                    table.insert(saved_data.items, {id = tonumber(item.id), mat = old_mat})
                    preserved_count = preserved_count + 1
                end
            end
        end
    end

    for _, bld in ipairs(df.global.world.buildings.all) do
        -- FIX: Verify building is Inorganic
        if not processed_blds[bld.id] and bld.mat_type == 0 then
            local old_mat = old_bld_map[bld.id]
            if old_mat and string.find(old_mat, "REFINISH_STEEL_") then
                local ok, m_index = pcall(function() return bld.mat_index end)
                local expected_wash_idx = get_dormant_wash_idx(old_mat)
                
                if ok and type(m_index) == 'number' and m_index == expected_wash_idx then
                    table.insert(saved_data.buildings, {id = tonumber(bld.id), mat = old_mat})
                    preserved_count = preserved_count + 1
                end
            end
        end
    end

    for key, old_mat in pairs(old_cons_map) do
        if not processed_cons[key] and string.find(old_mat, "REFINISH_STEEL_") then
            local parts = {}
            for part in string.gmatch(key, "[^_]+") do table.insert(parts, part) end
            table.insert(saved_data.constructions, {x = tonumber(parts[1]), y = tonumber(parts[2]), z = tonumber(parts[3]), mat = old_mat})
            preserved_count = preserved_count + 1
        end
    end

    if shell_count > 0 then 
        print("Refinish Metal: Washed " .. shell_count .. " targeted wall shells and floors to Steel.") 
        if _G.refinish_log_event then _G.refinish_log_event("SAVE/WASH: Washed " .. shell_count .. " targeted wall shells and floors to Steel.") end
    end
    if preserved_count > 0 then 
        print("Refinish Metal: Preserved " .. preserved_count .. " unrendered specific finishes in JSON.") 
        if _G.refinish_log_event then _G.refinish_log_event("SAVE/WASH: Preserved " .. preserved_count .. " unrendered specific finishes in JSON.") end
    end

    -- Write payload counts to the persistent telemetry table
    if _G.refinish_telemetry and _G.refinish_telemetry.last_save and saved_data then
        _G.refinish_telemetry.last_save.items = saved_data.items and #saved_data.items or 0
        _G.refinish_telemetry.last_save.buildings = saved_data.buildings and #saved_data.buildings or 0
        _G.refinish_telemetry.last_save.constructions = saved_data.constructions and #saved_data.constructions or 0
    end

    local payload = json.encode(saved_data)
    dfhack.persistent.saveSiteData("REFINISH_STEEL_PAYLOAD", payload)
    
    local total_count = count + preserved_count
    print("Refinish Metal: Secured " .. total_count .. " objects directly into native save memory.")
    if _G.refinish_log_event then _G.refinish_log_event("SAVE/WASH: Sequence complete. Secured " .. total_count .. " objects into JSON payload.") end
    
    _G.refinish_data_loaded = false
end

save_and_wash()