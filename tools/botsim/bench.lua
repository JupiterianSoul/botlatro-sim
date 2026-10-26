package.path = "assets/?.lua;tools/?.lua;" .. package.path
require("botsim.jitopt")
local E = require("bot.sim.engine")
local ST = require("bot.sim.state")
local P = require("botsim.policy")

local N = tonumber(arg and arg[1]) or 40
local clock = os.clock

local decks = {"b_red", "b_blue", "b_yellow", "b_green", "b_black", "b_painted", "b_plasma", "b_erratic"}
local logs = {}
local actions, hands, antes = 0, 0, 0
local t0 = clock()
for i = 1, N do
    local setup = {seed = string.format("BENCH%03d", i), deck = decks[(i - 1) % #decks + 1], stake = (i - 1) % 8 + 1}
    local s = E.new_run(setup)
    local log = {setup = setup}
    local guard = 0
    while s.phase ~= "game_over" and s.won == 0 and guard < 1000 do
        local a = P.choose(s)
        if not a or not E.step(s, a) then break end
        log[#log + 1] = a
        if a.type == "play" then hands = hands + 1 end
        guard = guard + 1
    end
    actions = actions + #log
    antes = antes + s.ante
    logs[i] = log
end
local t_policy = clock() - t0
print(string.format("greedy policy runs: %d runs in %.2fs, %.1f runs/s, %.1f actions/s, avg ante %.2f (policy previews every play subset)",
    N, t_policy, N / t_policy, actions / t_policy, antes / N))

local reps = math.max(1, math.floor(20000 / math.max(1, actions)))
t0 = clock()
local ra, rh = 0, 0
for _ = 1, reps do
    for i = 1, N do
        local log = logs[i]
        local s = E.new_run(log.setup)
        for j = 1, #log do
            local a = log[j]
            E.step(s, a)
            if a.type == "play" then rh = rh + 1 end
        end
        ra = ra + #log
    end
end
local t_raw = clock() - t0
print(string.format("raw sim replay: %d runs in %.2fs, %.1f runs/s, %.0f actions/s, %.0f scored hands/s",
    N * reps, t_raw, N * reps / t_raw, ra / t_raw, rh / t_raw))

local s = E.new_run({seed = "MICRO001", deck = "b_red", stake = 1})
for _, k in ipairs({"j_joker", "j_blueprint", "j_duo", "j_scholar", "j_baron"}) do E.add_joker(s, k) end
E.step(s, {type = "select"})
local M = 200000
t0 = clock()
local c
for _ = 1, M do c = ST.clone(s) end
local t_clone = clock() - t0
local scratch = ST.scratch()
t0 = clock()
for _ = 1, M do ST.copy_into(scratch, s) end
local t_copy = clock() - t0
local pos = {1, 2, 3, 4, 5}
t0 = clock()
for _ = 1, M do E.preview_into(scratch, s, pos) end
local t_prev = clock() - t0
local t_score = t_prev - t_copy
print(string.format("clone(): %.0f/s   copy_into(): %.0f/s   score (5 cards, 5 jokers, minus copy): %.0f/s   preview incl copy: %.0f/s",
    M / t_clone, M / t_copy, M / math.max(t_score, 1e-9), M / t_prev))
local _ = c

P.shop = true
local slogs = {}
local sactions, santes, swins = 0, 0, 0
t0 = clock()
for i = 1, N do
    local setup = {seed = string.format("SHOP%04d", i), deck = decks[(i - 1) % #decks + 1], stake = (i - 1) % 8 + 1}
    local st = E.new_run(setup)
    local log = {setup = setup}
    local guard = 0
    while st.phase ~= "game_over" and st.won == 0 and guard < 3000 do
        local a = P.choose(st)
        if not a or not E.step(st, a) then break end
        log[#log + 1] = a
        guard = guard + 1
    end
    sactions = sactions + #log
    santes = santes + st.ante
    swins = swins + st.won
    slogs[i] = log
end
local t_spol = clock() - t0
print(string.format("greedy shop policy runs: %d runs in %.2fs, %.1f runs/s, %.1f actions/s, avg ante %.2f, wins %d",
    N, t_spol, N / t_spol, sactions / t_spol, santes / N, swins))
P.shop = false
local sreps = math.max(1, math.floor(20000 / math.max(1, sactions)))
t0 = clock()
local sra = 0
for _ = 1, sreps do
    for i = 1, N do
        local log = slogs[i]
        local st = E.new_run(log.setup)
        for j = 1, #log do E.step(st, log[j]) end
        sra = sra + #log
    end
end
local t_sraw = clock() - t0
print(string.format("raw sim replay with shop: %d runs in %.2fs, %.1f runs/s, %.0f actions/s",
    N * sreps, t_sraw, N * sreps / t_sraw, sra / t_sraw))

