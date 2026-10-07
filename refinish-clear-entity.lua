-- refinish-clear-entity.lua
-- Removes dynamically injected reactions from all civilization UIs globally.

local VERBOSE_DEBUG = false
local debug_file = nil

local function dprint(msg)
    if debug_file then debug_file:write(msg .. "\n") end
end

if VERBOSE_DEBUG then
    debug_file = io.open(dfhack.getDFPath() .. "/refinish_clear_entity_debug.txt", "w")
    dprint("==================================================")
    dprint("REFINISH STEEL: CLEAR ENTITY DEBUG LOG")
    dprint("==================================================")
end

-- STATE MANAGER: Deep RAM Verification (Using player civ as a proxy check)
if _G.refinish_entity_loaded == nil or _G.refinish_entity_loaded == true then
    local actually_loaded = false
    local player_civ = df.historical_entity.find(df.global.plotinfo.civ_id)
    if player_civ and player_civ.entity_raw then
        local permitted = player_civ.entity_raw.workshops.permitted_reaction_id
        local reactions = df.global.world.raws.reactions.reactions
        for _, pid in ipairs(permitted) do
            if pid >= 0 and pid < #reactions then
                local rxn = reactions[pid]
                if rxn and string.find(rxn.code, "REFINISH_STEEL_RXN_") then
                    actually_loaded = true
                    break
                end
            end
        end
    end
    if not actually_loaded then _G.refinish_entity_loaded = false end
end

if not _G.refinish_entity_loaded then
    print("Refinish Metal: UI already locked. Skipping.")
    if _G.refinish_log_event then _G.refinish_log_event("CLEAR ENTITY: UI already locked. Skipping.") end
    return
end

local rxn_ids_to_remove = {}
local reactions_array = df.global.world.raws.reactions.reactions

-- First, map out the integer IDs of our injected reactions
for i = #reactions_array - 1, 0, -1 do
    local rxn = reactions_array[i]
    if string.find(rxn.code, "REFINISH_STEEL_") then
        rxn_ids_to_remove[rxn.index] = true
    end
end

local processed_raws = {}
local removed_count = 0
local entities_scrubbed = 0

-- Sweep Global Entities and Erase
for _, civ in ipairs(df.global.world.entities.all) do
    if civ.type == df.historical_entity_type.Civilization and civ.entity_raw then
        
        -- Pointer Safety: Only scrub each raw table once
        if not processed_raws[civ.entity_raw] then
            processed_raws[civ.entity_raw] = true
            
            local permitted = civ.entity_raw.workshops.permitted_reaction_id
            local cleared_from_this_entity = 0
            
-- LIFO loop to safely erase from the vector
            for i = #permitted - 1, 0, -1 do
                if rxn_ids_to_remove[permitted[i]] then
                    dprint(string.format("  [-] Erasing Reaction ID %d from Class %s", permitted[i], civ.entity_raw.code))
                    permitted:erase(i)
                    cleared_from_this_entity = cleared_from_this_entity + 1
                    removed_count = removed_count + 1
                end
            end
            
            if cleared_from_this_entity > 0 then
                entities_scrubbed = entities_scrubbed + 1
            end
        end
    end
end

if removed_count > 0 then
    print(string.format("Refinish-Clear-Entity: Excised %d reactions globally from %d civilizations.", removed_count, entities_scrubbed))
    if _G.refinish_log_event then _G.refinish_log_event(string.format("CLEAR ENTITY: Excised %d reactions globally from %d civilization UIs.", removed_count, entities_scrubbed)) end
else
    print("Refinish-Clear-Entity: No UI elements found to clean globally.")
    if _G.refinish_log_event then _G.refinish_log_event("CLEAR ENTITY: No UI elements found to clean globally.") end
end

if debug_file then
    debug_file:close()
    debug_file = nil
end

_G.refinish_entity_loaded = false