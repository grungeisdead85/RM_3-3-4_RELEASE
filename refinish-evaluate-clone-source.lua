--@ module = true
-- refinish-evaluate-clone-source.lua
-- ==========================================
-- RM MODULE CLONE SOURCE EVALUATOR
-- ==========================================
-- Scans the loaded inorganic array and selects the best clone
-- donor for each material class. Runs once at the start of the
-- module pipeline, caches results in _G, and downstream injection
-- pulls from the cache.
--
-- WHY THIS IS SEPARATE:
--   Clone selection is non-trivial evaluation logic. It walks
--   the entire inorganic array, checks flag signatures, scores
--   candidates, and makes a judgment call. Burying that inside
--   the injection file would make both harder to debug and test.
--   This file runs, caches, and gets out of the way.
--
-- CACHE LOCATION:
--   _G.refinish_module_clone_cache
--   Keyed by material class name (e.g. "METAL", "STONE").
--   Each value is the inorganic_raw object to use as clone donor.
--
-- LIFECYCLE:
--   Populated: Once per module pipeline run (called from engine).
--   Consumed:  By refinish-module-inject.lua during material injection.
--   Cleared:   On shutdown alongside other module globals.
-- ==========================================

local types = reqscript('refinish-module-types')


-- ==========================================
-- SCORE A SINGLE CANDIDATE
-- ==========================================
-- Given an inorganic and a class signature from the types dict,
-- return a numeric score. Higher = better donor. Returns -1 if
-- the candidate fails a hard requirement (disqualified).
--
-- Scoring logic:
--   1. Check require_true flags. ALL must be true or candidate
--      is disqualified (-1).
--   2. Check require_false flags. ALL must be false or candidate
--      is disqualified (-1).
--   3. Base score of 1 for passing requirements.
--   4. Bonus points for each "prefer" flag that's true.
--   5. Penalty for exotic flags that suggest the candidate is
--      unusual (GENERATED, DIVINE, MYTHICAL, SPECIAL, DEEP_SPECIAL).
--      We want plain, vanilla-feeling donors - not artifacts of
--      world-gen or divine intervention.
--   6. Small bonus for having a non-empty state_name (indicates
--      the material has been properly initialized with display data).
-- ==========================================
local function score_candidate(inorganic, signature)
    local mat_flags = inorganic.material.flags

    -- Hard requirements: must have these flags set to true
    for _, flag_name in ipairs(signature.require_true) do
        if not mat_flags[flag_name] then
            return -1
        end
    end

    -- Hard requirements: must have these flags set to false
    for _, flag_name in ipairs(signature.require_false) do
        if mat_flags[flag_name] then
            return -1
        end
    end

    -- Passed requirements - start scoring
    local score = 1

    -- Soft preferences: bonus for each preferred flag
    for _, flag_name in ipairs(signature.prefer) do
        if mat_flags[flag_name] then
            score = score + 5
        end
    end

    -- Exotic penalty: deduct for unusual origin flags.
    -- These materials may carry engine-internal state that
    -- makes them poor structural donors.
    local inorg_flags = inorganic.flags
    local exotic_flags = { "GENERATED", "DIVINE", "MYTHICAL", "MYTHICAL_REMNANT", "SPECIAL", "DEEP_SPECIAL" }
    for _, flag_name in ipairs(exotic_flags) do
        if inorg_flags[flag_name] then
            score = score - 10
        end
    end

    -- Initialization bonus: material has a proper display name
    local solid_name = inorganic.material.state_name.Solid
    if solid_name and solid_name ~= "" then
        score = score + 2
    end

    return score
end


-- ==========================================
-- EVALUATE ONE CLASS
-- ==========================================
-- Walks the full inorganic array and returns the best candidate
-- for a given class signature. Returns nil if no candidate passes
-- the hard requirements.
-- ==========================================
local function evaluate_class(class_name, signature)
    local inorganics = df.global.world.raws.inorganics.all
    local best = nil
    local best_score = -1

    for _, inorganic in ipairs(inorganics) do
        -- Skip any RM-injected or module-injected materials.
        -- We only want vanilla or raws-loaded materials as donors.
        if not string.find(inorganic.id, "REFINISH_STEEL_") then
            local dominated_by_module = false
            if _G.refinish_module_registry then
                for prefix, _ in pairs(_G.refinish_module_registry) do
                    if string.find(inorganic.id, prefix) then
                        dominated_by_module = true
                        break
                    end
                end
            end

            if not dominated_by_module then
                local score = score_candidate(inorganic, signature)
                if score > best_score then
                    best_score = score
                    best = inorganic
                end
            end
        end
    end

    return best, best_score
end


-- ==========================================
-- PUBLIC: RUN EVALUATION
-- ==========================================
-- Evaluates clone donors for every material class that has a
-- signature defined in the types dictionary. Caches results
-- in _G.refinish_module_clone_cache.
--
-- Called once from the module engine before injection runs.
-- Returns the cache table (also accessible via _G).
--
-- The classes_needed parameter is optional. If provided, only
-- those classes are evaluated (saves time when a module only
-- uses METAL, for example). If nil, all classes are evaluated.
-- ==========================================
function evaluate(classes_needed)
    _G.refinish_module_clone_cache = {}
    local cache = _G.refinish_module_clone_cache

    -- Determine which classes to evaluate
    local classes_to_eval = {}
    if classes_needed then
        -- Only evaluate what's actually requested
        for _, class_name in ipairs(classes_needed) do
            if types.CLONE_SIGNATURES[class_name] then
                classes_to_eval[class_name] = types.CLONE_SIGNATURES[class_name]
            end
        end
    else
        -- Evaluate all defined classes
        classes_to_eval = types.CLONE_SIGNATURES
    end

    for class_name, signature in pairs(classes_to_eval) do
        -- RAW class has no signature - it falls back to STONE
        -- as the most structurally neutral inorganic type
        local eval_sig = signature
        if class_name == "RAW" and #signature.require_true == 0 then
            eval_sig = types.CLONE_SIGNATURES["STONE"]
            if not eval_sig then
                -- No stone signature either - skip RAW
                if _G.refinish_log_event then
                    _G.refinish_log_event("CLONE EVAL: RAW class has no fallback signature. Skipped.")
                end
                goto continue
            end
        end

        local best, score = evaluate_class(class_name, eval_sig)

        -- GLASS fallback: vanilla worlds have no IS_GLASS inorganics.
        -- Fall back to CERAMIC donor - structurally closest match
        -- (both are IS_X + ITEMS_HARD, non-metal, non-weapon).
        -- The GLASS preset will flip IS_CERAMIC→false, IS_GLASS→true.
        if not best and class_name == "GLASS" then
            local ceramic_sig = types.CLONE_SIGNATURES["CERAMIC"]
            if ceramic_sig then
                best, score = evaluate_class("GLASS(->CERAMIC)", ceramic_sig)
                if best and _G.refinish_log_event then
                    _G.refinish_log_event(string.format(
                        "CLONE EVAL: Class [GLASS] no native donor. Falling back to CERAMIC donor [%s] (score %d).",
                        best.id, score
                    ))
                end
            end
        end

        if best then
            cache[class_name] = best
            if _G.refinish_log_event then
                _G.refinish_log_event(string.format(
                    "CLONE EVAL: Class [%s] -> donor [%s] (score %d).",
                    class_name, best.id, score
                ))
            end
        else
            -- No candidate found for this class. This is not fatal -
            -- it just means any module materials of this class will
            -- fail at injection time with a clear error.
            if _G.refinish_log_event then
                _G.refinish_log_event(string.format(
                    "CLONE EVAL WARNING: No valid donor found for class [%s].",
                    class_name
                ))
            end
        end

        ::continue::
    end

    local count = 0
    for _ in pairs(cache) do count = count + 1 end

    if _G.refinish_log_event then
        _G.refinish_log_event(string.format("CLONE EVAL: Complete. %d classes resolved.", count))
    end

    return cache
end


-- ==========================================
-- PUBLIC: GET DONOR FOR CLASS
-- ==========================================
-- Convenience accessor. Returns the cached donor for a class,
-- or nil if none was found. Safe to call at any time - returns
-- nil if the evaluator hasn't run yet.
-- ==========================================
function get_donor(class_name)
    if not _G.refinish_module_clone_cache then return nil end
    return _G.refinish_module_clone_cache[class_name]
end


return _ENV