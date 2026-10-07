-- refinish-clear-reaction.lua
-- Removes dynamically generated reactions from global memory.

-- STATE MANAGER: Deep RAM Verification
if _G.refinish_reactions_loaded == nil or _G.refinish_reactions_loaded == true then
    local actually_loaded = false
    for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
        if string.find(rxn.code, "REFINISH_STEEL_RXN_") then
            actually_loaded = true
            break
        end
    end
    if not actually_loaded then _G.refinish_reactions_loaded = false end
end

if not _G.refinish_reactions_loaded then
    print("Refinish Metal: Reactions already cleared. Skipping.")
    if _G.refinish_log_event then _G.refinish_log_event("CLEAR RXN: Reactions already cleared. Skipping.") end -- ADDED LOG
    return
end

local reactions_array = df.global.world.raws.reactions.reactions
local scrubbed_rxns = 0

-- LIFO loop prevents array index shifting
for i = #reactions_array - 1, 0, -1 do
    local rxn = reactions_array[i]
    if string.find(rxn.code, "REFINISH_STEEL_") then
        rxn:delete() -- Free the C++ memory allocation
        reactions_array:erase(i) -- Remove the pointer from the global vector
        scrubbed_rxns = scrubbed_rxns + 1
    end
end

if scrubbed_rxns > 0 then
    print("Refinish-Clear-Reaction: Excised " .. scrubbed_rxns .. " injected reactions from RAM.")
    if _G.refinish_log_event then _G.refinish_log_event("CLEAR RXN: Excised " .. scrubbed_rxns .. " injected reactions from RAM.") end -- ADDED LOG
else
    print("Refinish-Clear-Reaction: No reactions found in RAM.")
    if _G.refinish_log_event then _G.refinish_log_event("CLEAR RXN: No reactions found in RAM.") end -- ADDED LOG
end

-- Add this to the bottom of refinish-clear-reaction.lua
local cat_array = df.global.world.raws.reactions.reaction_categories
local scrubbed_cats = 0

for i = #cat_array - 1, 0, -1 do
    local cat = cat_array[i]
    if string.find(cat.id, "REFINISH_STEEL_CAT_") then
        cat:delete()
        cat_array:erase(i)
        scrubbed_cats = scrubbed_cats + 1
    end
end

if scrubbed_cats > 0 then
    print("Refinish-Clear-Reaction: Excised " .. scrubbed_cats .. " UI categories.")
    if _G.refinish_log_event then _G.refinish_log_event("CLEAR RXN: Excised " .. scrubbed_cats .. " UI categories.") end -- ADDED LOG
end

_G.refinish_reactions_loaded = false