local T = ...
local E = require("bot.sim.engine")
local D = require("bot.sim.data")

local function fight(boss, opts)
    opts = opts or {}
    local s = E.new_run({seed = opts.seed or "FINAL001", deck = opts.deck or "b_red", stake = opts.stake or 8})
    E.step(s, {type = "skip"})
    E.step(s, {type = "skip"})
    s.ante = opts.ante or 8
    for _, j in ipairs(opts.jokers or {}) do
        if type(j) == "table" then E.add_joker(s, j[1], nil, j[2]) else E.add_joker(s, j) end
    end
    s.boss_choice = D.BLIND_ID[boss]
    s.money = opts.money or 0
    T.ok(E.step(s, {type = "select"}), boss .. " select")
    T.eq(s.blind, D.BLIND_ID[boss], boss .. " active")
    return s
end

local function last_hand(s, part)
    s.hands_left = 1
    s.chips = s.blind_chips * part
    return E.step(s, {type = "play", cards = {1}})
end

local function has(s, key)
    for k = 1, s.n_jok do
        if s.j_id[k] == D.JOKER_ID[key] then return k end
    end
end

local BOSSES = {"bl_final_acorn", "bl_final_leaf", "bl_final_vessel", "bl_final_bell", "bl_final_heart"}

for _, boss in ipairs(BOSSES) do
    local s = fight(boss)
    T.ok(last_hand(s, 1), boss .. " winning hand accepted")
    T.eq(s.phase, "win", boss .. " beaten ends in win")
    T.eq(s.won, 1, boss .. " beaten sets won")
    T.eq(s.game_over, 0, boss .. " beaten is not game over")
    T.eq(s.ante, 9, boss .. " beaten moves past ante 8")

    s = fight(boss)
    local need = s.blind_chips
    T.ok(last_hand(s, 0.5), boss .. " losing hand accepted")
    T.eq(s.phase, "game_over", boss .. " lost ends in game over")
    T.eq(s.won, 0, boss .. " lost does not set won")
    T.eq(s.game_over, 1, boss .. " lost is game over")
    T.eq(s.ante, 8, boss .. " lost stays on ante 8")
    T.eq(s.blind_chips, need, boss .. " lost keeps the target")
end

do
    local s = fight("bl_final_acorn", {jokers = {"j_mr_bones", "j_joker"}})
    T.ok(last_hand(s, 0.3), "bones hand accepted")
    T.eq(s.phase, "win", "bones at 30 percent wins the final boss")
    T.eq(s.won, 1, "bones win sets won")
    T.eq(has(s, "j_mr_bones"), nil, "bones is used up")
    T.ok(has(s, "j_joker"), "other joker stays")
    T.eq(s.n_jok, 1, "one joker left")

    s = fight("bl_final_acorn", {jokers = {"j_mr_bones"}})
    last_hand(s, 0.1)
    T.eq(s.phase, "game_over", "bones under a quarter does not save")
    T.eq(s.won, 0, "bones under a quarter is no win")
    T.ok(has(s, "j_mr_bones"), "bones stays when it did not save")

    s = fight("bl_final_heart", {jokers = {"j_mr_bones"}})
    T.eq(s.j_debuff[1], 1, "heart debuffs a lone joker")
    last_hand(s, 0.3)
    T.eq(s.phase, "game_over", "debuffed bones does not save")
    T.eq(s.won, 0, "debuffed bones is no win")

    s = fight("bl_final_leaf", {jokers = {"j_mr_bones", "j_mr_bones"}})
    last_hand(s, 0.3)
    T.eq(s.phase, "win", "two bones still win")
    T.eq(s.n_jok, 1, "only one of two bones is used")

    s = fight("bl_wall", {ante = 3, jokers = {"j_mr_bones"}, money = 0})
    local reward = s.blind_dollars
    T.ok(reward > 0, "wall pays when beaten")
    last_hand(s, 0.3)
    T.eq(s.phase, "round_eval", "bones before the final ante goes on")
    T.eq(s.won, 0, "bones before the final ante is no win")
    T.eq(s.n_jok, 0, "bones used before the final ante")
    T.eq(s.round_dollars < reward, true, "a saved round pays no blind reward")
end

do
    local s = fight("bl_final_vessel", {ante = 7})
    last_hand(s, 1)
    T.eq(s.phase, "round_eval", "final boss on ante 7 after a lost ante goes on")
    T.eq(s.won, 0, "final boss on ante 7 is no win")
    T.eq(s.ante, 8, "next ante")
end

do
    local base = {[5] = 25000, [6] = 60000, [7] = 110000, [8] = 200000}
    for ante, amount in pairs(base) do
        local s = fight("bl_final_acorn", {ante = ante})
        T.eq(E.get_blind_amount(s, ante), amount, "stake 8 base amount ante " .. ante)
        T.eq(s.blind_chips, amount * 2, "stake 8 boss target ante " .. ante)
    end
    T.eq(fight("bl_final_vessel").blind_chips, 1200000, "vessel target at stake 8")
    T.eq(fight("bl_final_leaf").blind_chips, 400000, "leaf target at stake 8")
    T.eq(fight("bl_final_bell").blind_chips, 400000, "bell target at stake 8")
    T.eq(fight("bl_final_heart").blind_chips, 400000, "heart target at stake 8")
    T.eq(fight("bl_final_vessel", {deck = "b_plasma"}).blind_chips, 2400000, "plasma doubles the vessel target")
end

do
    local showdown = {}
    for i = 1, 200 do
        local s = E.new_run({seed = "BOSS" .. i, deck = "b_red", stake = 8})
        for ante = 1, 8 do
            s.ante = ante
            local b = D.BLINDS[E.get_new_boss(s)]
            T.eq(not not b.showdown, ante == 8, "only ante 8 draws a final boss")
            if ante == 8 then showdown[b.key] = (showdown[b.key] or 0) + 1 end
        end
    end
    for _, boss in ipairs(BOSSES) do T.ok((showdown[boss] or 0) >= 15, "final boss drawn: " .. boss) end
end

do
    local s = fight("bl_final_vessel", {jokers = {"j_luchador", "j_joker"}})
    s.chips = 500000
    T.ok(E.step(s, {type = "sell", area = "jokers", card = has(s, "j_luchador")}), "luchador sold on vessel")
    T.eq(s.phase, "win", "score over the reduced vessel target ends the round")
    T.eq(s.won, 1, "that round wins the run")

    s = fight("bl_final_vessel", {jokers = {"j_luchador"}})
    s.chips = 100000
    E.step(s, {type = "sell", area = "jokers", card = 1})
    T.eq(s.blind_chips, 400000, "disabled vessel target")
    T.eq(s.phase, "play", "score under the reduced target keeps playing")

    s = fight("bl_wall", {ante = 3, jokers = {"j_luchador"}})
    s.chips = s.blind_chips * 0.6
    E.step(s, {type = "sell", area = "jokers", card = 1})
    T.eq(s.phase, "round_eval", "score over the reduced wall target ends the round")

    s = fight("bl_final_leaf", {jokers = {"j_joker", "j_joker"}})
    T.eq(s.blind_disabled, 0, "leaf active")
    E.step(s, {type = "sell", area = "jokers", card = 1})
    T.eq(s.blind_disabled, 1, "selling a joker disables leaf")
    T.eq(s.phase, "play", "leaf stays in play under its target")
    T.eq(s.c_debuff[s.hand[1]], 0, "leaf disabled lifts the debuff")

    s = fight("bl_final_acorn", {jokers = {"j_joker", "j_mime", "j_duo"}})
    last_hand(s, 1)
    T.eq(s.j_flip[1] + s.j_flip[2] + s.j_flip[3], 0, "acorn flips back at the end")
end

do
    local s = fight("bl_wall", {ante = 5, jokers = {"j_joker"}})
    for i = 1, s.n_hand do s.hand[i] = nil end
    for i = 1, s.n_deck do s.deck[i] = nil end
    s.n_hand, s.n_deck = 0, 0
    T.ok(E.step(s, {type = "sell", area = "jokers", card = 1}), "sell with no cards left")
    T.eq(s.phase, "game_over", "no cards left anywhere ends the round")
end

do
    local s = fight("bl_final_vessel", {ante = 5, jokers = {{"j_joker", {rental = true}}, {"j_mime", {rental = true}}}, money = 20})
    last_hand(s, 1)
    T.eq(s.phase, "round_eval", "rental round goes on")
    T.eq(s.money < 20, true, "rentals are charged at round end")
    T.eq(20 - s.money, 6, "two rentals cost 3 each")
    T.eq(s.round_dollars >= 2, true, "interest and hands are still paid")

    s = fight("bl_final_acorn", {jokers = {{"j_mr_bones", {rental = true}}, {"j_joker", {rental = true}}}, money = 10})
    last_hand(s, 0.3)
    T.eq(s.money, 4, "a saved final round still charges rent")

    s = fight("bl_wall", {ante = 5, jokers = {{"j_joker", {perish = 1}}, {"j_mime", {perish = 3}}}})
    last_hand(s, 1)
    T.eq(s.j_perish[1], 0, "perishable runs out")
    T.eq(s.j_debuff[1], 1, "dead perishable is debuffed after the round")
    T.eq(s.j_perish[2], 2, "other perishable counts down")
    T.eq(s.j_debuff[2], 0, "other perishable still works")

    s = fight("bl_wall", {ante = 5, jokers = {{"j_joker", {eternal = true}}}})
    T.eq(E.step(s, {type = "sell", area = "jokers", card = 1}), false, "eternal cannot be sold")

    for _, c in ipairs({{4, 0}, {5, 1}, {24, 4}, {25, 5}, {300, 5}}) do
        s = fight("bl_wall", {ante = 5, money = c[1]})
        s.hands_left = 1
        s.discards_left = 0
        s.chips = s.blind_chips
        local boss_dollars = s.blind_dollars
        E.step(s, {type = "play", cards = {1}})
        T.eq(s.round_dollars, boss_dollars + c[2], "interest on " .. c[1] .. " dollars")
    end
end
