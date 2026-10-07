--@ module = true
-- refinish-module-dependencies.lua
-- ==========================================
-- RM MODULE DEPENDENCY JIT CACHE
-- ==========================================
-- Provides O(1) lookups for DF arrays. Walks an array only
-- when explicitly requested by a module, then caches the
-- result in _G for the duration of the session.

local CACHE_BUILDERS = {
    inorganic = function()
        local map = {}
        for _, mat in ipairs(df.global.world.raws.inorganics.all) do
            map[mat.id] = true
        end
        return map
    end,
    
    color = function()
        local map = {}
        for _, c in ipairs(df.global.world.raws.descriptors.colors) do
            map[c.id] = true
        end
        return map
    end,
    
    workshop = function()
        local map = {}
        for _, ws in ipairs(df.global.world.raws.buildings.workshops) do
            map[ws.code] = true
        end
        return map
    end
}

-- ==========================================
-- PUBLIC API: CHECK DEPENDENCY
-- ==========================================
function check(category, id)
    -- Ensure the global cache container exists
    _G.refinish_dependency_cache = _G.refinish_dependency_cache or {}
    local cache = _G.refinish_dependency_cache
    
    -- JIT GATE: Build the map if it hasn't been built yet
    if not cache[category] then
        if CACHE_BUILDERS[category] then
            cache[category] = CACHE_BUILDERS[category]()
        else
            -- Unknown category requested: fail safe and log
            if _G.refinish_log_event then 
                _G.refinish_log_event("DEPENDENCY ERROR: Unknown category requested: " .. tostring(category))
            end
            return false 
        end
    end
    
    -- O(1) Instant Lookup
    return cache[category][id] == true
end

return _ENV