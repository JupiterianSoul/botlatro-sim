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
    mix = -1, score_prior = 0, score_top = 6, score_temp = 4, skip_pen = 1, skip_ante = 1, type_mass = 0, tm_plays = 0, quick_clear = 0, pace = 0, pace_net = 0, prefix = "", first = 1, seeds = 10, jsonl = "", fair = 0, search_ph = "", rec = "", solver = "", solver_qc = 0, set = "", curve = 0, leaf_money = 0, leaf_rent = 0, leaf_dead = 0, rent_prior = 1, sell_dead = 0}
for _, a in ipairs(arg or {}) do
    local k, v = a:match("^([%w_]+)=(.*)$")
    if k then opt[k] = tonumber(v) or v end
end

local mc
if opt.who == "net" then
    local W = WT.load(opt.weights)
    mc = MC.new(NET.new(W), {K = opt.K, seed = 99991, alpha = 0.5, mix = opt.mix >= 0 and opt.mix or nil,
        score_prior = opt.score_prior, score_top = opt.score_top, score_temp = opt.score_temp, skip_pen = opt.skip_pen, skip_ante = opt.skip_ante, type_mass = opt.type_mass, tm_plays = opt.tm_plays, quick_clear = opt.quick_clear, pace = opt.pace, pace_net = opt.pace_net, leaf_money = opt.leaf_money, leaf_rent = opt.leaf_rent, leaf_dead = opt.leaf_dead, rent_prior = opt.rent_prior, nodes = opt.sims + 2, full = true})
end
POL.shop = true
local FAIR = opt.fair > 0 and require("bot.seer.fair") or nil
local PL = require("bot.seer.play")
local SOLVER = FAIR and opt.solver ~= "" and FAIR.new({budget = opt.solver, quick_clear = opt.solver_qc > 0}) or nil
local REC = opt.rec ~= "" and mc and require("botsim.train.records") or nil
local TCH = REC and SOLVER and require("botsim.seer.teacher") or nil
local rf, nrun = REC and assert(io.open(opt.rec, "wb")), 0
if rf then rf:write(REC.file_header()) end

local LEAVE, SKIP = {type = "leave"}, {type = "skip"}
local step = {type = "play", cards = {}}
local F, AB = FE.new_state_buf(), FE.new_action_buf(1024)
local st = {}

local function play(deck, stake, seed)
    local s = E.new_run({seed = seed, deck = deck, stake = stake})
    for k, v in tostring(opt.set):gmatch("([%w_]+):(-?[%d%.]+)") do s[k] = tonumber(v) end
    local moves, econ_run, why = 0, 0, "max_moves"
    local curve, curve_ante = {}, 0
    local recs = rf and {}
    while moves < opt.max_moves do
        MC.advance_forced(s)
        if MC.terminal(s) then why = "end" break end
        local ph = s.phase
        if opt.curve > 0 and s.ante ~= curve_ante then
            curve_ante = s.ante
            local rent, dead, et = 0, 0, 0
            for k = 1, s.n_jok do
                rent = rent + s.j_rental[k]
                et = et + s.j_eternal[k]
                if s.j_perish[k] == 0 then dead = dead + 1 end
            end
            curve[#curve + 1] = string.format("%d:%d:%d:%d:%d:%d", s.ante, s.money, s.n_jok, rent, dead, et)
        end
        if opt.sell_dead > 0 and ph == "shop" then
            for k = s.n_jok, 1, -1 do
                if s.j_perish[k] == 0 then E.step(s, {type = "sell", area = "jokers", card = k}) end
            end
        end
        if ph == "shop" or ph == "pack" then econ_run = econ_run + 1 else econ_run = 0 end
        if econ_run > opt.max_shop then
            if not E.step(s, ph == "pack" and SKIP or LEAVE) then why = "stuck_econ:" .. ph break end
        elseif SOLVER and ph == "play" then
            SOLVER.last_cands = nil
            local acts = SOLVER:decide(s)
            if recs and acts and acts[1] then
                local r = TCH.encode(s, acts[1], {K = 32, neg = 16, n_sims = opt.sims}, FAIR.scores_of(SOLVER.last_cands or {}))
                if r then recs[#recs + 1] = r end
            end
            if not acts or not acts[1] or not E.step(s, acts[1]) then
                local fb = PL.fast_action(s)
                if not fb or not E.step(s, fb) then why = "step_failed:play:solver" break end
            end
            moves = moves + 1
        elseif mc then
            local view = s
            if FAIR then view = FAIR.world(FAIR.sanitize(s), string.format("FW%s_%d", seed, moves)) end
            local sims = opt.sims
            if opt.search_ph ~= "" and not ("," .. opt.search_ph .. ","):find("," .. ph .. ",", 1, true) then sims = 0 end
            mc:search(view, sims, {noise = 0, reuse = not FAIR, adaptive = true})
            local e = mc:choose(0)
            if not e then why = "no_edge:" .. ph break end
            if recs then recs[#recs + 1] = REC.encode_record(mc.F_root, mc, e, sims, FE.PHASES[ph] or 0) end
            mc:edge_action(e, step, view)
            if not FAIR then mc:commit(e) end
            if not E.step(s, step) then why = "step_failed:" .. ph .. ":" .. tostring(step.type) break end
            moves = moves + 1
        else
            FE.state(s, F)
            local n = FE.list_actions(s, AB, F)
            if n == 0 then why = "no_actions:" .. ph break end
            local a = POL.choose(s)
            local k = a and FE.find_action(AB, a, s) or -1
            if k < 0 then k = 0 end
            local fs = FE.to_step(AB, k, st, s)
            if not E.step(s, fs) then why = "step_failed:" .. ph .. ":" .. tostring(fs.type) break end
            moves = moves + 1
        end
    end
    local won = s.won == 1 and 1 or 0
    local ante = won == 1 and s.win_ante + 1 or s.ante
    if recs then
        nrun = nrun + 1
        rf:write(REC.encode_run(recs, won, math.min(ante, 255), FE.DECK_IDX[deck] or 0, stake, nrun))
    end
    s.eval_curve = table.concat(curve, ",")
    return won, ante, why, moves, s
end

local function death_fields(s)
    return string.format(',"blind":%d,"chips":%.0f,"need":%.0f,"money":%d,"n_jok":%d,"disc_left":%d', s.blind, s.chips, s.blind_chips, s.money, s.n_jok, s.discards_left) .. (opt.curve > 0 and string.format(',"curve":"%s"', s.eval_curve) or "")
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
                    local w, a, why, mv, fs = play(d, stk, seed)
                    wins, antes, sq = wins + w, antes + a, sq + a * a
                    if jf then
                        jf:write(string.format('{"deck":"%s","stake":%d,"seed":"%s","won":%d,"ante":%d,"time":%.2f,"end":"%s","moves":%d%s}\n', d, stk, seed, w, a, os.clock() - t0, why, mv, death_fields(fs)))
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
            local w, a, why, mv = play(c.deck, c.stake, ES.seed(c.deck, c.stake, k))
            wins = wins + w
            antes = antes + a
            sq = sq + a * a
            if jf then
                jf:write(string.format('{"deck":"%s","stake":%d,"seed":"%s","won":%d,"ante":%d,"time":%.2f,"end":"%s","moves":%d}\n', c.deck, c.stake, ES.seed(c.deck, c.stake, k), w, a, os.clock() - t0, why, mv))
                jf:flush()
            end
        end
        fh:write(json.encode({deck = c.deck, stake = c.stake, n = c.per, wins = wins, ante_sum = antes, ante_sq = sq}) .. "\n")
        fh:flush()
    end
end
end
if jf then jf:close() end
if rf then rf:close() end
if fh ~= io.stdout then fh:close() end
