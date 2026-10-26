local T = ...
local E = require("bot.sim.engine")
local D = require("bot.sim.data")

local function boss_round(boss, jokers, seed)
    local s = E.new_run({seed = seed or "BLINDS01", deck = "b_red", stake = 1})
    for _, j in ipairs(jokers or {}) do E.add_joker(s, j) end
    s.boss_choice = D.BLIND_ID[boss]
    E.step(s, {type = "skip"})
    E.step(s, {type = "skip"})
    s.money = 4
    T.ok(E.step(s, {type = "select"}), boss .. " select")
    T.eq(s.blind, D.BLIND_ID[boss], boss .. " active")
    return s
end

local function count(s, arr, pred)
    local n = 0
    for i = 1, #arr do if pred(arr[i]) then n = n + 1 end end
    return n
end

local function all_cards(s)
    local t = {}
    for c = 1, s.n_cards do if s.c_alive[c] == 1 then t[#t + 1] = c end end
    return t
end

local s = boss_round("bl_water")
T.eq(s.discards_left, 0, "water discards")
s = boss_round("bl_needle")
T.eq(s.hands_left, 1, "needle hands")
s = boss_round("bl_manacle")
T.eq(s.hand_size, 7, "manacle hand size")
T.eq(s.n_hand, 7, "manacle drawn")
s = boss_round("bl_wall")
T.eq(s.blind_chips, 1200, "wall target")
s = boss_round("bl_final_vessel")
T.eq(s.blind_chips, 1800, "vessel target")
s = boss_round("bl_club")
T.eq(count(s, all_cards(s), function(c) return s.c_debuff[c] == 1 end), 13, "club debuffs 13 cards")
s = boss_round("bl_plant")
T.eq(count(s, all_cards(s), function(c) return s.c_debuff[c] == 1 end), 12, "plant debuffs faces")
s = boss_round("bl_plant", {"j_pareidolia"})
T.eq(count(s, all_cards(s), function(c) return s.c_debuff[c] == 1 end), 52, "plant with pareidolia debuffs all")
s = boss_round("bl_final_leaf")
T.eq(count(s, all_cards(s), function(c) return s.c_debuff[c] == 1 end), 52, "leaf debuffs all")
s = boss_round("bl_house")
T.eq(count(s, s.hand, function(c) return s.c_flip[c] == 1 end), 8, "house flips first hand")
s = boss_round("bl_mark")
local faces = count(s, s.hand, function(c) return s.c_rank[c] >= 11 and s.c_rank[c] <= 13 end)
T.eq(count(s, s.hand, function(c) return s.c_flip[c] == 1 end), faces, "mark flips faces")
s = boss_round("bl_final_bell")
T.eq(count(s, s.hand, function(c) return s.c_forced[c] == 1 end), 1, "bell forces one card")
local forced
for i = 1, s.n_hand do if s.c_forced[s.hand[i]] == 1 then forced = i end end
local other = forced == 1 and 2 or 1
T.eq(E.step(s, {type = "play", cards = {other}}), false, "bell requires forced card")
T.eq(E.step(s, {type = "play", cards = {forced}}), true, "bell allows forced card")
s = boss_round("bl_final_heart", {"j_joker", "j_mime"})
T.eq(s.j_debuff[1] + s.j_debuff[2], 1, "crimson heart debuffs one joker")
s = boss_round("bl_final_acorn", {"j_joker", "j_mime", "j_duo"})
T.eq(s.j_flip[1] + s.j_flip[2] + s.j_flip[3], 3, "acorn flips jokers")
s = boss_round("bl_hook")
E.step(s, {type = "play", cards = {1}})
T.eq(s.n_disc, 3, "hook discards two")
s = boss_round("bl_serpent")
E.step(s, {type = "play", cards = {1, 2}})
T.eq(s.n_hand, 9, "serpent draws three even past hand size")
s = boss_round("bl_fish")
E.step(s, {type = "play", cards = {1, 2}})
T.eq(count(s, s.hand, function(c) return s.c_flip[c] == 1 end), 2, "fish flips drawn cards")
s = boss_round("bl_mouth")
local function find_pair(st)
    for i = 1, st.n_hand do
        for j = i + 1, st.n_hand do
            if st.c_rank[st.hand[i]] == st.c_rank[st.hand[j]] then return {i, j} end
        end
    end
end
local ok1, g1 = E.play(s, {1})
T.ok(ok1 and g1 > 0, "mouth first hand scores")
local pr = find_pair(s)
if pr then
    local _, g2 = E.play(s, pr)
    T.eq(g2, 0, "mouth blocks other hand type")
end
s = E.new_run({seed = "PILLAR01", deck = "b_red", stake = 1})
s.boss_choice = D.BLIND_ID.bl_pillar
E.step(s, {type = "select"})
s.blind_chips = 1
local played = s.hand[1]
E.step(s, {type = "play", cards = {1}})
E.step(s, {type = "cash_out"})
E.step(s, {type = "leave"})
E.step(s, {type = "skip"})
E.step(s, {type = "select"})
T.eq(s.c_debuff[played], 1, "pillar debuffs card played this ante")
do
    local st = E.new_run({seed = "EMPTYDK1", deck = "b_red", stake = 1})
    E.step(st, {type = "select"})
    st.blind_chips = 1e12
    st.hands_left = 99
    st.discards_left = 99
    local guard = 0
    while st.phase == "play" and guard < 100 do
        local c = {}
        for i = 1, math.min(5, st.n_hand) do c[i] = i end
        E.step(st, {type = "discard", cards = c})
        guard = guard + 1
    end
    T.eq(st.phase, "game_over", "empty deck and hand ends the round")
end
