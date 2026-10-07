-- refinish-shutdown.lua
-- ==========================================
-- REFINISH METAL: PIPELINE SHUTDOWN
-- ==========================================
-- Clears all injected assets from RAM. In AUTOSAVE mode, items
-- are washed to JSON first via refinish-save. In HOTSAVE mode,
-- the save step is skipped entirely; items carry their own
-- mat_index values.
--
-- Per-step timing is logged. Debug mode shows a telemetry prompt.
-- ==========================================

local RefinishPrompt = reqscript('refinish-prompt').RefinishPrompt
local THEME = reqscript('refinish-theme').get_current_theme()

local args = {...}
local force_silent = (args[1] == 'SILENT')

local msg_setting = dfhack.persistent.getSiteData('refinish_config_msg')
if not msg_setting or msg_setting == "" then msg_setting = 'GUIDED' end

-- ==========================================
-- PROTOCOL CHECK
-- In HOTSAVE mode, refinish-save is skipped entirely.
-- Items are never washed: they carry their own mat_index.
-- The clear sequence runs regardless of protocol.
-- ==========================================
local save_protocol = dfhack.persistent.getSiteData('refinish_config_save_protocol')
if not save_protocol or save_protocol == "" then save_protocol = 'AUTOSAVE' end

local function execute_shutdown()
    print("==================================================")
    print("REFINISH STEEL: INITIATING SHUTDOWN")
    print("==================================================")
    if _G.refinish_log_event then _G.refinish_log_event("SHUTDOWN: Sequence initiated (Silent: " .. tostring(force_silent) .. ", Protocol: " .. save_protocol .. ").") end

    local shutdown_clock = os.clock()
    local t = shutdown_clock

    -- ==========================================
    -- STEP 1: SAVE PAYLOAD (Autosave protocol only)
    -- ==========================================
    local t_save = 0
    if save_protocol == 'AUTOSAVE' then
        dfhack.run_script('refinish-save')
        t_save = os.clock() - t
        if _G.refinish_log_event then _G.refinish_log_event(string.format("SHUTDOWN: Save payload complete (%.3fs).", t_save)) end
    else
        if _G.refinish_log_event then _G.refinish_log_event("SHUTDOWN: Hotsave mode; skipping refinish-save.") end
    end
    t = os.clock()

    -- ==========================================
    -- STEP 2: CLEAR ENTITY PERMISSIONS
    -- ==========================================
    dfhack.run_script('refinish-clear-entity')
    local t_clr_ent = os.clock() - t
    if _G.refinish_log_event then _G.refinish_log_event(string.format("SHUTDOWN: Entity permissions cleared (%.3fs).", t_clr_ent)) end
    t = os.clock()

    -- ==========================================
    -- STEP 3: CLEAR REACTIONS
    -- ==========================================
    dfhack.run_script('refinish-clear-reaction')
    local t_clr_rxn = os.clock() - t
    if _G.refinish_log_event then _G.refinish_log_event(string.format("SHUTDOWN: Reactions cleared (%.3fs).", t_clr_rxn)) end
    t = os.clock()

    -- ==========================================
    -- STEP 4: CLEAR MATERIALS
    -- ==========================================
    dfhack.run_script('refinish-clear')
    local t_clr_mat = os.clock() - t
    if _G.refinish_log_event then _G.refinish_log_event(string.format("SHUTDOWN: Materials cleared (%.3fs).", t_clr_mat)) end

    -- ==========================================
    -- STEP 5: CLEAR MODULE ASSETS
    -- ==========================================
    pcall(function()
        local mod_engine = dfhack.script_environment('refinish-module-engine')
        if mod_engine and mod_engine.clear_module_assets then
            mod_engine.clear_module_assets()
        end
    end)

    -- ==========================================
    -- FINALIZE SHUTDOWN TELEMETRY
    -- ==========================================
    local t_total = os.clock() - shutdown_clock

    -- Write to the autosave telemetry sub-table if it exists.
    -- During an autosave cycle, refinish-autosave calls us with
    -- 'SILENT' and reads these values back afterward.
    if _G.refinish_telemetry and _G.refinish_telemetry.last_save then
        _G.refinish_telemetry.last_save.t_save = t_save
        _G.refinish_telemetry.last_save.t_clr_ent = t_clr_ent
        _G.refinish_telemetry.last_save.t_clr_rxn = t_clr_rxn
        _G.refinish_telemetry.last_save.t_clr_mat = t_clr_mat
    end

    if _G.refinish_log_event then
        _G.refinish_log_event(string.format(
            "SHUTDOWN: Complete (%.3fs); Save:%.3f | Ent:%.3f | Rxn:%.3f | Mat:%.3f",
            t_total, t_save, t_clr_ent, t_clr_rxn, t_clr_mat
        ))
    end

    print(string.format("Refinish Metal: Shutdown complete (%.3fs). Mod is dormant.", t_total))
    print("==================================================")

    if force_silent then return end

    -- ==========================================
    -- USER-FACING PROMPTS
    -- ==========================================
    if msg_setting == 'PASSIVE' then
        dfhack.gui.showAnnouncement('Refinish Metal: Shutdown complete. Memory clear.', THEME.PRI, true)
    elseif msg_setting == 'DEBUG' then
        local report = string.format(
            "Shutdown Complete (%.3fs)\n\n" ..
            "--- CLEAR TIMING ---\n" ..
            "Save Payload:     %.3fs\n" ..
            "Clear Entities:   %.3fs\n" ..
            "Clear Reactions:  %.3fs\n" ..
            "Clear Materials:  %.3fs\n\n" ..
            "Protocol: %s\n" ..
            "It is now safe to manually save.",
            t_total, t_save, t_clr_ent, t_clr_rxn, t_clr_mat, save_protocol
        )
        RefinishPrompt{
            frame_h = 18,
            frame_w = 55,
            text = report,
            on_ok = function() end
        }:show()
    elseif msg_setting == 'GUIDED' then
        RefinishPrompt{
            frame_h = 10,
            text = "Shutdown sequence complete. It is now safe to manually save.",
            on_ok = function() end
        }:show()
    end
end

-- ==========================================
-- EXECUTION GATE
-- ==========================================
if force_silent or msg_setting == 'PASSIVE' or msg_setting == 'SILENT' then
    execute_shutdown()
else
    RefinishPrompt{
        text = "Preparing to initiate shutdown sequence. Proceed?",
        text_pen = THEME.PRI,
        on_yes = function() execute_shutdown() end,
        on_no = function()
            if _G.refinish_log_event then _G.refinish_log_event("SHUTDOWN: User canceled manual shutdown prompt.") end
        end
    }:show()
end