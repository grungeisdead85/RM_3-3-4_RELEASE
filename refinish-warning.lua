--@ module = true
-- refinish-warning.lua

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')

RefinishWarningOverlay = defclass(RefinishWarningOverlay, overlay.OverlayWidget)
RefinishWarningOverlay.ATTRS = {
    desc = "Refinish Warning Overlay",
    default_pos = {x = 70, y = 10},
    default_enabled = true,
    viewscreens = 'dwarfmode/Options',
    version = "3.2",

    frame = {w = 52, h = 11},
    frame_style = gui.FRAME_BOLD,
    frame_background = gui.CLEAR_PEN,

    visible = function() 
        -- Hide entirely if the master mod state is dormant (Vanilla saves)
        if not _G.refinish_active then return false end

        local focus = dfhack.gui.getCurFocus()
        
        if type(focus) == 'table' and #focus == 1 and focus[1] == 'dwarfmode/Options' then
            return true
        end
        
        return false
    end,
}

function RefinishWarningOverlay:init()
    local function is_safe()
        return (not _G.refinish_data_loaded) and (not _G.refinish_ram_loaded)
    end

    -- HELPER: Check the active menu wipe setting
    local function get_esc_mode()
        local mode = dfhack.persistent.getSiteData('refinish_config_esc')
        return (mode and mode ~= "") and mode or 'AUTO'
    end

    -- HELPER: Read the user's custom hotkeys
    local function get_hk(id, default)
        local hk = dfhack.persistent.getSiteData(id)
        return (hk and hk ~= "") and hk or default
    end

    self:addviews{
        widgets.Label{
            frame = {l = 1, t = 1},
            text = {
                {
                    text = function() return is_safe() and "*** REFINISH METAL DATA IS NOT LOADED ***" or "!!! REFINISH METAL DATA IS LOADED !!!" end,
                    pen = function() return is_safe() and COLOR_LIGHTGREEN or COLOR_RED end
                }
            }
        },
        widgets.Label{
            frame = {l = 1, t = 3},
            text = {
                {
                    text = function() return is_safe() and "It is safe to manually save the game." or "DO NOT MANUALLY SAVE WHILE DATA IS LOADED!" end,
                    pen = function() return is_safe() and COLOR_LIGHTGREEN or COLOR_RED end
                }
            }
        },
        widgets.Label{
            frame = {l = 1, t = 5},
            text = {
                {
                    text = function()
                        local mode = get_esc_mode()
                        local hk_startup = get_hk('refinish_hk_startup', 'Ctrl-Alt-X')
                        local hk_wipe = get_hk('refinish_hk_wipe', 'Ctrl-Shift-X')
                        
                        if mode == 'AUTO' then
                            return is_safe() and "Close this menu to reload Refinish Metal" or "Please wait. Your data is being unloaded and preserved"
                        else
                            return is_safe() and "Press " .. hk_startup .. " to manually reload" or "Press " .. hk_wipe .. " to prevent save corruption"
                        end
                    end,
                    pen = function() return is_safe() and COLOR_LIGHTGREEN or COLOR_RED end
                }
            }
        },
        widgets.Label{
            frame = {l = 1, t = 6},
            text = {
                {
                    text = function()
                        local mode = get_esc_mode()
                        if mode == 'AUTO' then
                            return is_safe() and "data automatically and resume the game." or "to prevent manual save corruption and data loss."
                        else
                            return is_safe() and "Refinish Metal data and resume the game." or "by unloading the data BEFORE A MANUAL SAVE!"
                        end
                    end,
                    pen = function() return is_safe() and COLOR_LIGHTGREEN or COLOR_RED end
                }
            }
        },
        widgets.HotkeyLabel{
            frame = {l = 1, b = 0},
            key = 'CUSTOM_ALT_C',
            label = 'Refinish Metal Configuration',
            on_activate = function() 
                if _G.refinish_log_event then _G.refinish_log_event("OVERLAY: User launched config menu via custom hotkey.") end -- ADDED LOG
                dfhack.run_script('refinish-config', 'show') 
            end,
            text_pen = COLOR_LIGHTBLUE
        }
    }
end

OVERLAY_WIDGETS = { warning = RefinishWarningOverlay }