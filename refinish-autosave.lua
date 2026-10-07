-- refinish-autosave.lua
-- ==========================================
-- REFINISH METAL: AUTOSAVE CYCLE
-- ==========================================
-- Two protocols:
--   HOTSAVE:  Clear RAM -> quicksave -> re-index RAM.
--             Items untouched. No JSON payload. Fastest.
--   AUTOSAVE: Wash items to JSON -> clear RAM -> quicksave -> full rebuild.
--             Legacy path for users who want the wash behaviour.
--
-- Timing data is written to _G.refinish_telemetry.last_save
-- (the persistent telemetry sub-table). This is NOT nil'd at
-- the end; it persists for the status panel and debug dump.
-- ==========================================

local utils = require('utils')

-- ==========================================
-- PROTOCOL GATE
-- ==========================================
local save_protocol = dfhack.persistent.getSiteData('refinish_config_save_protocol')
if not save_protocol or save_protocol == "" then save_protocol = 'AUTOSAVE' end

local msg_setting = dfhack.persistent.getSiteData('refinish_config_msg')
if not msg_setting or msg_setting == "" then msg_setting = 'GUIDED' end

-- ==========================================
-- OWNERSHIP TEST
-- ==========================================
-- Every id prefix RM or one of its modules owns. Core RM is always
-- included; module prefixes come from the live registry, which
-- clear_module_assets does not nil, so they remain readable after a
-- clear. A nil registry means the token call has not run yet, so
-- nothing of ours is in the arrays to find.
--
-- Declared here rather than beside the clear gate because the
-- baseline check below needs it too.
-- ==========================================
local function rm_owned(str)
    if string.sub(str, 1, 15) == "REFINISH_STEEL_" then return true end
    for prefix, _ in pairs(_G.refinish_module_registry or {}) do
        if string.sub(str, 1, #prefix) == prefix then return true end
    end
    return false
end

-- ==========================================
-- BASELINE CHECK
-- If RAM isn't loaded there's nothing for us to do.
-- Just fire a vanilla quicksave and exit.
-- ==========================================
-- _G.refinish_ram_loaded alone is not sufficient. It describes core
-- RM only, and module materials are injected by a separate pipeline
-- with its own flag. Any state where one is live and the other is
-- not would pass this check and write injected data to disk.
--
-- The array is the ground truth, so it is asked directly. This runs
-- once per save trigger, not per frame, so a walk of the inorganics
-- and reactions arrays is affordable.
local function ram_is_at_baseline()
    if _G.refinish_ram_loaded then return false end
    if _G.refinish_modules_injected then return false end
    for _, mat in ipairs(df.global.world.raws.inorganics.all) do
        if rm_owned(mat.id) then return false end
    end
    for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
        if rm_owned(rxn.code) then return false end
    end
    return true
end

if ram_is_at_baseline() then
    print("Refinish Metal: Memory is already at baseline. Triggering standard quicksave.")
    if _G.refinish_log_event then _G.refinish_log_event("AUTOSAVE: Memory at baseline. Standard quicksave.") end
    dfhack.run_command('quicksave')
    return
end

-- ==========================================
-- TELEMETRY HELPER
-- ==========================================
-- Writes to _G.refinish_telemetry.last_save if the table exists.
-- ==========================================
local function lset(key, value)
    if _G.refinish_telemetry and _G.refinish_telemetry.last_save then
        _G.refinish_telemetry.last_save[key] = value
    end
end

-- Reset the last_save sub-table for this cycle
if _G.refinish_telemetry and _G.refinish_telemetry.last_save then
    local ls = _G.refinish_telemetry.last_save
    ls.protocol = save_protocol
    ls.timestamp = os.date("%H:%M:%S")
    ls.t_save = 0
    ls.t_clr_ent = 0; ls.t_clr_rxn = 0; ls.t_clr_mat = 0
    ls.t_engine = 0; ls.t_restore = 0; ls.t_active = 0
    ls.items = 0; ls.buildings = 0; ls.constructions = 0
end

_G.refinish_autosave_in_progress = true

-- Pause the game if configured to do so
local pause_setting = dfhack.persistent.getSiteData('refinish_config_pause')
if pause_setting ~= 'NO' then
    if not df.global.pause_state then
        df.global.pause_state = true
        print("Refinish Metal: Pausing to initiate save routine...")
        if _G.refinish_log_event then _G.refinish_log_event("AUTOSAVE: Paused for save routine.") end
    end
end

-- ==========================================
-- SHARED: PHYSICAL RAM CLEAR CHECK
-- ==========================================
-- Used by both protocols to confirm RAM is fully evacuated
-- before handing off to the engine save.
-- ==========================================
local function is_memory_physically_clear()
    -- Every id prefix that must be gone before the engine save.
    -- Core RM plus every module prefix from the live registry.
    -- Testing only REFINISH_STEEL_ meant this returned true with
    -- module materials still in the array, so a failed module clear
    -- was invisible and the quicksave went ahead regardless.
    -- clear_module_assets does not nil the registry, so the prefixes
    -- are still readable here after it runs.

    for _, mat in ipairs(df.global.world.raws.inorganics.all) do
        if rm_owned(mat.id) then return false end
    end
    local reactions = df.global.world.raws.reactions.reactions
    for _, rxn in ipairs(reactions) do
        if rm_owned(rxn.code) then return false end
    end
    for _, cat in ipairs(df.global.world.raws.reactions.reaction_categories) do
        if rm_owned(cat.id) then return false end
    end
    local player_civ = df.historical_entity.find(df.global.plotinfo.civ_id)
    if player_civ and player_civ.entity_raw then
        local permitted = player_civ.entity_raw.workshops.permitted_reaction_id
        for _, pid in ipairs(permitted) do
            if pid >= #reactions then return false end
        end
    end
    return true
end


-- ==============================================================
-- ==============================================================
-- HOTSAVE PROTOCOL
-- Clear RAM -> Quicksave -> Re-index RAM.
-- Items on the map are never touched. No JSON payload written.
-- ==============================================================
-- ==============================================================
if save_protocol == 'HOTSAVE' then
    if _G.refinish_log_event then _G.refinish_log_event("AUTOSAVE (HOTSAVE): Protocol initiated.") end
    print("Refinish Metal: Hotsave initiated. Clearing RAM...")

    local cycle_clock = os.clock()

    -- ==========================================
    -- HOTSAVE STEP 1: CLEAR RAM
    -- ==========================================
    -- We call the three clear scripts directly, bypassing
    -- refinish-shutdown entirely (shutdown calls refinish-save
    -- first, which we explicitly do not want in hotsave mode).
    -- ==========================================
    local t = os.clock()
    dfhack.run_script('refinish-clear-entity')
    local t_clr_ent = os.clock() - t; lset('t_clr_ent', t_clr_ent); t = os.clock()

    dfhack.run_script('refinish-clear-reaction')
    local t_clr_rxn = os.clock() - t; lset('t_clr_rxn', t_clr_rxn); t = os.clock()

    dfhack.run_script('refinish-clear')

    -- The three clear scripts above filter on the literal
    -- REFINISH_STEEL_ prefix, so they remove core RM and nothing
    -- else. Module assets are swept only by clear_module_assets,
    -- which HOTSAVE never reached because it bypasses
    -- refinish-shutdown. Module materials stayed live in the
    -- inorganics array across the quicksave.
    --
    -- Runs last, matching refinish-shutdown.lua:56-82. Core RM
    -- injects after modules, so removing core RM first and modules
    -- second is strict LIFO across the whole injected region.
    -- clear_module_assets sweeps entity permissions before deleting
    -- reactions (engine:819), so no permitted_reaction_id is left
    -- dangling for is_memory_physically_clear to trip on.
    pcall(function()
        local mod_engine = dfhack.script_environment('refinish-module-engine')
        if mod_engine and mod_engine.clear_module_assets then
            mod_engine.clear_module_assets()
        end
    end)

    local t_clr_mat = os.clock() - t; lset('t_clr_mat', t_clr_mat)

    if _G.refinish_log_event then
        _G.refinish_log_event(string.format("AUTOSAVE (HOTSAVE): RAM cleared (Ent:%.3f | Rxn:%.3f | Mat:%.3f).", t_clr_ent, t_clr_rxn, t_clr_mat))
    end

    -- ==========================================
    -- HOTSAVE STEP 2: WAIT FOR PHYSICAL CONFIRMATION
    -- Then fire the engine save and re-index on the next tick.
    -- ==========================================
    local function hotsave_trigger()
        local ok, err = pcall(function()
            print("Refinish Metal: RAM confirmed clear. Executing engine quicksave...")
            if _G.refinish_log_event then _G.refinish_log_event("AUTOSAVE (HOTSAVE): RAM confirmed clear. Initiating quicksave.") end

            local function do_save_and_restore()
                local engine_start = os.clock()
                dfhack.run_command('quicksave')

                -- Re-index on the very next tick after quicksave returns
                dfhack.timeout(1, 'ticks', function()
                    local ok2, err2 = pcall(function()
                        local t_engine = os.clock() - engine_start
                        lset('t_engine', t_engine)

                        print("Refinish Metal: Quicksave complete. Restoring RAM...")
                        if _G.refinish_log_event then _G.refinish_log_event(string.format("AUTOSAVE (HOTSAVE): Quicksave complete (%.3fs). Restoring RAM.", t_engine)) end

                        -- ==========================================
                        -- HOTSAVE STEP 3: RESTORE RAM
                        -- ==========================================
                        -- Run the full index chain. Skip refinish-load:
                        -- items already carry their mat_index on the
                        -- objects and need no restoration.
                        -- ==========================================
                        local restore_start = os.clock()
                        local t2 = restore_start

                        -- Ghost job sweep
                        local orphaned_jobs_fixed = 0
                        pcall(function()
                            for _, job in utils.listpairs(df.global.world.jobs.list) do
                                if job.job_type == df.job_type.CustomReaction then
                                    local r_name = tostring(job.reaction_name)
                                    if string.find(r_name, "^REFINISH_STEEL_RXN_LUA_GRIND_") then
                                        local base_name = string.match(r_name, "^(REFINISH_STEEL_RXN_LUA_GRIND_[%a]+)")
                                        if base_name and r_name ~= base_name then
                                            job.reaction_name = base_name
                                            orphaned_jobs_fixed = orphaned_jobs_fixed + 1
                                        end
                                    end
                                end
                            end
                        end)
                        if orphaned_jobs_fixed > 0 and _G.refinish_log_event then
                            _G.refinish_log_event(string.format("AUTOSAVE (HOTSAVE): Rescued %d orphaned reactions.", orphaned_jobs_fixed))
                        end
                        local r_sweep = os.clock() - t2; t2 = os.clock()

                        -- Modules are cleared before the quicksave now, so
                        -- they have to be rebuilt here. Order mirrors
                        -- refinish-startup exactly: modules inject first and
                        -- occupy the lower band, core RM appends after them.
                        -- Re-injecting in any other order would swap the bands
                        -- and move every index in the save.
                        --
                        -- refinish-scan depends on this having run: the
                        -- blueprint is built from the live inorganics array,
                        -- so module materials must be present before it scans.
                        --
                        -- run_module_pipeline returns immediately unless
                        -- _G.refinish_modules_injected is false, which
                        -- clear_module_assets set on the way out (engine:877
                        -- and engine:623).
                        pcall(function()
                            dfhack.script_environment('refinish-module-engine').run_module_pipeline()
                        end)
                        local r_mod = os.clock() - t2; t2 = os.clock()

                        dfhack.run_script('refinish-scan')
                        local r_scan = os.clock() - t2; t2 = os.clock()

                        dfhack.run_script('refinish-index')
                        local r_mat = os.clock() - t2; t2 = os.clock()

                        dfhack.run_script('refinish-index-reaction')
                        local r_rxn = os.clock() - t2; t2 = os.clock()

                        -- Module permissions were erased with the module
                        -- reactions, so they are re-evaluated here. Sits
                        -- between index-reaction and index-entity because that
                        -- is where refinish-startup:141-147 puts it: the
                        -- evaluator registers module metals as known, and
                        -- index-entity gates core RM permissions on that.
                        pcall(function()
                            if _G.refinish_module_registry and next(_G.refinish_module_registry) then
                                dfhack.script_environment('refinish-module-evaluate-permissions').evaluate_and_inject()
                            end
                        end)
                        local r_modperm = os.clock() - t2; t2 = os.clock()

                        dfhack.run_script('refinish-index-entity')
                        local r_ent = os.clock() - t2

                        local t_restore = os.clock() - restore_start
                        lset('t_restore', t_restore)

                        _G.refinish_autosave_in_progress = false

                        -- ==========================================
                        -- HOTSAVE TELEMETRY REPORT
                        -- ==========================================
                        local clear_total = t_clr_ent + t_clr_rxn + t_clr_mat
                        local active_time = clear_total + t_engine + t_restore
                        lset('t_active', active_time)

                        -- Log the full cycle as a single structured entry
                        if _G.refinish_log_event then
                            _G.refinish_log_event(string.format(
                                "AUTOSAVE (HOTSAVE): Cycle complete (%.3fs); Clear:%.3f | Engine:%.3f | Restore:%.3f",
                                active_time, clear_total, t_engine, t_restore
                            ))
                        end

                        -- User-facing output
                        if msg_setting == 'DEBUG' then
                            local report = string.format(
                                "Hotsave Cycle Complete (%.3fs)\n\n" ..
                                "--- RAM CLEAR (%.3fs) ---\n" ..
                                "Clear Entities:   %.3fs\n" ..
                                "Clear Reactions:  %.3fs\n" ..
                                "Clear Materials:  %.3fs\n\n" ..
                                "--- ENGINE SAVE ---\n" ..
                                "Quicksave:        %.3fs\n\n" ..
                                "--- RAM RESTORE (%.3fs) ---\n" ..
                                "Ghost Sweep:      %.3fs\n" ..
                                "Module Pipeline:  %.3fs\n" ..
                                "Blueprint Scan:   %.3fs\n" ..
                                "Index Materials:  %.3fs\n" ..
                                "Index Reactions:  %.3fs\n" ..
                                "Module Perms:     %.3fs\n" ..
                                "Index Entities:   %.3fs\n" ..
                                "Orphans Fixed: %d",
                                active_time,
                                clear_total, t_clr_ent, t_clr_rxn, t_clr_mat,
                                t_engine,
                                t_restore, r_sweep, r_mod, r_scan, r_mat, r_rxn, r_modperm, r_ent,
                                orphaned_jobs_fixed
                            )
                            local RefinishPrompt = reqscript('refinish-prompt').RefinishPrompt
                            RefinishPrompt{
                                frame_h = 26,
                                frame_w = 55,
                                text = report,
                                on_ok = function() end
                            }:show()
                        elseif msg_setting == 'GUIDED' then
                            local RefinishPrompt = reqscript('refinish-prompt').RefinishPrompt
                            RefinishPrompt{
                                frame_h = 10,
                                text = string.format("Hotsave complete (%.2fs).", active_time),
                                on_ok = function() end
                            }:show()
                        elseif msg_setting == 'PASSIVE' then
                            local THEME = reqscript('refinish-theme').get_current_theme()
                            dfhack.gui.showAnnouncement(string.format('Refinish Metal: Hotsave complete (%.2fs).', active_time), THEME.PRI, true)
                        end
                    end)

                    if not ok2 then
                        print("REFINISH FATAL RESTORE ERROR: " .. tostring(err2))
                        if _G.refinish_log_event then _G.refinish_log_event("FATAL RESTORE CRASH: " .. tostring(err2)) end
                    end
                end)
            end

            -- Pre-save prompt for DEBUG only. Guided just proceeds.
            if msg_setting == 'DEBUG' then
                local RefinishPrompt = reqscript('refinish-prompt').RefinishPrompt
                local THEME = reqscript('refinish-theme').get_current_theme()
                RefinishPrompt{
                    text = "RAM cleared. Press ENTER to quicksave. Pipeline will restore on unpause.",
                    text_pen = THEME.PRI,
                    on_ok = function() do_save_and_restore() end
                }:show()
            else
                do_save_and_restore()
            end
        end)

        if not ok then
            print("REFINISH FATAL HOTSAVE ERROR: " .. tostring(err))
            if _G.refinish_log_event then _G.refinish_log_event("FATAL HOTSAVE CRASH: " .. tostring(err)) end
        end
    end

    -- Poll until RAM is physically confirmed clear, then fire
    local function wait_for_clear()
        if not is_memory_physically_clear() then
            dfhack.timeout(10, 'frames', wait_for_clear)
        else
            hotsave_trigger()
        end
    end

    wait_for_clear()
    return  -- Explicit return so the autosave protocol block below doesn't execute
end


-- ==============================================================
-- ==============================================================
-- AUTOSAVE PROTOCOL (LEGACY)
-- Full cycle: wash items to JSON, clear RAM, quicksave, rebuild.
-- ==============================================================
-- ==============================================================
if _G.refinish_log_event then _G.refinish_log_event("AUTOSAVE (AUTOSAVE): Protocol initiated. Full save/wash cycle.") end
print("Refinish Metal: Washing items and clearing RAM...")

-- refinish-shutdown writes its per-step timings into
-- _G.refinish_telemetry.last_save (t_save, t_clr_ent, etc.)
dfhack.run_script('refinish-shutdown', 'SILENT')

local function trigger_save_and_rebuild()
    print("Refinish Metal: Save initiated. Mod data will be restored when you UNPAUSE.")
    if _G.refinish_log_event then _G.refinish_log_event("AUTOSAVE (AUTOSAVE): Initiating quicksave...") end

    local engine_start = os.clock()
    dfhack.run_command('quicksave')

    dfhack.timeout(1, 'ticks', function()
        local ok, fatal_err = pcall(function()
            local t_engine = os.clock() - engine_start
            lset('t_engine', t_engine)

            print("Refinish Metal: Quicksave complete. Rebuilding RAM...")
            if _G.refinish_log_event then _G.refinish_log_event(string.format("AUTOSAVE (AUTOSAVE): Quicksave complete (%.3fs). Initiating startup...", t_engine)) end

            -- refinish-startup writes its per-step timings into
            -- _G.refinish_telemetry.startup (which we also read below)
            local restore_start = os.clock()
            local load_ok, load_err = pcall(function() dfhack.run_script('refinish-startup', 'SILENT', 'NOPROMPT') end)
            if not load_ok then
                print("Refinish Metal Warning: " .. tostring(load_err))
                if _G.refinish_log_event then _G.refinish_log_event("AUTOSAVE ERROR: Startup failed -> " .. tostring(load_err)) end
            end
            local t_restore = os.clock() - restore_start
            lset('t_restore', t_restore)

            _G.refinish_autosave_in_progress = false

            -- ==========================================
            -- AUTOSAVE TELEMETRY REPORT
            -- ==========================================
            -- Pull shutdown timings from last_save (written by shutdown)
            -- and startup timings from startup (written by startup).
            -- ==========================================
            local ls = _G.refinish_telemetry and _G.refinish_telemetry.last_save
            local st = _G.refinish_telemetry and _G.refinish_telemetry.startup

            local unload_total = ls and (ls.t_save + ls.t_clr_ent + ls.t_clr_rxn + ls.t_clr_mat) or 0
            local active_time = unload_total + t_engine + t_restore
            lset('t_active', active_time)

            -- Grab payload counts from refinish-save (if it stored them)
            local saved_items = ls and ls.items or 0
            local saved_bldgs = ls and ls.buildings or 0
            local saved_cons  = ls and ls.constructions or 0

            -- Log the full cycle as a single structured entry
            if _G.refinish_log_event then
                _G.refinish_log_event(string.format(
                    "AUTOSAVE (AUTOSAVE): Cycle complete (%.3fs); Unload:%.3f | Engine:%.3f | Restore:%.3f | Items:%d",
                    active_time, unload_total, t_engine, t_restore, saved_items
                ))
            end

            -- User-facing output
            if msg_setting == 'DEBUG' then
                -- Pull per-step restore timings from telemetry.startup
                -- (written by refinish-startup via tset() calls)
                local st = _G.refinish_telemetry and _G.refinish_telemetry.startup
                local report = string.format(
                    "Autosave Cycle Complete (%.3fs)\n\n" ..
                    "--- DATA SECURED ---\n" ..
                    "Items: %d  |  Buildings: %d  |  Constructions: %d\n\n" ..
                    "--- UNLOAD (%.3fs) ---\n" ..
                    "Save Payload:     %.3fs\n" ..
                    "Clear Entities:   %.3fs\n" ..
                    "Clear Reactions:  %.3fs\n" ..
                    "Clear Materials:  %.3fs\n\n" ..
                    "--- ENGINE SAVE ---\n" ..
                    "Quicksave:        %.3fs\n\n" ..
                    "--- RESTORE (%.3fs) ---\n" ..
                    "Ghost Sweep:      %.3fs\n" ..
                    "Module Pipeline:  %.3fs\n" ..
                    "Blueprint Scan:   %.3fs\n" ..
                    "Index Materials:  %.3fs\n" ..
                    "Index Reactions:  %.3fs\n" ..
                    "Index Entities:   %.3fs\n" ..
                    "Restore Payload:  %.3fs",
                    active_time,
                    saved_items, saved_bldgs, saved_cons,
                    unload_total, ls and ls.t_save or 0, ls and ls.t_clr_ent or 0, ls and ls.t_clr_rxn or 0, ls and ls.t_clr_mat or 0,
                    t_engine,
                    t_restore,
                    st and st.t_sweep or 0, st and st.t_modules or 0, st and st.t_scan or 0,
                    st and st.t_idx_mat or 0, st and st.t_idx_rxn or 0, st and st.t_idx_ent or 0,
                    st and st.t_load or 0
                )
                local RefinishPrompt = reqscript('refinish-prompt').RefinishPrompt
                RefinishPrompt{
                    frame_h = 28,
                    frame_w = 55,
                    text = report,
                    on_ok = function() end
                }:show()
            elseif msg_setting == 'GUIDED' then
                local RefinishPrompt = reqscript('refinish-prompt').RefinishPrompt
                RefinishPrompt{
                    frame_h = 10,
                    text = string.format("Autosave complete (%.2fs). %d objects secured.", active_time, saved_items + saved_bldgs + saved_cons),
                    on_ok = function() end
                }:show()
            elseif msg_setting == 'PASSIVE' then
                local THEME = reqscript('refinish-theme').get_current_theme()
                dfhack.gui.showAnnouncement(string.format('Refinish Metal: Autosave complete (%.2fs).', active_time), THEME.PRI, true)
            end
        end)

        if not ok then
            print("REFINISH FATAL UI ERROR: " .. tostring(fatal_err))
            if _G.refinish_log_event then _G.refinish_log_event("FATAL UI CRASH: " .. tostring(fatal_err)) end
        end
    end)
end

local function wait_for_shutdown()
    if not is_memory_physically_clear() then
        dfhack.timeout(10, 'frames', wait_for_shutdown)
    else
        local ok, err = pcall(function()
            print("Refinish Metal: RAM confirmed clear. Triggering quicksave...")
            if _G.refinish_log_event then _G.refinish_log_event("AUTOSAVE (AUTOSAVE): RAM confirmed clear.") end

            -- Pre-save prompt for DEBUG only
            if msg_setting == 'DEBUG' then
                local RefinishPrompt = reqscript('refinish-prompt').RefinishPrompt
                local THEME = reqscript('refinish-theme').get_current_theme()
                RefinishPrompt{
                    text = "Shutdown complete. Press ENTER to quicksave. Pipeline will restore on unpause.",
                    text_pen = THEME.PRI,
                    on_ok = function() trigger_save_and_rebuild() end
                }:show()
            else
                trigger_save_and_rebuild()
            end
        end)

        if not ok then
            print("REFINISH FATAL SHUTDOWN ERROR: " .. tostring(err))
            if _G.refinish_log_event then _G.refinish_log_event("FATAL SHUTDOWN CRASH: " .. tostring(err)) end
        end
    end
end

wait_for_shutdown()