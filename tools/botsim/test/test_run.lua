local T = ...
local E = require("bot.sim.engine")
local ST = require("bot.sim.state")
local D = require("bot.sim.data")
local SN = require("bot.sim.snapshot")
local P = require("botsim.policy")

local s = E.new_run({seed = "AAAA1111", deck = "b_abandoned", stake = 1})
T.eq(s.n_deck, 40, "abandoned deck size")
s = E.new_run({seed = "AAAA1111", deck = "b_checkered", stake = 1})
local bad = 0
for c = 1, s.n_cards do if s.c_suit[c] == 3 or s.c_suit[c] == 4 then bad = bad + 1 end end
T.eq(bad, 0, "checkered deck only spades and hearts")
s = E.new_run({seed = "AAAA1111", deck = "b_painted", stake = 1})
T.eq(s.hand_size, 10, "painted hand size")
T.eq(s.joker_limit, 4, "painted joker slots")
s = E.new_run({seed = "AAAA1111", deck = "b_black", stake = 1})
T.eq(s.resets_hands, 3, "black deck hands")
T.eq(s.joker_limit, 6, "black deck jokers")
s = E.new_run({seed = "AAAA1111", deck = "b_red", stake = 5})
T.eq(s.resets_discards, 3, "red deck blue stake discards")
s = E.new_run({seed = "AAAA1111", deck = "b_yellow", stake = 1})
T.eq(s.money, 14, "yellow deck money")
s = E.new_run({seed = "AAAA1111", deck = "b_magic", stake = 1})
T.eq(s.cons_limit, 3, "magic deck crystal ball")
T.eq(s.n_cons, 2, "magic deck fools")
s = E.new_run({seed = "AAAA1111", deck = "b_erratic", stake = 1})
T.eq(s.n_deck, 52, "erratic deck size")

s = E.new_run({seed = "AAAA1111", deck = "b_red", stake = 1})
T.eq(E.get_blind_amount(s, 1), 300, "ante 1 base")
T.eq(E.get_blind_amount(s, 8), 50000, "ante 8 base")
T.eq(E.get_blind_amount(s, 9), 110000, "ante 9 base")
T.eq(E.get_blind_amount(s, 10), 560000, "ante 10 base")
s.scaling = 3
T.eq(E.get_blind_amount(s, 2), 1000, "gold stake ante 2")
s = E.new_run({seed = "AAAA1111", deck = "b_plasma", stake = 1})
E.step(s, {type = "select"})
T.eq(s.blind_chips, 600, "plasma small blind")
s = E.new_run({seed = "AAAA1111", deck = "b_red", stake = 2})
E.step(s, {type = "select"})
T.eq(s.blind_dollars, 0, "red stake no small reward")

local function play_run(seed, deck, stake, max_steps, log)
    local st = E.new_run({seed = seed, deck = deck, stake = stake})
    local steps = 0
    while st.phase ~= "game_over" and st.won == 0 and steps < max_steps do
        local a = P.choose(st)
        if not a then break end
        if log then log[#log + 1] = a end
        local ok = E.step(st, a)
        if not ok then return st, false, a end
        steps = steps + 1
    end
    return st, true
end

local decks = {"b_red", "b_blue", "b_yellow", "b_green", "b_black", "b_magic", "b_nebula", "b_ghost", "b_abandoned",
    "b_checkered", "b_zodiac", "b_painted", "b_anaglyph", "b_plasma", "b_erratic"}
local all_ok = true
for i, deck in ipairs(decks) do
    for stake = 1, 8, 7 do
        local _, ok, a = play_run("RUN" .. i .. "S" .. stake, deck, stake, 400)
        if not ok then
            all_ok = false
            print("illegal action", deck, stake, a.type)
        end
    end
end
T.ok(all_ok, "greedy runs on every deck finish with legal actions")

local log = {}
local st1 = play_run("CLONE001", "b_red", 1, 25, log)
local snap1 = SN.line(st1)
local st2 = E.new_run({seed = "CLONE001", deck = "b_red", stake = 1})
for i = 1, 10 do E.step(st2, log[i]) end
local c = ST.clone(st2)
for i = 11, #log do E.step(c, log[i]) end
T.eq(SN.line(c), snap1, "clone mid-run replays to the same snapshot")
for i = 11, #log do E.step(st2, log[i]) end
T.eq(SN.line(st2), snap1, "original replays to the same snapshot")

local json = require("bot.sim.json")
local dec = json.decode(snap1)
T.eq(dec.step, st1.step, "snapshot json roundtrip step")
T.eq(#dec.hand, st1.n_hand, "snapshot hand length")
T.ok(dec.rng.shuffle ~= nil, "snapshot has rng shuffle")
T.eq(D.HAND_NAMES[12], "High Card", "hand names")
