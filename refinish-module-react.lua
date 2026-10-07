--@ module = true
-- refinish-module-react.lua
-- ==========================================
-- RM MODULE REACTION BUILDER
-- ==========================================
-- Takes validated reaction definitions and constructs live DF
-- reactions in RAM. For each reaction:
--   1. Find a template reaction (auto-score + fallback)
--   2. Deep-copy the template
--   3. Set identity, building, skill, fuel, category
--   4. Build reagents from the definition's type specs
--   5. Build products with material resolution / derivation
--   6. Inject into the live reactions array
--
-- Also handles:
--   - Category injection (menu structure)
--   - Entity permission injection (civ workshop access)
--
-- DEPENDENCIES:
--   refinish-module-types.lua - Reagent types, product types,
--                                building types, skill map
--
-- CALLED FROM:
--   refinish-module-engine.lua (pipeline steps)
-- ==========================================

local types = reqscript('refinish-module-types')

-- Anchored, plain-text prefix test. Local copy of the engine's helper,
-- kept here rather than shared so this file keeps its single require.
-- See the note in refinish-module-engine.lua for why string.find is
-- the wrong tool for this.
local function has_prefix(str, prefix)
    return string.sub(str, 1, #prefix) == prefix
end

-- ==========================================
-- INORGANIC LOOKUP BUILDER
-- ==========================================
-- Builds a name->index dictionary from the live inorganic array.
-- Called once before reaction building so mat_id references can
-- be resolved to numeric indices.
-- ==========================================
local function build_mat_lookup()
    local lookup = {}
    for i, mat in ipairs(df.global.world.raws.inorganics.all) do
        lookup[mat.id] = i
    end
    return lookup
end


-- ==========================================
-- TEMPLATE SCORING
-- ==========================================
-- Given a reaction definition and a candidate template reaction,
-- score how well the template matches the definition's shape.
-- Higher = better match. Used by find_template to pick the best
-- structural donor from the loaded reaction array.
--
-- Scoring criteria:
--   - Building type match (highest weight - wrong building = wrong
--     workshop entirely)
--   - Fuel flag match
--   - Reagent count similarity
--   - Product item_type match
--
-- This is a heuristic, not an exact matcher. The fallback_template
-- field exists as the safety net if scoring picks poorly.
-- ==========================================
local function score_template(sig, def)
    local score = 0
    local building_def = types.BUILDING_TYPES[def.building]

    if building_def and sig.has_building then
        for _, b_type_def in ipairs(building_def.type) do
            for _, b_type_rxn in ipairs(sig.building_types) do
                if b_type_def == b_type_rxn then
                    score = score + 30
                    goto building_matched
                end
            end
        end
        ::building_matched::

        if #building_def.subtype > 0 then
            for _, sub_def in ipairs(building_def.subtype) do
                for _, sub_rxn in ipairs(sig.building_subtypes) do
                    if sub_def == sub_rxn then
                        score = score + 10
                        goto subtype_matched
                    end
                end
            end
            ::subtype_matched::
        end
    end

    local def_fuel = def.fuel or false
    if sig.fuel == def_fuel then
        score = score + 10
    end

    if def.reagents then
        local diff = math.abs(sig.reagent_count - #def.reagents)
        if diff == 0 then
            score = score + 15
        elseif diff <= 2 then
            score = score + 5
        end
    end

    if def.products and #def.products > 0 then
        local want = def.products[1].type
        local wanted_type = types.PRODUCT_TYPES[want]
        local want_improvement = wanted_type and wanted_type.improvement

        local wanted_item_type = wanted_type and wanted_type.item_type
        if wanted_item_type == nil and not want_improvement then
            local resolved = df.item_type[want]
            if type(resolved) == "number" then
                wanted_item_type = resolved
            end
        end

        if want_improvement then
            if sig.has_improvement then
                score = score + 20
            end
        elseif wanted_item_type ~= nil then
            for _, ptype in ipairs(sig.product_item_types) do
                if ptype == wanted_item_type then
                    score = score + 20
                    break
                end
            end
        end
    end

    return score
end


-- ==========================================
-- FIND TEMPLATE REACTION
-- ==========================================
-- Scores every loaded reaction against the definition and returns
-- the best match. Falls back to a named reaction code if the
-- scorer finds nothing suitable.
--
-- Skips RM-injected and module-injected reactions - we only want
-- vanilla or raws-loaded reactions as structural donors.
-- ==========================================
local function find_template(def, fast_reactions_cache)
    local best_rxn = nil
    local best_score = -1

    for _, sig in ipairs(fast_reactions_cache.signatures) do
        local score = score_template(sig, def)
        if score > best_score then
            best_score = score
            best_rxn = sig.ptr
        end
    end

    if not best_rxn and def.fallback_template then
        best_rxn = fast_reactions_cache.by_code[def.fallback_template]
        best_score = 0 -- Fallbacks bypass scoring
    end

    return best_rxn, best_score
end

-- ==========================================
-- RESOLVE ITEM SUBTYPE
-- ==========================================
-- Tools, trapcomps and similar identify their item by an itemdef code
-- string. The reagent and product structs want a numeric subtype, and
-- that number is a position in the matching world.raws.itemdefs list,
-- which shifts whenever a mod adds or removes one.
--
-- So we look it up by code every time, exactly like custom workshops.
--
-- Returns the subtype index, or -1 if it isn't loaded. A -1 leaves the
-- slot unrestricted, which is wrong but far better than silently
-- pointing at whatever now occupies that position, hence the warning.
-- ==========================================

-- Which itemdefs list belongs to which item type. Only the types that
-- actually carry subtypes need an entry.
local ITEMDEF_LISTS = {
    [df.item_type.TOOL]     = "tools",
    [df.item_type.TRAPCOMP] = "trapcomps",
    [df.item_type.WEAPON]   = "weapons",
    [df.item_type.ARMOR]    = "armor",
    [df.item_type.TOY]      = "toys",
    [df.item_type.INSTRUMENT] = "instruments",
    [df.item_type.AMMO]     = "ammo",
    [df.item_type.SIEGEAMMO] = "siege_ammo",
}

local itemdef_cache = {}

local function resolve_item_subtype(item_type, code)
    local list_name = ITEMDEF_LISTS[item_type]
    if not list_name then
        return -1
    end

    -- JIT GATE: Build dictionary exactly once per item list type
    if not itemdef_cache[list_name] then
        local ok, defs = pcall(function() return df.global.world.raws.itemdefs[list_name] end)
        if not ok or not defs then return -1 end
        
        itemdef_cache[list_name] = {}
        for i, td in ipairs(defs) do
            local got, sub = pcall(function() return td.subtype end)
            if got and type(sub) == "number" then
                itemdef_cache[list_name][td.id] = sub
            else
                itemdef_cache[list_name][td.id] = i
            end
        end
    end

    -- O(1) Instant Lookup
    local subtype = itemdef_cache[list_name][code]
    if not subtype then
        if _G.refinish_log_event then
            _G.refinish_log_event(string.format("MODULE REACT WARNING: itemdef '%s' not found in %s. slot left unrestricted.",
            tostring(code), list_name))
        end
        return -1
    end
    
    return subtype
end

-- Kept so existing callers do not change. Tools were the only consumer
-- before trapcomps arrived with the glass unit.
local function resolve_tool_subtype(code)
    return resolve_item_subtype(df.item_type.TOOL, code)
end


-- ==========================================
-- REAGENT FLAG MAP
-- ==========================================
-- The rest of the job item filter vocabulary, past the flags that
-- build_reagent maps by hand. Those are explicit because they carry an
-- alias (glass_material writes flags1.glass), read from outside the
-- flags block (sand_bearing reads rgt_def root), or needed the comment.
-- Everything here has a schema name identical to its struct field, so a
-- table beats another ninety if statements.
--
-- Most of these have no reaction raw token behind them. No raw file can
-- set them and no vanilla reaction exercises the path, so some will be
-- inert in a reaction context. Exposed anyway: an inert flag costs a
-- table row, and the only way to learn which ones bite is to set them.
-- flags1.furniture had no token either and DF rendered it correctly in
-- the reagent tooltip.
--
-- Bit numbers are from df.reaction_reagent_itemst, dumped live. The
-- UNUSED bits are omitted deliberately.
--
-- Module level rather than local to the function: build_reagent runs
-- once per reagent per reaction, and ArgMOD alone has thousands.
local REAGENT_FLAG_MAP = {

    -- Item state, origin and processing history.
    flags1 = {
        "improvable",             --  0  can still take decoration
        "butcherable",            --  1  a corpse a butcher would accept
        "millable",               --  2  goes in a quern
        "allow_buryable",         --  3  permits coffin-bound items
        "undisturbed",            --  5  vermin, not yet agitated
        "collected",              --  6  gathered rather than found
        "sharpenable",            --  7  knappable stone
        "murdered",               --  8  corpse of a murder victim
        "processable",            -- 11  plant with a process reaction
        "cookable",               -- 13  a kitchen would accept it
        "extract_bearing_plant",  -- 14
        "extract_bearing_fish",   -- 15
        "extract_bearing_vermin", -- 16
        "processable_to_vial",    -- 17
        "processable_to_barrel",  -- 19
        "tameable_vermin",        -- 21
        "nearby",                 -- 22  near the workshop specifically
        "milk",                   -- 25  the item is milk
        "milkable",               -- 26  a milkable creature
        "lye_bearing",            -- 31
    },

    -- Material families, decoration state and stockpile designations.
    flags2 = {
        "dye",                --  0  is a dye
        "dyeable",            --  1  can be dyed
        "dyed",               --  2  already dyed
        "sewn_imageless",     --  3  cloth with no image sewn into it
        "glass_making",       --  4  a glassmaking material
        "screw",              --  5  the mechanism part
        "deep_material",      --  9  adamantine and friends
        "melt_designated",    -- 10  flagged for melting
        "allow_artifact",     -- 13  DANGER: lets a reagent take an
                              --      artifact. non_artifact in flags3
                              --      is the one you almost always want.
        "plaster_containing", -- 22
        "lye_milk_free",      -- 27  container holds neither lye nor milk
        "blunt",              -- 28
        "unengraved",         -- 29
    },

    -- Material classes and item circumstance.
    flags3 = {
        "non_absorbent",              --  2
        "non_pressed",                --  3  not yet through a press
        "allow_liquid_powder",        --  4
        "any_craft",                  --  5  also set by the ANY_CRAFT
                                      --      reagent type's own defaults
        "food_storage",               --  7
        "sand",                       --  9  distinct from flags1
                                      --      sand_bearing, which is the
                                      --      one Collect Sand uses
        "can_use_location_reserved",  -- 10
        "written_on",                 -- 11
        "edged",                      -- 12
        "on_ground",                  -- 13  lying loose, not stored
        "divine",                     -- 14
        "crafted_artifact",           -- 15  DANGER: requires an artifact
        "gem",                        -- 20
        "empty_or_water",             -- 21
    },
}

-- ==========================================
-- BUILD REAGENT
-- ==========================================
-- Constructs a single reaction_reagent_itemst from a reagent
-- definition and a base reagent (cloned from the template).
--
-- The base reagent provides valid C++ internal state. After
-- cloning, we zero out ALL item filter flags (flags1-5) to
-- prevent stale template constraints from leaking through
-- (body_part, unrotten, bone, non_economic, etc.). Then we
-- rebuild only what the schema specifies.
--
-- This is the same neutral reset philosophy used for materials:
-- clone for structure, clear for semantics, rebuild from schema.
-- ==========================================
local function build_reagent(rgt_def, base_reagent, mat_lookup, all_reagent_defs)
    local r = df.reaction_reagent_itemst:new()
    r:assign(base_reagent)

    -- ---- NEUTRAL RESET: ITEM FILTER FLAGS ----
    -- Zero out ALL item filter flags inherited from the template.
    -- These flags control what items DF considers valid for this
    -- reagent slot. A creature-body-part template would have
    -- flags2.body_part=true, flags1.unrotten=true, etc. - leaving
    -- these set makes our boulder/bar/powder reagent reject
    -- everything except body parts.
    --
    -- flags1: empty, unrotten, body_part filters, sand_bearing, etc.
    -- flags2: non_economic, building_material, bone, shell, etc.
    -- flags3: metal, stone, gem, wood material-class filters, etc.
    -- flags4, flags5: additional filter integers
    --
    -- Bitfield structs use .whole to access the underlying integer.
    -- After zeroing, only flags explicitly set by the schema
    -- (via the flags block) will be active.
    r.flags1.whole = 0
    r.flags2.whole = 0
    r.flags3.whole = 0
    r.flags4 = 0
    r.flags5 = 0

    -- Also clear tool use and dye color filters
    r.has_tool_use = -1
    r.dye_color = -1

    -- Identity
    r.code = rgt_def.code

    -- Quantity
    r.quantity = rgt_def.quantity or 1
    r.min_dimension = -1

    -- Type resolution: pull field values from the types dictionary
    local rtype = types.REAGENT_TYPES[rgt_def.type]
    if rtype then
        r.item_type = rtype.item_type

        -- Tool reagents name their subtype by itemdef code (see
        -- resolve_tool_subtype). Everything else clears the subtype so
        -- the template's own subtype can't leak through.
        if rtype.item_subtype then
            r.item_subtype = resolve_tool_subtype(rtype.item_subtype)
        else
            r.item_subtype = -1
        end

        -- mat_type: use type default, but POWDER is special -
        -- if mat_id is given, resolve to INORGANIC (0), else wildcard (-1)
        if rgt_def.type == "POWDER" then
            if rgt_def.mat_id and mat_lookup[rgt_def.mat_id] then
                r.mat_type = 0  -- INORGANIC
                r.mat_index = mat_lookup[rgt_def.mat_id]
            else
                r.mat_type = -1
                r.mat_index = -1
            end
        else
            r.mat_type = rtype.mat_type or -1

            -- mat_index resolution from mat_id
            if rtype.needs_mat_id and rgt_def.mat_id then
                r.mat_index = mat_lookup[rgt_def.mat_id] or -1
            elseif rtype.mat_index ~= nil then
                r.mat_index = rtype.mat_index
            else
                r.mat_index = -1
            end
        end

        -- metal_ore resolution from metal_id (ORE_OF type).
        -- For ORE_OF: resolve metal_id to an inorganic index.
        -- For everything else: force -1 to clear any stale value
        -- inherited from the base reagent (e.g. if the base was a
        -- boulder reagent from BRASS_MAKING with metal_ore pointing
        -- at zinc, and we're building a METAL_BAR reagent for copper,
        -- the leftover metal_ore would confuse DF).
        if rtype.needs_metal_id and rgt_def.metal_id then
            r.metal_ore = mat_lookup[rgt_def.metal_id] or -1
        else
            r.metal_ore = -1
        end

        -- reaction_class: use definition override, else type default
        if rgt_def.reaction_class then
            r.reaction_class = rgt_def.reaction_class
        else
            r.reaction_class = rtype.reaction_class or ""
        end
    end

    -- has_material_reaction_product (e.g. "FIRED_MAT" for clay matching)
    if rgt_def.has_material_reaction_product then
        r.has_material_reaction_product = rgt_def.has_material_reaction_product
    else
        r.has_material_reaction_product = ""
    end

    -- Reagent flags (reaction_reagent_flags level)
    local flags = rgt_def.flags or {}
    r.flags.PRESERVE_REAGENT = flags.preserve or false
    r.flags.IN_CONTAINER = flags.in_container or false
    r.flags.DOES_NOT_DETERMINE_PRODUCT_AMOUNT = flags.does_not_determine_product_amount or false

    -- ---- TYPE-LEVEL FLAGS ----
    -- Some reagent types are defined by a flag rather than an item
    -- type. ANY_CRAFT is item_type -1 plus flags3.any_craft, so the
    -- type dictionary carries the flag and it gets applied here, after
    -- the neutral reset and before the modder's own flags.
    local rtype_def = types.REAGENT_TYPES[rgt_def.type]
    if rtype_def and rtype_def.flags3 then
        for name, val in pairs(rtype_def.flags3) do
            r.flags3[name] = val
        end
    end

    -- flags3:
    --   unimproved  → [NOT_IMPROVED] item must carry no improvements.
    --                 Glazing reactions use it so a glazed craft cannot
    --                 be glazed a second time. Note the raw token and
    --                 the struct field disagree on naming.
    --   any_raw_material → [ANY_RAW_MATERIAL]
    if flags.unimproved ~= nil then
        r.flags3.unimproved = flags.unimproved
    end
    if flags.any_raw_material ~= nil then
        r.flags3.any_raw_material = flags.any_raw_material
    end

    -- flags3 material-class filters. These cut across item types: a
    -- wood filter matches a log, a bed and a wooden jug alike, so pair
    -- them with an item type or with a flags1 category below.
    --   wood   → [WOOD_MATERIAL]
    --   stone  → [STONE_MATERIAL]
    --   metal  → [METAL_MATERIAL]
    --   hard   → [ANY_HARD_MATERIAL]
    --   woven  → cloth that was woven, as opposed to felted or leather
    --
    --   grown_not_crafted → the item was harvested or grown rather than
    --                 built. This is what separates a plump helmet from
    --                 a wooden bed when both answer to flags2.plant.
    --
    --   non_artifact → excludes artifacts. Belongs on EVERY reagent
    --                 that consumes its input, and especially on any
    --                 reagent using item_type -1. Without it a wildcard
    --                 reagent will eventually eat a legendary artifact
    --                 and there is no way to get it back.
    if flags.wood              ~= nil then r.flags3.wood              = flags.wood              end
    if flags.stone             ~= nil then r.flags3.stone             = flags.stone             end
    if flags.metal             ~= nil then r.flags3.metal             = flags.metal             end
    if flags.hard              ~= nil then r.flags3.hard              = flags.hard              end
    if flags.woven             ~= nil then r.flags3.woven             = flags.woven             end
    if flags.grown_not_crafted ~= nil then r.flags3.grown_not_crafted = flags.grown_not_crafted end
    if flags.non_artifact      ~= nil then r.flags3.non_artifact      = flags.non_artifact      end
    -- Item filter flags (flags1/flags2 level)
    -- After neutral reset, all bits are zero. These are rebuilt
    -- only from explicit schema values. Each flag maps to a DF
    -- raw tag on the reagent.
    --
    -- flags1:
    --   empty          → [EMPTY] container must be empty
    --   sand_bearing   → [SAND_BEARING] material must have SOIL_SAND
    --                    (reads from rgt_def root, not flags block)
    -- flags2:
    --   non_economic   → [NON_ECONOMIC] accept non-economic stones
    --   building_material → [BUILDING_MATERIAL] accept building mats
    --   fire_safe      → [FIRE_SAFE] must be fire safe
    --   magma_safe     → [MAGMA_SAFE] must be magma safe
    --   allow_melt_dump → [ALLOW_MELT_DUMP] accept melt-designated items
    if flags.empty ~= nil then
        r.flags1.empty = flags.empty
    end
    if rgt_def.sand_bearing ~= nil then
        r.flags1.sand_bearing = rgt_def.sand_bearing
    end
    if flags.non_economic ~= nil then
        r.flags2.non_economic = flags.non_economic
    end
    if flags.building_material ~= nil then
        r.flags2.building_material = flags.building_material
    end
    if flags.fire_safe ~= nil then
        r.flags2.fire_safe = flags.fire_safe
    end
    if flags.magma_safe ~= nil then
        r.flags2.magma_safe = flags.magma_safe
    end
    if flags.allow_melt_dump ~= nil then
        r.flags2.allow_melt_dump = flags.allow_melt_dump
    end
    -- flags1 also carries two material filters:
    --   glass  → [GLASS_MATERIAL] item must be made of glass.
    --            ArgMOD puts this on 30 of his 38 jug reagents so the
    --            chemist takes glass jugs specifically - without it the
    --            reaction would grab ceramic and metal jugs too.
    if flags.glass_material ~= nil then
        r.flags1.glass = flags.glass_material
    end
    if flags.unrotten ~= nil then
        r.flags1.unrotten = flags.unrotten
    end

    -- flags2 carries the material-family filters. On an untyped reagent
    -- (item_type -1) these do ALL of the filtering, so dropping every
    -- one of them turns the reagent into a wildcard that matches every
    -- item in the fortress. Confirmed live: a BODY_PART reagent whose
    -- only flag was unrotten took a fuel bar and two pitch buckets.
    --
    -- Creature side:
    --   body_part   → [USE_BODY_COMPONENT] item is a body part. This
    --                 one is sufficient on its own; verified taking
    --                 raw hides while leaving bars and buckets alone.
    --   bone        → [ANY_BONE_MATERIAL]
    --   shell       → [ANY_SHELL_MATERIAL]
    --   horn        → [ANY_HORN_MATERIAL]
    --   pearl       → [ANY_PEARL_MATERIAL]
    --   ivory_tooth → [ANY_TOOTH_MATERIAL]
    --   totemable   → skull and similar, what a totem can be made from
    --   leather     → [ANY_LEATHER_MATERIAL] tanned hide only. A raw
    --                 hide is a body part and answers to body_part.
    --   silk        → [ANY_SILK_MATERIAL]
    --   yarn        → [ANY_YARN_MATERIAL]
    --   hair_wool   → hair and wool before spinning
    --   soap        → [ANY_SOAP_MATERIAL]
    --
    -- Plant side:
    --   plant       → [ANY_PLANT_MATERIAL] anything made of plant
    --                 material, which includes wooden furniture and
    --                 plant cloth, not just harvested plants. Vanilla
    --                 pairs it with an item type: the gukil strings
    --                 reagent is THREAD at mat -1/-1 carrying nothing
    --                 else. Narrow it with an item type or with
    --                 flags3.grown_not_crafted.
    if flags.body_part   ~= nil then r.flags2.body_part   = flags.body_part   end
    if flags.bone        ~= nil then r.flags2.bone        = flags.bone        end
    if flags.shell       ~= nil then r.flags2.shell       = flags.shell       end
    if flags.horn        ~= nil then r.flags2.horn        = flags.horn        end
    if flags.pearl       ~= nil then r.flags2.pearl       = flags.pearl       end
    if flags.ivory_tooth ~= nil then r.flags2.ivory_tooth = flags.ivory_tooth end
    if flags.totemable   ~= nil then r.flags2.totemable   = flags.totemable   end
    if flags.leather     ~= nil then r.flags2.leather     = flags.leather     end
    if flags.silk        ~= nil then r.flags2.silk        = flags.silk        end
    if flags.yarn        ~= nil then r.flags2.yarn        = flags.yarn        end
    if flags.hair_wool   ~= nil then r.flags2.hair_wool   = flags.hair_wool   end
    if flags.soap        ~= nil then r.flags2.soap        = flags.soap        end
    if flags.plant       ~= nil then r.flags2.plant       = flags.plant       end

    -- flags1 item categories. These are job item filter bits with no
    -- reaction raw token behind them, so no raw file can express them.
    -- Runtime injection can. Untested in a reaction context, which is
    -- exactly why the furniture intake is worth trying first.
    --   furniture      → item is furniture (bed, table, cabinet, door)
    --   finished_goods → item is a finished good
    --   ammo           → item is ammunition
    if flags.furniture      ~= nil then r.flags1.furniture      = flags.furniture      end
    if flags.finished_goods ~= nil then r.flags1.finished_goods = flags.finished_goods end
    if flags.ammo           ~= nil then r.flags1.ammo           = flags.ammo           end

    -- flags1 exclusions. Same story as the categories above: job item
    -- filter bits with no raw token, so no raw file can set them.
    --
    --   not_bin → item is not a bin. The furniture category includes
    --             containers, and a furniture reagent will happily take
    --             a barrel off the stockpile floor. Confirmed live: the
    --             first CHAR_FURNITURE job grabbed a barrel.
    --
    --   solid   → item is in a solid state. Worth pairing with any
    --             item_type -1 reagent to keep liquids and powders out
    --             of a filter that was only ever meant for objects.
    if flags.not_bin ~= nil then r.flags1.not_bin = flags.not_bin end
    if flags.solid   ~= nil then r.flags1.solid   = flags.solid   end

    -- Everything else in the filter vocabulary. See REAGENT_FLAG_MAP
    -- above the function. A schema flag not listed there and not
    -- handled explicitly above is silently ignored, which is why
    -- preflight validates flag names against the same source.
    for bf_name, names in pairs(REAGENT_FLAG_MAP) do
        local bf = r[bf_name]
        for _, flag_name in ipairs(names) do
            if flags[flag_name] ~= nil then
                bf[flag_name] = flags[flag_name]
            end
        end
    end

    -- Container linkage: contains field.
    -- The "contains" array on a reagent holds the INDICES (positions)
    -- of the reagents it contains. We resolve the code name to an
    -- index by finding which position in the reaction's reagent list
    -- has that code.
    r.contains:resize(0)
    if rgt_def.contains then
        for idx, other_def in ipairs(all_reagent_defs) do
            if other_def.code == rgt_def.contains then
                -- DF uses 0-based indexing for the contains array
                r.contains:insert('#', idx - 1)
                break
            end
        end
    end

    return r
end

-- ==========================================
-- FIND IMPROVEMENT DONOR
-- ==========================================
-- Improvement products are a different C++ class from item products
-- (reaction_product_item_improvementst rather than
-- reaction_product_itemst), with different fields and its own flag
-- layout.
--
-- Rather than construct one from nothing, we clone a live one, exactly
-- as reagents and item products clone their template. Any glazing
-- reaction in the loaded raws will do as a donor.
--
-- Returns nil if the loaded raws contain no improvement product at all,
-- in which case the caller skips the reaction rather than injecting it
-- half-built.
-- ==========================================
local function find_improvement_donor()
    local fallback = nil
    for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
        for _, prod in ipairs(rxn.products) do
            if df.reaction_product_item_improvementst:is_instance(prod) then
                local ok, glazed = pcall(function() return prod.flags.GLAZED end)
                if ok and glazed then
                    return prod
                end
                fallback = fallback or prod
            end
        end
    end
    return fallback
end


-- ==========================================
-- BUILD IMPROVEMENT PRODUCT
-- ==========================================
-- Constructs a reaction_product_item_improvementst from a product
-- definition and a donor cloned from the live raws.
--
-- Only the fields we are certain of are overwritten. The donor's flag
-- bits are deliberately kept: every improvement in the schema uses
-- GET_MATERIAL_FROM_REAGENT, which is what any glazing donor already
-- has set. Validation rejects other material modes rather than letting
-- them inject against flags we did not set.
--
-- improvement_type is resolved by name through df.improvement_type so
-- there is no hardcoded enum value to drift.
-- ==========================================
local function build_improvement_product(prod_def, donor)
    local p = df.reaction_product_item_improvementst:new()
    p:assign(donor)

    -- ---- IDENTITY ----
    p.product_token        = ""
    p.product_to_container = ""
    p.part_token           = ""

    p.target_reagent = prod_def.target_reagent or ""

    -- ---- IMPROVEMENT TYPE ----
    -- GLAZED is not a member of df.improvement_type. The enum has 15
    -- entries and glaze is not one of them. A working vanilla glazing
    -- product is improvement_type COVERED with a GLAZED bit set in its
    -- flags, so glaze is a variety of covering rather than a type of
    -- its own.
    --
    -- The schema keeps saying GLAZED because that is the name the DF
    -- raws use and the name a modder will reach for. The translation
    -- to COVERED plus a flag happens here.
    --
    -- Read directly off GLAZE_JUG in a live install:
    --   improvement_type 1 (COVERED), flags {GET_MATERIAL_PRODUCT, GLAZED}
    local want_glazed = (prod_def.improvement_type == "GLAZED")
    local type_name   = want_glazed and "COVERED" or prod_def.improvement_type

    local itype = df.improvement_type[type_name]
    if type(itype) ~= "number" then
        local msg = string.format(
            "MODULE REACT WARNING: unknown improvement_type '%s'. product skipped.",
            tostring(prod_def.improvement_type))
        if _G.refinish_log_event then
            _G.refinish_log_event(msg)
        end
        return nil
    end
    p.improvement_type          = itype
    p.improvement_specific_type = prod_def.improvement_specific_type or 0

    p.probability = prod_def.probability or 100

    -- ---- NEUTRAL RESET: FLAGS ----
    -- Same rule build_product follows: clone for C++ structure, zero
    -- every semantic flag, rebuild from schema.
    --
    -- This used to keep the donor's flags on the assumption that any
    -- improvement donor would already be set for material-from-reagent.
    -- The donor is whatever comes first in raws order, so in practice
    -- that meant inheriting GET_MATERIAL_SAME from a scroll and no
    -- GLAZED bit at all.
    for bit, _ in pairs(p.flags) do
        p.flags[bit] = false
    end

    p.flags.GET_MATERIAL_PRODUCT = true
    if want_glazed then
        p.flags.GLAZED = true
    end

    -- ---- MATERIAL ----
    -- The improvement takes its material from a reagent's reaction
    -- product, e.g. the GLAZE_MAT of whatever is in the glaze slot.
    -- GET_MATERIAL_PRODUCT above is what makes DF read these two.
    p.mat_type  = -1
    p.mat_index = -1
    p.get_material.reagent_code = prod_def.get_material_product.reagent_code
    p.get_material.product_code = prod_def.get_material_product.product_code

    return p
end

-- ==========================================
-- BUILD PRODUCT
-- ==========================================
-- Constructs a single reaction_product_itemst from a product
-- definition and a base product (cloned from the template).
--
-- Same neutral reset philosophy as build_reagent: clone for
-- C++ structure, zero all semantic flags, rebuild from schema.
-- Without this, template flags like CRAFTS (random craft output)
-- or USE_REAGENT_ITEM leak through and override our product type.
-- ==========================================
local function build_product(prod_def, base_product, mat_lookup)
    local p = df.reaction_product_itemst:new()
    p:assign(base_product)

    -- ---- NEUTRAL RESET: PRODUCT FLAGS ----
    -- Zero all product flags inherited from the template.
    -- These flags control what DF produces and how it resolves
    -- the output material. A craft-making template would have
    -- CRAFTS=true, causing random craft items instead of our
    -- specified product type.
    --
    -- Known flags:
    --   GET_MATERIAL_SAME, GET_MATERIAL_PRODUCT - material resolution
    --   FORCE_EDGE - edged item (knapping)
    --   PASTE, PRESSED - material state overrides
    --   CRAFTS - random craft item generation (the crown/earring bug)
    --   USE_FULL_REACTION_PRODUCT_CLASS - advanced material derivation
    --   USE_REAGENT_ITEM - output uses reagent's item type
    --   TRANSFER_ARTIFACT_STATUS - artifact inheritance
    --
    -- All zeroed, then rebuilt from schema below.
    p.flags.GET_MATERIAL_SAME = false
    p.flags.GET_MATERIAL_PRODUCT = false
    p.flags.FORCE_EDGE = false
    p.flags.PASTE = false
    p.flags.PRESSED = false
    p.flags.CRAFTS = false
    p.flags.USE_FULL_REACTION_PRODUCT_CLASS = false
    p.flags.USE_REAGENT_ITEM = false
    p.flags.TRANSFER_ARTIFACT_STATUS = false

    -- Clear get_material linkage from template
    p.get_material.reagent_code = ""
    p.get_material.product_code = ""

    -- Clear container linkage from template
    p.product_to_container = ""

    -- ---- ITEM TYPE ----
    -- Named entries in PRODUCT_TYPES exist for the cases that need a
    -- non-default mat_type or a special flag. Anything else resolves by
    -- name straight out of df.item_type, which covers the whole item
    -- enum without a table row per kind.
    --
    -- Previously an unrecognised type left the template donor's
    -- item_type in place, which produced the wrong item silently.
    local ptype = types.PRODUCT_TYPES[prod_def.type]
    if ptype and ptype.item_type ~= nil then
        p.item_type = ptype.item_type
    else
        local resolved = df.item_type[prod_def.type]
        if type(resolved) == "number" then
            p.item_type = resolved
        else
            if _G.refinish_log_event then
                _G.refinish_log_event(string.format("MODULE REACT WARNING: unknown product type '%s'. product skipped.",
                tostring(prod_def.type)))
            end
            return nil
        end
    end

    -- CRAFTS is carried by a flag, not an item type. The neutral reset
    -- above cleared it, so set it back on for products that want it.
    if ptype and ptype.crafts then
        p.flags.CRAFTS = true
    end

    -- ---- ITEM SUBTYPE ----
    -- Default -1, because template donors carry specific subtypes
    -- (an instrument subtype, say) that would contaminate the product.
    -- When the schema names one, resolve the itemdef code at build time
    -- since those indices shift with mod load order.
    p.item_subtype = -1
    if prod_def.subtype then
        p.item_subtype = resolve_item_subtype(p.item_type, prod_def.subtype)
    end

    -- Count and dimension
    p.count = prod_def.count or 1
    p.product_dimension = prod_def.dimension or 150
    p.probability = prod_def.probability or 100

    -- Material resolution: exactly one of three modes
    -- Mode 1: Direct mat_id -> resolved inorganic index
    if prod_def.mat_id then
        p.mat_type = (ptype and ptype.mat_type) or 0  -- default INORGANIC
        -- A product type with mat_subtypes carries a builtin material
        -- whose index selects WHICH form of it. COAL is the only one so
        -- far: 0 is coke, 1 is charcoal. Neither is an inorganic, so the
        -- lookup below can never find them, and letting it miss wrote
        -- -1 into every coal bar RM has ever built.
        --
        -- An unmapped name fails hard rather than falling back. The
        -- reason this went unnoticed for so long is that the old path
        -- failed silently and produced a plausible looking item.
        if ptype and ptype.mat_subtypes then
            local sub = ptype.mat_subtypes[prod_def.mat_id]
            if sub == nil then
                local names = {}
                for k in pairs(ptype.mat_subtypes) do names[#names + 1] = k end
                table.sort(names)
                if _G.refinish_log_event then
                    _G.refinish_log_event(string.format(
                        "MODULE REACT WARNING: product type '%s' has no mat_subtype '%s'. expected one of: %s. product skipped.",
                        tostring(prod_def.type), tostring(prod_def.mat_id),
                        table.concat(names, ", ")))
                end
                return nil
            end
            p.mat_index = sub

        -- A builtin-material product has no inorganic to find. Force
        -- -1 rather than leaning on the lookup missing.
        elseif ptype and ptype.builtin then
            p.mat_index = -1
        else
            p.mat_index = mat_lookup[prod_def.mat_id] or -1
        end
        p.flags.GET_MATERIAL_SAME = false
        p.flags.GET_MATERIAL_PRODUCT = false
        p.get_material.reagent_code = ""
        p.get_material.product_code = ""

    -- Mode 2: Inherit material from a reagent (sharp rock pattern)
    elseif prod_def.get_material_same then
        p.mat_type = -1
        p.mat_index = -1
        p.flags.GET_MATERIAL_SAME = true
        p.flags.GET_MATERIAL_PRODUCT = false
        p.get_material.reagent_code = prod_def.get_material_same
        p.get_material.product_code = ""

    -- Mode 3: Derive from reagent's reaction product (clay bricks, soap)
    elseif prod_def.get_material_product then
        p.mat_type = -1
        p.mat_index = -1
        p.flags.GET_MATERIAL_SAME = false
        p.flags.GET_MATERIAL_PRODUCT = true
        p.get_material.reagent_code = prod_def.get_material_product.reagent_code
        p.get_material.product_code = prod_def.get_material_product.product_code

    -- Mode 4: Builtin material carried by the product type itself.
    -- Ash, pearlash, coal and potash bars name no material, because the
    -- type already says which one it is.
    elseif ptype and ptype.builtin then
        p.mat_type  = ptype.mat_type
        p.mat_index = -1
        p.flags.GET_MATERIAL_SAME = false
        p.flags.GET_MATERIAL_PRODUCT = false
        p.get_material.reagent_code = ""
        p.get_material.product_code = ""
    end

    -- Product-to-container linkage
    if prod_def.to_container then
        p.product_to_container = prod_def.to_container
    else
        p.product_to_container = ""
    end

    -- Force edge flag (knapping pattern)
    p.flags.FORCE_EDGE = prod_def.force_edge or false

    return p
end

-- ==========================================
-- RESOLVE CUSTOM WORKSHOP
-- ==========================================
-- Custom workshops (ArgMOD's Chemist, vanilla's Soap Maker) are raw
-- objects rather than df.workshop_type enum entries. A reaction points
-- at one by storing the workshop's runtime index in building.custom.
--
-- That index depends on raw load order, so it can't be a constant in
-- the types dictionary - we look it up by code string at build time.
--
-- Returns the index, or nil if no workshop with that code is loaded
-- (i.e. the modder's building raws aren't installed).
-- ==========================================
local custom_workshop_cache = nil

local function resolve_custom_workshop(code)
    -- JIT GATE: Build dictionary exactly once
    if not custom_workshop_cache then
        local ok, shops = pcall(function() return df.global.world.raws.buildings.workshops end)
        if not ok or not shops then return nil end
        
        custom_workshop_cache = {}
        for i, ws in ipairs(shops) do
            local got, id = pcall(function() return ws.id end)
            if got and type(id) == "number" then 
                custom_workshop_cache[ws.code] = id 
            else
                custom_workshop_cache[ws.code] = i
            end
        end
    end
    
    -- O(1) Instant Lookup
    return custom_workshop_cache[code]
end

-- ==========================================
-- PUBLIC: INJECT REACTIONS
-- ==========================================
-- Main entry point for reaction building. Takes a list of
-- validated reaction definitions and injects each into the
-- live reactions array.
--
-- Parameters:
--   reactions - Array of reaction definition tables
--   prefix   - Module's ID prefix string
--   mod_name - Module's display name (for logging)
--   registry - The module registry (_G.refinish_module_registry)
--
-- Returns: count of reactions successfully injected
-- ==========================================
local function disable_fortress_mode(rxn) rxn.flags.FORTRESS_MODE_ENABLED = false end
local function set_fortress_mode(rxn, val) rxn.flags.FORTRESS_MODE_ENABLED = val end

function inject_reactions(reactions_defs, prefix, mod_name, registry)
    local debug_react = false
    -- FLUSH CACHES TO PREVENT DANGLING C++ POINTERS ON RESTART
    custom_workshop_cache = nil
    itemdef_cache = {}
    
    local reactions_array = df.global.world.raws.reactions.reactions
    local mat_lookup = build_mat_lookup()
    local count = 0

    -- Pull all C++ reactions into pure Lua signatures ONCE.
    -- This prevents 10,000,000+ C++ boundary crossings during template scoring.
    local fast_reactions_cache = { signatures = {}, by_code = {} }
    
    for _, rxn in ipairs(reactions_array) do
        fast_reactions_cache.by_code[rxn.code] = rxn
        
        -- Skip RM core reactions and procedural junk so we don't even cache them
        if not has_prefix(rxn.code, "REFINISH_STEEL_") and not rxn.flags.GENERATED then
            
            local is_module = false
            if registry then
                for prefix, _ in pairs(registry) do
                    if has_prefix(rxn.code, prefix) then 
                        is_module = true 
                        break 
                    end
                end
            end

            if not is_module then
                local sig = {
                    ptr = rxn,
                    code = rxn.code,
                    has_building = (rxn.building and rxn.building.type) and true or false,
                    building_types = {},
                    building_subtypes = {},
                    fuel = rxn.flags.FUEL,
                    reagent_count = rxn.reagents and #rxn.reagents or 0,
                    has_improvement = false,
                    product_item_types = {}
                }
                
                if sig.has_building then
                    for _, bt in ipairs(rxn.building.type) do table.insert(sig.building_types, bt) end
                    for _, bst in ipairs(rxn.building.subtype) do table.insert(sig.building_subtypes, bst) end
                end
                
                if rxn.products then
                    for _, prod in ipairs(rxn.products) do
                        if df.reaction_product_item_improvementst:is_instance(prod) then
                            sig.has_improvement = true
                        elseif df.reaction_product_itemst:is_instance(prod) then
                            table.insert(sig.product_item_types, prod.item_type)
                        end
                    end
                end
                
                table.insert(fast_reactions_cache.signatures, sig)
            end
        end
    end

    for _, def in ipairs(reactions_defs) do
        local full_id = prefix .. "RXN_" .. def.key

        -- ---- STEP 1: FIND TEMPLATE ----
        -- Pass the fast cache in to bypass the C++ boundary
        local template, template_score = find_template(def, fast_reactions_cache)
        if not template then
            if _G.refinish_log_event then
                _G.refinish_log_event(string.format(
                    "MODULE REACT WARNING: No template could be found for [%s].", full_id
                ))
            end
            goto continue
        end

        -- Log the template selection so the modder can verify
        -- the engine picked a sensible structural donor
        if _G.refinish_log_event and debug_react then
            _G.refinish_log_event(string.format(
                "MODULE REACT: [%s] -> template [%s] (score %d, building %s, skill %s).",
                full_id, template.code, template_score,
                def.building or "nil", def.skill or "inherited"
            ))
        end

        -- ---- STEP 2: DEEP COPY TEMPLATE ----
        local rxn = df.reaction:new()
        rxn:assign(template)

        -- ---- STEP 2.5: NEUTRAL RESET - REACTION FLAGS ----
        -- Zero all reaction-level flags inherited from the template.
        -- Same philosophy as reagent/product neutral resets: clone
        -- for C++ structure, zero semantics, rebuild from schema.
        -- Without this, template flags like GENERATED (procedural
        -- instrument reactions), AUTOMATIC, ADVENTURE_MODE_ENABLED,
        -- and WORLDGEN_ENABLED bleed through and contaminate the
        -- injected reaction's identity.
        rxn.flags.FUEL = false
        rxn.flags.AUTOMATIC = false
        rxn.flags.ADVENTURE_MODE_ENABLED = false
        rxn.flags.GENERATED = false
        rxn.flags.WORLDGEN_ENABLED = false
        pcall(disable_fortress_mode, rxn)

        -- Clear template identity baggage. Generated reactions carry
        -- raw_strings full of instrument tokens, descriptions with
        -- item references, and source entity/historical figure IDs
        -- that have no meaning for module reactions.
        rxn.raw_strings:resize(0)
        rxn.descriptions:resize(0)
        rxn.source_hfid = -1
        rxn.source_enid = -1

        -- Numeric fields that vary across template donors and have
        -- no schema override. Neutral values sourced from vanilla
        -- MAKE_PLASTER_POWDER / STEEL_MAKING as reference:
        --   max_multiplier = 1 (no output scaling)
        --   rand_range, skill_mult, attr_gain, exp_gain = 0
        -- Generated reactions carry non-zero values for these
        -- (e.g. rand_range=11, skill_mult=5) that would silently
        -- alter crafting behavior if left in place.
        rxn.max_multiplier = 1
        rxn.rand_range = 0
        rxn.skill_mult = 0
        rxn.attr_gain = 0
        rxn.exp_gain = 0

        -- ---- STEP 3: IDENTITY ----
        rxn.code = full_id
        rxn.name = def.name

        -- ---- STEP 4: CATEGORY ----
        rxn.category = def.category or ""

        -- ---- STEP 5: FUEL ----
        rxn.flags.FUEL = def.fuel or false

        -- ---- STEP 5.5: FORTRESS MODE FLAG ----
        -- Set FORTRESS_MODE_ENABLED explicitly from the schema.
        -- Default: false. Modder sets true when they intend the
        -- reaction to be available to the player regardless of civ
        -- permits. This is an intentional choice, never automatic.
        local rf = def.reaction_flags or {}
        pcall(set_fortress_mode, rxn, rf.fortress_mode or false)

        -- ---- STEP 6: BUILDING ----
        -- Overwrite the building type/subtype/custom arrays from
        -- the types dictionary. This ensures the reaction appears
        -- at the correct workshop regardless of what the template had.
        local building_def = types.BUILDING_TYPES[def.building]
        if building_def then
            -- Custom workshops need a runtime lookup. Resolve FIRST, so
            -- a failure leaves the template's building intact instead of
            -- writing a half-built one that points nowhere.
            local custom_idx = nil
            local custom_ok  = true
            if building_def.custom_code then
                custom_idx = resolve_custom_workshop(building_def.custom_code)
                if not custom_idx then
                    custom_ok = false
                    if _G.refinish_log_event then
                        _G.refinish_log_event(string.format("MODULE REACT WARNING: [%s] needs custom workshop '%s', which is missing. Building left unchanged.",
                        tostring(def.id), building_def.custom_code))
                    end
                end
            end

            if custom_ok then
                -- Menu hotkey. DF stores one per building variant,
                -- parallel to type/subtype/custom, which is why it is
                -- inserted inside the loop rather than set once.
                -- Verified against MAKE_LEAD_GLASS_ENORMOUSCORKSCREW,
                -- where the vector runs alongside the other three.
                --
                -- Resolved by name so there is no interface_key value
                -- hardcoded here. Default 0 is "no hotkey", which is
                -- what every reaction got before this.
                local hotkey = 0
                if def.building_hotkey then
                    local k = df.interface_key[def.building_hotkey]
                    if type(k) == "number" then
                        hotkey = k
                    else
                        if _G.refinish_log_event then
                            _G.refinish_log_event(string.format("MODULE REACT WARNING: [%s] has unknown building_hotkey '%s'. Ignored.",
                                tostring(def.key), tostring(def.building_hotkey)))
                        end
                    end
                end

                rxn.building.type:resize(0)
                rxn.building.subtype:resize(0)
                rxn.building.custom:resize(0)
                rxn.building.hotkey:resize(0)

                for i, bt in ipairs(building_def.type) do
                    rxn.building.type:insert('#', bt)
                    rxn.building.subtype:insert('#', building_def.subtype[i])
                    rxn.building.custom:insert('#', custom_idx or building_def.custom[i])
                    rxn.building.hotkey:insert('#', hotkey)
                end
            end
        end

        -- ---- STEP 7: SKILL ----
        if def.skill and types.SKILL_MAP[def.skill] then
            rxn.skill = types.SKILL_MAP[def.skill]
        end

        -- ---- STEP 8: BUILD REAGENTS ----
        -- Find a base reagent from the template to clone as our
        -- structural starting point. This preserves internal C++
        -- fields we can't set from Lua.
        local base_reagent = nil
        for _, rgt in ipairs(template.reagents) do
            if df.reaction_reagent_itemst:is_instance(rgt) then
                base_reagent = rgt
                break
            end
        end

        if base_reagent and def.reagents then
            rxn.reagents:resize(0)
            for _, rgt_def in ipairs(def.reagents) do
                local r = build_reagent(rgt_def, base_reagent, mat_lookup, def.reagents)
                rxn.reagents:insert('#', r)
            end
        end

        -- ---- STEP 9: BUILD PRODUCTS ----
        -- Two product classes are possible. Item products clone a donor
        -- from this reaction's own template; improvement products clone
        -- one from anywhere in the loaded raws, since a structurally
        -- similar template is not guaranteed to carry one.
        local base_product = nil
        for _, prod in ipairs(template.products) do
            if df.reaction_product_itemst:is_instance(prod) then
                base_product = prod
                break
            end
        end

        if def.products then
            local wants_item = false
            local wants_improvement = false
            for _, prod_def in ipairs(def.products) do
                local pt = types.PRODUCT_TYPES[prod_def.type]
                if pt and pt.improvement then
                    wants_improvement = true
                else
                    wants_item = true
                end
            end

            -- Resolve donors up front so a failure skips the reaction
            -- cleanly instead of leaving it with a partial product list.
            local improvement_donor = nil
            if wants_improvement then
                improvement_donor = find_improvement_donor()
                if not improvement_donor then
                    if _G.refinish_log_event then
                        _G.refinish_log_event(string.format("MODULE REACT WARNING: cannot find improvement product clone required for [%s]. reaction skipped.",
                        tostring(def.key)))
                    end
                    goto continue
                end
            end
            if wants_item and not base_product then
                if _G.refinish_log_event then
                        _G.refinish_log_event(string.format("MODULE REACT WARNING: cannot find item product clone required for [%s]. reaction skipped.",
                    tostring(def.key)))
                end
                goto continue
            end

            rxn.products:resize(0)
            for _, prod_def in ipairs(def.products) do
                local pt = types.PRODUCT_TYPES[prod_def.type]
                local p
                if pt and pt.improvement then
                    p = build_improvement_product(prod_def, improvement_donor)
                else
                    p = build_product(prod_def, base_product, mat_lookup)
                end
                if p then
                    rxn.products:insert('#', p)
                end
            end
        end

        -- ---- STEP 10: INJECT ----
        reactions_array:insert('#', rxn)
        rxn.index = #reactions_array - 1
        
        -- Fallbacks can use newly injected reactions instantly
        fast_reactions_cache.by_code[rxn.code] = rxn
        
        count = count + 1

        ::continue::
    end

    if _G.refinish_log_event then
        _G.refinish_log_event(string.format(
            "MODULE REACT: [%s] built %d reactions.", mod_name, count
        ))
    end

    return count
end


-- ==========================================
-- PUBLIC: INJECT CATEGORIES
-- ==========================================
-- Injects a module's category tree into the live
-- reaction_categories array. Categories provide the menu
-- structure players see at workshops.
--
-- Parameters:
--   categories - Array of category definitions from the JSON
--   prefix     - Module's ID prefix string
--
-- Returns: count of categories injected
-- ==========================================
function inject_categories(categories, prefix)
    if not categories or #categories == 0 then return 0 end

    local cat_array = df.global.world.raws.reactions.reaction_categories
    local count = 0

    -- Snapshot existing category IDs to avoid duplicates
    local existing = {}
    for _, c in ipairs(cat_array) do
        existing[c.id] = true
    end

    -- Build the full ID for each category and organize into a tree
    -- for depth-first injection (parents before children)
    local cat_map = {}
    local roots = {}

    for _, cat_def in ipairs(categories) do
        local full_id = prefix .. "CAT_" .. cat_def.key

        -- The parent must be prefixed too. cat_map is keyed by full_id,
        -- so an unprefixed parent could never match one of our own
        -- categories, and every entry fell through to the root list
        -- with a dangling parent string. An empty parent stays empty,
        -- and a parent naming a category this module does not declare
        -- is left alone so it can point at a pre-existing one.
        local parent_id = ""
        if cat_def.parent and cat_def.parent ~= "" then
            local prefixed = prefix .. "CAT_" .. cat_def.parent
            local declared = false
            for _, other in ipairs(categories) do
                if other.key == cat_def.parent then declared = true break end
            end
            parent_id = declared and prefixed or cat_def.parent
        end

        -- key is the menu hotkey, an interface_key value, 0 for none.
        -- Note it is NOT the schema's key field, which is the string
        -- identifier that becomes id above. Resolved by name so no
        -- interface_key number is hardcoded.
        local hotkey = 0
        if cat_def.hotkey then
            local k = df.interface_key[cat_def.hotkey]
            if type(k) == "number" then
                hotkey = k
            else
                if _G.refinish_log_event then
                        _G.refinish_log_event(string.format("MODULE REACT WARNING: [%s] has unknown hotkey '%s'. ignored.",
                    tostring(cat_def.key), tostring(cat_def.hotkey)))
                end
            end
        end

        local entry = {
            id          = full_id,
            name        = cat_def.name,
            parent      = parent_id,
            description = cat_def.description or "",
            hotkey      = hotkey,
            children    = {},
        }
        cat_map[full_id] = entry
    end

    -- Organize into tree: find each entry's parent
    for _, entry in pairs(cat_map) do
        if entry.parent == "" or not cat_map[entry.parent] then
            -- Top-level category (or parent is external)
            table.insert(roots, entry)
        else
            table.insert(cat_map[entry.parent].children, entry)
        end
    end

    -- Sort siblings alphabetically for deterministic order
    local function sort_children(node)
        table.sort(node.children, function(a, b) return a.id < b.id end)
        for _, child in ipairs(node.children) do sort_children(child) end
    end
    table.sort(roots, function(a, b) return a.id < b.id end)
    for _, root in ipairs(roots) do sort_children(root) end

    -- Depth-first injection: parents before children
    local function inject_node(node)
        if not existing[node.id] then
            local c = df.reaction_category:new()
            c.id          = node.id
            c.name        = node.name
            c.parent      = node.parent
            c.description = node.description
            c.key         = node.hotkey
            cat_array:insert('#', c)
            existing[node.id] = true
            count = count + 1
        end
        for _, child in ipairs(node.children) do
            inject_node(child)
        end
    end
    for _, root in ipairs(roots) do inject_node(root) end

    if _G.refinish_log_event then
        _G.refinish_log_event(string.format(
            "MODULE REACT: Injected %d categories.", count
        ))
    end

    return count
end




return _ENV