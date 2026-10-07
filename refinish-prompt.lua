--@ module = true
-- refinish-prompt.lua

local gui = require('gui')
local widgets = require('gui.widgets')
local theme_engine = reqscript('refinish-theme') -- INJECT THE THEME TOOL

RefinishPrompt = defclass(RefinishPrompt, gui.ZScreenModal)
RefinishPrompt.ATTRS = {
    focus_path = 'refinish/prompt',
    title = "REFINISH METAL",
    text = "",
    text_pen = DEFAULT_NIL, -- Will default to PRI if not explicitly passed
    frame_w = 55,
    frame_h = 12,
    on_yes = DEFAULT_NIL,
    on_no = DEFAULT_NIL,
    on_ok = DEFAULT_NIL,
}

function RefinishPrompt:init()
    -- Fetch the live theme at the exact moment the prompt is drawn
    local THEME = theme_engine.get_current_theme()
    
    -- Default the main body text to Primary if the caller didn't specify (like a Risk color)
    local active_text_pen = self.text_pen or THEME.PRI
    local buttons = {}
    
    -- Helper: Build a themed button label with manually colored key indicator
    local function make_button(key_token, label_text, pen_key, pen_label)
        local key_str = dfhack.screen.getKeyDisplay(df.interface_key[key_token])
        return {
            {text = key_str, pen = pen_key},
            {text = ": " .. label_text, pen = pen_label}
        }
    end
    
    -- ==========================================
    -- ACTION CALLBACKS
    -- Shared by both on_click (mouse) and onInput (keyboard).
    -- Each action logs the user's choice with a truncated snippet
    -- of the prompt text so you can tell WHICH prompt it was.
    -- ==========================================

    -- Build a short context string from the prompt text (first 50
    -- chars, truncated at a word boundary). This appears in the log
    -- so you can tell which prompt the user responded to.
    local context = self.text or ""
    if #context > 50 then
        context = string.sub(context, 1, 50):match("(.-)%s[^%s]*$") or string.sub(context, 1, 50)
        context = context .. "..."
    end
    -- Strip newlines so the log entry stays on one line
    context = context:gsub("\n", " ")

    self.action_yes = function()
        if _G.refinish_log_event then _G.refinish_log_event("PROMPT: [Yes] " .. context) end
        self:dismiss()
        self.on_yes()
    end

    self.action_no = function()
        if _G.refinish_log_event then _G.refinish_log_event("PROMPT: [No] " .. context) end
        self:dismiss()
        if self.on_no then self.on_no() end
    end

    self.action_ok = function()
        if _G.refinish_log_event then _G.refinish_log_event("PROMPT: [OK] " .. context) end
        self:dismiss()
        if self.on_ok then self.on_ok() end
    end

    if self.on_yes then
        table.insert(buttons, widgets.Label{
            frame = {b = 0, l = 5, w = 10},
            text = make_button('SELECT', 'Yes', THEME.PRI, THEME.SEC),
            on_click = self.action_yes,
        })
        table.insert(buttons, widgets.Label{
            frame = {b = 0, l = 38, w = 7},
            text = make_button('LEAVESCREEN', 'No', THEME.PRI, THEME.SEC),
            on_click = self.action_no,
        })
    else
        table.insert(buttons, widgets.Label{
            frame = {b = 0, l = 22, w = 9},
            text = make_button('SELECT', 'OK', THEME.PRI, THEME.SEC),
            on_click = self.action_ok,
        })
    end

    self:addviews{
        widgets.Window{
            frame = {w = self.frame_w, h = self.frame_h},
            frame_title = self.title,
            frame_style = gui.FRAME_MEDIUM,
            subviews = {
                widgets.WrappedLabel{
                    frame = {t = 0, l = 0, b = 2},
                    text_to_wrap = self.text,
                    text_pen = active_text_pen
                },
                widgets.Panel{
                    frame = {b = 0, l = 0, r = 0, h = 1},
                    subviews = buttons
                }
            }
        }
    }
end

function RefinishPrompt:onInput(keys)
    if self.on_yes then
        if keys.SELECT then self.action_yes(); return true
        elseif keys.LEAVESCREEN then self.action_no(); return true end
    else
        if keys.SELECT or keys.LEAVESCREEN then self.action_ok(); return true end
    end
    return RefinishPrompt.super.onInput(self, keys)
end

return RefinishPrompt