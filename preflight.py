#!/usr/bin/env python3
"""
preflight.py - offline schema check for RM module JSON files.

Mirrors every rejection branch in refinish-module-validate.lua so you can
catch a bad file without launching Dwarf Fortress.

WHAT IT READS
    refinish-module-types.lua   The engine's type dictionary. Reagent types,
                                product types, buildings, skills and material
                                classes are all parsed OUT OF IT rather than
                                hardcoded here, so this script cannot drift
                                from the engine. Re-copy it from your live RM
                                install whenever RM updates.
    <name>_materials.json       Your module's materials file.
    <name>_reactions.json       Your module's reactions file.

USAGE
    python3 preflight.py                          auto-discover in this folder
    python3 preflight.py mats.json rxns.json      explicit files
    python3 preflight.py --types /path/types.lua mats.json rxns.json

EXIT CODES
    0   passed (warnings may still have been printed)
    1   failed, at least one error
    2   could not find or read an input file

ERRORS vs WARNINGS
    An ERROR is something refinish-module-validate.lua will reject, which
    takes the whole module down. Fix these.

    A WARNING is something this script cannot verify offline, or something
    that is legal but is a known way to shoot yourself. It does not fail
    the run.
"""

import argparse
import glob
import json
import os
import re
import sys


# ===============================================================
# PARSE THE ENGINE'S TYPE TABLES
# ===============================================================
# Everything the validator checks a name against lives in
# refinish-module-types.lua. Parsing it means this script stays
# correct when the engine gains a new reagent type or building.
#
# An early version hardcoded these lists, drifted from the engine,
# and missed the needs_mat_id class of failure entirely. Do not
# reintroduce hardcoded copies.
# ===============================================================
def load_engine_types(path):
    text = open(path, encoding='utf-8', errors='replace').read().replace('\r', '')

    def table_keys(name):
        m = re.search(r'^' + name + r' = \{(.*?)^\}', text, re.S | re.M)
        if not m:
            return set()
        return set(re.findall(r'^    ([A-Z_0-9]+)\s*=', m.group(1), re.M))

    # Reagent types, with the two per-type requirements the validator
    # enforces. Value is (needs_mat_id, needs_metal_id).
    reagents = {}
    m = re.search(r'^REAGENT_TYPES = \{(.*?)^\}', text, re.S | re.M)
    if m:
        for entry in re.finditer(r'^    ([A-Z_0-9]+) = \{(.*?)^    \}',
                                 m.group(1), re.S | re.M):
            body = entry.group(2)
            reagents[entry.group(1)] = (
                bool(re.search(r'needs_mat_id\s*=\s*true', body)),
                bool(re.search(r'needs_metal_id\s*=\s*true', body)),
            )

    # Product types, flagging the ones that carry a builtin material.
    # Those name no material of their own and are exempt from the
    # exactly-one-material-source rule.
    products = {}
    m = re.search(r'^PRODUCT_TYPES = \{(.*?)^\}', text, re.S | re.M)
    if m:
        for line in m.group(1).splitlines():
            entry = re.match(r'\s*([A-Z_0-9]+)\s*=\s*\{(.*)', line)
            if entry:
                products[entry.group(1)] = bool(
                    re.search(r'builtin\s*=\s*true', entry.group(2)))

    skills = set()
    m = re.search(r'SKILL_MAP = \{(.*?)^\}', text, re.S | re.M)
    if m:
        skills = set(re.findall(r'^\s+([A-Z_0-9]+)\s*=\s*\S', m.group(1), re.M))

    return {
        'reagents':  reagents,
        'products':  products,
        'classes':   table_keys('MATERIAL_CLASS_PRESETS'),
        'buildings': table_keys('BUILDING_TYPES'),
        'skills':    skills,
    }


# ===============================================================
# REPORTING
# ===============================================================
ERRORS = []
WARNINGS = []


def err(msg):
    ERRORS.append(msg)


def warn(kind, msg):
    """kind groups repetitive warnings in the report so a 900-reaction
    module does not print 700 near-identical lines."""
    WARNINGS.append((kind, msg))


# ===============================================================
# df.item_type NAMES
# ===============================================================
# A product type not listed in PRODUCT_TYPES is still valid if
# df.item_type knows the name, and the reaction builder resolves it
# that way. This script cannot read the DF enum, so it carries a copy.
#
# The list is ADVISORY and is only consulted to suppress a warning.
# Being incomplete costs a spurious warning. Being wrong costs a
# missing warning. Neither can turn an error into a pass, because
# an unrecognised product type was never an error here in the first
# place. If a name you use is missing, add it.
# ===============================================================
DF_ITEM_TYPES = {
    'BAR', 'SMALLGEM', 'BLOCKS', 'ROUGH', 'BOULDER', 'WOOD', 'DOOR',
    'FLOODGATE', 'BED', 'CHAIR', 'CHAIN', 'FLASK', 'GOBLET', 'INSTRUMENT',
    'TOY', 'WINDOW', 'CAGE', 'BARREL', 'BUCKET', 'ANIMALTRAP', 'TABLE',
    'COFFIN', 'STATUE', 'CORPSE', 'WEAPON', 'ARMOR', 'SHOES', 'SHIELD',
    'HELM', 'GLOVES', 'BOX', 'BIN', 'ARMORSTAND', 'WEAPONRACK', 'CABINET',
    'FIGURINE', 'AMULET', 'SCEPTER', 'AMMO', 'CROWN', 'RING', 'EARRING',
    'BRACELET', 'GEM', 'ANVIL', 'CORPSEPIECE', 'REMAINS', 'MEAT', 'FISH',
    'FISH_RAW', 'VERMIN', 'IS_PET', 'SEEDS', 'PLANT', 'SKIN_TANNED',
    'PLANT_GROWTH', 'THREAD', 'CLOTH', 'TOTEM', 'PANTS', 'BACKPACK',
    'QUIVER', 'CATAPULTPARTS', 'BALLISTAPARTS', 'SIEGEAMMO',
    'BALLISTAARROWHEAD', 'TRAPPARTS', 'TRAPCOMP', 'DRINK', 'POWDER_MISC',
    'CHEESE', 'FOOD', 'LIQUID_MISC', 'COIN', 'GLOB', 'ROCK', 'PIPE_SECTION',
    'HATCH_COVER', 'GRATE', 'QUERN', 'MILLSTONE', 'SPLINT', 'CRUTCH',
    'TRACTION_BENCH', 'ORTHOPEDIC_CAST', 'TOOL', 'SLAB', 'EGG', 'BOOK',
    'SHEET', 'BRANCH',
}


# ===============================================================
# RUNTIME SENTINELS
# ===============================================================
# A module Lua file may write an explicit null into mat_id or metal_id
# as a sentinel meaning "resolve this against the loaded world before
# handing the data to RM." The sand pattern is the standard case.
#
# JSON distinguishes a key that is absent from one that is present and
# null, and that distinction is the whole signal. Absent means the
# modder forgot. Present-and-null means they meant it.
#
# The engine never sees these, so flagging them as errors would fail
# every module that resolves anything at load time.
# ===============================================================
def is_sentinel(d, field):
    return isinstance(d, dict) and field in d and d[field] is None


# ===============================================================
# SHARED TYPE PREDICATES
# ===============================================================
# The validator's helpers, translated. The bool exclusion matters:
# Python treats True as an int, Lua does not treat true as a number,
# so a JSON true in a numeric field must fail here as it would there.
# ===============================================================
def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def is_nil_or_num(v):
    return v is None or is_num(v)


def is_str(v):
    return isinstance(v, str)


def is_nonempty_str(v):
    return isinstance(v, str) and v != ''


def is_nil_or_str(v):
    return v is None or isinstance(v, str)


def is_table(v):
    return isinstance(v, (dict, list))


# ===============================================================
# MODULE IDENTITY
# ===============================================================
# Checked per file, then cross-checked between them. The engine
# rejects the module if the two prefixes disagree.
# ===============================================================
def check_module_block(doc, label):
    m = doc.get('module')
    if not isinstance(m, dict):
        err("%s: missing 'module' block" % label)
        return None

    prefix = m.get('prefix')
    if not is_nonempty_str(prefix):
        err("%s: module.prefix must be a non-empty string" % label)
    else:
        if not prefix.endswith('_'):
            err("%s: module.prefix must end with an underscore: %r" % (label, prefix))
        if 'REFINISH_STEEL_' in prefix:
            err("%s: module.prefix collides with RM core: %r" % (label, prefix))

    if not is_nonempty_str(m.get('name')):
        err("%s: module.name must be a non-empty string" % label)
    if not is_nonempty_str(m.get('version')):
        err("%s: module.version must be a non-empty string" % label)

    deps = m.get('depends_on')
    if deps is not None:
        if not isinstance(deps, list):
            err("%s: module.depends_on must be an array of prefix strings" % label)
        else:
            for i, dep in enumerate(deps, 1):
                if not is_nonempty_str(dep):
                    err("%s: module.depends_on[%d] must be a non-empty string" % (label, i))
                elif not dep.endswith('_'):
                    err("%s: module.depends_on[%d] must end with an underscore: %r"
                        % (label, i, dep))
                elif dep == prefix:
                    err("%s: module.depends_on[%d] cannot be this module's own prefix"
                        % (label, i))
    return prefix


# ===============================================================
# MATERIALS
# ===============================================================
def check_materials(doc, engine, label):
    mats = doc.get('materials')
    if not isinstance(mats, list):
        err("%s: missing 'materials' array" % label)
        return []
    if not mats:
        err("%s: 'materials' array is empty" % label)
        return []

    stress_fields = ('IMPACT', 'COMPRESSIVE', 'TENSILE', 'TORSION', 'SHEAR', 'BENDING')
    heat_fields = ('spec_heat', 'melting_point', 'boiling_point', 'ignite_point',
                   'heatdam_point', 'colddam_point', 'mat_fixed_temp')

    seen = set()
    for i, x in enumerate(mats):
        t = "materials[%d] (%s)" % (i, x.get('key'))

        # ---- key ----
        k = x.get('key')
        if not is_nonempty_str(k):
            err("%s.key must be a non-empty string" % t)
            k = ''
        else:
            if re.search(r'\s', k):
                err("%s.key must not contain whitespace" % t)
            if k != k.upper():
                err("%s.key must be UPPERCASE" % t)
            if k in seen:
                err("%s.key is duplicated" % t)
            seen.add(k)

        if not is_nonempty_str(x.get('name')):
            err("%s.name must be a non-empty string" % t)

        # ---- class ----
        cls = x.get('material_class')
        if not is_nonempty_str(cls):
            err("%s.material_class is required" % t)
        elif cls not in engine['classes']:
            err("%s.material_class %r is not a recognized class" % (t, cls))

        # ---- appearance ----
        if x.get('color') is not None and not is_str(x['color']):
            err("%s.color must be a string or null" % t)
        fb = x.get('fallback_colors')
        if fb is not None:
            if not isinstance(fb, list):
                err("%s.fallback_colors must be an array or null" % t)
            else:
                for j, c in enumerate(fb, 1):
                    if not is_str(c):
                        err("%s.fallback_colors[%d] must be a string" % (t, j))
        if x.get('color') is None:
            warn('color',
             "%s: no color set. The material takes whatever colour the "
                 "clone donor had." % t)
        elif not fb:
            warn('color',
             "%s: color %r has no fallback_colors. If that descriptor is "
                 "not loaded the material renders grey with no error."
                 % (t, x.get('color')))

        # ---- numbers ----
        for f in ('value', 'solid_density', 'liquid_density', 'molar_mass'):
            if not is_nil_or_num(x.get(f)):
                err("%s.%s must be a number or null" % (t, f))

        heat = x.get('heat')
        if heat is not None:
            if not isinstance(heat, dict):
                err("%s.heat must be a table or null" % t)
            else:
                for f in heat_fields:
                    if not is_nil_or_num(heat.get(f)):
                        err("%s.heat.%s must be a number or null" % (t, f))

        st = x.get('strength')
        if st is not None:
            if not isinstance(st, dict):
                err("%s.strength must be a table or null" % t)
            else:
                for group in ('yield', 'fracture', 'strain_at_yield'):
                    g = st.get(group)
                    if g is None:
                        continue
                    if not isinstance(g, dict):
                        err("%s.strength.%s must be a table or null" % (t, group))
                        continue
                    for f in stress_fields:
                        if not is_nil_or_num(g.get(f)):
                            err("%s.strength.%s.%s must be a number or null"
                                % (t, group, f))
                if not is_nil_or_num(st.get('max_edge')):
                    err("%s.strength.max_edge must be a number or null" % t)

        # ---- gem names ----
        g = x.get('gem_names')
        if g is not None:
            if not isinstance(g, list) or len(g) != 2:
                err("%s.gem_names must be an array of exactly 2 strings or null" % t)
            elif not (is_str(g[0]) and is_str(g[1])):
                err("%s.gem_names entries must be strings" % t)
        if cls == 'GEM' and g is None:
            err("%s: material_class GEM requires gem_names" % t)

        # ---- classes and products ----
        rc = x.get('reaction_classes')
        if rc is not None:
            if not isinstance(rc, list):
                err("%s.reaction_classes must be an array or null" % t)
            else:
                for j, c in enumerate(rc, 1):
                    if not is_str(c):
                        err("%s.reaction_classes[%d] must be a string" % (t, j))

        rp = x.get('reaction_products')
        if rp is not None:
            if not isinstance(rp, list):
                err("%s.reaction_products must be an array or null" % t)
            else:
                for j, p in enumerate(rp, 1):
                    if not isinstance(p, dict):
                        err("%s.reaction_products[%d] must be a table" % (t, j))
                        continue
                    if not is_nonempty_str(p.get('id')):
                        err("%s.reaction_products[%d].id is required" % (t, j))
                    if not is_nonempty_str(p.get('mat_id')):
                        err("%s.reaction_products[%d].mat_id is required" % (t, j))

        for f in ('material_flags', 'inorganic_flags'):
            if x.get(f) is not None and not isinstance(x[f], dict):
                err("%s.%s must be a table or null" % (t, f))

    return mats


# ===============================================================
# REAGENTS
# ===============================================================
def check_reagent(g, j, tag, engine):
    t = "%s.reagents[%d] (%s)" % (tag, j, g.get('code'))

    if not is_nonempty_str(g.get('code')):
        err("%s.code is required" % t)

    ty = g.get('type')
    if not is_nonempty_str(ty):
        err("%s.type is required" % t)
    elif ty not in engine['reagents']:
        err("%s.type %r is not a recognized reagent type" % (t, ty))
    else:
        needs_mat, needs_metal = engine['reagents'][ty]
        if needs_mat and not is_nonempty_str(g.get('mat_id')):
            if is_sentinel(g, 'mat_id'):
                warn('sentinel',
                     "%s: mat_id is explicitly null. Your module Lua must fill "
                     "it in before returning the data, or the engine rejects "
                     "this reagent." % t)
            else:
                err("%s: type %r requires mat_id" % (t, ty))
        if needs_metal and not is_nonempty_str(g.get('metal_id')):
            if is_sentinel(g, 'metal_id'):
                warn('sentinel',
                     "%s: metal_id is explicitly null. Your module Lua must "
                     "fill it in before returning the data." % t)
            else:
                err("%s: type %r requires metal_id" % (t, ty))

    if not is_num(g.get('quantity')):
        err("%s.quantity must be a number" % t)

    if g.get('flags') is not None and not isinstance(g['flags'], dict):
        err("%s.flags must be a table or null" % t)

    for f in ('contains', 'contains_in'):
        if g.get(f) is not None and not is_str(g[f]):
            err("%s.%s must be a string or null" % (t, f))

    for f in ('has_material_reaction_product', 'reaction_class'):
        if not is_nil_or_str(g.get(f)):
            err("%s.%s must be a string or null" % (t, f))

    # ---- warnings the validator does not raise ----
    flags = g.get('flags') or {}

    # A flag name react.lua does not recognise is silently discarded.
    # Nothing errors, the reagent just quietly matches more than it was
    # meant to. Catching typos here is the only place it gets caught.
    #
    # Mirrors refinish-module-react.lua: the explicit mappings in
    # build_reagent plus every entry in REAGENT_FLAG_MAP. Re-copy this
    # set whenever that file gains flags.
    for name in flags:
        if name not in KNOWN_REAGENT_FLAGS:
            err("%s.flags.%s is not a recognized flag name. The reaction "
                "builder ignores unknown flags, so the filter you intended "
                "will not be applied." % (t, name))

    # unrotten is a positive requirement. Setting it false does not mean
    # "must be rotten", it means no rot requirement at all, which is the
    # default. DF has no filter for requiring rot.
    if flags.get('unrotten') is False:
        warn('dead_field',
             "%s: unrotten false is a no-op, not an inverse. DF cannot "
             "require an item be rotten. Omit the flag." % t)

    # The two flags that can consume something irreplaceable.
    if flags.get('allow_artifact'):
        warn('artifact_risk',
             "%s: allow_artifact lets this reagent take an artifact. If the "
             "reaction consumes its input the artifact is gone. Pair with "
             "non_artifact instead unless this is deliberate." % t)
    if flags.get('crafted_artifact'):
        warn('artifact_risk',
             "%s: crafted_artifact REQUIRES an artifact rather than "
             "permitting one. This reagent will seek out exactly the items "
             "most players never want consumed." % t)

    # contains_in is accepted by the validator but the reaction builder
    # never reads it. It does nothing.
    if g.get('contains_in') is not None:
        warn('dead_field',
         "%s: contains_in is validated but the reaction builder ignores it. "
             "Put contains on the container instead." % t)

    # sand_bearing sits at the reagent root, not in flags. Inside flags
    # it is silently discarded.
    if 'sand_bearing' in flags:
        err("%s: sand_bearing belongs at the root of the reagent, not inside "
            "flags. Inside flags it is silently ignored." % t)

    if g.get('sand_bearing') and g.get('mat_id'):
        warn('redundant_filter',
             "%s: sand_bearing plus mat_id means an item must satisfy both. "
             "Once the material is known the flag is redundant and is one more "
             "filter that can reject a valid bag." % t)

    # Item type -1 reagents match everything until narrowed.
    if ty == 'ANY_CRAFT' and not g.get('reaction_class'):
        warn('wildcard_reagent',
             "%s: ANY_CRAFT is item type -1. Without a reaction_class it "
             "matches every craft in the fortress." % t)
    if ty == 'BODY_PART':
        # body_part alone is sufficient. Verified live: a reagent
        # carrying only body_part took raw hides and left coal bars and
        # pitch buckets alone. The narrowing flags are optional.
        if not flags.get('body_part'):
            warn('wildcard_reagent',
                 "%s: BODY_PART is item type -1 and the flags do all the "
                 "filtering. Without flags.body_part it matches every item "
                 "in the fortress, including bars, buckets and furniture." % t)
    if ty == 'ANY_ITEM':
        # ANY_ITEM has no item type at all, so an empty flags block is a
        # reagent that matches literally everything.
        narrowing = [f for f in flags
                     if f not in ('preserve', 'non_artifact', 'unrotten', 'solid')
                     and flags.get(f)]
        if not narrowing:
            warn('wildcard_reagent',
                 "%s: ANY_ITEM is item type -1 with nothing pinning it. It "
                 "needs at least one filtering flag or it matches every item "
                 "in the fortress." % t)
        if flags.get('furniture') and not flags.get('not_bin'):
            warn('wildcard_reagent',
                 "%s: the furniture category includes containers. Without "
                 "not_bin this reagent will take barrels and bins off the "
                 "stockpile floor." % t)
        if not flags.get('non_artifact'):
            warn('artifact_risk',
                 "%s: an item type -1 reagent without non_artifact will "
                 "eventually reach an artifact." % t)
    if ty == 'CONTAINER':
        warn('wildcard_reagent',
             "%s: CONTAINER is item type -1 and DF will accept a metal bar or a "
             "weapon as a container. Use BUCKET or BARREL." % t)

    if flags.get('in_container') and not g.get('contains'):
        pass  # the container side is checked at reaction level


# ===============================================================
# REAGENT FLAG VOCABULARY
# ===============================================================
# Every flag name refinish-module-react.lua acts on. Anything else in a
# flags block is discarded by the reaction builder without complaint.
#
# Grouped the way react.lua handles them, not the way DF groups them by
# bitfield, so the two files can be diffed against each other.
KNOWN_REAGENT_FLAGS = frozenset((
    # reagent-level, not job item filter bits
    'preserve', 'in_container',

    # mapped explicitly in build_reagent
    'empty', 'glass_material', 'unrotten',
    'non_economic', 'building_material', 'fire_safe', 'magma_safe',
    'allow_melt_dump',
    'body_part', 'bone', 'shell', 'horn', 'pearl', 'ivory_tooth',
    'totemable', 'leather', 'silk', 'yarn', 'hair_wool', 'soap', 'plant',
    'furniture', 'finished_goods', 'ammo', 'not_bin', 'solid',
    'unimproved', 'any_raw_material',
    'wood', 'stone', 'metal', 'hard', 'woven', 'grown_not_crafted',
    'non_artifact',

    # REAGENT_FLAG_MAP flags1
    'improvable', 'butcherable', 'millable', 'allow_buryable',
    'undisturbed', 'collected', 'sharpenable', 'murdered', 'processable',
    'cookable', 'extract_bearing_plant', 'extract_bearing_fish',
    'extract_bearing_vermin', 'processable_to_vial',
    'processable_to_barrel', 'tameable_vermin', 'nearby', 'milk',
    'milkable', 'lye_bearing',

    # REAGENT_FLAG_MAP flags2
    'dye', 'dyeable', 'dyed', 'sewn_imageless', 'glass_making', 'screw',
    'deep_material', 'melt_designated', 'allow_artifact',
    'plaster_containing', 'lye_milk_free', 'blunt', 'unengraved',

    # REAGENT_FLAG_MAP flags3
    'non_absorbent', 'non_pressed', 'allow_liquid_powder', 'any_craft',
    'food_storage', 'sand', 'can_use_location_reserved', 'written_on',
    'edged', 'on_ground', 'divine', 'crafted_artifact', 'gem',
    'empty_or_water',
))


# ===============================================================
# PRODUCTS
# ===============================================================
def check_product(p, j, tag, codes, engine):
    t = "%s.products[%d]" % (tag, j)

    ptype = p.get('type')
    if not is_nonempty_str(ptype):
        err("%s.type is required" % t)
        return

    if ptype not in engine['products'] and ptype not in DF_ITEM_TYPES:
        # The validator accepts any df.item_type name too. This script
        # checks its own advisory copy of that enum and flags anything in
        # neither list, rather than failing it.
        warn('unnamed_product_type',
             "%s.type %r is neither a named product type nor a df.item_type "
             "name this script knows. The engine accepts it only if the DF enum "
             "has it, otherwise the product is skipped with a console message."
             % (t, ptype))

    # ---- improvement products: different class, different rules ----
    if ptype == 'IMPROVEMENT':
        if not is_nonempty_str(p.get('improvement_type')):
            err("%s.improvement_type is required for IMPROVEMENT products" % t)
        if not is_nonempty_str(p.get('target_reagent')):
            err("%s.target_reagent is required for IMPROVEMENT products" % t)
        gmp = p.get('get_material_product')
        if (not isinstance(gmp, dict)
                or not is_nonempty_str(gmp.get('reagent_code'))
                or not is_nonempty_str(gmp.get('product_code'))):
            err("%s: IMPROVEMENT products require get_material_product with "
                "reagent_code and product_code" % t)
        elif gmp['reagent_code'] not in codes:
            err("%s.get_material_product.reagent_code references unknown code %r"
                % (t, gmp['reagent_code']))
        if p.get('mat_id') is not None or p.get('get_material_same') is not None:
            err("%s: IMPROVEMENT products cannot use mat_id or get_material_same" % t)
        if p.get('target_reagent') and p['target_reagent'] not in codes:
            err("%s.target_reagent references unknown code %r"
                % (t, p['target_reagent']))
        return

    # ---- builtin-material products name no material ----
    builtin = engine['products'].get(ptype, False)
    sources = sum(1 for f in ('mat_id', 'get_material_same', 'get_material_product')
                  if p.get(f) is not None)

    if not (builtin and sources == 0):
        if sources == 0 and is_sentinel(p, 'mat_id'):
            warn('sentinel',
                 "%s: mat_id is explicitly null. Your module Lua must fill it "
                 "in before returning the data, or the engine rejects this "
                 "product." % t)
        elif sources == 0:
            err("%s: must specify exactly one of mat_id, get_material_same, or "
                "get_material_product" % t)
        elif sources > 1:
            err("%s: only one of mat_id, get_material_same, or "
                "get_material_product allowed" % t)

    gmp = p.get('get_material_product')
    if gmp is not None:
        if not isinstance(gmp, dict):
            err("%s.get_material_product must be a table" % t)
        else:
            if not is_nonempty_str(gmp.get('reagent_code')):
                err("%s.get_material_product.reagent_code is required" % t)
            elif gmp['reagent_code'] not in codes:
                err("%s.get_material_product.reagent_code references unknown "
                    "code %r" % (t, gmp['reagent_code']))
            if not is_nonempty_str(gmp.get('product_code')):
                err("%s.get_material_product.product_code is required" % t)

    gms = p.get('get_material_same')
    if gms is not None and gms not in codes:
        err("%s.get_material_same references unknown code %r" % (t, gms))

    tc = p.get('to_container')
    if tc is not None and tc not in codes:
        err("%s.to_container references unknown code %r" % (t, tc))

    for f in ('count', 'dimension', 'probability'):
        if p.get(f) is not None and not is_num(p[f]):
            err("%s.%s must be a number or null" % (t, f))


# ===============================================================
# REACTIONS
# ===============================================================
VALID_PERM_MODES = {'AUTO', 'ENTITY_CODE', 'NONE'}


def check_reactions(doc, engine, label):
    rxns = doc.get('reactions')
    if not isinstance(rxns, list):
        err("%s: missing 'reactions' array" % label)
        return []
    if not rxns:
        err("%s: 'reactions' array is empty" % label)
        return []

    seen = set()
    for i, r in enumerate(rxns):
        t = "reactions[%d] (%s)" % (i, r.get('key'))

        k = r.get('key')
        if not is_nonempty_str(k):
            err("%s.key must be a non-empty string" % t)
        elif k in seen:
            err("%s.key is duplicated" % t)
        else:
            seen.add(k)

        if not is_nonempty_str(r.get('name')):
            err("%s.name must be a non-empty string" % t)

        b = r.get('building')
        if not is_nonempty_str(b):
            err("%s.building is required" % t)
        elif b not in engine['buildings']:
            err("%s.building %r is not a recognized building type" % (t, b))

        s = r.get('skill')
        if s is not None:
            if not is_str(s):
                err("%s.skill must be a string or null" % t)
            elif engine['skills'] and s not in engine['skills']:
                err("%s.skill %r is not a recognized skill" % (t, s))
        else:
            warn('no_skill',
                 "%s: no skill set. The reaction inherits whichever skill the "
                 "cloned structural template happened to carry." % t)

        if r.get('fuel') is not None and not isinstance(r['fuel'], bool):
            err("%s.fuel must be true, false, or null" % t)
        if not is_nil_or_str(r.get('category')):
            err("%s.category must be a string or null" % t)
        if not is_nil_or_str(r.get('fallback_template')):
            err("%s.fallback_template must be a string or null" % t)

        # ---- permissions ----
        perm = r.get('permissions')
        if perm is not None:
            if not isinstance(perm, dict):
                err("%s.permissions must be a table or null" % t)
                perm = {}
            mode = perm.get('mode')
            if mode is not None:
                if not is_str(mode):
                    err("%s.permissions.mode must be a string or null" % t)
                elif mode not in VALID_PERM_MODES:
                    err("%s.permissions.mode %r is not recognized "
                        "(valid: AUTO, ENTITY_CODE, NONE)" % (t, mode))
            if mode == 'ENTITY_CODE':
                ents = perm.get('entities')
                if not isinstance(ents, list) or not ents:
                    err("%s.permissions: ENTITY_CODE mode requires a non-empty "
                        "'entities' array" % t)
                else:
                    for j, e in enumerate(ents, 1):
                        if not is_nonempty_str(e):
                            err("%s.permissions.entities[%d] must be a non-empty "
                                "string" % (t, j))
            elif perm.get('entities') is not None:
                err("%s.permissions: 'entities' should only be set with "
                    "ENTITY_CODE mode" % t)

        # ---- reaction flags ----
        rf = r.get('reaction_flags')
        if rf is not None:
            if not isinstance(rf, dict):
                err("%s.reaction_flags must be a table or null" % t)
            elif (rf.get('fortress_mode') is not None
                  and not isinstance(rf['fortress_mode'], bool)):
                err("%s.reaction_flags.fortress_mode must be true, false, or null" % t)

        # NONE permissions with no fortress_mode bypass makes a reaction
        # nobody can run. Legal, and almost never intended.
        mode = (perm or {}).get('mode')
        fort = (rf or {}).get('fortress_mode')
        if mode == 'NONE' and not fort:
            warn('unreachable',
                 "%s: permissions NONE with fortress_mode false or unset. No "
                 "civilization gets this reaction and the player cannot bypass, "
                 "so nobody can run it." % t)

        # ---- reagents ----
        rgts = r.get('reagents')
        if not isinstance(rgts, list) or not rgts:
            err("%s.reagents must be a non-empty array" % t)
            rgts = []

        codes = set()
        for j, g in enumerate(rgts, 1):
            if not isinstance(g, dict):
                err("%s.reagents[%d] must be a table" % (t, j))
                continue
            check_reagent(g, j, t, engine)
            c = g.get('code')
            if c in codes:
                err("%s.reagents[%d].code %r is duplicated" % (t, j, c))
            if is_nonempty_str(c):
                codes.add(c)

        for j, g in enumerate(rgts, 1):
            if not isinstance(g, dict):
                continue
            for f in ('contains', 'contains_in'):
                v = g.get(f)
                if v is not None and v not in codes:
                    err("%s.reagents[%d].%s references unknown code %r"
                        % (t, j, f, v))

        # Container pairing. A slot marked in_container with nothing
        # declaring that it contains it will never be filled.
        contained = {g.get('contains') for g in rgts
                     if isinstance(g, dict) and g.get('contains')}
        for g in rgts:
            if not isinstance(g, dict):
                continue
            if (g.get('flags') or {}).get('in_container') and g.get('code') not in contained:
                warn('container_pairing',
                     "%s: reagent %r is flagged in_container but no other "
                     "reagent declares 'contains' pointing at it. The slot will "
                     "never be filled." % (t, g.get('code')))

        # ---- products ----
        prods = r.get('products')
        if not isinstance(prods, list) or not prods:
            err("%s.products must be a non-empty array" % t)
            prods = []
        for j, p in enumerate(prods, 1):
            if not isinstance(p, dict):
                err("%s.products[%d] must be a table" % (t, j))
                continue
            check_product(p, j, t, codes, engine)

        # A container that receives output should be preserved and empty.
        for p in prods:
            if not isinstance(p, dict):
                continue
            tc = p.get('to_container')
            if not tc:
                continue
            for g in rgts:
                if isinstance(g, dict) and g.get('code') == tc:
                    f = g.get('flags') or {}
                    if not f.get('preserve'):
                        warn('container_pairing',
                             "%s: reagent %r receives output via to_container "
                             "but is not flagged preserve, so it is consumed."
                             % (t, tc))
                    if not f.get('empty'):
                        warn('container_pairing',
                             "%s: reagent %r receives output via to_container "
                             "but is not flagged empty, so a full bag can be "
                             "chosen." % (t, tc))

    return rxns


# ===============================================================
# CATEGORIES
# ===============================================================
def check_categories(doc, label):
    cats = doc.get('categories')
    if cats is None:
        return []
    if not isinstance(cats, list):
        err("%s: 'categories' must be an array" % label)
        return []

    seen = set()
    for i, c in enumerate(cats):
        t = "categories[%d] (%s)" % (i, c.get('key'))
        if not is_nonempty_str(c.get('key')):
            err("%s.key must be a non-empty string" % t)
        elif c['key'] in seen:
            err("%s.key is duplicated" % t)
        else:
            seen.add(c['key'])

        if not is_nonempty_str(c.get('name')):
            err("%s.name must be a non-empty string" % t)
        if not is_str(c.get('parent', '')):
            err("%s.parent must be a string (empty for top-level)" % t)
        if not is_nil_or_str(c.get('description')):
            err("%s.description must be a string or null" % t)
        if not is_nil_or_str(c.get('hotkey')):
            err("%s.hotkey must be a string or null" % t)

    return cats


# ===============================================================
# CROSS-REFERENCE CHECKS
# ===============================================================
# Not in the validator. These catch the failures that pass validation
# and then go wrong silently in game: a mat_id that resolves to -1 and
# matches nothing, a category ID written without its prefix.
# ===============================================================
def check_cross_references(prefix, mats, rxns, cats):
    own_ids = {prefix + m['key'] for m in mats
               if is_nonempty_str(m.get('key'))}
    cat_ids = {prefix + 'CAT_' + c['key'] for c in cats
               if is_nonempty_str(c.get('key'))}

    def check_id(value, where):
        """A prefixed ID must be one this module actually declares.
        Anything unprefixed is vanilla or another module and cannot be
        resolved offline."""
        if not is_nonempty_str(value):
            return
        if value.startswith(prefix) and value not in own_ids:
            err("%s references %r, which this module's prefix claims but no "
                "material declares" % (where, value))

    for m in mats:
        for rp in m.get('reaction_products') or []:
            if isinstance(rp, dict):
                check_id(rp.get('mat_id'),
                         "materials (%s).reaction_products" % m.get('key'))

    for r in rxns:
        tag = "reactions (%s)" % r.get('key')
        for g in r.get('reagents') or []:
            if isinstance(g, dict):
                check_id(g.get('mat_id'), tag + " reagent %r" % g.get('code'))
                check_id(g.get('metal_id'), tag + " reagent %r" % g.get('code'))
        for p in r.get('products') or []:
            if isinstance(p, dict):
                check_id(p.get('mat_id'), tag + " product")

        cat = r.get('category')
        if is_nonempty_str(cat):
            if cat in cat_ids:
                continue
            bare = [c['key'] for c in cats if c.get('key') == cat]
            if bare:
                err("%s.category is %r, the bare key. A reaction needs the full "
                    "ID: %r" % (tag, cat, prefix + 'CAT_' + cat))
            elif cat.startswith(prefix):
                err("%s.category %r is not declared in the categories array"
                    % (tag, cat))
            else:
                warn('external_category',
                     "%s.category %r is not declared here. That is legal if it "
                     "names a category some other module already injected."
                     % (tag, cat))

    # Category parents name a bare key, unlike reaction categories.
    declared = {c['key'] for c in cats if is_nonempty_str(c.get('key'))}
    for c in cats:
        p = c.get('parent')
        if is_nonempty_str(p) and p not in declared:
            if p.startswith(prefix + 'CAT_'):
                warn('category_parent',
                     "categories (%s).parent is %r, the full prefixed ID. This "
                     "works, because an unrecognised parent is passed through "
                     "unchanged, but the documented form is the bare key."
                     % (c.get('key'), p))
            else:
                warn('category_parent',
                     "categories (%s).parent %r is not declared here. Legal if "
                     "it names a category that already exists. Note parent "
                     "takes the BARE key, unlike a reaction's category field."
                     % (c.get('key'), p))


# ===============================================================
# FILE DISCOVERY
# ===============================================================
def autodiscover(folder):
    """Find one materials file and one reactions file in a folder."""
    mats = sorted(glob.glob(os.path.join(folder, '*_materials.json')))
    rxns = sorted(glob.glob(os.path.join(folder, '*_reactions.json')))
    if len(mats) != 1 or len(rxns) != 1:
        return None, None, (
            "Found %d materials file(s) and %d reactions file(s) in %s.\n"
            "Expected exactly one of each named <something>_materials.json and\n"
            "<something>_reactions.json, or pass the paths as arguments."
            % (len(mats), len(rxns), os.path.abspath(folder)))
    return mats[0], rxns[0], None


def load(path, what):
    if not os.path.exists(path):
        print("Cannot find %s: %s" % (path, what))
        sys.exit(2)
    try:
        return json.load(open(path, encoding='utf-8'))
    except json.JSONDecodeError as e:
        print("%s is not valid JSON: %s" % (path, e))
        print("Fix the syntax error before running preflight again.")
        sys.exit(2)


# ===============================================================
# MAIN
# ===============================================================
def main():
    ap = argparse.ArgumentParser(
        description="Offline schema check for RM module JSON files.")
    ap.add_argument('materials', nargs='?',
                    help="materials JSON (auto-discovered if omitted)")
    ap.add_argument('reactions', nargs='?',
                    help="reactions JSON (auto-discovered if omitted)")
    ap.add_argument('--types', default='refinish-module-types.lua',
                    help="path to refinish-module-types.lua from your RM install")
    ap.add_argument('--verbose', action='store_true',
                    help="print every warning instead of the first few per group")
    ap.add_argument('--strict', action='store_true',
                    help="treat warnings as failures")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))

    types_path = args.types
    if not os.path.exists(types_path):
        alt = os.path.join(here, os.path.basename(types_path))
        if os.path.exists(alt):
            types_path = alt
        else:
            print("Cannot find %s." % args.types)
            print("Copy refinish-module-types.lua from your Refinish Metal install")
            print("into this folder, or pass --types with its path.")
            sys.exit(2)

    mats_path, rxns_path = args.materials, args.reactions
    if not mats_path or not rxns_path:
        mats_path, rxns_path, problem = autodiscover(here)
        if problem:
            print(problem)
            sys.exit(2)

    engine = load_engine_types(types_path)
    if not engine['reagents'] or not engine['buildings']:
        print("Parsed %s but found no type tables in it." % types_path)
        print("Check that it is a complete, current copy from your RM install.")
        sys.exit(2)

    mats_doc = load(mats_path, "this module's materials file")
    rxns_doc = load(rxns_path, "this module's reactions file")

    mats_label = os.path.basename(mats_path)
    rxns_label = os.path.basename(rxns_path)

    # ---- module identity, per file then cross-checked ----
    mats_prefix = check_module_block(mats_doc, mats_label)
    rxns_prefix = check_module_block(rxns_doc, rxns_label)
    if mats_prefix and rxns_prefix and mats_prefix != rxns_prefix:
        err("module.prefix disagrees between files: %s has %r, %s has %r. "
            "The engine rejects the module on this."
            % (mats_label, mats_prefix, rxns_label, rxns_prefix))

    # ---- content ----
    mats = check_materials(mats_doc, engine, mats_label)
    rxns = check_reactions(rxns_doc, engine, rxns_label)
    cats = check_categories(rxns_doc, rxns_label)

    if mats_prefix:
        check_cross_references(mats_prefix, mats, rxns, cats)

    # ---- report ----
    print("engine tables from %s: %d reagent types, %d product types, "
          "%d buildings, %d skills, %d material classes"
          % (os.path.basename(types_path), len(engine['reagents']),
             len(engine['products']), len(engine['buildings']),
             len(engine['skills']), len(engine['classes'])))
    print("checked %s and %s" % (mats_label, rxns_label))

    if WARNINGS:
        # Group by kind. A 950-reaction module can produce hundreds of the
        # same warning, and a flat dump buries the one that matters.
        groups = {}
        for kind, msg in WARNINGS:
            groups.setdefault(kind, []).append(msg)

        print("\n%d warning(s) in %d group(s). Warnings do not fail the run."
              % (len(WARNINGS), len(groups)))
        for kind in sorted(groups):
            msgs = groups[kind]
            print("\n  [%s] %d" % (kind, len(msgs)))
            shown = msgs if args.verbose else msgs[:3]
            for m in shown:
                print("    - " + m)
            if len(msgs) > len(shown):
                print("    ... and %d more (run with --verbose to see all)"
                      % (len(msgs) - len(shown)))

    if ERRORS:
        print("\nPREFLIGHT FAILED: %d error(s):\n" % len(ERRORS))
        for e in ERRORS[:40]:
            print("  " + e)
        if len(ERRORS) > 40:
            print("  ... and %d more" % (len(ERRORS) - 40))
        sys.exit(1)

    if WARNINGS and args.strict:
        print("\nPREFLIGHT FAILED: warnings treated as errors (--strict).")
        sys.exit(1)

    print("\nPREFLIGHT PASSED: %d materials, %d reactions, %d categories"
          % (len(mats), len(rxns), len(cats)))
    sys.exit(0)


if __name__ == '__main__':
    main()
