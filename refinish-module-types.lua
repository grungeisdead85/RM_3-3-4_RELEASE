--@ module = true
-- refinish-module-types.lua
-- ==========================================
-- RM MODULE TYPE DICTIONARY
-- ==========================================
-- Pure data tables that map friendly schema names to DF internal
-- values. Every other module engine file imports this. No side
-- effects, no globals, no runtime state — just lookups.
--
-- ADDING NEW TYPES:
--   1. Add an entry to the appropriate table below.
--   2. The engine files that consume these tables will pick it
--      up automatically — no wiring needed.
--   3. Update the schema reference JSON so modders know it exists.
--
-- NAMING CONVENTION:
--   Table keys are UPPERCASE strings matching the schema values
--   that modders write in their JSON data files. The engine does
--   a direct key lookup — no fuzzy matching, no case folding.
-- ==========================================


-- ==========================================
-- REAGENT TYPES
-- ==========================================
-- Maps schema reagent type names to the DF fields needed to
-- construct a reaction_reagent_itemst. The reaction builder
-- reads these to populate item_type, mat_type, mat_index,
-- reaction_class, and the needs_mat_id flag.
--
-- Fields:
--   item_type      — DF item_type enum value
--   mat_type       — Material type. 0=INORGANIC, 7=COAL, -1=any
--   mat_index      — Material index. -1=any (wildcard)
--   reaction_class — String for reaction_class matching. ""=none
--   needs_mat_id   — If true, the engine resolves mat_id from
--                     the reagent spec to an inorganic index
--   needs_metal_id — If true, the engine resolves metal_id to
--                     an inorganic index and sets reagent.metal_ore
--   has_material_reaction_product — Default value for this field.
--                     Can be overridden per-reagent in the spec.
-- ==========================================
REAGENT_TYPES = {

    -- ----- ORGANIC INTAKE -----
    -- All of these wildcard the material deliberately. Organic mat_type
    -- is computed per species (plant = 419 + that plant's own local
    -- material index, creature = 19 + its own), and those local indices
    -- are NOT stable across species. Olive proves it: its local material
    -- 1 is frozen olive oil where nearly every other tree has wood, so a
    -- fixed mat_type of 420 would quietly accept oil in a wood reaction.
    --
    -- Filtering therefore happens entirely through flags in the JSON.
    -- Vanilla does the same: the gukil strings reagent is THREAD at
    -- mat -1/-1 carrying nothing but ANY_PLANT_MATERIAL.
    --
    -- Named rather than numbered: an off by one in the item enum
    -- silently swaps the item kind.

    -- Everything. Flags MUST filter or this matches every item in the
    -- fortress. For cross-cutting filters no single item type can
    -- express, such as furniture combined with a wood material.
    ANY_ITEM     = { item_type = -1,                       mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },

    -- A harvested plant, what a farm plot yields.
    PLANT        = { item_type = df.item_type.PLANT,        mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },

    -- Leaves, fruit, nuts. What a plant grows rather than is.
    PLANT_GROWTH = { item_type = df.item_type.PLANT_GROWTH, mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },

    SEEDS        = { item_type = df.item_type.SEEDS,        mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },

    -- A whole body, as distinct from CORPSEPIECE which is a part.
    CORPSE       = { item_type = df.item_type.CORPSE,       mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },

    -- Bones, skulls, raw hides, teeth, shells. BODY_PART below reaches
    -- the same items via flags at item_type -1; this pins the type.
    CORPSEPIECE  = { item_type = df.item_type.CORPSEPIECE,  mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },

    -- Tanned leather. A raw hide is CORPSEPIECE, not this.
    SKIN_TANNED  = { item_type = df.item_type.SKIN_TANNED,  mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },

    -- Spun thread. Plant, silk and yarn all arrive as this item type,
    -- separated by flags2.plant / silk / yarn.
    THREAD       = { item_type = df.item_type.THREAD,       mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },

    CLOTH        = { item_type = df.item_type.CLOTH,        mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },

    -- Fat and tallow. Dimensioned, so quantity counts units not items.
    GLOB         = { item_type = df.item_type.GLOB,         mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },

    -- Organs and cuts. Confirmed live: a heart is MEAT, not
    -- CORPSEPIECE, and neither body_part nor a CORPSEPIECE reagent can
    -- reach one. Arms, heads and bones are CORPSEPIECE. The split
    -- follows the stockpile: organs are food, limbs are corpses.
    MEAT         = { item_type = df.item_type.MEAT,         mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },

    -- Prepared fish, as distinct from FISH_RAW.
    FISH         = { item_type = df.item_type.FISH,         mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },
    FISH_RAW     = { item_type = df.item_type.FISH_RAW,     mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },

    EGG          = { item_type = df.item_type.EGG,          mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },
    CHEESE       = { item_type = df.item_type.CHEESE,       mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },

    -- Vermin remains. Its own stockpile category, so its own type.
    REMAINS      = { item_type = df.item_type.REMAINS,      mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },

    -- What tree felling leaves behind. Item type 91, distinct from
    -- WOOD at 5, and nothing in vanilla consumes it.
    BRANCH       = { item_type = df.item_type.BRANCH,       mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },

    -- A skull mounted as a totem. Item type 59, no longer a corpse
    -- piece, so no body_part reagent will reach one.
    TOTEM        = { item_type = df.item_type.TOTEM,        mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },

    -- Prepared meals and raw food. FOOD is 72, DRINK is 69.
    FOOD         = { item_type = df.item_type.FOOD,         mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },
    DRINK        = { item_type = df.item_type.DRINK,        mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },

    -- Extracts, oils, syrups. Dimensioned and container-bound, so a
    -- reagent needs in_container plus a matching container reagent.
    LIQUID_MISC  = { item_type = df.item_type.LIQUID_MISC,  mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },

    -- Paper. SHEET is 90, BOOK is 89. Both carry flags3.written_on,
    -- which is how a reaction avoids consuming a written work.
    SHEET        = { item_type = df.item_type.SHEET,        mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },
    BOOK         = { item_type = df.item_type.BOOK,         mat_type = -1, mat_index = -1, reaction_class = "", needs_mat_id = false, needs_metal_id = false },

    -- ----- BARS -----
    -- A bar of a specific inorganic metal (iron, copper, etc.)
    METAL_BAR = {
        item_type      = 0,      -- df.item_type.BAR
        mat_type       = 0,      -- INORGANIC
        mat_index      = nil,    -- resolved from mat_id at build time
        reaction_class = "",
        needs_mat_id   = true,
        needs_metal_id = false,
    },

    -- Any bar (no material restriction)
    BAR_ANY = {
        item_type      = 0,      -- df.item_type.BAR
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Any coal bar (charcoal or coke wildcard)
    COKE = {
        item_type      = 0,      -- df.item_type.BAR
        mat_type       = 7,      -- COAL material class
        mat_index      = -1,     -- wildcard
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- ----- BOULDERS -----
    -- A boulder of a specific inorganic material
    BOULDER = {
        item_type      = 4,      -- df.item_type.BOULDER
        mat_type       = 0,      -- INORGANIC
        mat_index      = nil,    -- resolved from mat_id
        reaction_class = "",
        needs_mat_id   = true,
        needs_metal_id = false,
    },

    -- Any inorganic boulder (INORGANIC:NONE). The magnifying glass
    -- material selector ONLY appears when mat_type=0 (INORGANIC)
    -- and mat_index=-1 (NONE). Using mat_type=-1 makes the reagent
    -- a full wildcard across all material types, which suppresses
    -- the selector entirely. Source: DF wiki material token table.
    BOULDER_ANY = {
        item_type      = 4,      -- df.item_type.BOULDER
        mat_type       = 0,      -- INORGANIC (required for magnifying glass)
        mat_index      = -1,     -- NONE (wildcard within inorganics)
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Any flux-bearing boulder (limestone, marble, etc.)
    -- DF matches via reaction_class on the reagent material
    FLUX = {
        item_type      = 4,      -- df.item_type.BOULDER
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "FLUX",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Any ore boulder that smelts to a specific metal.
    -- Engine resolves metal_id to an inorganic index and sets
    -- the reagent.metal_ore field. DF then matches any boulder
    -- whose metal_ore table contains that metal.
    -- Pattern source: BRASS_MAKING [REAGENT:A:1:METAL_ORE:ZINC]
    ORE_OF = {
        item_type      = 4,      -- df.item_type.BOULDER
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = true,   -- resolves metal_id -> reagent.metal_ore
    },

    -- ----- POWDERS -----
    -- A powder (sand, plaster, etc.). Usually paired with a BAG
    -- via the container/contents linkage.
    POWDER = {
        item_type      = 70,     -- df.item_type.POWDER_MISC
        mat_type       = nil,    -- resolved from mat_id if given, else -1
        mat_index      = nil,    -- resolved from mat_id if given, else -1
        reaction_class = "",
        needs_mat_id   = false,  -- optional: if mat_id given, resolve it
        needs_metal_id = false,
    },

    -- Any powder — magnifying glass attempt. Wiki says POWDER_MISC
    -- uses NONE:NONE, but that didn't work. Trying INORGANIC:NONE
    -- since runtime injection bypassed raws limitations for BOULDER.
    POWDER_ANY = {
        item_type      = 70,     -- df.item_type.POWDER_MISC
        mat_type       = 0,      -- INORGANIC:NONE attempt
        mat_index      = -1,     -- NONE
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- ----- CONTAINERS -----
    -- An empty bag. Used as a container for powders.
    BAG = {
        item_type      = 31,     -- df.item_type.BAG
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- A generic container (any item). Too broad for practical use —
    -- DF will grab bars, weapons, etc. as "containers." Prefer
    -- BUCKET or BARREL for liquid reactions.
    -- Pattern source: MAKE_SOAP_FROM_TALLOW reagents[1] ("lye container")
    CONTAINER = {
        item_type      = -1,     -- any item that can contain liquid
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- A bucket. The standard liquid container for workshop reactions.
    -- item_type 18 = df.item_type.BUCKET
    BUCKET = {
        item_type      = 18,     -- df.item_type.BUCKET
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- A barrel. Alternative liquid container, larger capacity.
    -- item_type 17 = df.item_type.BARREL
    BARREL = {
        item_type      = 17,     -- df.item_type.BARREL
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- ----- LIQUIDS -----
    -- A liquid (lye, water, milk, etc.) stored in a container.
    -- Must be paired with a CONTAINER reagent via contains linkage.
    -- The liquid reagent gets IN_CONTAINER=true; the container gets
    -- PRESERVE_REAGENT=true and contains pointing to the liquid.
    -- Pattern source: MAKE_SOAP_FROM_TALLOW reagents[0] ("lye")

    -- Water specifically. mat_type=6 is the builtin water material.
    -- Discovered via: dfhack.matinfo.find('WATER') -> <material 6:-1>
    WATER = {
        item_type      = 73,     -- df.item_type.LIQUID_MISC
        mat_type       = 6,      -- builtin water material type
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Generic liquid. mat_type resolved from mat_id if given.
    -- For non-inorganic liquids (lye=11, milk, etc.) the mat_type
    -- must be specified directly since they aren't in the inorganic
    -- array. Currently only supports builtin material types.
    LIQUID = {
        item_type      = 73,     -- df.item_type.LIQUID_MISC
        mat_type       = nil,    -- resolved from context
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- An inorganic liquid: acids, alkalis, solutions. Unlike WATER
    -- (a builtin material at mat_type 6) these live in the inorganic
    -- array, so mat_type is 0 and the index is resolved from mat_id.
    -- Pairs with a BUCKET/BARREL/JUG reagent via contains linkage,
    -- exactly like WATER does.
    LIQUID_INORGANIC = {
        item_type      = 73,     -- df.item_type.LIQUID_MISC
        mat_type       = 0,      -- INORGANIC
        mat_index      = nil,    -- resolved from mat_id
        reaction_class = "",
        needs_mat_id   = true,
        needs_metal_id = false,
    },

    -- A potash bar. mat_type 8 is the builtin POTASH material —
    -- confirmed against the builtin index list (6=WATER, 7=COAL,
    -- 8=POTASH, 9=ASH, 10=PEARLASH, 11=LYE).
    BAR_POTASH = {
        item_type      = 0,      -- df.item_type.BAR
        mat_type       = 8,      -- builtin POTASH
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Ash and pearlash bars. Same shape as COAL and BAR_POTASH above,
    -- but the builtin index is resolved by name rather than written as
    -- a literal: being off by one here silently swaps the material for
    -- its neighbour in the builtin table, which is the same reasoning
    -- JUG gives for using df.item_type symbolically.
    --
    -- ASH is verified as 9 from the GLAZE_CRAFT_ASH path map.
    BAR_ASH = {
        item_type      = 0,
        mat_type       = df.builtin_mats.ASH,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    BAR_PEARLASH = {
        item_type      = 0,
        mat_type       = df.builtin_mats.PEARLASH,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- A boulder of no declared material class, narrowed by
    -- reaction_class instead. Distinct from BOULDER_ANY, which pins
    -- mat_type to INORGANIC on purpose for the magnifying glass case.
    -- Verified against MAKE_EARTHENWARE_TYPE_CRAFTS, where
    -- [REAGENT:clay:1:BOULDER:NONE:NONE:NONE] stores mat_type -1.
    BOULDER_UNTYPED = {
        item_type      = 4,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Blocks of any material. BLOCKS above requires a mat_id; this is
    -- the wildcard form, used where the block material is whatever the
    -- reaction happens to consume.
    BLOCKS_ANY = {
        item_type      = 2,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Any inorganic liquid, narrowed by reaction_class rather than by a
    -- specific material — the liquid counterpart to POWDER_ANY.
    -- ArgMOD writes [LIQUID_MISC:NONE:INORGANIC:NONE] with a
    -- [REACTION_CLASS:...] filter, e.g. "any strong base" for caustics.
    -- Kept separate from LIQUID_INORGANIC so that type stays strict and
    -- still catches a forgotten mat_id.
    LIQUID_INORGANIC_ANY = {
        item_type      = 73,     -- df.item_type.LIQUID_MISC
        mat_type       = 0,      -- INORGANIC
        mat_index      = -1,     -- NONE
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Any rough gem, narrowed by reaction_class. Used for his beryl and
    -- fluorite grinding, where several minerals share a reaction class.
    ROUGH_ANY = {
        item_type      = 3,      -- df.item_type.ROUGH
        mat_type       = 0,      -- INORGANIC
        mat_index      = -1,     -- NONE
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- A standard wooden log.
    WOOD = {
        item_type      = df.item_type.WOOD,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- ----- TOOLS -----
    -- A jug. Vanilla liquid/food container, used across ArgMOD's
    -- chemistry chain to hold acids and solutions.
    --
    -- item_type is symbolic rather than a literal: TOOL is the one
    -- category where being off by one silently grabs a completely
    -- different item class, so we let DFHack resolve it.
    --
    -- item_subtype holds the itemdef CODE, not a number. Tool indices
    -- shift with mod load order, so the reaction builder resolves the
    -- code at build time — same principle as custom workshops.
    JUG = {
        item_type      = df.item_type.TOOL,   -- 86
        item_subtype   = "ITEM_TOOL_JUG",     -- resolved at build time
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- A large pot. Same tool-itemdef pattern as JUG above: the subtype
    -- is a CODE, resolved at build time because tool indices shift with
    -- mod load order.
    LARGE_POT = {
        item_type      = df.item_type.TOOL,
        item_subtype   = "ITEM_TOOL_LARGE_POT",
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- A statue. No subtype: STATUE is a plain item type.
    STATUE = {
        item_type      = df.item_type.STATUE,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Any craft item. Verified against GLAZE_CRAFT_ASH: DF stores this
    -- as item_type -1 with flags3.any_craft set, so the flag does all
    -- the filtering and the item type matches anything.
    --
    -- Like BODY_PART above, this is only safe when the reagent also
    -- carries a reaction_class or equivalent narrowing. Argendauss uses
    -- reaction_class CAN_GLAZE on every one of them.
    --
    -- flags3 is applied by build_reagent after the neutral reset. It is
    -- a type-level property, not a modder choice, which is why it lives
    -- here rather than in the schema's flags block.
    ANY_CRAFT = {
        item_type      = -1,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
        flags3         = { any_craft = true },
    },

    -- ----- CREATURE MATERIALS -----
    -- An untyped reagent slot filtered entirely by flags rather than by
    -- item type — bones, shells, horns. item_type -1 matches anything,
    -- so this type is ONLY safe when paired with body_part plus one of
    -- the bone/shell/horn flags. Used by CALCINE_BONES, GRIND_SHELLS
    -- and the two hartshorn reactions.
    BODY_PART = {
        item_type      = -1,     -- any item; the flags do the filtering
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- ----- ORGANIC INTAKE -----
    -- Item types a reaction can consume organic matter through.
    --
    -- Every one of them wildcards the material, and that is deliberate
    -- rather than lazy. Organic mat_type is computed per species: a
    -- plant material is 419 plus that plant's own local material index,
    -- a creature material is 19 plus its own. Those local indices are
    -- NOT stable across species. Olive proves it, since its local
    -- material 1 is frozen olive oil while almost every other tree has
    -- wood there, so a fixed mat_type of 420 would quietly accept oil
    -- in a wood reaction.
    --
    -- So filtering happens entirely through flags in the JSON. That is
    -- what vanilla does too: the gukil strings reagent is THREAD at
    -- mat -1/-1 carrying nothing but ANY_PLANT_MATERIAL, and the soap
    -- reagent is GLOB at mat -1/-1 carrying a reaction class.
    --
    -- Named rather than numbered for the reason JUG gives: an off by
    -- one in the item enum silently swaps the item kind.

    -- Everything. Flags MUST do the filtering or this matches every
    -- item in the fortress, including furniture, bars and artifacts.
    -- Use it for cross-cutting filters that no single item type can
    -- express, such as furniture combined with a wood material.
    ANY_ITEM = {
        item_type      = -1,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- A harvested plant, the thing a farm plot yields.
    PLANT = {
        item_type      = df.item_type.PLANT,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Leaves, fruit, nuts. Anything a plant grows rather than is.
    PLANT_GROWTH = {
        item_type      = df.item_type.PLANT_GROWTH,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    SEEDS = {
        item_type      = df.item_type.SEEDS,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- A whole body. Distinct from CORPSEPIECE, which is a part.
    CORPSE = {
        item_type      = df.item_type.CORPSE,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Bones, skulls, hides, teeth, shells. BODY_PART above reaches the
    -- same items through flags at item_type -1; this one pins the type
    -- instead, which is safer where no other filter is wanted.
    CORPSEPIECE = {
        item_type      = df.item_type.CORPSEPIECE,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Tanned leather, not the raw hide. Raw hides are CORPSEPIECE.
    SKIN_TANNED = {
        item_type      = df.item_type.SKIN_TANNED,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Spun thread. Plant, silk and yarn all arrive as this item type,
    -- separated by flags2.plant, flags2.silk and flags2.yarn.
    THREAD = {
        item_type      = df.item_type.THREAD,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    CLOTH = {
        item_type      = df.item_type.CLOTH,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- Fat and tallow. Dimensioned, so quantity counts units, not items.
    GLOB = {
        item_type      = df.item_type.GLOB,
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },

    -- ----- RAW / ROUGH -----
    -- A rough gemstone or uncut glass piece
    ROUGH = {
        item_type      = 3,      -- df.item_type.ROUGH
        mat_type       = 0,      -- INORGANIC
        mat_index      = nil,    -- resolved from mat_id
        reaction_class = "",
        needs_mat_id   = true,
        needs_metal_id = false,
    },

    -- ----- BLOCKS -----
    BLOCKS = {
        item_type      = 2,      -- df.item_type.BLOCKS
        mat_type       = 0,      -- INORGANIC
        mat_index      = nil,    -- resolved from mat_id
        reaction_class = "",
        needs_mat_id   = true,
        needs_metal_id = false,
    },

    -- ----- ROCKS -----
    -- A rock item (knapping, sharp rocks)
    ROCK = {
        item_type      = 76,     -- df.item_type.ROCK
        mat_type       = -1,
        mat_index      = -1,
        reaction_class = "",
        needs_mat_id   = false,
        needs_metal_id = false,
    },
}


-- ==========================================
-- PRODUCT TYPES
-- ==========================================
-- Maps schema product type names to DF item_type values.
-- The reaction builder uses these when constructing products.
-- mat_type is included because some product types have a
-- fixed material class (e.g. bars are always INORGANIC for
-- our purposes, but could be COAL for fuel products).
-- ==========================================
PRODUCT_TYPES = {
    BAR         = { item_type = 0,  mat_type = 0  },  -- INORGANIC bar
    -- BAR_COAL carries mat_subtypes. See the builtin bars note below.
    BAR_COAL    = { item_type = 0,  mat_type = df.builtin_mats.COAL,
                    mat_subtypes = { COKE = 0, CHARCOAL = 1, COAL = -1, TEST_A = 2, TEST_B = 3} },
    BLOCKS      = { item_type = 2,  mat_type = 0  },  -- Stone/ceramic blocks
    ROUGH       = { item_type = 3,  mat_type = 0  },  -- Raw gem / uncut glass
    BOULDER     = { item_type = 4,  mat_type = 0  },  -- Boulder
    LIQUID_MISC = { item_type = 73, mat_type = 6  },  -- Liquid (water=mat_type 6)
    POWDER_MISC = { item_type = 70, mat_type = 0  },  -- Powder
    ROCK        = { item_type = 76, mat_type = -1 },  -- Rock item
    LIQUID_MISC_INORGANIC = { item_type = 73, mat_type = 0 },  -- acid/alkali output
    BAR_POTASH            = { item_type = 0,  mat_type = 8 },  -- potash bar output

    -- Builtin-material bars. The material lives in mat_type and there
    -- is no inorganic to look up, so mat_index stays -1 and the product
    -- names no material of its own.
    --
    -- BAR_POTASH above is this shape too, and it works because POTASH
    -- has no subtypes: its mat_id misses the inorganic lookup, the miss
    -- returns -1, and -1 is correct for a material with one form.
    --
    -- BAR_COAL is NOT that shape, and reading it as though it were was
    -- the bug. The builtin COAL material is a single object whose
    -- state_name.Solid is just "coal". Coke and charcoal are not
    -- separate materials in the raws. mat_index is a pure discriminator
    -- that DF's item naming and stockpile code reads:
    --
    --     0   coke      (vanilla LIGNITE_TO_COKE writes this)
    --     1   charcoal  (the wood furnace's built-in job writes this)
    --    -1   neither, so DF falls back to a generic label
    --
    -- Confirmed two ways. The vanilla reaction's product carries
    -- mat_type 7 with mat_index 0, and dfhack.matinfo.find resolves
    -- 'COAL:COKE' to 7/0 and 'COAL:CHARCOAL' to 7/1.
    --
    -- So BAR_COAL carries mat_subtypes, mapping the schema's mat_id
    -- string onto that index. Before it existed, mat_id fell through to
    -- the inorganic lookup, missed, and every coal bar RM built was
    -- written as -1.
    --
    -- ASH and PEARLASH resolve by name for the reason JUG gives: off by
    -- one in the builtin table silently swaps the material.
    BAR_ASH      = { item_type = 0, mat_type = df.builtin_mats.ASH,      builtin = true },
    BAR_PEARLASH = { item_type = 0, mat_type = df.builtin_mats.PEARLASH, builtin = true },

    -- A random craft item. Verified against MAKE_EARTHENWARE_TYPE_CRAFTS:
    -- DF stores this as item_type -1 with the CRAFTS product flag set,
    -- and picks the actual craft itself. The flag is applied in
    -- build_product because the neutral reset clears it first.
    CRAFTS = { item_type = -1, mat_type = -1, crafts = true },

    -- Not an item product at all. This is a sentinel: build_product
    -- hands anything with this type to build_improvement_product, which
    -- constructs a reaction_product_item_improvementst instead.
    IMPROVEMENT = { improvement = true },
}


-- ==========================================
-- BUILDING TYPES
-- ==========================================
-- Maps schema building names to DF building type/subtype pairs.
-- Most furnace-class buildings have two entries: normal + magma.
-- Custom workshops have a single entry with a custom index.
--
-- Structure:
--   type[]    — Building type values (one per variant)
--   subtype[] — Building subtype values (parallel to type[])
--   custom[]  — Custom workshop index (-1 = not custom)
--
-- Pattern source: Reaction path maps for STEEL_MAKING,
-- MAKE_PLASTER_POWDER, MAKE_COBALT_GLASS, MAKE_SOAP_FROM_TALLOW
-- ==========================================
BUILDING_TYPES = {
    -- ---- FURNACES (building_type 5) ----
    -- All furnaces have normal + magma variants.

    -- Wood Furnace (type 5 is furnace, subtype 0 is wood furnace)
    WOOD_FURNACE = {
        type    = { 5 },
        subtype = { 0 },
        custom  = { -1 },
    },

    -- Smelter (1) + Magma Smelter (4)
    SMELTER = {
        type    = { 5, 5 },
        subtype = { 1, 4 },
        custom  = { -1, -1 },
    },

    -- Glass Furnace (2) + Magma Glass Furnace (5)
    GLASS_FURNACE = {
        type    = { 5, 5 },
        subtype = { 2, 5 },
        custom  = { -1, -1 },
    },

    -- Kiln (3) + Magma Kiln (6)
    KILN = {
        type    = { 5, 5 },
        subtype = { 3, 6 },
        custom  = { -1, -1 },
    },

    -- ---- WORKSHOPS (building_type 13) ----
    -- Subtypes from df.workshop_type enum.

    -- Mason's Workshop (2) — make blocks, stone furniture
    MASON = {
        type    = { 13 },
        subtype = { 2 },
        custom  = { -1 },
    },

    -- Craftsdwarf's Workshop (3) — stone/bone/shell crafts
    -- NOTE: subtype 3, NOT 0. Subtype 0 is Carpenter's Workshop.
    CRAFTSMAN = {
        type    = { 13 },
        subtype = { 3 },
        custom  = { -1 },
    },

    -- Jeweler's Workshop (4) — cut/encrust gems
    JEWELER = {
        type    = { 13 },
        subtype = { 4 },
        custom  = { -1 },
    },

    -- Metalsmith's Forge (5) + Magma Forge (6)
    FORGE = {
        type    = { 13, 13 },
        subtype = { 5, 6 },
        custom  = { -1, -1 },
    },

    -- Quern (17) + Millstone (22) — the two milling workshops.
    -- ArgMOD lists BOTH on all 41 of his grinding reactions so the
    -- player can use either, which is structurally identical to the
    -- normal+magma furnace pairs above.
    MILL = {
        type    = { 13, 13 },
        subtype = { 17, 22 },
        custom  = { -1, -1 },
    },

    -- Ashery (20) — potash, lye, and ash processing.
    ASHERY = {
        type    = { 13 },
        subtype = { 20 },
        custom  = { -1 },
    },

    -- ---- CUSTOM WORKSHOPS (type 13, subtype 23 = workshop_type.Custom) ----
    -- These are raw objects, NOT entries in the df.workshop_type enum.
    -- A reaction points at one by storing the workshop's runtime index
    -- in building.custom. That index depends on raw load order, so it
    -- CANNOT be a constant here — `custom_code` names the workshop and
    -- the reaction builder resolves it at build time.
    --
    -- Note SOAP_MAKER is vanilla content that happens to be implemented
    -- as a custom workshop (vanilla building_custom.txt), so it goes
    -- through exactly the same path as a modded one.

    SOAP_MAKER = {
        type        = { 13 },
        subtype     = { 23 },
        custom      = { -1 },        -- filled in at runtime
        custom_code = "SOAP_MAKER",
    },

    -- ArgMOD's Chemist (building_arg_chemist.txt). Stays in raws —
    -- we only need to find it, never to create it.
    CHEMIST = {
        type        = { 13 },
        subtype     = { 23 },
        custom      = { -1 },
        custom_code = "CHEMIST",
    },

    -- ArgMOD's Compounder (building_arg_compounder.txt). Same deal as
    -- CHEMIST: a raws workshop we only ever need to find, never build.
    -- Its runtime index depends on raw load order, so custom_code names
    -- it and the reaction builder resolves it at build time.
    COMPOUNDER = {
        type        = { 13 },
        subtype     = { 23 },
        custom      = { -1 },
        custom_code = "COMPOUNDER",
    },

    -- No building (adventure mode reactions)
    NONE = {
        type    = {},
        subtype = {},
        custom  = {},
    },
}


-- ==========================================
-- BUILDING CAPABILITY GATES
-- ==========================================
-- Maps each BUILDING_TYPES key to the job capability required for
-- a civilization to use that workshop. The module permission
-- evaluator checks these gates against each civ's permitted_job
-- array before injecting reaction permissions.
--
-- Gate types (mixed in a single list):
--   - "StrangeMoodForge", "StrangeMoodMagmaForge", etc:
--       Checked via numeric df.job_type enum iteration
--       (same pattern as boot Pass 3). These represent deep
--       cultural capabilities that encompass entire material
--       classes, not just individual job skills.
--
--   - "GLASSMAKER", "POTTER", etc:
--       Checked as direct boolean keys on permitted_job.
--       These represent specific workshop operator skills.
--
-- A civ passes the gate if ANY entry in the list is true.
-- (e.g., a smelter gate passes if the civ has EITHER
-- StrangeMoodForge OR StrangeMoodMagmaForge.)
--
-- ADDING NEW BUILDINGS:
--   1. Add the building to BUILDING_TYPES above.
--   2. Add its gate entry here.
--   3. The evaluator picks it up automatically.
-- ==========================================
BUILDING_CAPABILITY_GATES = {
    -- ---- FURNACES ----

    -- ---- WHY NONE OF THESE ARE MOOD GATES ANY MORE ----
    --
    -- entity_raw.jobs.permitted_job is indexed by df.profession, not
    -- df.job_type. Verified: the live array is 135 slots and
    -- df.profession has exactly 135 entries, and reads by name agree
    -- with reads by df.profession index on every civ tested.
    --
    -- The mood gates indexed it with df.job_type values, which landed
    -- on unrelated professions:
    --
    --   StrangeMoodForge      = 55 -> LYE_MAKER
    --   StrangeMoodMagmaForge = 56 -> WOOD_BURNER
    --   StrangeMoodMason      = 60 -> BEEKEEPER
    --
    -- So the smelter gate asked whether a civ made lye or burned
    -- wood, and the kiln gate asked whether it kept bees. Both looked
    -- plausible because civs with broad profession lists tend to have
    -- those slots set as well.
    --
    -- Beyond the wrong read, a mood is the wrong QUESTION. A strange
    -- mood is about artifact creation, not about whether a civ has the
    -- profession that operates a building. Goblins have MASON and
    -- STONECRAFTER but never take mason moods.
    --
    -- Each gate now names the profession that actually runs the
    -- building. All names verified present in df.profession.

    -- Wood Furnace: requires the wood burner profession
    WOOD_FURNACE = {
        gate_type = "permitted_job",
        jobs = { "WOOD_BURNER" },
    },

    -- Smelter: FURNACE_OPERATOR (17) is what runs a smelter, and the
    -- smelter is the only building that produces metal bars, whether
    -- from ore or by alloying.
    SMELTER = {
        gate_type = "permitted_job",
        jobs = { "FURNACE_OPERATOR" },
    },

    -- Kiln: POTTER (33) and GLAZER (34). Both verified by name and by
    -- df.profession index on MOUNTAIN, which has each of them.
    KILN = {
        gate_type = "permitted_job",
        jobs = { "POTTER", "GLAZER" },
    },

    -- Glass Furnace: direct job check, not a mood
    GLASS_FURNACE = {
        gate_type = "permitted_job",
        jobs = { "GLASSMAKER" },
    },

    -- ---- WORKSHOPS ----

    -- Mason's Workshop: masonry skill
    MASON = {
        gate_type = "permitted_job",
        jobs = { "MASON" },
    },

    -- Craftsdwarf's Workshop: any craft skill
    CRAFTSMAN = {
        gate_type = "permitted_job",
        jobs = { "STONECRAFTER", "WOODCRAFTER", "BONE_CARVER" },
    },

    -- Jeweler's Workshop: gem working skills
    JEWELER = {
        gate_type = "permitted_job",
        jobs = { "JEWELER", "GEM_CUTTER", "GEM_SETTER" },
    },

    -- Metalsmith's Forge: the smith professions, 16 and 18 to 21.
    --
    -- This is deliberately NOT the same test as the smelter. The old
    -- comment claimed smelting and forging were one capability; they
    -- are not. Metal bars come only from a smelter. A forge governs
    -- working existing bars, which for RM means grinding them to dust.
    --
    -- Kobolds are the case that proves the distinction: they have
    -- FURNACE_OPERATOR but none of the smith professions. They can
    -- smelt and they cannot forge.
    FORGE = {
        gate_type = "permitted_job",
        jobs = { "METALSMITH", "WEAPONSMITH", "ARMORER",
                 "BLACKSMITH", "METALCRAFTER" },
    },

    -- Mill, Ashery, and the two custom workshops: no capability gate.
    --
    -- This is deliberate. The existing gates guard against handing a
    -- smelting reaction to a civ with no metalworking culture. But a
    -- module using ENTITY_CODE permissions has already named its civs
    -- explicitly, and a speculative gate on top can only SUBTRACT from
    -- what the module author asked for — silently, since an unknown
    -- permitted_job name fails closed via pcall.
    --
    -- ArgMOD names MOUNTAIN, PLAINS and EVIL by hand, and further
    -- restricts the Chemist with [PERMITTED_BUILDING:CHEMIST] on
    -- MOUNTAIN only. That list is authoritative; second-guessing it
    -- would change his work. Tighten these later if a module ever
    -- needs AUTO mode on these workshops.
    MILL       = { gate_type = "none", jobs = {} },
    ASHERY     = { gate_type = "none", jobs = {} },
    SOAP_MAKER = { gate_type = "none", jobs = {} },
    CHEMIST    = { gate_type = "none", jobs = {} },
    COMPOUNDER = { gate_type = "none", jobs = {} },
    

    -- No building: no capability gate (adventure mode, always passes)
    NONE = {
        gate_type = "none",
        jobs = {},
    },
}


-- ==========================================
-- SKILL MAP
-- ==========================================
-- Maps schema skill names to DF job_skill enum values.
-- Sourced from: :lua for i,v in ipairs(df.job_skill) do print(i,v) end
-- Only includes skills relevant to workshop reactions.
--
-- IMPORTANT: These are df.job_skill indexes, NOT df.job_type.
-- The reaction's .skill field takes a job_skill value.
-- ==========================================
SKILL_MAP = {
    -- Furnace skills
    WOOD_BURNING    = 63,   -- Wood Furnace Operation
    SMELT           = 24,   -- Furnace Operating (smelter reactions)
    GLASSMAKER      = 34,   -- Glassmaking
    POTTERY         = 109,  -- Pottery (kiln reactions)

    -- Workshop skills: stone/masonry
    MASONRY         = 4,    -- Masonry (mason's workshop)
    STONECRAFT      = 32,   -- Stone Crafting (craftsdwarf's workshop)
    KNAPPING        = 105,  -- Knapping
    CUT_STONE       = 135,  -- Stone Cutting
    CARVE_STONE     = 136,  -- Stone Carving

    -- Workshop skills: metalworking
    FORGE_WEAPON    = 26,   -- Weaponsmithing (forge)
    FORGE_ARMOR     = 27,   -- Armorsmithing (forge)
    FORGE_FURNITURE = 28,   -- Blacksmithing / furniture (forge)
    METALCRAFT      = 33,   -- Metal Crafting (craftsdwarf's workshop)

    -- Workshop skills: gems
    GEM_CUTTING     = 29,   -- Gem Cutting (jeweler's workshop)
    GEM_SETTING     = 30,   -- Gem Setting (jeweler's workshop)

    -- Workshop skills: organic
    WOODCRAFT       = 31,   -- Wood Crafting
    BONECARVE       = 36,   -- Bone Carving
    LEATHERWORK     = 35,   -- Leatherworking
    CARPENTRY       = 2,    -- Carpentry

    -- Workshop skills: textiles and misc
    WEAVING         = 13,   -- Weaving (loom)
    CLOTHESMAKING   = 15,   -- Clothes Making
    STRAND_EXTRACT  = 25,   -- Strand Extraction
    SOAP_MAKING     = 65,   -- Soap Making
    MILLING         = 16,   -- Milling (quern/millstone)
    LYE_MAKING      = 64,   -- Lye Making (ashery, chemist)
    LYE_MAKING      = 64,   -- Lye Making (ashery, chemist)

    -- Glazing. Verified as 110 from the GLAZE_CRAFT_ASH path map,
    -- not inferred: that reaction carries [SKILL:GLAZING] in raws and
    -- stores skill = 110.
    GLAZING         = 110,  -- Glazing (kiln)
    POTASH_MAKING   = 66,   -- Potash Making (ashery, kiln, chemist)
}


-- ==========================================
-- MATERIAL CLASS PRESETS
-- ==========================================
-- Maps schema material_class names to the material.flags that
-- the engine force-sets after cloning. The engine:
--   1. Deep-copies the auto-selected clone source (all flags come along)
--   2. Applies the preset below (force-sets listed flags to true)
--   3. Applies any material_flags overrides from the definition
--
-- The "clear" list is flags that get force-set to FALSE before
-- the preset is applied. This ensures a clean slate when
-- crossing material boundaries (e.g. cloning from a metal to
-- make a stone — we need to clear the metal flags first).
--
-- RAW class applies no preset and no clearing — clone flags
-- are preserved exactly as-is.
-- ==========================================
MATERIAL_CLASS_PRESETS = {

    METAL = {
        clear = {
            "IS_STONE", "IS_GEM", "IS_GLASS", "IS_CERAMIC",
        },
        set = {
            "IS_METAL", "ITEMS_METAL", "ITEMS_HARD",
            "ITEMS_BARRED", "ITEMS_SCALED",
            "ITEMS_WEAPON", "ITEMS_WEAPON_RANGED",
            "ITEMS_AMMO", "ITEMS_DIGGER",
            "ITEMS_ARMOR", "ITEMS_ANVIL",
        },
    },

    STONE = {
        clear = {
            "IS_METAL", "IS_GEM", "IS_GLASS", "IS_CERAMIC",
            "ITEMS_METAL", "ITEMS_BARRED", "ITEMS_SCALED",
            "ITEMS_WEAPON", "ITEMS_WEAPON_RANGED",
            "ITEMS_AMMO", "ITEMS_DIGGER",
            "ITEMS_ARMOR", "ITEMS_ANVIL",
        },
        set = {
            "IS_STONE", "ITEMS_HARD", "ITEMS_QUERN",
        },
    },

    GEM = {
        clear = {
            "IS_METAL", "IS_STONE", "IS_GLASS", "IS_CERAMIC",
            "ITEMS_METAL", "ITEMS_BARRED", "ITEMS_SCALED",
            "ITEMS_WEAPON", "ITEMS_WEAPON_RANGED",
            "ITEMS_AMMO", "ITEMS_DIGGER",
            "ITEMS_ARMOR", "ITEMS_ANVIL",
        },
        set = {
            "IS_GEM",
        },
    },

    CERAMIC = {
        clear = {
            "IS_METAL", "IS_GEM", "IS_GLASS",
            "ITEMS_METAL", "ITEMS_BARRED", "ITEMS_SCALED",
            "ITEMS_WEAPON", "ITEMS_WEAPON_RANGED",
            "ITEMS_AMMO", "ITEMS_DIGGER",
            "ITEMS_ARMOR", "ITEMS_ANVIL",
        },
        set = {
            "IS_CERAMIC", "ITEMS_HARD",
        },
    },

    -- Glass: produced at glass furnace. Buildable (windows, blocks).
    -- Flags match the modded cobalt glass inorganic pattern:
    -- IS_GLASS + ITEMS_HARD, everything else cleared.
    -- Vanilla glass types (GREEN_GLASS, CLEAR_GLASS, CRYSTAL_GLASS)
    -- are NOT inorganic definitions — they're engine-side. A modded
    -- glass defined as an inorganic with IS_GLASS behaves like glass
    -- in gameplay (windows, crafts, etc.). Source: cobalt glass mod
    -- path map (modded_cobalt_glass_inorganic_path_map.txt).
    GLASS = {
        clear = {
            "IS_METAL", "IS_GEM", "IS_STONE", "IS_CERAMIC",
            "ITEMS_METAL", "ITEMS_BARRED", "ITEMS_SCALED",
            "ITEMS_WEAPON", "ITEMS_WEAPON_RANGED",
            "ITEMS_AMMO", "ITEMS_DIGGER",
            "ITEMS_ARMOR", "ITEMS_ANVIL",
            "ITEMS_QUERN",
        },
        set = {
            "IS_GLASS", "ITEMS_HARD",
        },
    },

    -- RAW: No clearing, no setting. Clone's flags are preserved
    -- exactly as-is. Use when the clone source already has the
    -- right flags, or when you want full manual control via
    -- material_flags overrides in the definition.
    RAW = {
        clear = {},
        set = {},
    },
}


-- ==========================================
-- CLONE SOURCE SCORING — CLASS SIGNATURES
-- ==========================================
-- For auto-clone selection, the engine needs to know what flag
-- signature identifies a "good donor" for each material class.
-- These are the flags the engine checks when scanning the
-- inorganic array for clone candidates.
--
-- The engine walks inorganics.all, checks each entry against the
-- required flags, and scores candidates by how cleanly they match.
-- The best scorer becomes the clone source for all materials of
-- that class in the current module pipeline run.
--
-- Fields:
--   require_true  — These material.flags must be true
--   require_false — These material.flags must be false
--   prefer        — Bonus score for these being true (soft preference)
-- ==========================================
CLONE_SIGNATURES = {

    METAL = {
        require_true  = { "IS_METAL" },
        require_false = { "IS_GEM", "IS_GLASS", "IS_CERAMIC" },
        -- Prefer common, clean metals over exotic ones
        prefer        = { "ITEMS_WEAPON", "ITEMS_ARMOR" },
    },

    STONE = {
        require_true  = { "IS_STONE" },
        require_false = { "IS_METAL", "IS_GEM", "IS_GLASS" },
        prefer        = {},
    },

    GEM = {
        require_true  = { "IS_GEM" },
        require_false = { "IS_METAL", "IS_GLASS" },
        prefer        = {},
    },

    CERAMIC = {
        require_true  = { "IS_CERAMIC" },
        require_false = { "IS_METAL", "IS_GEM", "IS_GLASS" },
        prefer        = {},
    },

    -- Glass: look for IS_GLASS inorganics (modded worlds may have
    -- them, e.g. cobalt glass). In vanilla worlds, no IS_GLASS
    -- inorganic exists — the evaluator will fail to find a donor.
    -- The engine handles this via fallback to CERAMIC donor (see
    -- refinish-evaluate-clone-source.lua fallback logic).
    GLASS = {
        require_true  = { "IS_GLASS" },
        require_false = { "IS_METAL", "IS_GEM", "IS_STONE" },
        prefer        = { "ITEMS_HARD" },
    },

    -- RAW: No signature — the modder must accept whatever the
    -- engine picks. In practice, RAW falls back to the STONE
    -- signature since stones are the most structurally neutral
    -- inorganic type. This fallback is handled in the injection
    -- logic, not here.
    RAW = {
        require_true  = {},
        require_false = {},
        prefer        = {},
    },
}


-- ==========================================
-- EXPORTS
-- ==========================================
-- All tables above are global (non-local) so they export
-- through _ENV when loaded via reqscript/script_environment.
-- ==========================================
return _ENV