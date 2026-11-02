local J = require("bot.sim.data_jokers")
local C = require("bot.sim.data_centers")
local D = require("bot.sim.data")
local N = require("botsim.book.notes")
local A = require("botsim.book.archetypes")

local K = {}

K.EDITIONS = {"e_foil", "e_holo", "e_polychrome", "e_negative"}
K.STICKERS = {"eternal", "perishable", "rental"}
K.STAKES = N.stake_levels
K.BOOSTER_KINDS = {"arcana", "celestial", "standard", "buffoon", "spectral"}
K.BOOSTER_SIZES = {"normal", "jumbo", "mega"}

local function copy_fields(dst, src, fields)
    for _, f in ipairs(fields) do
        if src[f] ~= nil then dst[f] = src[f] end
    end
end

local function merge(data, note)
    local o = {}
    for k, v in pairs(note or {}) do o[k] = v end
    if data then
        copy_fields(o, data, {"key", "name", "cost", "rarity", "config", "effect", "set", "order", "kind", "weight", "boss", "dollars", "mult", "min_ante", "requires"})
        if data.kind and note and note.kind then o.kind = note.kind end
    end
    return o
end

local function bykey(list)
    local m = {}
    for _, e in ipairs(list) do m[e.key] = e end
    return m
end

local function booster_parts(key)
    local kind, size = key:match("^p_(%a+)_(%a+)_%d+$")
    return kind, size
end

function K.categories()
    local cats = {}
    local function add(name, keys, notes, datamap)
        cats[#cats + 1] = {name = name, keys = keys, notes = notes, data = datamap or {}}
    end
    local function keys_of(list)
        local o = {}
        for _, e in ipairs(list) do o[#o + 1] = e.key end
        return o
    end
    add("joker", keys_of(J), N.jokers, bykey(J))
    local tarots, planets, spectrals = keys_of(C.Tarot), keys_of(C.Planet), keys_of(C.Spectral)
    add("tarot", tarots, N.consumables, bykey(C.Tarot))
    add("planet", planets, N.consumables, bykey(C.Planet))
    add("spectral", spectrals, N.consumables, bykey(C.Spectral))
    add("voucher", keys_of(C.Voucher), N.vouchers, bykey(C.Voucher))
    add("tag", keys_of(C.Tag), N.tags, bykey(C.Tag))
    local boss, normal, bm = {}, {}, {}
    for _, b in ipairs(D.BLINDS) do
        bm[b.key] = b
        if b.boss then boss[#boss + 1] = b.key else normal[#normal + 1] = b.key end
    end
    add("boss", boss, N.blinds, bm)
    add("normal_blind", normal, N.blinds, bm)
    local decks = {}
    for k in pairs(D.DECKS) do decks[#decks + 1] = k end
    table.sort(decks)
    add("deck", decks, N.decks)
    add("stake", K.STAKES, N.stakes)
    add("hand", D.HAND_NAMES, N.hands)
    add("seal", D.SEAL_KEYS, N.seals)
    add("edition", K.EDITIONS, N.editions)
    add("enhancement", keys_of(C.Enhanced), N.enhancements, bykey(C.Enhanced))
    add("booster", keys_of(C.Booster), nil, bykey(C.Booster))
    add("booster_kind", K.BOOSTER_KINDS, N.boosters)
    add("booster_size", K.BOOSTER_SIZES, N.booster_sizes)
    add("sticker", K.STICKERS, N.stickers)
    return cats
end

local function note_for(cat, key)
    if cat.name == "booster" then
        local kind, size = booster_parts(key)
        local kn, sn = N.boosters[kind], N.booster_sizes[size]
        if not kn or not sn then return nil end
        return {
            what = kn.what .. " " .. sn.what, when = kn.when .. " " .. sn.when,
            combos = kn.combos, archetypes = kn.archetypes, src = "guess", booster_kind = kind, booster_size = size,
        }
    end
    return cat.notes[key]
end

function K.build()
    local errors, book, counts = {}, {}, {}
    local known = {}
    local cats = K.categories()
    for _, cat in ipairs(cats) do
        counts[cat.name] = #cat.keys
        local out = {}
        for _, key in ipairs(cat.keys) do
            known[key] = true
            local n = note_for(cat, key)
            if not n then
                errors[#errors + 1] = "no note for " .. cat.name .. " " .. key
            else
                out[key] = merge(cat.data[key], n)
            end
        end
        book[cat.name] = out
        if cat.notes then
            local want = {}
            for _, key in ipairs(cat.keys) do want[key] = true end
            local shared = cat.name == "tarot" or cat.name == "planet" or cat.name == "spectral"
            if not shared then
                for key in pairs(cat.notes) do
                    if not want[key] and not (cat.name == "boss" or cat.name == "normal_blind") then
                        errors[#errors + 1] = "note key not in data: " .. cat.name .. " " .. key
                    end
                end
            end
        end
    end
    local blind_keys = {}
    for _, b in ipairs(D.BLINDS) do blind_keys[b.key] = true end
    for key in pairs(N.blinds) do
        if not blind_keys[key] then errors[#errors + 1] = "note key not in data: blind " .. key end
    end
    local cons = {}
    for _, t in ipairs{C.Tarot, C.Planet, C.Spectral} do for _, e in ipairs(t) do cons[e.key] = true end end
    for key in pairs(N.consumables) do
        if not cons[key] then errors[#errors + 1] = "note key not in data: consumable " .. key end
    end
    for _, c in ipairs(cats) do
        for _, key in ipairs(c.keys) do known[key] = true end
    end
    for _, t in ipairs{C.Enhanced} do for _, e in ipairs(t) do known[e.key] = true end end
    local prefixes = {"j_", "c_", "v_", "m_", "tag_", "b_", "bl_", "e_", "s_", "p_"}
    local function is_key(s)
        for _, p in ipairs(prefixes) do
            if s:sub(1, #p) == p then return true end
        end
        return false
    end
    local function check_list(owner, list)
        for _, c in ipairs(list or {}) do
            if is_key(c) then
                if not known[c] then errors[#errors + 1] = owner .. ": unknown combo key " .. c end
            elseif not A[c] then
                errors[#errors + 1] = owner .. ": unknown archetype or combo " .. c
            end
        end
    end
    for cname, out in pairs(book) do
        for key, e in pairs(out) do
            check_list(cname .. " " .. key, e.combos)
            for _, a in ipairs(e.archetypes or {}) do
                if not A[a] then errors[#errors + 1] = cname .. " " .. key .. ": unknown archetype " .. a end
            end
        end
    end
    for name, a in pairs(A) do
        for _, f in ipairs{"key_jokers", "support_jokers", "consumables", "vouchers", "decks"} do
            for _, k in ipairs(a[f]) do
                if not known[k] then errors[#errors + 1] = "archetype " .. name .. ": unknown key " .. k end
            end
        end
    end
    for key, r in pairs(N.rules) do
        check_list("rule " .. key, r.combos)
    end
    for key, e in pairs(book.joker or {}) do
        if not e.kind then errors[#errors + 1] = "joker " .. key .. " has no kind" end
    end
    table.sort(errors)
    return book, counts, errors, cats
end

return K
