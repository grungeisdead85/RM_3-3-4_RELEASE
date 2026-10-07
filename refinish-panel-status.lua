--@ module = true
-- refinish-panel-status.lua
-- ==========================================
-- SYSTEM TELEMETRY PANEL
-- ==========================================
-- All value tokens use FUNCTIONS instead of static strings.
-- The List widget calls these on every render frame, so the
-- display is always current without ever calling setChoices().
-- No polling loop needed. No scroll disturbance. No scrollbar
-- jumps.
--
-- SECTION ORDER (state first, benchmarks last):
--   1. SYSTEM          - Version, protocol
--   2. PIPELINE STATE  - Live state flags
--   3. MONITORS        - Background loop heartbeats, autosave timer
--   4. SESSION         - Log buffer, config mode
--   5. BASELINE        - Vanilla game state counts
--   6. BLUEPRINT       - Scanner output counts
--   7. INJECTED        - Live RAM injection counts
--   8. BOOT TIMING     - Map-load cache building breakdown
--   9. STARTUP TIMING  - Last pipeline rebuild breakdown
--  10. LAST SAVE CYCLE - Most recent autosave cycle breakdown
-- ==========================================

local gui = require('gui')
local widgets = require('gui.widgets')

RefinishPanelStatus = defclass(RefinishPanelStatus, widgets.Panel)
RefinishPanelStatus.ATTRS = {
    theme = DEFAULT_NIL,
}

function RefinishPanelStatus:init()
    self.theme = self.theme or reqscript('refinish-theme').get_current_theme()

    -- Build choices ONCE. Values are function tokens that the
    -- List widget evaluates fresh on every render frame.
    local choices = self:build_status_lines()

    self.list_widget = widgets.List{
        frame = {t = 2, l = 0, r = 0, b = 0},
        choices = choices,
        cursor_pen = self.theme.PRI,
    }

    self:addviews{
        widgets.Label{ frame = {t = 0, l = 0}, text = "SYSTEM TELEMETRY", text_pen = self.theme.PRI },
        self.list_widget,
    }
end

-- ==========================================
-- DATA BUILDER
-- ==========================================
-- Builds the choices array ONCE. Static labels are plain strings.
-- Dynamic values are wrapped in functions so the List re-evaluates
-- them on every draw call. This gives us live updates with zero
-- polling overhead and zero scroll disturbance.
-- ==========================================
function RefinishPanelStatus:build_status_lines()
    local choices = {}
    local PRI = self.theme.PRI
    local SEC = self.theme.SEC
    local HDR = self.theme.NEUTRAL_B

    -- ==========================================
    -- DISPLAY HELPERS
    -- ==========================================
    -- Each helper inserts one choice into the array.
    -- Value tokens use functions for live data.
    -- ==========================================

    -- Section header
    local function hdr(txt)
        table.insert(choices, { text = {{ text = txt, pen = HDR }} })
    end

    -- Single value row: static label, dynamic value
    local function row(label, value_fn)
        local lbl_str = string.format("  %-18s", label)
        table.insert(choices, { text = {
            { text = lbl_str, pen = SEC },
            { text = value_fn, pen = PRI }
        }})
    end

    -- Two-column row: static labels, dynamic values
    local function pair(lbl_a, val_fn_a, lbl_b, val_fn_b)
        local la = string.format("  %-18s", lbl_a)
        local lb = string.format("%-18s", lbl_b)
        table.insert(choices, { text = {
            { text = la, pen = SEC },
            { text = function() return string.format("%-14s", val_fn_a()) end, pen = PRI },
            { text = lb, pen = SEC },
            { text = val_fn_b, pen = PRI }
        }})
    end

    -- Timing row: shows seconds or "-" for zero
    local function trow(label, time_fn)
        local lbl_str = string.format("  %-18s", label)
        table.insert(choices, { text = {
            { text = lbl_str, pen = SEC },
            { text = function()
                local s = time_fn()
                if not s or s == 0 then return "-" end
                return string.format("%.3fs", s)
            end, pen = function()
                local s = time_fn()
                return (s and s > 0) and PRI or SEC
            end }
        }})
    end

    -- Timing pair: two timing values side by side
    local function tpair(lbl_a, time_fn_a, lbl_b, time_fn_b)
        local la = string.format("  %-18s", lbl_a)
        local lb = string.format("%-18s", lbl_b)
        local function tfmt(fn)
            local s = fn()
            if not s or s == 0 then return "-" end
            return string.format("%.3fs", s)
        end
        local function tpen(fn)
            local s = fn()
            return (s and s > 0) and PRI or SEC
        end
        table.insert(choices, { text = {
            { text = la, pen = SEC },
            { text = function() return string.format("%-14s", tfmt(time_fn_a)) end, pen = function() return tpen(time_fn_a) end },
            { text = lb, pen = SEC },
            { text = function() return tfmt(time_fn_b) end, pen = function() return tpen(time_fn_b) end }
        }})
    end

    local function gap()
        table.insert(choices, { text = "" })
    end

    -- Formatters that return functions
    local function bfmt(getter)
        return function()
            local val = getter()
            if val == true then return "Yes"
            elseif val == false then return "No"
            else return "-" end
        end
    end

    -- Safe telemetry sub-table accessors
    local function tel()     return _G.refinish_telemetry or {} end
    local function boot()    return tel().boot or {} end
    local function startup() return tel().startup or {} end
    local function lsave()   return tel().last_save or {} end
    local function counts()  return tel().counts or {} end


    -- ==========================================
    -- 1. SYSTEM
    -- ==========================================
    hdr("SYSTEM")
    pair("Refinish Metal:", function() return _G.refinish_version or "?" end,
         "DFHack:",         function() return dfhack.getDFHackVersion() end)
    row("Dwarf Fortress:", function() return dfhack.getDFVersion() end)
    row("Save Protocol:", function()
        local p = "AUTOSAVE"
        pcall(function()
            local v = dfhack.persistent.getSiteData('refinish_config_save_protocol')
            if v and v ~= "" then p = v end
        end)
        return p
    end)
    gap()

    -- ==========================================
    -- 2. PIPELINE STATE
    -- ==========================================
    hdr("PIPELINE STATE")
    pair("Active:",      bfmt(function() return _G.refinish_active end),
         "Menu Lock:",   bfmt(function() return _G.refinish_menu_locked end))
    pair("Materials:",   bfmt(function() return _G.refinish_ram_loaded end),
         "Reactions:",   bfmt(function() return _G.refinish_reactions_loaded end))
    pair("Permissions:", bfmt(function() return _G.refinish_entity_loaded end),
         "Payload:",     bfmt(function() return _G.refinish_data_loaded end))
    gap()

    -- ==========================================
    -- 3. MONITORS
    -- ==========================================
    hdr("MONITORS")
    row("UI Tripwire:", function() return _G.refinish_last_ui_ping or "Inactive" end)
    row("Calendar Loop:", function() return _G.refinish_last_cal_ping or "Inactive" end)
    row("JIT Watcher:", function() return _G.refinish_last_watch_ping or "Inactive" end)
    pair("Autosave In:", bfmt(function() return _G.refinish_autosave_in_progress end),
         "Interval:", function()
            local v = "SEASONAL"
            pcall(function()
                local s = dfhack.persistent.getSiteData('refinish_config_interval')
                if s and s ~= "" then v = s end
            end)
            return v
         end)
    row("Last Save:", function()
        if not _G.refinish_last_real_save then return "N/A" end
        local elapsed = os.time() - _G.refinish_last_real_save
        if elapsed < 60 then return elapsed .. "s ago"
        elseif elapsed < 3600 then return math.floor(elapsed / 60) .. "m ago"
        else return math.floor(elapsed / 3600) .. "h " .. math.floor((elapsed % 3600) / 60) .. "m ago" end
    end)
    gap()

    -- ==========================================
    -- 4. SESSION
    -- ==========================================
    hdr("SESSION")
    row("Log Buffer:", function()
        local n = _G.refinish_log and #_G.refinish_log or 0
        return n .. " / 5000"
    end)
    pair("Verbosity:", function()
        local v = "GUIDED"
        pcall(function()
            local s = dfhack.persistent.getSiteData('refinish_config_msg')
            if s and s ~= "" then v = s end
        end)
        return v
    end, "Finishes:", function()
        local v = "ON"
        pcall(function()
            local s = dfhack.persistent.getSiteData('refinish_config_perf')
            if s and s ~= "" then v = s end
        end)
        return v
    end)
    gap()

    -- ==========================================
    -- 5. BASELINE
    -- ==========================================
    hdr("BASELINE")
    pair("Inorganics:", function() return counts().base_inorganics or 0 end,
         "Reactions:",  function() return counts().base_reactions or 0 end)
    pair("Valid Metals:", function() return counts().valid_metals or 0 end,
         "Known Metals:", function() return counts().known_metals or 0 end)
    pair("Rxn Traits:", function() return counts().reaction_traits or 0 end,
         "Civ Techs:",  function() return counts().civ_techs or 0 end)
    gap()

    -- ==========================================
    -- 6. BLUEPRINT
    -- ==========================================
    hdr("BLUEPRINT")
    pair("Active Bases:", function() return counts().active_bases or 0 end,
         "Materials:",    function() return counts().bp_materials or 0 end)
    pair("Reactions:",    function() return counts().bp_reactions or 0 end,
         "Categories:",   function() return counts().bp_categories or 0 end)
    gap()

    -- ==========================================
    -- 7. INJECTED
    -- ==========================================
    hdr("INJECTED")
    pair("Materials:",   function() return counts().inj_materials or 0 end,
         "Reactions:",   function() return counts().inj_reactions or 0 end)
    pair("Categories:",  function() return counts().inj_categories or 0 end,
         "Permissions:", function() return counts().inj_permissions or 0 end)
    row("Civs Permitted:", function() return counts().civs_unlocked or 0 end)
    gap()

    -- ==========================================
    -- 8. BOOT TIMING
    -- ==========================================
    hdr("BOOT TIMING")
    trow("Total:", function() return boot().t_total end)
    tpair("Modules:",   function() return boot().t_modules end,
          "Evaluators:", function() return boot().t_eval end)
    tpair("Boot Scan:", function() return boot().t_boot_scan end,
          "State Check:", function() return boot().t_state end)
    gap()

    -- ==========================================
    -- 9. STARTUP TIMING
    -- ==========================================
    hdr("STARTUP TIMING")
    trow("Total:", function() return startup().t_total end)
    tpair("Ghost Sweep:", function() return startup().t_sweep end,
          "Modules:",     function() return startup().t_modules end)
    tpair("Scan:",        function() return startup().t_scan end,
          "Index Mats:",  function() return startup().t_idx_mat end)
    tpair("Index Rxns:",  function() return startup().t_idx_rxn end,
          "Index Ents:",  function() return startup().t_idx_ent end)
    trow("Payload Load:", function() return startup().t_load end)
    gap()

    -- ==========================================
    -- 10. LAST SAVE CYCLE
    -- ==========================================
    hdr("LAST SAVE CYCLE")
    pair("Protocol:", function() return lsave().protocol or "N/A" end,
         "Timestamp:", function() return lsave().timestamp or "N/A" end)
    trow("Active Time:", function() return lsave().t_active end)
    tpair("Clear Ents:", function() return lsave().t_clr_ent end,
          "Clear Rxns:", function() return lsave().t_clr_rxn end)
    tpair("Clear Mats:", function() return lsave().t_clr_mat end,
          "Save JSON:",  function() return lsave().t_save end)
    tpair("Engine Save:", function() return lsave().t_engine end,
          "Restore:",     function() return lsave().t_restore end)
    pair("Items:", function() return lsave().items or 0 end,
         "Buildings:", function() return lsave().buildings or 0 end)
    row("Constructions:", function() return lsave().constructions or 0 end)

    return choices
end

return _ENV