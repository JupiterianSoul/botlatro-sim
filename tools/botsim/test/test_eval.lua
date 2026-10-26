local T = ...
local EV = require("bot.sim.eval")
local E = require("bot.sim.engine")
local H = dofile("tools/botsim/test/helpers.lua")
local D = require("bot.sim.data")

local function check(str, want, want_scoring, flags)
    local s = H.blank()
    local cs = H.cards(s, str)
    flags = flags or {}
    local top = EV.evaluate(s, cs, #cs, flags.ff, flags.sc, flags.sm, flags.sp)
    T.eq(D.HAND_NAMES[top] or "none", want, str)
    if want_scoring then
        local got = {}
        for i = 1, #cs do got[i] = EV.scoring[i] and "1" or "0" end
        T.eq(table.concat(got), want_scoring, str .. " scoring")
    end
    return s
end

check("AS", "High Card", "1")
check("AS KH 9D 4C 2S", "High Card", "10000")
check("2S KH 9D 4C 3S", "High Card", "01000")
check("AS AH 9D 4C 2S", "Pair", "11000")
check("AS AH 9D 9C 2S", "Two Pair", "11110")
check("AS AH AD 9C 2S", "Three of a Kind", "11100")
check("AS 2H 3D 4C 5S", "Straight", "11111")
check("TS JH QD KC AS", "Straight", "11111")
check("KS AH 2D 3C 4S", "High Card", "01000")
check("AS 9S 7S 4S 2S", "Flush", "11111")
check("AS AH AD 9C 9S", "Full House", "11111")
check("AS AH AD AC 9S", "Four of a Kind", "11110")
check("9S TS JS QS KS", "Straight Flush", "11111")
check("AS AH AD AC AS", "Five of a Kind", "11111")
check("AS AS AS 9S 9S", "Flush House", "11111")
check("AS AS AS AS AS", "Flush Five", "11111")
check("AS 9S 7S 4S", "High Card", "1000")
check("AS 9S 7S 4S 2H", "Flush", "11110", {ff = true})
check("AS 9S 7S 4S", "Flush", "1111", {ff = true})
check("5S 6H 7D 8C KS", "Straight", "11110", {ff = true})
check("2S 4H 6D 8C TS", "Straight", "11111", {sc = true})
check("2S 4H 6D 8C TS", "High Card", "00001")
check("AH 9D 7H 4D 2H", "Flush", "11111", {sm = true})
check("AH 9D 7H 4D 2H", "High Card", "10000")
check("AH 9H:m_wild 7H 4H 2S:m_wild", "Flush", "11111")
check("AH AD 7H 4C 2S:m_stone", "Pair", "11001")
check("AH AD 7H 4C 2S", "Pair", "11111", {sp = true})
check("2S:m_stone 3S:m_stone", "High Card", "11")
check("AS AH 9D 9C 9S", "Full House", "11111")
check("7S 7H 7D 7C", "Four of a Kind", "1111")

do
    local s = check("AS AH AD AC 9S", "Four of a Kind")
    T.ok(EV.present[9] and EV.present[11] and not EV.present[10], "four of a kind contains three and pair, not two pair")
    s = check("AS AH AD 9C 9S", "Full House")
    T.ok(EV.present[10] and EV.present[11] and EV.present[9], "full house contains two pair")
    local _ = s
end

do
    local s = H.blank()
    local cs = H.cards(s, "2S 2H 2D KS KH QD AC")
    for i, cid in ipairs(cs) do s.hand[i] = cid end
    s.n_hand = #cs
    E.sort_hand(s)
    local names = {}
    for i = 1, s.n_hand do
        local cid = s.hand[i]
        names[i] = D.RANK_CHARS[s.c_rank[cid]] .. D.SUIT_CHARS[s.c_suit[cid]]
    end
    T.eq(table.concat(names, " "), "AC KS KH QD 2S 2H 2D", "hand sort desc by rank then suit")
end
