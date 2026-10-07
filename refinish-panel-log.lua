--@ module = true
-- refinish-panel-log.lua
-- ==========================================
-- LIVE EVENT LOG PANEL
-- ==========================================
-- Displays the in-memory log buffer (_G.refinish_log) with
-- color-coded severity. Log entries are colored based on their
-- PREFIX (the text before the first colon), not keyword scanning
-- the entire message. This is fast and deterministic.
--
-- SEVERITY LEVELS (in priority order):
--   FATAL    - Unrecoverable crash during a pipeline step
--   ERROR    - Recoverable failure (missing data, decode error)
--   WARN     - Non-critical issue (dropped base, skipped shell)
--   CYCLE    - Pipeline lifecycle (boot, startup, shutdown, autosave)
--   BUILD    - Asset construction (scan, index, evaluate, load, save)
--   CLEAR    - Asset teardown (clear scripts)
--   SYSTEM   - Session lifecycle (map load/unload, DF launch)
--   RUNTIME  - Background monitors (JIT, watcher, tripwire, calendar)
--   UI       - Panel navigation, prompts, config changes
--   DEFAULT  - Anything that doesn't match a known prefix
-- ==========================================

local gui = require('gui')
local widgets = require('gui.widgets')
local dialogs = require('gui.dialogs')


-- ==========================================
-- TEXT WRAPPING HELPER
-- ==========================================
-- Wraps a log entry to fit within max_width characters.
-- Continuation lines are indented by 4 spaces so the timestamp
-- on the first line stays visually distinct. The indent is counted
-- against max_width, so wrapped lines never grow past it.
--
-- ON THE WIDTH:
-- This list and the help panel's content list are both subviews of
-- the same centre router, so both get the same panel width P.
--   help: inset l=25, no icon, wraps to 46 -> reserves P - 71
--   log:  inset l=0, icon_width 2, was 73  -> reserved P - 75
-- The log was reserving 4 fewer columns than the help panel, which
-- is why full-length lines printed underneath the scrollbar. 69
-- gives it the identical margin the help panel already uses.
-- ==========================================
local WRAP_WIDTH = 69

local function wrap_log_entry(text, max_width)
    local lines = {}
    if not text or text == "" then return lines end

    local INDENT = "    "
    local current_line = ""

    -- Push the line in progress and start a fresh continuation line.
    local function newline()
        table.insert(lines, current_line)
        current_line = INDENT
    end

    for word in text:gmatch("%S+") do
        -- Working copy. The generic-for control variable is read-only
        -- in Lua 5.4 and later, so an oversized word has to be eaten
        -- through a local instead of by reassigning `word` itself.
        local rest = word

        -- Loop because one word may need more than one line.
        while true do
            -- No space before the first word on a line.
            local sep = (current_line == "" or current_line == INDENT) and "" or " "
            local room = max_width - #current_line - #sep

            if #rest <= room then
                current_line = current_line .. sep .. rest
                break
            end

            if current_line ~= "" and current_line ~= INDENT then
                -- Line has content, so wrap and retry on a fresh one.
                newline()
            else
                -- Already on a fresh line and it still does not fit,
                -- so the word itself is longer than a line. Take what
                -- fits and carry the rest over.
                --
                -- Without this, a single long token (a file path, a
                -- mod ID, a material list with no spaces) is emitted
                -- at full length regardless of max_width and runs
                -- under the scrollbar no matter what the width is.
                current_line = current_line .. rest:sub(1, room)
                rest = rest:sub(room + 1)
                newline()
            end
        end
    end

    if current_line ~= "" and current_line ~= INDENT then
        table.insert(lines, current_line)
    end

    return lines
end


-- ==========================================
-- SEVERITY DETECTION (PREFIX-BASED)
-- ==========================================
-- Extracts the prefix (text before the first ":") from a log
-- entry and matches it against known prefix patterns. This is
-- more reliable than keyword-scanning the entire message body
-- because prefixes are controlled by us, but message content
-- can contain any words (e.g. "Error" in a metal name wouldn't
-- accidentally flag as an error).
--
-- Priority order matters: FATAL/ERROR/WARN are checked first
-- because a message like "STARTUP WARNING: ..." should be WARN,
-- not PIPELINE.
-- ==========================================

-- Lookup table: prefix fragment -> severity level.
-- Checked via string.find on the prefix (before the first colon).
-- Order within each severity doesn't matter; cross-severity
-- priority is handled by checking FATAL/ERROR/WARN first.
local PREFIX_RULES = {
    -- FATAL: Unrecoverable crashes
    { pattern = "FATAL",            severity = "FATAL" },

    -- ERROR: Recoverable failures
    { pattern = "ERROR",            severity = "ERROR" },

    -- WARN: Non-critical issues
    { pattern = "WARNING",          severity = "WARN" },

    -- CYCLE: Pipeline lifecycle transitions (boot, startup, shutdown, autosave)
    { pattern = "BOOT",             severity = "CYCLE" },
    { pattern = "STARTUP",          severity = "CYCLE" },
    { pattern = "SHUTDOWN",         severity = "CYCLE" },
    { pattern = "HARD SHUTDOWN",    severity = "CYCLE" },
    { pattern = "AUTOSAVE",         severity = "CYCLE" },

    -- SYSTEM: Session lifecycle
    { pattern = "SC_MAP",           severity = "SYSTEM" },
    { pattern = "SYSTEM",           severity = "SYSTEM" },
    { pattern = "STATE CHECK",      severity = "SYSTEM" },
    { pattern = "=== DWARF",        severity = "SYSTEM" },
    { pattern = "Refinish Metal v", severity = "SYSTEM" },

    -- BUILD: Asset construction (scan, index, evaluate, modules)
    { pattern = "SCANNER",          severity = "BUILD" },
    { pattern = "INDEX",            severity = "BUILD" },
    { pattern = "MODULE ENGINE",    severity = "BUILD" },
    { pattern = "MODULE REACT",     severity = "BUILD" },
    { pattern = "MODULE INJECT",    severity = "BUILD" },
    { pattern = "MODULE PERMISSIONS", severity = "BUILD" },
    { pattern = "EVALUATE",         severity = "BUILD" },
    { pattern = "SAVE/WASH",        severity = "BUILD" },
    { pattern = "LOAD",             severity = "BUILD" },
    { pattern = "DIAGNOSTIC DUMP",  severity = "BUILD" },

    -- CLEAR: Asset teardown
    { pattern = "CLEAR",            severity = "CLEAR" },

    -- RUNTIME: Background monitors and JIT
    { pattern = "JIT",              severity = "RUNTIME" },
    { pattern = "Ghost Swap",       severity = "RUNTIME" },
    { pattern = "WATCHER",          severity = "RUNTIME" },
    { pattern = "Watcher",          severity = "RUNTIME" },
    { pattern = "UI Tripwire",      severity = "RUNTIME" },
    { pattern = "UI Monitor",       severity = "RUNTIME" },
    { pattern = "Autosave Timer",   severity = "RUNTIME" },
    { pattern = "Calendar",         severity = "RUNTIME" },
    { pattern = "OVERLAY",          severity = "RUNTIME" },

    -- UI: Panel navigation, prompts, config
    { pattern = "UI NAV",           severity = "UI" },
    { pattern = "PROMPT",           severity = "UI" },
    { pattern = "Config",           severity = "UI" },
    { pattern = "HELP",             severity = "UI" },
    { pattern = "CIV DASH",         severity = "UI" },
    { pattern = "INSPECTOR",        severity = "UI" },
    { pattern = "LOG VIEWER",       severity = "UI" },
    { pattern = "Live UI log",      severity = "UI" },
}

-- Severity markers that appear at the HEAD of the message body,
-- immediately after the prefix colon.
--
-- The prefix rules above classify by subsystem, which is not the
-- same thing as severity. RM states severity after the colon:
--
--   MODULE PERMISSIONS: REJECTED [...] for [EVIL] ...
--   MODULE ENGINE: REACTION INJECTION FAILED for [...]
--
-- Classified by prefix alone, the first rendered in DEFAULT blue,
-- identical to an ordinary line, and the second rendered in BUILD
-- green, identical to a successful step. A failure that looks like
-- a success is worse than no message at all, because it reports
-- that everything is fine.
--
-- Scanning the whole body would be unsafe, exactly as the note
-- above says: a material or reaction id could contain any word.
-- Two constraints keep this tight:
--
--   1. Only the first few words are examined, so an id appearing
--      later in the message can never trigger a severity.
--   2. Matching is case sensitive and these markers are caps by
--      convention. "REJECTED" at the head is a marker; the
--      lowercase "rejected" in a summary count is prose and is
--      correctly ignored.
local BODY_RULES = {
    { pattern = "FATAL",    severity = "FATAL" },
    { pattern = "FAILED",   severity = "ERROR" },
    { pattern = "ERROR",    severity = "ERROR" },
    { pattern = "REJECTED", severity = "WARN"  },
    { pattern = "WARNING",  severity = "WARN"  },
}

-- How many leading words of the body to examine. Three covers the
-- longest marker phrase currently emitted, "MATERIAL INJECTION
-- FAILED", without reaching into argument text.
local BODY_WORDS_CHECKED = 3

local function get_severity(msg)
    if not msg then return "DEFAULT" end

    -- Extract the prefix: everything before the first colon,
    -- or the first 40 chars if there's no colon (covers messages
    -- like "=== DWARF FORTRESS EXECUTABLE LAUNCHED ===").
    local prefix = string.match(msg, "^%[%d+:%d+:%d+%]%s*(.-):")
    if not prefix then
        prefix = string.sub(msg, 1, 60)
    end

    -- ---- BODY HEAD, CHECKED FIRST ----
    -- Severity outranks subsystem. A build step that failed is a
    -- failure, not a build step.
    local body = string.match(msg, "^%[%d+:%d+:%d+%]%s*.-:%s*(.*)")
    if body then
        local checked = 0
        for word in body:gmatch("%S+") do
            for _, rule in ipairs(BODY_RULES) do
                if string.find(word, rule.pattern, 1, true) then
                    return rule.severity
                end
            end
            checked = checked + 1
            if checked >= BODY_WORDS_CHECKED then break end
        end
    end

    -- ---- SUBSYSTEM PREFIX ----
    -- Walk the rules in priority order
    for _, rule in ipairs(PREFIX_RULES) do
        if string.find(prefix, rule.pattern, 1, true) then
            return rule.severity
        end
    end

    return "DEFAULT"
end


-- ==========================================
-- PANEL CLASS
-- ==========================================
RefinishPanelLog = defclass(RefinishPanelLog, widgets.Panel)
RefinishPanelLog.ATTRS = {
    theme = DEFAULT_NIL,
}

function RefinishPanelLog:init()
    self.theme = self.theme or reqscript('refinish-theme').get_current_theme()

    -- Severity -> Color mapping
    -- Each category gets its own color so the log has visual
    -- structure. Pipeline events are split into three phases
    -- (CYCLE/BUILD/CLEAR) to break up the wall of same-color text.
    self.severity_pens = {
        FATAL    = self.theme.RISK_H,     -- Red: crash
        ERROR    = self.theme.RISK_M,     -- LRed: failure
        WARN     = self.theme.RISK_L,     -- Yellow: caution
        CYCLE    = self.theme.TER,        -- Cyan: pipeline lifecycle (boot/startup/shutdown)
        BUILD    = self.theme.PRI,        -- LGreen: asset construction (scan/index/evaluate)
        CLEAR    = self.theme.SEC,        -- LBlue: teardown (clear scripts)
        SYSTEM   = self.theme.NEUTRAL_B,  -- White: session lifecycle (map load/unload)
        RUNTIME  = self.theme.PRI,        -- LBlue: background monitors (watcher/tripwire/JIT)
        UI       = self.theme.NEUTRAL_S,  -- Black: low-priority navigation
        DEFAULT  = self.theme.SEC,        -- LBlue: uncategorized
    }

    -- Build initial log display
    self.log_lines = self:build_log_lines()
    self.last_log_count = _G.refinish_log and #_G.refinish_log or 0

    self.list_widget = widgets.List{
        frame = {t = 2, l = 0, r = 0, b = 4},
        choices = self.log_lines,
        selected = #self.log_lines,  -- Start at the bottom (newest entries)
        text_pen = self.theme.SEC,
        cursor_pen = self.theme.SEC,  -- Not visible on text (tokens override), but required
        icon_width = 2,               -- Reserve 2 chars left of text for the cursor marker
    }

    -- Block STRING_A key events from reaching the list's scroll
    -- handler. Theme colour pickers on the config panel use
    -- shifted number keys (STRING_A symbols like @ and *), which
    -- collide with DF's secondary scroll bindings. Since the log
    -- list has no text input, it should never process STRING_A keys.
    local orig_onInput = self.list_widget.onInput
    self.list_widget.onInput = function(list_self, keys)
        if keys._STRING then return false end
        return orig_onInput(list_self, keys)
    end

    self.tick_counter = 0

    -- ==========================================
    -- THEMED KEY DISPLAY HELPER
    -- ==========================================
    local function make_key_label(key_token, label_text, pen_label)
        local key_str = dfhack.screen.getKeyDisplay(df.interface_key[key_token])
        return {
            {text = key_str, pen = self.theme.PRI},
            {text = ": " .. label_text, pen = pen_label}
        }
    end

    -- Store action callbacks so onInput can reference them
    self.actions = {
        CUSTOM_CTRL_C = function()
            _G.refinish_log = {}
            if _G.refinish_log_event then _G.refinish_log_event("LOG VIEWER: Live log cleared by user.") end
            self:refresh_list()
        end,
        CUSTOM_CTRL_L = function()
            self:export_permanent_dump()
        end,
        CUSTOM_CTRL_D = function()
            reqscript('refinish-dump').execute()
        end
    }

    self:addviews{
        widgets.Label{ frame = {t = 0, l = 0}, text = "LIVE EVENT LOG", text_pen = self.theme.PRI },
        self.list_widget,

        -- BOTTOM CONTROL BAR
        widgets.Panel{
            frame = {b = 0, l = 0, r = 0, h = 3},
            subviews = {
                widgets.Label{
                    frame = {t = 0, l = 0, w = 22},
                    text = make_key_label('CUSTOM_CTRL_C', 'Clear Live Log', self.theme.SEC),
                    on_click = self.actions.CUSTOM_CTRL_C,
                },
                widgets.Label{
                    frame = {t = 1, l = 0, w = 23},
                    text = make_key_label('CUSTOM_CTRL_L', 'Export Log Dump', self.theme.SEC),
                    on_click = self.actions.CUSTOM_CTRL_L,
                },
                widgets.Label{
                    frame = {t = 2, l = 0, w = 25},
                    text = make_key_label('CUSTOM_CTRL_D', 'Export Debug Dump', self.theme.SEC),
                    on_click = self.actions.CUSTOM_CTRL_D,
                }
            }
        }
    }
end


-- ==========================================
-- POLLING LOOP
-- ==========================================
-- Checks every 60 render ticks for new log entries. If the log
-- buffer has grown since last check, rebuild the display and
-- use setChoices to update. Scroll position is preserved: if the
-- user was at the bottom (watching live), we pin to the new
-- bottom. If they scrolled up to read something, we hold position.
-- ==========================================
function RefinishPanelLog:onRenderFrame(dc, rect)
    self.tick_counter = self.tick_counter + 1
    if self.tick_counter >= 60 then
        self.tick_counter = 0
        local current_count = _G.refinish_log and #_G.refinish_log or 0
        if current_count ~= self.last_log_count then
            self.last_log_count = current_count

            -- Capture scroll state BEFORE rebuilding
            local old_choices = self.list_widget:getChoices()
            local old_sel = self.list_widget:getSelected() or 0
            local old_page_top = self.list_widget.page_top or 1
            local was_at_bottom = (old_sel >= #old_choices - 2)

            -- Full rebuild (row count changes with new entries)
            self.log_lines = self:build_log_lines()
            self.list_widget:setChoices(self.log_lines)

            local new_count = #self.log_lines

            if was_at_bottom or #old_choices == 0 then
                -- Pin hard to the bottom: move cursor to last entry,
                -- then force page_top so the viewport's last visible
                -- row IS the last entry. This keeps new entries flush
                -- at the bottom of the visible area.
                self.list_widget:setSelected(new_count)

                -- Calculate page_top: the list shows (frame height)
                -- rows at a time. We want the last row at the bottom
                -- of the visible area, so page_top = total - visible + 1.
                local visible = self.list_widget.frame_body and self.list_widget.frame_body.height or 20
                local target_top = new_count - visible + 1
                if target_top < 1 then target_top = 1 end
                self.list_widget.page_top = target_top
            else
                -- User scrolled up - hold their reading position.
                -- Restore both cursor and scroll offset.
                if old_sel > 0 and old_sel <= new_count then
                    self.list_widget:setSelected(old_sel)
                end
                self.list_widget.page_top = old_page_top
            end
        end
    end
    RefinishPanelLog.super.onRenderFrame(self, dc, rect)
end
-- Shared between init() and refresh_list(). Reads the global
-- log buffer in reverse order (buffer stores newest-first, so we
-- iterate backwards to produce chronological display: oldest at
-- top, newest at bottom).
-- ==========================================
function RefinishPanelLog:build_log_lines()
    local lines = {}
    -- Capture self for use in icon callbacks. Unlike the local
    -- list_ref approach, self.list_widget is always the live
    -- widget - even on the first call from init() when it gets
    -- assigned immediately after build_log_lines returns.
    local panel = self

    if _G.refinish_log and #_G.refinish_log > 0 then
        for i = #_G.refinish_log, 1, -1 do
            local raw_text = _G.refinish_log[i]
            local severity = get_severity(raw_text)
            local pen = self.severity_pens[severity] or self.theme.SEC
            local wrapped = wrap_log_entry(raw_text, WRAP_WIDTH)
            for _, line in ipairs(wrapped) do
                local idx = #lines + 1
                table.insert(lines, {
                    text = {{ text = line, pen = pen }},
                    -- Icon callback: returns a cursor marker on the
                    -- selected row, blank on all others. Uses panel
                    -- reference to access list_widget at render time
                    -- (not build time), so it's never nil or stale.
                    icon = function()
                        if panel.list_widget then
                            local sel = panel.list_widget:getSelected()
                            if sel == idx then return string.char(16) end
                        end
                        return " "
                    end,
                    icon_pen = self.theme.NEUTRAL_B,
                })
            end
        end
    else
        table.insert(lines, { text = {{ text = "  (Log is empty)", pen = self.theme.SEC }} })
    end

    return lines
end


-- ==========================================
-- KEY INPUT HANDLER
-- ==========================================
function RefinishPanelLog:onInput(keys)
    for key_name, action in pairs(self.actions) do
        if keys[key_name] then
            action()
            return true
        end
    end
    return RefinishPanelLog.super.onInput(self, keys)
end


-- ==========================================
-- IN-PLACE LIST REFRESH
-- ==========================================
function RefinishPanelLog:refresh_list()
    self.log_lines = self:build_log_lines()
    self.list_widget:setChoices(self.log_lines)
end


-- ==========================================
-- PERMANENT DUMP GENERATOR
-- ==========================================
function RefinishPanelLog:export_permanent_dump()
    local dump_name = reqscript('refinish-debug').make_filename("log")

    local ok, err = pcall(function()
        local file = io.open(dump_name, "w")
        if file then
            file:write("==================================================\n")
            file:write("REFINISH STEEL: PERMANENT EVENT LOG DUMP\n")
            file:write("TIMESTAMP: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
            file:write("==================================================\n\n")

            if _G.refinish_log and #_G.refinish_log > 0 then
                for i = #_G.refinish_log, 1, -1 do
                    file:write(_G.refinish_log[i] .. "\n")
                end
            else
                file:write("(No events logged.)\n")
            end
            file:close()
        end
    end)

    if ok then
        if _G.refinish_log_event then _G.refinish_log_event("LOG VIEWER: Permanent log dump exported -> " .. dump_name) end
        dialogs.showMessage(
            "Export Successful",
            "The permanent log has been saved to your main Dwarf Fortress folder as:\n\n" .. dump_name,
            self.theme.PRI
        )
        self:refresh_list()
    else
        if _G.refinish_log_event then _G.refinish_log_event("LOG VIEWER ERROR: Failed to export -> " .. tostring(err)) end
        dialogs.showMessage(
            "Export Failed",
            "An error occurred while trying to save the log file:\n\n" .. tostring(err),
            self.theme.RISK_H or COLOR_RED
        )
        self:refresh_list()
    end
end

return _ENV