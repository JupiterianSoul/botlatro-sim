package.path = "assets/?.lua;tools/?.lua;" .. package.path
require("botsim.jitopt")

local E = require("bot.sim.engine")
local FE = require("bot.nn.features")
local WT = require("bot.nn.weights")
local NET = require("bot.nn.net")
local MC = require("bot.nn.mcts")
local POL = require("botsim.policy")
local ES = require("botsim.train.evalset")
local json = require("bot.sim.json")

local opt = {who = "greedy", weights = "", sims = 32, K = 24, per = 6, decks = "", stakes = "", part = 0, parts = 1, out = "", max_moves = 3000, max_shop = 40,
    mix = -1, score_prior = 0, score_top = 6, score_temp = 4, skip_pen = 1, skip_ante = 1, prefix = "", first = 1, seeds = 10, jsonl = ""}
for _, a in ipairs(arg or {}) do
    local k, v = a:match("^([%w_]+)=(.*)$")
    if k then opt[k] = tonumber(v) or v end
end

local mc
if opt.who == "net" then
    local W = WT.load(opt.weights)
    mc = MC.new(NET.new(W), {K = opt.K, seed = 99991, alpha = 0.5, mix = opt.mix >= 0 and opt.mix or nil,
        score_prior = opt.score_prior, score_top = opt.score_top, score_temp = opt.score_temp, skip_pen = opt.skip_pen, skip_ante = opt.skip_ante, nodes = opt.sims + 2, full = true})
end
POL.shop = true

local LEAVE, SKIP = {type = "leave"}, {type = "skip"}
local step = {type = "play", cards = {}}
local F, AB = FE.new_state_buf(), FE.new_action_buf(1024)
local st = {}

local function play(deck, stake, seed)
    local s = E.new_run({seed = seed, deck = deck, stake = stake})
    local moves, econ_run = 0, 0
    while moves < opt.max_moves do
        MC.advance_forced(s)
        if MC.terminal(s) then break end
        local ph = s.phase
        if ph == "shop" or ph == "pack" then econ_run = econ_run + 1 else econ_run = 0 end
        if econ_run > opt.max_shop then
            if not E.step(s, ph == "pack" and SKIP or LEAVE) then break end
        elseif mc then
            mc:search(s, opt.sims, {noise = 0, reuse = true, adaptive = true})
            local e = mc:choose(0)
            if not e then break end
            mc:edge_action(e, step, s)
            mc:commit(e)
            if not E.step(s, step) then break end
            moves = moves + 1
        else
            FE.state(s, F)
            local n = FE.list_actions(s, AB, F)
            if n == 0 then break end
            local a = POL.choose(s)
            local k = a and FE.find_action(AB, a, s) or -1
            if k < 0 then k = 0 end
            if not E.step(s, FE.to_step(AB, k, st, s)) then break end
            moves = moves + 1
        end
    end
    local won = s.won == 1 and 1 or 0
    return won, won == 1 and s.win_ante + 1 or s.ante
end

local DECKS, STAKES = ES.parse(opt.decks, tostring(opt.stakes))
local fh = opt.out ~= "" and assert(io.open(opt.out, "wb")) or io.stdout
local jf = opt.jsonl ~= "" and assert(io.open(opt.jsonl, "w")) or nil
if opt.prefix ~= "" then
    local i = 0
    for _, d in ipairs(DECKS) do
        for _, stk in ipairs(STAKES) do
            local wins, antes, sq = 0, 0, 0
            for k = opt.first, opt.first + opt.seeds - 1 do
                i = i + 1
                if (i - 1) % opt.parts == opt.part then
                    local seed = string.format("%s%04d", opt.prefix, k)
                    local t0 = os.clock()
                    local w, a = play(d, stk, seed)
                    wins, antes, sq = wins + w, antes + a, sq + a * a
                    if jf then
                        jf:write(string.format('{"deck":"%s","stake":%d,"seed":"%s","won":%d,"ante":%d,"time":%.2f}\n', d, stk, seed, w, a, os.clock() - t0))
                        jf:flush()
                    end
                end
            end
            fh:write(json.encode({deck = d, stake = stk, n = opt.seeds, wins = wins, ante_sum = antes, ante_sq = sq}) .. "\n")
            fh:flush()
        end
    end
else
for i, c in ipairs(ES.cells(opt.per, DECKS, STAKES)) do
    if (i - 1) % opt.parts == opt.part then
        local wins, antes, sq = 0, 0, 0
        for k = 1, c.per do
            local t0 = os.clock()
            local w, a = play(c.deck, c.stake, ES.seed(c.deck, c.stake, k))
            wins = wins + w
            antes = antes + a
            sq = sq + a * a
            if jf then
                jf:write(string.format('{"deck":"%s","stake":%d,"seed":"%s","won":%d,"ante":%d,"time":%.2f}\n', c.deck, c.stake, ES.seed(c.deck, c.stake, k), w, a, os.clock() - t0))
                jf:flush()
            end
        end
        fh:write(json.encode({deck = c.deck, stake = c.stake, n = c.per, wins = wins, ante_sum = antes, ante_sq = sq}) .. "\n")
        fh:flush()
    end
end
end
if jf then jf:close() end
if fh ~= io.stdout then fh:close() end
