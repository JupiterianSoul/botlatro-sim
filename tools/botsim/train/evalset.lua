local M = {}

M.DECKS = {"b_red", "b_blue", "b_yellow", "b_black"}
M.STAKES = {1, 3}
M.ALL_DECKS = {"b_red", "b_blue", "b_yellow", "b_green", "b_black", "b_magic", "b_nebula", "b_ghost", "b_abandoned", "b_checkered",
    "b_zodiac", "b_painted", "b_anaglyph", "b_plasma", "b_erratic"}

local function list(v, default, num)
    if v == nil or v == "" then return default end
    if v == "all" then return M.ALL_DECKS end
    local out = {}
    for x in tostring(v):gmatch("[^,]+") do out[#out + 1] = num and tonumber(x) or x end
    return out
end

function M.parse(decks, stakes)
    return list(decks, M.DECKS), list(stakes, M.STAKES, true)
end

function M.cells(per, decks, stakes)
    local out = {}
    for _, d in ipairs(decks or M.DECKS) do
        for _, st in ipairs(stakes or M.STAKES) do
            out[#out + 1] = {deck = d, stake = st, per = per}
        end
    end
    return out
end

function M.seed(deck, stake, k)
    return string.format("EV_%s_%d_%d", deck, stake, k)
end

function M.name(per, decks, stakes)
    decks, stakes = decks or M.DECKS, stakes or M.STAKES
    local n = #decks * #stakes * per
    if decks == M.DECKS and stakes == M.STAKES then return "fixed-" .. n end
    return string.format("d%d-s%s-%d", #decks, table.concat(stakes, ""), n)
end

return M
