-- refinish-scan.lua
-- ==========================================
-- SCRIPT LOGIC: REFINISH-SCAN (MULTI-BASE MODE)
-- ==========================================
local json = require('json')

if _G.refinish_blueprint ~= nil then
    print("Refinish Metal: Blueprint already exists in memory. Skipping scan.")
    return
end

print("==================================================")
print("REFINISH STEEL: INITIATING MASTER SCANNER")
print("==================================================")
if _G.refinish_log_event then _G.refinish_log_event("SCANNER: Master scan initiated (Multi-Base Mode).") end

local perf_setting = dfhack.persistent.getSiteData('refinish_config_perf') or 'ON'

-- ==========================================
-- INITIALIZE BLUEPRINT & TIER 1 ROOT
-- ==========================================
_G.refinish_blueprint = {
    materials = {},
    reactions = {},
    original_names = {},
    categories = {
        -- TIER 1: THE ROOT
        ROOT = { id = "REFINISH_STEEL_CAT_ROOT", name = "Refinish metal bars", parent = "" }
    }
}

-- =================
-- OVERRIDES
-- =================
local SPECIAL_FINISH = {
    ["IRON"] = { prefix = "ironclad" },
    ["GOLD"] = { prefix = "gilded" },
    ["PLATINUM"] = { prefix = "platinized" },
    ["SILVER"] = { prefix = "silvered" },
    ["COPPER"] = { prefix = "coppered" },
    ["NICKEL"] = { prefix = "nickeled" },
    ["ZINC"] = { prefix = "galvanized" },
    ["BRONZE"] = { prefix = "bronzed" },
    ["BRASS"] = { prefix = "brassed" },
    ["ROSE_GOLD"] = { prefix = "rose-gilded" },
    ["PIG_IRON"] = { prefix = "pig" },
    ["STEEL"] = { prefix = "satin" },
    ["ELECTRUM"] = { prefix = "electrumized" },
    ["TIN"] = { prefix = "tinned" },
    ["PEWTER_FINE"] = { prefix = "fine-pewtered" },
    ["PEWTER_TRIFLE"] = { prefix = "trifle-pewtered" },
    ["PEWTER_LAY"] = { prefix = "lay-pewtered" },
    ["LEAD"] = { prefix = "leaded" },
    ["ALUMINUM"] = { prefix = "aluminized" },
    ["NICKEL_SILVER"] = { prefix = "nickel-silvered" },
    ["BILLON"] = { prefix = "billonclad" },
    ["STERLING_SILVER"] = { prefix = "sterling-silvered" },
    ["BLACK_BRONZE"] = { prefix = "black-bronzed" },
    ["BISMUTH"] = { prefix = "bismuth-washed" },
    ["BISMUTH_BRONZE"] = { prefix = "bismuth-bronzed" },
    ["ADAMANTINE"] = { prefix = "adamantinized" },
    ["HEMATITE"] = { prefix = "ferriferous" },
    ["LIMONITE"] = { prefix = "ferriferous" },
    ["GARNIERITE"] = { prefix = "kupfernickeled" },
    ["NATIVE_GOLD"] = { prefix = "auriferous" },
    ["NATIVE_SILVER"] = { prefix = "argentiferous" },
    ["NATIVE_COPPER"] = { prefix = "cupriferous" },
    ["MALACHITE"] = { prefix = "cupriferous" },
    ["GALENA"] = { prefix = "plumbiferous" },
    ["SPHALERITE"] = { prefix = "zinciferous" },
    ["CASSITERITE"] = { prefix = "stanniferous" },
    ["NATIVE_PLATINUM"] = { prefix = "platiniferous" },
    ["TETRAHEDRITE"] = { prefix = "cupriferous" },
    ["HORN_SILVER"] = { prefix = "argentiferous" },
    ["BISMUTHINITE"] = { prefix = "bismuthiferous" },
    ["MAGNETITE"] = { prefix = "ferriferous" },
    ["NATIVE_ALUMINUM"] = { prefix = "aluminiferous" },
    ["RAW_ADAMANTINE"] = { prefix = "adamantiferous" }
}

local inorganics = df.global.world.raws.inorganics.all
local colors = df.global.world.raws.descriptors.colors

-- ==========================================
-- LOAD ACTIVE BASE METALS FROM JSON
-- ==========================================
local saved_bases_str = dfhack.persistent.getSiteData('refinish_config_bases')
local active_bases_dict = {}

if saved_bases_str and saved_bases_str ~= "" then
    pcall(function() active_bases_dict = json.decode(saved_bases_str) end)
else
    active_bases_dict["STEEL"] = true
end

if not next(active_bases_dict) then
    print("Refinish Metal: No active base metals selected in configuration. Asset building will remain dormant.")
    if _G.refinish_log_event then _G.refinish_log_event("SCANNER: No base metals selected. Asset building aborted (Dormant mode).") end
    return
end

-- ==========================================
-- GATEKEEPER INTERCEPT
-- ==========================================
local bases_env = dfhack.script_environment('refinish-bases')
-- We pass true, true to pull the absolute maximum list of physical metals so we can check against it
local valid_metals_list = bases_env.get_valid_bases(true, true) 

local metal_reaction_lookup = {}
for _, m in ipairs(valid_metals_list) do
    metal_reaction_lookup[m.id] = m.has_reaction
end

-- Validate the Base Metals requested by the user
local active_bases = {}
for _, mat in ipairs(inorganics) do
    if active_bases_dict[mat.id] then
        if metal_reaction_lookup[mat.id] then
            local name = mat.material.state_name[0] or mat.id
            table.insert(active_bases, {
                id = mat.id,
                name = string.lower(name),
                value = mat.material.material_value
            })
        else
            -- Legitimately failed validation. Notify explicitly.
            print(string.format("Refinish Metal WARNING: Base metal [%s] dropped. It lacks a valid crafting/smelting path.", mat.id))
            if _G.refinish_log_event then _G.refinish_log_event(string.format("SCANNER WARNING: Base metal [%s] dropped (No valid path).", mat.id)) end
        end
    end
end

if #active_bases == 0 then
    print("Refinish Metal: No VALID active base metals survived the security scan. Asset building will remain dormant.")
    if _G.refinish_log_event then _G.refinish_log_event("SCANNER: All selected bases were invalid. Aborted (Dormant mode).") end
    return
end

if _G.refinish_log_event then _G.refinish_log_event("SCANNER: Loaded " .. #active_bases .. " verified active base metals.") end

-- ==========================================
-- DYNAMIC CATEGORY GENERATION (BASE-FIRST RESTRUCTURE)
-- ==========================================
for _, base in ipairs(active_bases) do
    -- Capitalize the first letter for UI readability (e.g., "steel" -> "Steel")
    local cap_name = string.gsub(base.name, "^%l", string.upper)
    
    -- TIER 2: THE BASE METAL BRANCH (e.g., "Steel finishes")
    local branch_id = "REFINISH_STEEL_CAT_BASE_" .. base.id
    _G.refinish_blueprint.categories[branch_id] = { id = branch_id, name = "Refinish " .. base.name .. " bars", parent = "REFINISH_STEEL_CAT_ROOT" }
    
    -- TIER 3: THE TYPE STEMS (Colour vs Material)
    local c_stem_id = branch_id .. "_COLOUR"
    _G.refinish_blueprint.categories[c_stem_id] = { id = c_stem_id, name = "Colour-based", parent = branch_id }
    
    local m_stem_id = branch_id .. "_MAT"
    _G.refinish_blueprint.categories[m_stem_id] = { id = m_stem_id, name = "Material-based", parent = branch_id }
    
    -- TIER 4: THE COLOUR LEAVES
    _G.refinish_blueprint.categories[c_stem_id .. "_STONE"] = { id = c_stem_id .. "_STONE", name = "Stone finish", parent = c_stem_id }
    _G.refinish_blueprint.categories[c_stem_id .. "_METAL"] = { id = c_stem_id .. "_METAL", name = "Metal finish", parent = c_stem_id }
    _G.refinish_blueprint.categories[c_stem_id .. "_GEM"]   = { id = c_stem_id .. "_GEM", name = "Gem finish", parent = c_stem_id }
    _G.refinish_blueprint.categories[c_stem_id .. "_OTHER"] = { id = c_stem_id .. "_OTHER", name = "Other finish", parent = c_stem_id }

    -- TIER 4: THE MATERIAL LEAVES
    _G.refinish_blueprint.categories[m_stem_id .. "_STONE"] = { id = m_stem_id .. "_STONE", name = "Stone finish", parent = m_stem_id }
    _G.refinish_blueprint.categories[m_stem_id .. "_METAL"] = { id = m_stem_id .. "_METAL", name = "Metal finish", parent = m_stem_id }
    _G.refinish_blueprint.categories[m_stem_id .. "_GEM"]   = { id = m_stem_id .. "_GEM", name = "Gem finish", parent = m_stem_id }
    _G.refinish_blueprint.categories[m_stem_id .. "_OTHER"] = { id = m_stem_id .. "_OTHER", name = "Other finish", parent = m_stem_id }
end

local valid_reagents = 0
local color_mats_created = 0
local specific_mats_created = 0

local function has_word(str, word)
    return string.match(string.lower(str), "%f[%a]" .. word .. "%f[%A]") ~= nil
end

-- INTAKE VALIDATOR
local rej_type, rej_phase, rej_value, rej_ghost = 0, 0, 0, 0
for _, mat in ipairs(inorganics) do
    if not string.find(mat.id, "REFINISH_STEEL_") then
        local mat_flags = mat.material.flags
        local inorg_flags = mat.flags 
        local reagent_val = mat.material.material_value
        local melt_point = mat.material.heat.melting_point
        
        local is_valid_type = mat_flags.IS_STONE or mat_flags.IS_METAL or mat_flags.IS_GEM or inorg_flags.SOIL_ANY or inorg_flags.SOIL_SAND
        -- THE FIX: Prune ghost metals from becoming finishes
        if mat_flags.IS_METAL and not metal_reaction_lookup[mat.id] then
            is_valid_type = false
            rej_ghost = rej_ghost + 1
        end
        local is_stable_solid = (melt_point == 0 or melt_point > 10015)
        local is_valid_value = (reagent_val >= 0)

        if is_valid_type and is_stable_solid and is_valid_value then
            
            -- Safe Integer Indexing (0 = Solid, 3 = Powder)
            local solid_name = mat.material.state_name[0]
            local powder_name = mat.material.state_name[3]
            local powder_adj = mat.material.state_adj[3]
            if not (has_word(powder_name, "sand") or has_word(powder_name, "gravel") or has_word(powder_name, "dust") or has_word(powder_name, "farin") or has_word(powder_name, "cement") or has_word(powder_name, "powder") or has_word(powder_name, "ash") or has_word(powder_name, "dirt")) then
                
                _G.refinish_blueprint.original_names[mat.id] = {
                    name = powder_name,
                    adj = powder_adj
                }
                
                mat.material.state_name[3] = solid_name .. " dust"
                mat.material.state_adj[3] = solid_name .. " dust"
            end

            -- THE CONDENSED COLOR FINISH (Color Matching)
            local color_idx = mat.material.state_color[0]
            local color_id = "UNKNOWN"
            local clean_color_name = "unknown"

            if color_idx >= 0 and color_idx < #colors then
                color_id = colors[color_idx].id
                clean_color_name = colors[color_idx].name
            end

            if color_idx < 0 then
                local states_to_check = {3, 5, 4}
                for _, s_idx in ipairs(states_to_check) do
                    local c_val = mat.material.state_color[s_idx]
                    if c_val >= 0 and c_val < #colors then
                        color_idx = c_val
                        color_id = colors[c_val].id
                        clean_color_name = colors[c_val].name
                        break
                    end
                end
            end

            if clean_color_name and clean_color_name ~= "unknown" then
                if clean_color_name == "" then
                    clean_color_name = string.lower(string.gsub(color_id, "_", " "))
                end
            end

            if clean_color_name == "unknown" or color_idx < 0 then
                local ansi_colors = {
                    [0] = { [0] = "black",      [1] = "dark gray" },
                    [1] = { [0] = "blue",       [1] = "light blue" },
                    [2] = { [0] = "green",      [1] = "light green" },
                    [3] = { [0] = "cyan",       [1] = "light cyan" },
                    [4] = { [0] = "red",        [1] = "light red" },
                    [5] = { [0] = "magenta",    [1] = "light magenta" },
                    [6] = { [0] = "brown",      [1] = "yellow" },
                    [7] = { [0] = "light gray", [1] = "white" }
                }
                
                local b_col = mat.material.build_color[0]
                local b_brt = mat.material.build_color[2]
                
                if b_col >= 0 and b_col <= 7 then
                    local brt_idx = (b_brt > 0) and 1 or 0
                    clean_color_name = ansi_colors[b_col][brt_idx]
                    color_id = string.upper(string.gsub(clean_color_name, " ", "_"))
                end
            end

            -- ==========================================
            -- BUILD BLUEPRINTS FOR EVERY ACTIVE BASE
            -- ==========================================
            for _, base_metal in ipairs(active_bases) do
                
                local final_val = base_metal.value
                local base_cat_suffix = "OTHER"
                
                if mat_flags.IS_GEM then
                    final_val = base_metal.value + reagent_val
                    base_cat_suffix = "GEM"
                elseif mat_flags.IS_METAL then
                    final_val = base_metal.value + math.floor(reagent_val / 3)
                    base_cat_suffix = "METAL"
                elseif mat_flags.IS_STONE or inorg_flags.SOIL_ANY or inorg_flags.SOIL_SAND then
                    final_val = base_metal.value + math.floor(reagent_val / 12)
                    base_cat_suffix = "STONE"
                end

                -- ROUTINE A: COLOR FINISH
                local c_mat_id = string.format("REFINISH_STEEL_MAT_COLOUR_%s_%s_MV%d", color_id, base_metal.id, final_val)
                local c_rxn_id = string.format("REFINISH_STEEL_RXN_COLOUR_%s_%s", base_metal.id, mat.id)

                if not _G.refinish_blueprint.materials[c_mat_id] then
                    _G.refinish_blueprint.materials[c_mat_id] = {
                        color_idx = color_idx,
                        mat_value = final_val,
                        adj_name = clean_color_name .. " " .. base_metal.name,
                        base_metal_id = base_metal.id
                    }
                    color_mats_created = color_mats_created + 1
                end

                _G.refinish_blueprint.reactions[c_rxn_id] = {
                    name = clean_color_name .. " " .. base_metal.name .. " (" .. string.lower(solid_name) .. " dust)",
                    reagent_id = mat.id,
                    base_metal_id = base_metal.id, 
                    dust_code = string.lower(solid_name) .. " dust",
                    output_mat_id = c_mat_id,
                    -- Routing to the new Base-First structure
                    category = "REFINISH_STEEL_CAT_BASE_" .. base_metal.id .. "_COLOUR_" .. base_cat_suffix 
                }

                -- ROUTINE B: SPECIFIC 1:1 FINISH
                if perf_setting == 'ON' or SPECIAL_FINISH[mat.id] then
                    local clean_adj_name = string.lower(solid_name) .. " " .. base_metal.name
                    if SPECIAL_FINISH[mat.id] then
                        clean_adj_name = SPECIAL_FINISH[mat.id].prefix .. " " .. base_metal.name
                    end

                    local s_mat_id = string.format("REFINISH_STEEL_MAT_SPECIFIC_%s_%s", base_metal.id, mat.id)
                    local s_rxn_id = string.format("REFINISH_STEEL_RXN_SPECIFIC_%s_%s", base_metal.id, mat.id)

                    if not _G.refinish_blueprint.materials[s_mat_id] then
                        _G.refinish_blueprint.materials[s_mat_id] = {
                            color_idx = color_idx,
                            mat_value = final_val,
                            adj_name = clean_adj_name,
                            base_metal_id = base_metal.id
                        }
                        specific_mats_created = specific_mats_created + 1
                    end

                    _G.refinish_blueprint.reactions[s_rxn_id] = {
                        name = clean_adj_name .. " (" .. string.lower(solid_name) .. " dust)",
                        reagent_id = mat.id,
                        base_metal_id = base_metal.id,
                        dust_code = string.lower(solid_name) .. " dust", 
                        output_mat_id = s_mat_id,
                        category = "REFINISH_STEEL_CAT_BASE_" .. base_metal.id .. "_MAT_" .. base_cat_suffix
                    }
                end
            end
            
            valid_reagents = valid_reagents + 1
        else
            if not is_valid_type then rej_type = rej_type + 1
            elseif not is_stable_solid then rej_phase = rej_phase + 1
            elseif not is_valid_value then rej_value = rej_value + 1
            end
        end
    end
end

local total_rejected = rej_type + rej_phase + rej_value + rej_ghost
if _G.refinish_log_event then 
    _G.refinish_log_event(string.format("SCANNER: Intake complete. %d reagents accepted, %d rejected (Type: %d, Phase: %d, Value: %d, Ghost Metal: %d).", 
        valid_reagents, total_rejected, rej_type, rej_phase, rej_value, rej_ghost)) 
end

-- ==========================================
-- UI DICTIONARY CACHE (O(1) LOOKUPS FOR HUD)
-- ==========================================
_G.refinish_blueprint.ui_dict = { 
    metal_names = {}, 
    ore_map = {}, 
    finish_counts = {}
}

for _, inorg in ipairs(inorganics) do
    local raw_name = inorg.material.state_name[0] or inorg.id
    local clean_name = raw_name:gsub("_", " "):gsub("(%S+)", function(word)
        return word:sub(1,1):upper() .. word:sub(2):lower()
    end)
    _G.refinish_blueprint.ui_dict.metal_names[inorg.id] = clean_name

    if inorg.metal_ore and inorg.metal_ore.mat_index then
        for _, target_idx in ipairs(inorg.metal_ore.mat_index) do
            local target_mat = inorganics[target_idx]
            if target_mat then _G.refinish_blueprint.ui_dict.ore_map[target_mat.id] = true end
        end
    end
end

for _, rxn in pairs(_G.refinish_blueprint.reactions) do
    local base = rxn.base_metal_id
    if base then
        _G.refinish_blueprint.ui_dict.finish_counts[base] = (_G.refinish_blueprint.ui_dict.finish_counts[base] or 0) + 1
    end
end

-- ==========================================
-- CIV TECH (FROM BOOT CACHE)
-- ==========================================
-- Boot's Pass 4 already evaluated every civilization's tech capabilities
-- and cached the results in _G.refinish_civ_tech. We copy it into the
-- blueprint so downstream consumers (index-entity, panel-civs, etc.)
-- find it in the expected location.
-- ==========================================
_G.refinish_blueprint.civ_tech = _G.refinish_civ_tech or {}

local total_mats = color_mats_created + specific_mats_created
print(string.format("Scan Complete: Mapped %d Reagents across %d Bases to %d Total Materials.", valid_reagents, #active_bases, total_mats))
print(string.format("  -> %d Condensed Color Materials", color_mats_created))
print(string.format("  -> %d Specific Material Materials", specific_mats_created))
print("Blueprint Table populated in memory.")
print("==================================================")
if _G.refinish_log_event then _G.refinish_log_event(string.format("SCANNER: Scan Complete. Mapped %d reagents to %d total materials (%d Color, %d Specific).", valid_reagents, total_mats, color_mats_created, specific_mats_created)) end