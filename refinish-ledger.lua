-- refinish-ledger.lua
-- ==========================================
-- MATERIAL INDEX LEDGER
-- ==========================================
-- THE PROBLEM
--
-- Items, buildings and constructions store mat_type and mat_index.
-- They do not store material names. An index is only meaningful
-- against the exact inorganics array that produced it.
--
-- The array is rebuilt from scratch every load, in three bands:
--
--   [0 .. V-1]    vanilla, read from the save's raw folder
--   [V .. ]       module materials, injected at startup Step 2
--   [.. end]      core RM materials, injected at startup Step 4
--
-- Vanilla never moves. The two injected bands do, whenever a
-- module is installed, removed, or updated with a different
-- material count. Because core RM injects after modules, a change
-- in the module band shifts core RM as well.
--
-- WHY THE PAYLOAD IS NOT ENOUGH
--
-- refinish-save washes core RM objects to a vanilla index and
-- records their names, so refinish-load can restore them without
-- interpreting anything. That covers core RM under AUTOSAVE only.
-- It covers nothing under HOTSAVE, which never calls refinish-save
-- (refinish-autosave.lua:105 and :118), and it has never covered
-- module materials under either protocol.
--
-- COVERAGE
--
--   HOTSAVE   every object sits at an injected index, is in the
--             ledger, and is remapped here. refinish-load does not
--             run at all.
--
--   AUTOSAVE  core RM objects were washed to vanilla indices,
--             which are below the injected band and therefore
--             absent from the ledger. remap() skips them and
--             refinish-load restores them by name. Module objects
--             were never washed, so they are in the ledger and are
--             remapped here. The two passes touch disjoint sets.
--
-- CALL ORDER (refinish-startup)
--
--   Step 4    material injection, indices become final
--   Step 6.5  remap()   must run BEFORE refinish-load
--   Step 7    refinish-load, payload restore
--   Step 8    write()   snapshot for the next session
--
-- remap() runs before refinish-load because the payload restore
-- sets mat_index from names. Remapping afterwards would take
-- freshly correct indices and rewrite them against a stale ledger.
-- ==========================================

local json = require('json')


-- ==========================================
-- CONFIGURATION
-- ==========================================

-- Site data key. Sits alongside REFINISH_STEEL_PAYLOAD.
local LEDGER_KEY = "REFINISH_STEEL_LEDGER"

-- Core RM material id prefix. Module prefixes come from the live
-- registry at runtime.
local CORE_PREFIX = "REFINISH_STEEL_"


-- ==========================================
-- HELPERS
-- ==========================================

-- Same test the module engine uses (refinish-module-engine.lua:81).
local function has_prefix(str, prefix)
    return string.sub(str, 1, #prefix) == prefix
end

-- Operational messages go to the RM log, never to print().
local function log(msg)
    if _G.refinish_log_event then _G.refinish_log_event(msg) end
end

-- Every id prefix that RM or one of its modules owns. Core RM is
-- always included; module prefixes are the keys of the registry,
-- populated by the module pipeline at Step 2.
local function owned_prefixes()
    local list = { CORE_PREFIX }
    for prefix, _ in pairs(_G.refinish_module_registry or {}) do
        table.insert(list, prefix)
    end
    return list
end

local function is_owned(mat_id, prefixes)
    for _, p in ipairs(prefixes) do
        if has_prefix(mat_id, p) then return true end
    end
    return false
end


-- ==========================================
-- WRITE
-- ==========================================
-- Snapshots id -> current index for every injected material.
--
-- Safe any time after Step 4, since nothing later in the pipeline
-- moves a material.
--
-- Returns the number of materials recorded.
-- ==========================================
function write()
    local prefixes = owned_prefixes()
    local mats = {}
    local n = 0

    for i, mat in ipairs(df.global.world.raws.inorganics.all) do
        if is_owned(mat.id, prefixes) then
            mats[mat.id] = i
            n = n + 1
        end
    end

    -- Refuse to overwrite a good ledger with an empty one. If
    -- injection failed this session, last session's record is the
    -- only thing that can still recover these objects.
    if n == 0 then
        log("LEDGER: No injected materials found. Existing ledger left intact.")
        return 0
    end

    dfhack.persistent.saveSiteData(LEDGER_KEY, json.encode({
        site_id = df.global.plotinfo.site_id,
        mats    = mats,
    }))

    log(string.format("LEDGER: Recorded %d material indices.", n))
    return n
end


-- ==========================================
-- REMAP
-- ==========================================
-- Rewrites every object whose stored index belonged to an injected
-- material last session.
--
-- Returns moved, skipped.
-- ==========================================
function remap()
    -- ---- READ THE PREVIOUS SESSION'S LEDGER ----
    local raw = dfhack.persistent.getSiteData(LEDGER_KEY)
    if not raw or raw == "" then
        -- A save that has never had a ledger. Guessing at what the
        -- stored indices used to mean would corrupt objects that are
        -- currently fine, so do nothing. write() runs later this
        -- session and the save is protected from here on.
        log("LEDGER: No previous ledger on this save. Remap skipped.")
        return 0, 0
    end

    local ok, old = pcall(json.decode, raw)
    if not ok or type(old) ~= 'table' or type(old.mats) ~= 'table' then
        log("LEDGER WARNING: Ledger could not be decoded. Remap skipped.")
        return 0, 0
    end

    -- ---- SITE ID GATE ----
    -- Same anti-ghosting rule as refinish-load.lua:74. A ledger from
    -- a different fortress describes a different array.
    local current_site = df.global.plotinfo.site_id
    if old.site_id and old.site_id ~= current_site then
        log(string.format(
            "LEDGER: Discarded ledger from a different Site ID (%s). Remap skipped.",
            tostring(old.site_id)))
        return 0, 0
    end

    -- ---- BUILD BOTH DIRECTIONS ----
    -- by_old_idx answers "what material was this index last time".
    -- by_id answers "where does that material live now".
    --
    -- Two lookups rather than a precomputed old->new pair map,
    -- because a pair map breaks as soon as two materials swap
    -- places. The name is the only stable identity.
    local inorganics = df.global.world.raws.inorganics.all

    local by_old_idx = {}
    for id, idx in pairs(old.mats) do
        by_old_idx[idx] = id
    end

    local by_id = {}
    for i, mat in ipairs(inorganics) do
        by_id[mat.id] = i
    end

    local moved, skipped = 0, 0

    -- ---- THE DECISION, MADE ONCE PER OBJECT ----
    -- Returns nil to mean "write nothing". That covers two cases:
    --
    --   not in the ledger    vanilla stone, and core RM objects
    --                        that refinish-save washed to a vanilla
    --                        index under AUTOSAVE. Those sit below
    --                        the injected band and are restored by
    --                        name in Step 7 instead.
    --
    --   material is gone     the mod that provided it was removed.
    --                        RM never writes a sentinel in this
    --                        case; refinish-load.lua:119, :163 and
    --                        :182 all require a resolved target and
    --                        skip the object otherwise. Same here.
    local function resolve(old_idx)
        local id = by_old_idx[old_idx]
        if not id then return nil end

        local new_idx = by_id[id]
        if not new_idx then
            skipped = skipped + 1
            return nil
        end

        if new_idx ~= old_idx then moved = moved + 1 end
        return new_idx
    end

    -- Bounds test matching refinish-save.lua:114 and :161. An index
    -- outside the array is never dereferenced.
    local function stored_index(obj)
        local ok_r, idx = pcall(function() return obj.mat_index end)
        if ok_r and type(idx) == 'number' and idx >= 0 and idx < #inorganics then
            return idx
        end
        return nil
    end

    -- ---- CONSTRUCTIONS ----
    -- Constructions have no id and no array. They are addressed
    -- only by tile, through dfhack.constructions.findAtTile, and
    -- they are reached through the item that built them, exactly as
    -- refinish-save.lua:124-147 does it.
    --
    -- A wall occupies its own tile and the floor above, so z+1 is
    -- checked too, and only when it carries the same old index as
    -- the tile below (refinish-save.lua:141).
    --
    -- mat_type is written alongside mat_index because every
    -- construction write in RM does that (refinish-save.lua:135-136,
    -- refinish-load.lua:131-132 and :183-184).
    --
    -- Wrapped so a construction fault cannot abort the item and
    -- building passes, matching refinish-load.lua:171.
    local function remap_construction_at(item)
        pcall(function()
            local pos = item.pos
            local cons = dfhack.constructions.findAtTile(pos)
            if not cons or cons.mat_type ~= 0 then return end

            local old_idx = stored_index(cons)
            if not old_idx then return end

            local new_idx = resolve(old_idx)
            if not new_idx then return end

            cons.mat_type = 0
            cons.mat_index = new_idx

            local above = dfhack.constructions.findAtTile(
                { x = pos.x, y = pos.y, z = pos.z + 1 })
            if above and above.mat_type == 0 and above.mat_index == old_idx then
                above.mat_type = 0
                above.mat_index = new_idx
            end
        end)
    end

    -- ---- ITEMS ----
    -- getActualMaterial() == 0 is the inorganic test used
    -- throughout RM. Organic items index a different array and must
    -- never be touched here.
    --
    -- The construction pass rides this loop because the item is the
    -- only handle a construction has. flags.construction marks an
    -- item that is part of one (refinish-load.lua:124).
    for _, item in ipairs(df.global.world.items.all) do
        if item:getActualMaterial() == 0 then
            if item.flags.construction then
                remap_construction_at(item)
            end

            local old_idx = stored_index(item)
            if old_idx then
                local new_idx = resolve(old_idx)
                if new_idx then item.mat_index = new_idx end
            end
        end
    end

    -- ---- BUILDINGS ----
    for _, bld in ipairs(df.global.world.buildings.all) do
        if bld.mat_type == 0 then
            local old_idx = stored_index(bld)
            if old_idx then
                local new_idx = resolve(old_idx)
                if new_idx then bld.mat_index = new_idx end
            end
        end
    end

    -- ---- REPORT ----
    if moved > 0 then
        log(string.format("LEDGER: Remapped %d objects to new material indices.", moved))
    end

    if skipped > 0 then
        log(string.format(
            "LEDGER WARNING: %d objects left untouched; their materials are no longer present.",
            skipped))
    end

    if moved == 0 and skipped == 0 then
        log("LEDGER: No objects needed remapping.")
    end

    return moved, skipped
end


return _ENV
