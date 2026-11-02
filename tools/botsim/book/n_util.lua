local U = {}

local HM = {
    HC = "High Card", P = "Pair", TP = "Two Pair", ["3K"] = "Three of a Kind", ST = "Straight",
    FL = "Flush", FH = "Full House", ["4K"] = "Four of a Kind", SF = "Straight Flush",
    ["5K"] = "Five of a Kind", FHF = "Flush House", FF = "Flush Five",
}
U.HM = HM

local function split(s)
    local out = {}
    if not s or s == "" then return out end
    for w in s:gmatch("[^,]+") do out[#out + 1] = w end
    return out
end

local function hands(s)
    local out = {}
    for _, c in ipairs(split(s)) do out[#out + 1] = assert(HM[c], "bad hand code " .. c) end
    return out
end

function U.joker(t)
    local o = {
        what = t[3], when = t[4], kind = t[2], src = "guess",
        combos = split(t.c), hands = hands(t.h), archetypes = split(t.a),
    }
    if t.suit then o.suit = t.suit end
    if t.rank then o.rank = t.rank end
    if t.scale then o.scale = t.scale end
    return t[1], o
end

function U.item(t)
    return t[1], {what = t[2], when = t[3], combos = split(t.c), archetypes = split(t.a), src = "guess"}
end

function U.build(list, fn)
    local out = {}
    for _, t in ipairs(list) do
        local k, v = fn(t)
        assert(not out[k], "duplicate " .. k)
        out[k] = v
    end
    return out
end

return U
