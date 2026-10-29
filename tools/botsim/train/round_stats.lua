package.path = "assets/?.lua;tools/?.lua;" .. package.path
require("botsim.jitopt")

local E = require("bot.sim.engine")
local PL = require("bot.seer.play")
local json = require("bot.sim.json")

local opt = {who = "net", weights = "", deck = "b_red", stake = 1, prefix = "BENCH", first = 1, seeds = 1, list = "", out = "",
    budget = "lite", K = 24, max_moves = 3000, type_mass = 0}
for _, a in ipairs(arg or {}) do
    local k, v = a:match("^([%w_]+)=(.*)$")
    if k then opt[k] = tonumber(v) or v end
end

local seeds = {}
if opt.list ~= "" then
    for n in tostring(opt.list):gmatch("[^,]+") do seeds[#seeds + 1] = string.format("%s%04d", opt.prefix, tonumber(n)) end
else
    for n = opt.first, opt.first + opt.seeds - 1 do seeds[#seeds + 1] = string.format("%s%04d", opt.prefix, n) end
end

local function net_player()
    local WT = require("bot.nn.weights")
    local NET = require("bot.nn.net")
    local MC = require("bot.nn.mcts")
    local mc = MC.new(NET.new(WT.load(opt.weights)), {K = opt.K, seed = 99991, alpha = 0.5, score_prior = 0, skip_pen = 1, skip_ante = 1, type_mass = opt.type_mass, nodes = 2, full = true})
    return function(setup, on_action)
        local s = E.new_run(setup)
        local step = {type = "play", cards = {}}
        for _ = 1, opt.max_moves do
            MC.advance_forced(s)
            if MC.terminal(s) then break end
            mc:search(s, 0, {noise = 0, reuse = true, adaptive = true})
            local e = mc:choose(0)
            if not e then break end
            mc:edge_action(e, step, s)
            mc:commit(e)
            on_action(s, step)
            if not E.step(s, step) then break end
        end
        return s
    end
end

local function fair_player()
    local F = require("bot.seer.fair")
    local b = F.BUDGETS[opt.budget] or F.BUDGETS.lite
    return function(setup, on_action)
        local fo = F.new({budget = opt.budget, seer = b.seer})
        local line = fo:play(setup)
        local s = E.new_run(setup)
        for i = 1, #line do
            on_action(s, line[i])
            if not E.step(s, line[i]) then break end
        end
        return s
    end
end

local play = opt.who == "fair" and fair_player() or net_player()
local out = opt.out ~= "" and assert(io.open(opt.out, "w")) or io.stdout
local tot = {rounds = 0, with_disc = 0, all_first = 0, disc = 0, disc_clear = 0, lost = 0}

for _, seed in ipairs(seeds) do
    local cur
    local rounds = {}
    local function flush(cleared)
        if cur then
            cur.cleared = cleared
            rounds[#rounds + 1] = cur
            cur = nil
        end
    end
    local s = play({seed = seed, deck = opt.deck, stake = opt.stake}, function(st, a)
        if st.phase ~= "play" then
            flush(st.phase ~= "game_over")
            return
        end
        if a.type ~= "play" and a.type ~= "discard" then return end
        if cur and (cur.ante ~= st.ante or cur.blind ~= st.blind) then flush(true) end
        if not cur then
            cur = {ante = st.ante, blind = st.blind, hands = st.hands_left, discards = st.discards_left, seq = "", clear_disc = 0, first_play = -1}
        end
        if a.type == "discard" then
            local _, v = PL.best_play(st)
            if v >= st.blind_chips - st.chips then cur.clear_disc = cur.clear_disc + 1 end
            cur.seq = cur.seq .. "D"
        else
            if cur.first_play < 0 then cur.first_play = st.discards_left end
            cur.seq = cur.seq .. "P"
        end
    end)
    flush(s.won == 1)
    for i, r in ipairs(rounds) do
        tot.rounds = tot.rounds + 1
        if r.discards > 0 then
            tot.with_disc = tot.with_disc + 1
            if r.first_play == 0 or (r.first_play < 0 and r.seq:find("D")) then tot.all_first = tot.all_first + 1 end
        end
        local nd = select(2, r.seq:gsub("D", ""))
        tot.disc = tot.disc + nd
        tot.disc_clear = tot.disc_clear + r.clear_disc
        r.seed, r.idx = seed, i
        out:write(json.encode(r), "\n")
    end
    local won = s.won == 1
    if not won then tot.lost = tot.lost + 1 end
    out:write(json.encode({seed = seed, done = true, won = won, ante = s.ante}), "\n")
    out:flush()
end
print(string.format("who %s games %d lost %d rounds %d with_discards %d all_discards_before_first_play %d discards %d discards_when_a_play_cleared %d",
    opt.who, #seeds, tot.lost, tot.rounds, tot.with_disc, tot.all_first, tot.disc, tot.disc_clear))
