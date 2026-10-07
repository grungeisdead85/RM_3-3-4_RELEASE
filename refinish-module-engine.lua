--@ module = true
-- refinish-module-engine.lua
-- ==========================================
-- RM MODULE ENGINE (ORCHESTRATOR)
-- ==========================================
-- The outer shell of the module system. Handles:
--   1. Listener registration (public API for module Lua files)
--   2. Token call broadcast (discover registered modules)
--   3. JSON loading and validation
--   4. Pipeline sequencing (clone eval -> inject materials ->
--      inject categories -> inject reactions)
--   5. Cleanup (LIFO sweep of all module assets on shutdown)
--
-- NOTE: Permissions are NOT handled here. They require civ_tech
-- data from boot Pass 3, which hasn't run yet when the module
-- pipeline fires. Permission evaluation is deferred to:
--   refinish-module-evaluate-permissions.lua
-- which runs during startup Step 5.5 (after boot, before
-- core entity injection).
--
-- This file is intentionally thin. The heavy lifting lives in:
--   refinish-module-types.lua       - Type dictionaries
--   refinish-module-validate.lua    - Schema validation
--   refinish-evaluate-clone-source.lua - Clone donor selection
--   refinish-module-inject.lua      - Material injection
--   refinish-module-react.lua       - Reaction/category injection
--   refinish-module-evaluate-permissions.lua - Permission evaluation
--
-- CALLED FROM:
--   refinish_steel.lua (boot step 1)
--   refinish-startup.lua (pipeline step 2)
--   refinish-shutdown.lua (cleanup)
--
-- PUBLIC API:
--   register_listener(name, callback) - Called by module Lua files
--   run_module_pipeline()             - Called by startup
--   clear_module_assets()             - Called by shutdown
-- ==========================================

local json = require('json')
local validator = reqscript('refinish-module-validate')
local clone_eval = reqscript('refinish-evaluate-clone-source')
local injector = reqscript('refinish-module-inject')
local reactor = reqscript('refinish-module-react')


-- ==========================================
-- MODULE REGISTRY (lives for the session)
-- ==========================================
-- Each entry is keyed by prefix string and contains the module's
-- validated payload (materials, reactions, categories, identity).
-- Populated during the token call, consumed during injection,
-- referenced during cleanup.
-- ==========================================
_G.refinish_module_registry = _G.refinish_module_registry or {}


-- ==========================================
-- UTILITY
-- ==========================================
local function count_table(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- ==========================================
-- PREFIX MATCHING
-- ==========================================
-- Anchored, plain-text prefix test.
--
-- The obvious version, string.find(str, prefix), is wrong twice over.
-- It is unanchored, so "ARGMOD_" matches "ARGMYTH_ARGMOD_..." anywhere
-- in the string and, worse, matches any longer prefix built on the same
-- stem. And its second argument is a Lua pattern, not a literal, so a
-- prefix containing - or % or . would behave unpredictably.
--
-- string.sub avoids both. It compares literal characters and only ever
-- looks at the start of the string.
-- ==========================================
local function has_prefix(str, prefix)
    return string.sub(str, 1, #prefix) == prefix
end

-- ==========================================
-- STEP 1: LISTENER REGISTRATION
-- ==========================================
-- External modules call this at load time to register their
-- callback for the token call. The callback should return a
-- table with two keys:
--   materials_json - path to the materials JSON file, or nil
--   reactions_json - path to the reactions JSON file, or nil
--
-- Or it can return pre-built payload tables directly (for
-- power users who build payloads in Lua, like Making Metal).
--
-- Usage from a module's Lua file:
--   local engine = dfhack.script_environment('refinish-module-engine')
--   engine.register_listener("my_mod", function()
--       return {
--           materials_json = "path/to/my_mod_materials.json",
--           reactions_json = "path/to/my_mod_reactions.json",
--       }
--   end)
-- ==========================================
-- mod_id is optional and should be the [ID:...] string from the
-- module's info.txt. When supplied, broadcast_token_call checks it
-- against get_active_mods and skips the module in worlds where it
-- is not installed. Omitting it means the module is always broadcast
-- to, which is correct for Lua-only modules with no mod folder.
function register_listener(module_name, callback, mod_id)
    _G.refinish_module_listeners = _G.refinish_module_listeners or {}
    _G.refinish_module_listeners[module_name] = {
        callback = callback,
        mod_id   = mod_id,
    }
    if _G.refinish_log_event then
        _G.refinish_log_event(string.format(
            "MODULE ENGINE: Listener registered: [%s].", module_name
        ))
    end
end


-- ==========================================
-- JSON FILE LOADER
-- ==========================================
-- Reads and parses a JSON file from disk. Returns the parsed
-- table on success, nil + error on failure.
-- ==========================================
local function load_json_file(path)
    local file = io.open(path, "r")
    if not file then
        return nil, "Cannot open file: " .. path
    end

    local content = file:read("*all")
    file:close()

    if not content or content == "" then
        return nil, "File is empty: " .. path
    end

    local ok, parsed = pcall(json.decode, content)
    if not ok then
        return nil, "JSON parse error in " .. path .. ": " .. tostring(parsed)
    end

    return parsed
end


-- ==========================================
-- STEP 2: TOKEN CALL BROADCAST
-- ==========================================
-- Broadcasts to all registered listeners. Each listener returns
-- either JSON file paths or pre-built payload tables. We load,
-- validate, and register each module.
-- ==========================================
-- Mod ids active in the CURRENT world, keyed for lookup. Nil when the
-- API is unavailable, which means "cannot tell" and must not be read
-- as "nothing is active".
local function active_mod_ids()
    local ok, sm = pcall(require, 'script-manager')
    if not ok or not sm or not sm.get_active_mods then return nil end
    local ok2, mods = pcall(sm.get_active_mods)
    if not ok2 or type(mods) ~= 'table' then return nil end
    local ids = {}
    for _, m in ipairs(mods) do
        if m.id then ids[m.id] = true end
    end
    return ids
end

local function broadcast_token_call()
    _G.refinish_module_registry = {}
    local accepted = 0
    local rejected = 0

    -- Listeners are _G globals and the DFHack Lua state outlives the
    -- world, so a module registered under one save is still sitting
    -- here when a different save loads. Modules guard themselves with
    -- getModSourcePath, but that resolves against installed_mods
    -- globally rather than the loaded world, so it answers for a mod
    -- this save never had.
    --
    -- Reproduced live: load a save with ArgMOD, switch to a save
    -- without it, and ArgMOD injects anyway. Because it injects first,
    -- every module after it shifts index and already-built workshops
    -- render as the wrong material.
    --
    -- get_active_mods is world-scoped, so it is the correct gate.
    -- Listeners are matched by mod_id when the module supplies one.
    -- A module that supplies none is always broadcast to, which keeps
    -- Lua-only modules and the older registration signature working.
    -- Absence from get_active_mods has two causes and only one of them
    -- means "skip". getModSourcePath resolves against every installed
    -- mod, not just the loaded world (Lua_API: returns nil only if the
    -- mod cannot be found at all, and returns the newest version's path
    -- when the world simply has not loaded it). So a nil path means the
    -- mod_id matches nothing on disk, which is a bad id rather than an
    -- inactive world.
    --
    -- That distinction matters because dropping a module shrinks the
    -- injected material band and shifts every index after it. Skipping
    -- on a typo would cause the exact corruption this gate exists to
    -- prevent. An unresolvable id therefore fails open and says so,
    -- which matches how a listener with no mod_id at all is treated.
    local function mod_id_resolves(mod_id)
        local ok, sm = pcall(require, 'script-manager')
        if not ok or not sm or not sm.getModSourcePath then return true end
        local ok2, path = pcall(sm.getModSourcePath, mod_id)
        if not ok2 then return true end
        return path ~= nil
    end

    local active = active_mod_ids()

    -- DIAGNOSTIC: record exactly what the world reported before any
    -- gating decision is made, so a dropped module can be attributed
    -- rather than guessed at. If a module's id is absent from this
    -- list while its mod is installed in the world, the fault is in
    -- get_active_mods at this call site, not in the comparison below.
    -- This only logs. No behaviour changes.
    if _G.refinish_log_event then
        if not active then
            _G.refinish_log_event(
                "MODULE ENGINE: get_active_mods unavailable. No listener gated this broadcast.")
        else
            local ids = {}
            for id, _ in pairs(active) do table.insert(ids, id) end
            table.sort(ids)
            _G.refinish_log_event(string.format(
                "MODULE ENGINE: World reports %d active mod(s): %s",
                #ids, table.concat(ids, ", ")))
        end
    end

    local listeners = {}
    local skipped = 0
    for name, entry in pairs(_G.refinish_module_listeners or {}) do
        local callback, mod_id = entry, nil
        if type(entry) == 'table' then
            callback, mod_id = entry.callback, entry.mod_id
        end
        if active and mod_id and not active[mod_id] then
            if mod_id_resolves(mod_id) then
                -- Installed somewhere, just not in this world. Correct skip.
                skipped = skipped + 1
                if _G.refinish_log_event then
                    _G.refinish_log_event(string.format(
                        "MODULE ENGINE: [%s] is not active in this world. Skipped.", name))
                end
            else
                -- Matches no installed mod. Treat as unknown, not absent.
                listeners[name] = callback
                if _G.refinish_log_event then
                    _G.refinish_log_event(string.format(
                        "MODULE ENGINE WARNING: [%s] declares mod_id [%s], which matches no installed mod. Broadcasting anyway. Correct the id to match info.txt.",
                        name, tostring(mod_id)))
                end
            end
        else
            listeners[name] = callback
        end
    end
    if skipped > 0 and _G.refinish_log_event then
        _G.refinish_log_event(string.format(
            "MODULE ENGINE: %d listener(s) skipped as inactive in this world.", skipped))
    end

    if _G.refinish_log_event then
        _G.refinish_log_event(string.format(
            "MODULE ENGINE: Token call broadcast. %d listeners registered.",
            count_table(listeners)
        ))
    end

    for module_name, callback in pairs(listeners) do
        -- Call the listener to get its payload or file paths
        local ok, response = pcall(callback)
        if not ok then
            rejected = rejected + 1
            print(string.format("Refinish Metal: Module [%s] crashed during token call: %s",
                tostring(module_name), tostring(response)))
            if _G.refinish_log_event then
                _G.refinish_log_event(string.format(
                    "MODULE ENGINE: Module [%s] crashed: %s",
                    tostring(module_name), tostring(response)
                ))
            end
            goto continue
        end

        if not response then
            rejected = rejected + 1
            print(string.format(
                "Refinish Metal: Module [%s] returned nothing from its token call. " ..
                "The usual cause is a MODULE_ID that does not match the mod's info.txt, " ..
                "which leaves the module unable to locate its own data folder.",
                tostring(module_name)))
            if _G.refinish_log_event then
                _G.refinish_log_event(string.format(
                    "MODULE ENGINE: [%s] rejected: listener returned nil.",
                    tostring(module_name)
                ))
            end
            goto continue
        end

        -- ---- RESOLVE MATERIALS ----
        local materials_payload = nil
        if response.materials_json then
            -- JSON file path mode
            local parsed, err = load_json_file(response.materials_json)
            if not parsed then
                rejected = rejected + 1
                print(string.format("Refinish Metal: Module [%s] materials file error: %s",
                    tostring(module_name), err))
                if _G.refinish_log_event then
                    _G.refinish_log_event(string.format(
                        "MODULE ENGINE: [%s] materials file error: %s",
                        tostring(module_name), err
                    ))
                end
                goto continue
            end
            materials_payload = parsed
        elseif response.materials then
            -- Pre-built payload mode (Lua power users)
            materials_payload = response
        end

        -- ---- RESOLVE REACTIONS ----
        local reactions_payload = nil
        if response.reactions_json then
            local parsed, err = load_json_file(response.reactions_json)
            if not parsed then
                rejected = rejected + 1
                print(string.format("Refinish Metal: Module [%s] reactions file error: %s",
                    tostring(module_name), err))
                if _G.refinish_log_event then
                    _G.refinish_log_event(string.format(
                        "MODULE ENGINE: [%s] reactions file error: %s",
                        tostring(module_name), err
                    ))
                end
                goto continue
            end
            reactions_payload = parsed
        elseif response.reactions then
            -- Pre-built payload mode
            reactions_payload = response
        end

        -- ---- VALIDATE ----
        local prefix = nil

        if materials_payload then
            local ok_v, valid, reason = pcall(validator.validate_materials, materials_payload)
            if not ok_v then
                valid, reason = false, "validator error: " .. tostring(valid)
            end
            if not valid then
                rejected = rejected + 1
                print(string.format("Refinish Metal: Module [%s] materials validation failed: %s",
                    tostring(module_name), reason))
                if _G.refinish_log_event then
                    _G.refinish_log_event(string.format(
                        "MODULE ENGINE WARNING: [%s] materials validation failed: %s",
                        tostring(module_name), reason
                    ))
                end
                goto continue
            end
            prefix = materials_payload.module.prefix
        end

        if reactions_payload then
            local ok_v, valid, reason = pcall(validator.validate_reactions, reactions_payload)
            if not ok_v then
                valid, reason = false, "validator error: " .. tostring(valid)
            end
            if not valid then
                rejected = rejected + 1
                print(string.format("Refinish Metal: Module [%s] reactions validation failed: %s",
                    tostring(module_name), reason))
                if _G.refinish_log_event then
                    _G.refinish_log_event(string.format(
                        "MODULE ENGINE WARNING: [%s] reactions validation failed: %s",
                        tostring(module_name), reason
                    ))
                end
                goto continue
            end
            -- Cross-check: if both payloads exist, prefixes must match
            if prefix and reactions_payload.module.prefix ~= prefix then
                rejected = rejected + 1
                print(string.format("Refinish Metal: Module [%s] prefix mismatch: materials='%s', reactions='%s'",
                    tostring(module_name), prefix, reactions_payload.module.prefix))
                goto continue
            end
            prefix = prefix or reactions_payload.module.prefix
        end

        -- ---- PREFIX COLLISION CHECK ----
        if not prefix then
            rejected = rejected + 1
            print(string.format(
                "Refinish Metal: Module [%s] supplied no prefix. Neither payload loaded.",
                tostring(module_name)))
            if _G.refinish_log_event then
                _G.refinish_log_event(string.format(
                    "MODULE ENGINE WARNING: [%s] rejected: no prefix in either payload.",
                    tostring(module_name)
                ))
            end
            goto continue
        end

        -- Two prefixes collide when either is a stem of the other, not
        -- only when they are equal. Every sweep in this engine selects
        -- assets by prefix, so "ARGMOD_" also selects
        -- "ARGMOD_MYTH_ORICHALCUM", and ArgMOD's shutdown would clear
        -- another module's materials. Anchoring the comparison does not
        -- help: a stem really is at the start of the string. Refusing
        -- the overlap here is the only fix.
        --
        -- has_prefix(x, x) is true, so this also catches the exact
        -- duplicate registration the old check was looking for.
        local clash = nil
        if has_prefix(prefix, "REFINISH_STEEL_") or has_prefix("REFINISH_STEEL_", prefix) then
            clash = "REFINISH_STEEL_ (RM core)"
        else
            for other, _ in pairs(_G.refinish_module_registry) do
                if has_prefix(prefix, other) or has_prefix(other, prefix) then
                    clash = other
                    break
                end
            end
        end

        if clash then
            rejected = rejected + 1
            print(string.format(
                "Refinish Metal: Module [%s] prefix [%s] overlaps [%s]. One is a stem of the other, so their assets cannot be told apart. Choose a prefix that is not built on another module's.",
                tostring(module_name), prefix, clash))
            if _G.refinish_log_event then
                _G.refinish_log_event(string.format(
                    "MODULE ENGINE WARNING: [%s] rejected: prefix [%s] overlaps [%s].",
                    tostring(module_name), prefix, clash
                ))
            end
            goto continue
        end

        -- ---- REGISTER ----
        local mod_name = "unknown"
        local depends_on = {}
        if materials_payload and materials_payload.module then
            mod_name = materials_payload.module.name
            depends_on = materials_payload.module.depends_on or {}
        elseif reactions_payload and reactions_payload.module then
            mod_name = reactions_payload.module.name
            depends_on = reactions_payload.module.depends_on or {}
        end

        -- If only the reactions file declares dependencies, honour them.
        -- Modules are free to put depends_on in either file or both, the
        -- same way they may declare the prefix in either.
        if #depends_on == 0 and reactions_payload and reactions_payload.module then
            depends_on = reactions_payload.module.depends_on or {}
        end

        _G.refinish_module_registry[prefix] = {
            name       = mod_name,
            prefix     = prefix,
            depends_on = depends_on,
            materials  = materials_payload and materials_payload.materials or {},
            reactions  = reactions_payload and reactions_payload.reactions or {},
            categories = reactions_payload and reactions_payload.categories or {},
        }

        accepted = accepted + 1
        local mat_count = materials_payload and #materials_payload.materials or 0
        local rxn_count = reactions_payload and #reactions_payload.reactions or 0

        if _G.refinish_log_event then
            _G.refinish_log_event(string.format(
                "MODULE ENGINE: Accepted [%s] prefix [%s] (%d materials, %d reactions).",
                mod_name, prefix, mat_count, rxn_count
            ))
        end

        ::continue::
    end

    if _G.refinish_log_event then
        _G.refinish_log_event(string.format(
            "MODULE ENGINE: Token call complete. %d accepted, %d rejected.",
            accepted, rejected
        ))
    end

    return accepted
end

-- ==========================================
-- INJECTION ORDER RESOLUTION
-- ==========================================
-- Decides which order modules are injected in.
--
-- WHY THIS EXISTS:
-- The engine injects one whole module at a time (materials, then
-- categories, then reactions). Reaction building resolves mat_id
-- references against the live inorganic array as it stands at that
-- moment, so a module can only name materials from raws, from itself,
-- or from a module already injected. Get the order wrong and the
-- references resolve to -1, which DF renders as magma.
--
-- Modules declare what they need via module.depends_on. This turns
-- that into a concrete order.
--
-- HOW:
-- Kahn's algorithm. Repeatedly take a module with no unplaced
-- dependencies and append it. Ready modules are taken in alphabetical
-- order rather than whatever order pairs() happens to produce, so the
-- result is identical on every data cycle. That matters: injected
-- material positions have to be stable across a hotsave.
--
-- Modules whose dependencies are not installed are dropped, and so is
-- anything depending on those, transitively. See the note in the
-- change document about why dropping beats loading broken.
--
-- Returns: an ordered array of prefixes to inject.
-- ==========================================
local function resolve_injection_order(registry)
    -- Alphabetical baseline. Everything below preserves this order
    -- among modules that the dependency graph leaves interchangeable.
    local prefixes = {}
    for prefix, _ in pairs(registry) do
        table.insert(prefixes, prefix)
    end
    table.sort(prefixes)

    local present = {}
    for _, p in ipairs(prefixes) do
        present[p] = true
    end

    -- ---- STEP 1: DROP MODULES WITH MISSING DEPENDENCIES ----
    -- Loops until nothing changes, so a module depending on a dropped
    -- module is dropped too, however long the chain is.
    local dropped = {}
    local changed = true
    while changed do
        changed = false
        for _, p in ipairs(prefixes) do
            if not dropped[p] then
                for _, dep in ipairs(registry[p].depends_on or {}) do
                    if not present[dep] or dropped[dep] then
                        dropped[p] = dep
                        changed = true
                        break
                    end
                end
            end
        end
    end

    for _, p in ipairs(prefixes) do
        if dropped[p] then
            print(string.format(
                "Refinish Metal: Module [%s] skipped: requires module [%s], which is not loaded.",
                registry[p].name, dropped[p]))
            if _G.refinish_log_event then
                _G.refinish_log_event(string.format(
                    "MODULE ENGINE WARNING: Skipped [%s]: unmet dependency [%s].",
                    p, dropped[p]
                ))
            end
        end
    end

    -- ---- STEP 2: BUILD THE GRAPH ----
    -- unmet[p]      = how many of p's dependencies are not yet placed
    -- dependents[p] = modules waiting on p
    local unmet, dependents = {}, {}
    for _, p in ipairs(prefixes) do
        if not dropped[p] then
            unmet[p] = 0
            dependents[p] = dependents[p] or {}
        end
    end
    for _, p in ipairs(prefixes) do
        if not dropped[p] then
            for _, dep in ipairs(registry[p].depends_on or {}) do
                unmet[p] = unmet[p] + 1
                dependents[dep] = dependents[dep] or {}
                table.insert(dependents[dep], p)
            end
        end
    end

    -- ---- STEP 3: PLACE THEM ----
    local order, placed = {}, {}
    local remaining = 0
    for _ in pairs(unmet) do
        remaining = remaining + 1
    end

    while remaining > 0 do
        -- First unplaced module with nothing left to wait for.
        -- prefixes is sorted, so this is the alphabetical tie-break.
        local pick = nil
        for _, p in ipairs(prefixes) do
            if unmet[p] == 0 and not placed[p] then
                pick = p
                break
            end
        end

        -- Nothing is ready, so the remainder form a dependency cycle.
        -- Break it alphabetically and say so. One of the modules in
        -- the cycle will inject before something it declared it needs,
        -- so its references may not resolve.
        if not pick then
            for _, p in ipairs(prefixes) do
                if unmet[p] and not placed[p] then
                    pick = p
                    break
                end
            end
            print(string.format(
                "Refinish Metal: Module dependency cycle detected. Breaking it at [%s].", pick))
            if _G.refinish_log_event then
                _G.refinish_log_event(string.format(
                    "MODULE ENGINE WARNING: Dependency cycle, broken at [%s].", pick
                ))
            end
        end

        table.insert(order, pick)
        placed[pick] = true
        remaining = remaining - 1

        for _, waiting in ipairs(dependents[pick] or {}) do
            if unmet[waiting] then
                unmet[waiting] = unmet[waiting] - 1
            end
        end
    end

    return order
end

-- ==========================================
-- STEP 3: PIPELINE EXECUTION
-- ==========================================
-- Runs the module pipeline in order:
--   1. Token call (discover and validate modules)
--   2. Clone source evaluation (pick donors per class)
--   3. Material injection (per module)
--   4. Category injection (per module)
--   5. Reaction injection (per module)
--
-- Permission injection is NOT part of this pipeline.
-- It runs later via refinish-module-evaluate-permissions.lua
-- (startup Step 5.5), after boot has built civ_tech.
--
-- Guard: _G.refinish_modules_injected prevents double-firing
-- during boot. Cleared on shutdown so re-firing works after
-- a data cycle wipe.
-- ==========================================
function run_module_pipeline()
    if _G.refinish_modules_injected then return end

    -- ---- STEP 1: TOKEN CALL ----
    local module_count = broadcast_token_call()
    if module_count == 0 then
        if _G.refinish_log_event then
            _G.refinish_log_event("MODULE ENGINE: No modules responded. Pipeline skipped.")
        end
        return
    end

    -- ---- STEP 2: CLONE SOURCE EVALUATION ----
    -- Collect which material classes are actually needed across
    -- all registered modules, so the evaluator only scans for
    -- classes that will be used.
    local classes_needed = {}
    local class_set = {}
    for _, module in pairs(_G.refinish_module_registry) do
        for _, mat in ipairs(module.materials) do
            if mat.material_class and not class_set[mat.material_class] then
                table.insert(classes_needed, mat.material_class)
                class_set[mat.material_class] = true
            end
        end
    end
    clone_eval.evaluate(classes_needed)

    -- Log the clone selections for visibility
    if _G.refinish_log_event and _G.refinish_module_clone_cache then
        for _, class_name in ipairs(classes_needed) do
            local donor = _G.refinish_module_clone_cache[class_name]
            if donor then
                _G.refinish_log_event(string.format(
                    "MODULE ENGINE: Clone selection: [%s] -> [%s].",
                    class_name, donor.id
                ))
            else
                _G.refinish_log_event(string.format(
                    "MODULE ENGINE WARNING: Clone selection: [%s] -> NO DONOR FOUND.",
                    class_name
                ))
            end
        end
    end

    -- ---- STEPS 3-5: PER-MODULE INJECTION ----
    -- Order comes from resolve_injection_order, which honours declared
    -- dependencies and falls back to alphabetical wherever the graph
    -- does not care. Deterministic across cycles either way.
    --
    -- NOTE: Permissions are NOT injected here. They require
    -- civ_tech data from boot Pass 3 (which metals each civ
    -- knows), and boot hasn't run yet at this point in the
    -- pipeline. Permission injection is handled by the dedicated
    -- evaluator (refinish-module-evaluate-permissions.lua) which
    -- runs after boot, during startup Step 5.5.
    local injection_order = resolve_injection_order(_G.refinish_module_registry)

    -- Published so the permission evaluator uses the same order.
    -- Cleared by clear_module_assets on shutdown.
    _G.refinish_module_order = injection_order

    local total_mats = 0
    local total_cats = 0
    local total_rxns = 0

    -- Reports a failed injection step and returns 0 so the running
    -- totals stay valid.
    --
    -- Lua puts "file:line:" at the front of every runtime error, so the
    -- message alone identifies where it happened. No traceback needed,
    -- and nothing here uses a facility this codebase has not already
    -- proven works.
    local function report_failure(label, prefix, err)
        local msg = string.format("MODULE ENGINE WARNING: %s FAILED for [%s]: %s",
                                  label, prefix, tostring(err))
        print(msg)
        if _G.refinish_log_event then
            _G.refinish_log_event(msg)
        end
        return 0
    end

    for _, prefix in ipairs(injection_order) do
        local module = _G.refinish_module_registry[prefix]

        -- Each step is wrapped on its own. A fault anywhere in the
        -- injection path used to unwind the whole pipeline with nothing
        -- in the log to say which module or which step, which cost
        -- every remaining module too. Now one step failing costs one
        -- step, and says so.
        --
        -- Explicit closures rather than a varargs wrapper: no unpack,
        -- so there is no Lua version question to get wrong.

        -- Materials
        if #module.materials > 0 then
            local ok, res = pcall(function()
                return injector.inject(module.materials, prefix, module.name)
            end)
            if ok then
                total_mats = total_mats + (res or 0)
            else
                report_failure("MATERIAL INJECTION", prefix, res)
            end
        end

        -- Categories (before reactions, so category IDs exist when
        -- reactions reference them)
        if module.categories and #module.categories > 0 then
            local ok, res = pcall(function()
                return reactor.inject_categories(module.categories, prefix)
            end)
            if ok then
                total_cats = total_cats + (res or 0)
            else
                report_failure("CATEGORY INJECTION", prefix, res)
            end
        end

        -- Reactions
        if #module.reactions > 0 then
            local ok, res = pcall(function()
                return reactor.inject_reactions(
                    module.reactions, prefix, module.name,
                    _G.refinish_module_registry
                )
            end)
            if ok then
                total_rxns = total_rxns + (res or 0)
            else
                report_failure("REACTION INJECTION", prefix, res)
            end
        end
    end

    -- ---- FINAL PASS: CROSS-MODULE REACTION PRODUCTS ----
    -- Runs after every module's materials exist, so a reaction_product
    -- pointing at another module resolves regardless of which order the
    -- two injected in. See resolve_deferred_products() for why ordering
    -- alone cannot solve this.
    local resolved = injector.resolve_deferred_products()
    if resolved > 0 and _G.refinish_log_event then
        _G.refinish_log_event(string.format(
            "MODULE INJECT: Resolved %d deferred reaction_product definitions across all modules.",
            resolved
        ))
    end

    _G.refinish_modules_injected = true

    print(string.format(
        "Refinish Metal Modules: %d modules loaded: %d materials, %d categories, %d reactions.",
        module_count, total_mats, total_cats, total_rxns
    ))
    if _G.refinish_log_event then
        _G.refinish_log_event(string.format(
            "MODULE ENGINE: Pipeline complete: %d modules, %d materials, %d categories, %d reactions. Permissions deferred to evaluator.",
            module_count, total_mats, total_cats, total_rxns
        ))
    end
end


-- ==========================================
-- CLEANUP: CLEAR ALL MODULE ASSETS
-- ==========================================
-- Sweeps all materials, reactions, and categories for each
-- registered module prefix. Called during RM's shutdown
-- sequence alongside the REFINISH_STEEL_ sweep.
--
-- Order matters:
--   1. Entity permissions (remove reaction indexes from civs)
--   2. Reactions (LIFO sweep)
--   3. Categories (LIFO sweep)
--   4. Materials (LIFO sweep)
--
-- Permissions first because they reference reaction indexes.
-- Reactions before materials because reactions may reference
-- material indexes. LIFO (end-to-start) preserves earlier
-- indexes during deletion.
-- ==========================================
function clear_module_assets()
    local total_cleared = 0

    -- ---- COLLECT ALL REACTION INDEXES TO REMOVE ----
    local reactions = df.global.world.raws.reactions.reactions
    local rxn_ids_to_remove = {}
    for prefix, _ in pairs(_G.refinish_module_registry) do
        for i, rxn in ipairs(reactions) do
            if has_prefix(rxn.code, prefix) then
                rxn_ids_to_remove[rxn.index] = true
            end
        end
    end

    -- ---- STEP 1: SWEEP ENTITY PERMISSIONS ----
    -- Remove module reaction indexes from all civ permission lists.
    -- Must happen before reactions are deleted to avoid dangling refs.
    for _, civ in ipairs(df.global.world.entities.all) do
        if civ.type == df.historical_entity_type.Civilization and civ.entity_raw then
            local permitted = civ.entity_raw.workshops.permitted_reaction_id
            for i = #permitted - 1, 0, -1 do
                if rxn_ids_to_remove[permitted[i]] then
                    permitted:erase(i)
                end
            end
        end
    end

    -- ---- PER-PREFIX CLEANUP ----
    for prefix, module in pairs(_G.refinish_module_registry) do
        local mat_cleared = 0
        local rxn_cleared = 0
        local cat_cleared = 0

        -- ---- STEP 2: SWEEP REACTIONS (LIFO) ----
        for i = #reactions - 1, 0, -1 do
            if has_prefix(reactions[i].code, prefix) then
                reactions[i]:delete()
                reactions:erase(i)
                rxn_cleared = rxn_cleared + 1
            end
        end

        -- ---- STEP 3: SWEEP CATEGORIES (LIFO) ----
        local cats = df.global.world.raws.reactions.reaction_categories
        for i = #cats - 1, 0, -1 do
            if has_prefix(cats[i].id, prefix) then
                cats[i]:delete()
                cats:erase(i)
                cat_cleared = cat_cleared + 1
            end
        end

        -- ---- STEP 4: SWEEP MATERIALS (LIFO) ----
        local raws = df.global.world.raws.inorganics.all
        for i = #raws - 1, 0, -1 do
            if has_prefix(raws[i].id, prefix) then
                raws[i]:delete()
                raws:erase(i)
                mat_cleared = mat_cleared + 1
            end
        end

        total_cleared = total_cleared + mat_cleared + rxn_cleared + cat_cleared
        if _G.refinish_log_event then
            _G.refinish_log_event(string.format(
                "MODULE ENGINE: Cleared [%s]: %d materials, %d reactions, %d categories.",
                prefix, mat_cleared, rxn_cleared, cat_cleared
            ))
        end
    end

    _G.refinish_modules_injected = false
    _G.refinish_module_order = nil
    _G.refinish_module_deferred_products = nil
    return total_cleared
end


return _ENV