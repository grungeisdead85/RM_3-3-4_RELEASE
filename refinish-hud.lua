--@ module = true
-- refinish-hud.lua

local gui = require('gui')
local widgets = require('gui.widgets')
local theme_engine = reqscript('refinish-theme')

-- Module requirements
local RefinishPanelConfig = reqscript('refinish-panel-config').RefinishPanelConfig
local RefinishPanelLog = reqscript('refinish-panel-log').RefinishPanelLog
local RefinishPanelMetals = reqscript('refinish-panel-metals').RefinishPanelMetals
local RefinishPanelStatus = reqscript('refinish-panel-status').RefinishPanelStatus
local RefinishPanelInspect = reqscript('refinish-panel-inspect').RefinishPanelInspect
local RefinishPanelHelp = reqscript('refinish-panel-help').RefinishPanelHelp
local RefinishPanelCivs = reqscript('refinish-panel-civs').RefinishPanelCivs

-- Changed from ZScreenModal to ZScreen to prevent forced pausing
RefinishMasterHUD = defclass(RefinishMasterHUD, gui.ZScreen)
RefinishMasterHUD.ATTRS = {
    focus_path = 'refinish/hud',
    target_route = 'config', -- Default routing argument
}

function RefinishMasterHUD:init()
    self.THEME = theme_engine.get_current_theme()

    -- ==========================================
    -- DYNAMIC ROUTING CALCULATOR
    -- ==========================================
    local l_page = 1
    local c_page = 1

    -- Restore pane positions if we're rebuilding after a theme change
    if _G.refinish_hud_restore_left then
        l_page = _G.refinish_hud_restore_left
        c_page = _G.refinish_hud_restore_right or 1
        _G.refinish_hud_restore_left = nil
        _G.refinish_hud_restore_right = nil
    else
        local route = string.lower(self.target_route)
        if route == 'config' then l_page = 1
        elseif route == 'metals' then l_page = 2
        elseif route == 'civs' then l_page = 3
        elseif route == 'status' then c_page = 1
        elseif route == 'log' then c_page = 2
        elseif route == 'inspect' then c_page = 3
        elseif route == 'help' then c_page = 4
        end
    end

    -- ==========================================
    -- ROUTER 1: LEFT PANE (Controls Configs/Log)
    -- ==========================================
    self.router_left = widgets.Pages{
        frame = {t = 0, l = 0, b = 2, w = 81}, 
        selected = l_page, 
        subviews = {
            RefinishPanelConfig{ theme = self.THEME },
            RefinishPanelMetals{ theme = self.THEME },
            RefinishPanelCivs{ theme = self.THEME }
        }
    }

    -- ==========================================
    -- ROUTER 2: RIGHT PANE (Metals/Status/Inspect)
    -- ==========================================
    self.router_center = widgets.Pages{
        frame = {t = 0, l = 82, b = 2, r = 0}, 
        selected = c_page, 
        subviews = {
            RefinishPanelStatus{ theme = self.THEME },
            RefinishPanelLog{ theme = self.THEME },
            RefinishPanelInspect{ theme = self.THEME },
            RefinishPanelHelp{ theme = self.THEME }
        }
    }

    -- ==========================================
    -- VIEW ASSEMBLY
    -- ==========================================
    self:addviews{
        widgets.Window{
            frame = {w = 160, h = 55, l = 3},
            frame_title = "REFINISH METAL",
            frame_style = gui.FRAME_MEDIUM,
            subviews = {

                -- THE CONTROL BAR
                widgets.Panel{
                    frame = {b = 0, l = 0, r = 0, h = 1},
                    subviews = {
                        widgets.Label{
                            frame = {t = 0, l = 0, w = 16}, 
                            text = {
                                {text = dfhack.screen.getKeyDisplay(df.interface_key.CUSTOM_N), pen = self.THEME.PRI},
                                {text = ": <- Left Pane", pen = self.THEME.SEC}
                            },
                            on_click = function() 
                                local curr = self.router_left:getSelected()
                                self.router_left:setSelected(curr == 1 and #self.router_left.subviews or curr - 1)
                            end
                        },
                        widgets.Label{
                            frame = {t = 0, l = 20, w = 16}, 
                            text = {
                                {text = dfhack.screen.getKeyDisplay(df.interface_key.CUSTOM_K), pen = self.THEME.PRI},
                                {text = ": Left Pane ->", pen = self.THEME.SEC}
                            },
                            on_click = function() 
                                local curr = self.router_left:getSelected()
                                self.router_left:setSelected(curr == #self.router_left.subviews and 1 or curr + 1)
                            end
                        },
                        widgets.Label{
                            frame = {t = 0, l = 82, w = 17}, 
                            text = {
                                {text = dfhack.screen.getKeyDisplay(df.interface_key.CUSTOM_M), pen = self.THEME.PRI},
                                {text = ": <- Right Pane", pen = self.THEME.SEC}
                            },
                            on_click = function() 
                                local curr = self.router_center:getSelected()
                                self.router_center:setSelected(curr == 1 and #self.router_center.subviews or curr - 1)
                            end
                        },
                        widgets.Label{
                            frame = {t = 0, l = 103, w = 17}, 
                            text = {
                                {text = dfhack.screen.getKeyDisplay(df.interface_key.CUSTOM_L), pen = self.THEME.PRI},
                                {text = ": Right Pane ->", pen = self.THEME.SEC}
                            },
                            on_click = function() 
                                local curr = self.router_center:getSelected()
                                self.router_center:setSelected(curr == #self.router_center.subviews and 1 or curr + 1)
                            end
                        },
                        widgets.Label{
                            frame = {t = 0, r = 2, w = 15},
                            text = {
                                {text = dfhack.screen.getKeyDisplay(df.interface_key.LEAVESCREEN), pen = self.THEME.PRI},
                                {text = ": Exit HUD", pen = self.THEME.SEC}
                            },
                            on_click = function() self:dismiss() end
                        }
                    }
                },

                -- ROUTERS 
                self.router_left,
                self.router_center
            }
        }
    }
end

-- ==========================================
-- KEY INPUT HANDLER
-- ==========================================
function RefinishMasterHUD:onInput(keys)
    if keys.CUSTOM_N then
        local curr = self.router_left:getSelected()
        self.router_left:setSelected(curr == 1 and #self.router_left.subviews or curr - 1)
        return true
    elseif keys.CUSTOM_K then
        local curr = self.router_left:getSelected()
        self.router_left:setSelected(curr == #self.router_left.subviews and 1 or curr + 1)
        return true
    elseif keys.CUSTOM_M then
        local curr = self.router_center:getSelected()
        self.router_center:setSelected(curr == 1 and #self.router_center.subviews or curr - 1)
        return true
    elseif keys.CUSTOM_L then
        local curr = self.router_center:getSelected()
        self.router_center:setSelected(curr == #self.router_center.subviews and 1 or curr + 1)
        return true
    elseif keys.LEAVESCREEN then
        self:dismiss()
        return true
    end
    return RefinishMasterHUD.super.onInput(self, keys)
end

-- ==========================================
-- LIVE ROUTING CONTROLLER
-- ==========================================
function RefinishMasterHUD:routeToPage(route)
    local l_page = self.router_left:getSelected()
    local c_page = self.router_center:getSelected()

    route = string.lower(route or 'config')
    if route == 'config' then l_page = 1
    elseif route == 'metals' then l_page = 2
    elseif route == 'civs' then l_page = 3
    elseif route == 'status' then c_page = 1
    elseif route == 'log' then c_page = 2
    elseif route == 'inspect' then c_page = 3
    elseif route == 'help' then c_page = 4
    end

    self.router_left:setSelected(l_page)
    self.router_center:setSelected(c_page)
end

-- ==========================================
-- SINGLETON DESTRUCTOR
-- ==========================================
function RefinishMasterHUD:onDismiss()
    _G.refinish_hud_view = nil
end

-- ==========================================
-- SCRIPT EXECUTION & ARGUMENT PARSING
-- ==========================================
if dfhack_flags and dfhack_flags.module then return _ENV end
local args = {...}
local requested_route = 'config'

if #args > 0 then
    if args[1] == 'show' and args[2] then
        requested_route = args[2]
    elseif args[1] ~= 'show' then
        requested_route = args[1]
    end
end

-- SINGLETON LAUNCH LOGIC
if _G.refinish_hud_view then
    _G.refinish_hud_view:routeToPage(requested_route)
    _G.refinish_hud_view:raise()
else
    _G.refinish_hud_view = RefinishMasterHUD{target_route = requested_route}:show()
end