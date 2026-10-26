local T = ...
local E = require("bot.sim.engine")
local ST = require("bot.sim.state")
local D = require("bot.sim.data")

local function to_shop(s)
    E.step(s, {type = "select"})
    s.blind_chips = 1
    local guard = 0
    while s.phase == "play" and guard < 20 do
        E.step(s, {type = "play", cards = {1, 2, 3, 4, 5}})
        guard = guard + 1
    end
    if s.phase == "round_eval" then E.step(s, {type = "cash_out"}) end
end

local s = E.new_run({seed = "ECON0001", deck = "b_red", stake = 1})
T.eq(s.orb_a1, 1, "orbital hands rolled for ante 1 at run start")
T.ok(s.orb_s > 0 and s.orb_b > 0, "orbital hands chosen")
s.chips = 0
s.money = 100
to_shop(s)
T.eq(s.phase, "shop", "reached the shop")
if s.phase == "shop" then
    T.eq(s.n_sj, 2, "two cards in the shop row")
    T.eq(s.n_sv, 1, "one voucher")
    T.eq(s.n_sb, 2, "two boosters")
    T.eq(D.BOOST[s.sb_id[1]].kind, "Buffoon", "first shop booster is a buffoon pack")
    local money = s.money
    local rc = s.reroll_cost
    T.ok(E.step(s, {type = "reroll"}), "reroll")
    T.eq(s.money, money - rc, "reroll paid")
    T.eq(s.reroll_cost, rc + 1, "reroll cost goes up")
    local a = ST.clone(s)
    local b = ST.clone(s)
    E.step(a, {type = "reroll"})
    E.step(b, {type = "reroll"})
    for i = 1, a.n_sj do T.eq(a.sj_id[i], b.sj_id[i], "reroll is deterministic") end
    local cost = E.shop_booster_cost(s, 1)
    money = s.money
    T.ok(E.step(s, {type = "open", card = 1}), "open booster")
    T.eq(s.phase, "pack", "in pack")
    T.eq(s.money, money - cost, "pack paid")
    T.eq(s.n_pk, 2, "buffoon pack has two jokers")
    local nj = s.n_jok
    T.ok(E.step(s, {type = "pick", card = 1}), "pick a joker")
    T.eq(s.n_jok, nj + 1, "joker added")
    T.eq(s.phase, "shop", "back in the shop")
    T.eq(s.up1, -1, "first booster slot used")
    local v = E.shop_joker_cost
    for i = 1, s.n_sj do T.ok(v(s, i) >= 0, "shop cost") end
    T.ok(E.step(s, {type = "leave"}), "leave shop")
    T.eq(s.shop_on, 0, "shop closed")
    T.eq(s.n_sj, 0, "shop row cleared")
end

s = E.new_run({seed = "ECON0002", deck = "b_red", stake = 1, challenge = "c_knife_1"})
T.eq(s.resets_discards, 3, "challenge deck has no red deck discard")
T.eq(s.n_jok, 1, "knife starts with a joker")
T.eq(s.j_eternal[1], 1, "knife joker is eternal")
T.eq(s.j_pin[1], 1, "knife joker is pinned")
s = E.new_run({seed = "ECON0003", deck = "b_red", stake = 1, challenge = "c_omelette_1"})
T.eq(s.n_jok, 5, "omelette has five eggs")
T.eq(s.no_interest, 1, "omelette has no interest")
T.ok(s.ban ~= 0 and s.ban.j_golden, "omelette bans golden joker")

s = E.new_run({seed = "ECON0004", deck = "b_magic", stake = 1})
T.eq(s.n_cons, 2, "magic deck fools")
E.step(s, {type = "select"})
T.ok(not E.step(s, {type = "use", card = 1}), "fool needs a last tarot or planet")
s.last_tp = D.CONS_ID.c_mercury
T.ok(E.step(s, {type = "use", card = 1}), "fool works after a planet")
T.eq(s.cons[s.n_cons], "c_mercury", "fool copies the last planet")
T.ok(E.step(s, {type = "use", card = s.n_cons}), "use mercury")
T.eq(s.h_level[D.HAND_ID.Pair], 2, "mercury levels pair")
T.eq(s.planets_used, 1, "planet counted once")

s = E.new_run({seed = "ECON0005", deck = "b_red", stake = 1})
E.add_joker(s, "j_campfire")
E.add_joker(s, "j_joker")
E.step(s, {type = "select"})
local money = s.money
local sell = E.joker_sell(s, 2)
T.ok(E.step(s, {type = "sell", area = "jokers", card = 2}), "sell joker")
T.eq(s.money, money + sell, "sell value paid")
T.near(s.j_x[1], 1.25, "campfire grows on sell")
T.ok(E.step(s, {type = "reorder_jokers", order = {1}}), "reorder one joker")
E.add_joker(s, "j_joker")
T.ok(E.step(s, {type = "reorder_jokers", order = {2, 1}}), "reorder")
T.eq(D.JOKERS[s.j_id[1]].key, "j_joker", "joker moved first")

local golden = {
    "5H", "AS", "7H", "TD", "8S", "3H", "6H", "8H", "6C", "AC", "3D", "9S", "TS",
    "7C", "2D", "3S", "4C", "AD", "5C", "5D", "8C", "TC", "7D", "6S", "3C", "4D",
    "6D", "7S", "TH", "8D", "9C", "4S", "AH", "5S", "4H", "2C", "9D", "2H", "9H",
    "2S",
}
s = E.new_run({seed = "QFCIQ6C1", deck = "b_abandoned", stake = 1})
local same = true
for i = 1, #golden do
    local cid = s.deck[s.n_deck - i + 1]
    if D.RANK_CHARS[s.c_rank[cid]] .. D.SUIT_CHARS[s.c_suit[cid]] ~= golden[i] then same = false end
end
T.ok(same, "starting deck equals the real game's (this LuaJIT's math.random matches LOVE 11.5)")

local rng = require("bot.sim.rng")
if rng.port then
    local bad, src = 0, 777
    for i = 1, 20000 do
        src = (src * 1103515245 + 12345) % 2147483648
        local x = src / 2147483648
        math.randomseed(x)
        rng.seed_raw(x)
        local n = 1 + i % 52
        if math.random(n) ~= rng.random_raw(n) or math.random() ~= rng.random_raw() then bad = bad + 1 end
    end
    T.eq(bad, 0, "FFI random port equals this LuaJIT's math.random")
end

s = E.new_run({seed = "TAIL0001", deck = "b_red", stake = 1})
local big = ST.clone(s)
E.step(s, {type = "select"})
local scratch = ST.scratch()
ST.copy_into(scratch, big)
ST.copy_into(scratch, s)
T.eq(#scratch.deck, s.n_deck, "copy_into clears the deck tail")
T.eq(#scratch.hand, s.n_hand, "copy_into hand length")
local nr = 0
for _ in pairs(scratch.rng) do nr = nr + 1 end
T.eq(nr, s.n_rk, "copy_into copies only used rng keys")
