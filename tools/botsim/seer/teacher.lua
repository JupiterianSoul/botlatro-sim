package.path = "assets/?.lua;tools/?.lua;" .. package.path
require("botsim.jitopt")

local E = require("bot.sim.engine")
local S = require("bot.seer.seer")
local FE = require("bot.nn.features")
local REC = require("botsim.train.records")

local T = {}

local F = FE.new_state_buf(true)
local AB = FE.new_action_buf(1024, true)

local rng_x = 1

function T.reseed(seed)
    rng_x = math.floor(seed or 1) % 2147483646 + 1
end

function T.rand(n)
    rng_x = (rng_x * 48271) % 2147483647
    return math.floor(rng_x / 2147483647 * n) + 1
end

function T.encode(s, a, opts, soft)
    if not FE.PHASES[s.phase] then return nil, s.phase end
    FE.state(s, F)
    local n = FE.list_actions(s, AB, F)
    if n < 2 then return nil, "forced" end
    local chosen = FE.find_action(AB, a, s)
    if not chosen or chosen < 0 then return nil, "unmatched_" .. s.phase end
    local vis = {[chosen] = 1}
    if soft and #soft > 0 then
        vis = {[chosen] = 0}
        for _, sc in ipairs(soft) do
            local k = FE.find_action(AB, sc.action, s)
            if k and k >= 0 then vis[k] = (vis[k] or 0) + sc.visits end
        end
        if vis[chosen] == 0 then vis[chosen] = 1 end
    end
    local others = {}
    for k = 0, n - 1 do if k ~= chosen then others[#others + 1] = k end end
    table.sort(others, function(x, y)
        local vx, vy = vis[x] or 0, vis[y] or 0
        if vx ~= vy then return vx > vy end
        local px, py = AB.type[x] <= 2 and AB.xe[x] or -math.huge, AB.type[y] <= 2 and AB.xe[y] or -math.huge
        if px ~= py then return px > py end
        return x < y
    end)
    local K = math.min(opts.K or 24, n, 255)
    local neg = math.min(opts.neg or 0, K - 1)
    local top = K - 1 - neg
    for i = top + 1, K - 1 do
        local j = i + T.rand(#others - i + 1) - 1
        others[i], others[j] = others[j], others[i]
    end
    local picks = {{k = chosen, visits = vis[chosen], prior = 1 / K}}
    for i = 1, K - 1 do picks[#picks + 1] = {k = others[i], visits = vis[others[i]] or 0, prior = 1 / K} end
    return REC.encode_choice(F, AB, picks, {chosen = 1, phase = FE.PHASES[s.phase], n_sims = opts.n_sims or 800})
end

function T.solved(setup, opts, index)
    T.reseed(index)
    local seer = S.new(opts.seer)
    local r = seer:solve(setup, {max_lines = opts.max_lines, time_limit = opts.time_limit})
    local s = E.new_run(setup)
    local recs, skipped = {}, {}
    for i = 1, #r.line do
        local a = r.line[i]
        local rec, why = T.encode(s, a, opts)
        if rec then recs[#recs + 1] = rec end
        if why then skipped[why] = (skipped[why] or 0) + 1 end
        if not E.step(s, a) then
            skipped.replay_break = (skipped.replay_break or 0) + 1
            break
        end
    end
    local won = s.won == 1 and 1 or 0
    local final_ante = won == 1 and s.win_ante + 1 or s.ante
    local blob = REC.encode_run(recs, won, final_ante, FE.DECK_IDX[setup.deck] or 0, setup.stake or 1, index or 0)
    return blob, {records = #recs, skipped = skipped, won = won, final_ante = final_ante, line = r.line, state = s, lines = r.lines}
end

function T.net_proposer(path, sims)
    local WT = require("bot.nn.weights")
    local NET = require("bot.nn.net")
    local MC = require("bot.nn.mcts")
    local mc = MC.new(NET.new(WT.load(path)), {K = 24, seed = 99991, alpha = 0.5, nodes = sims + 2, full = true})
    local step = {type = "play", cards = {}}
    return function(s)
        if MC.terminal(s) or s.phase == "round_eval" then return nil end
        mc:search(s, sims, {noise = 0, reuse = false, adaptive = true})
        local e = mc:choose(0)
        if not e then return nil end
        return S.copy_action(mc:edge_action(e, step, s))
    end
end

function T.fair(setup, opts, index)
    T.reseed(index)
    local FA = require("bot.seer.fair")
    local b = FA.BUDGETS[opts.budget or "lite"] or FA.BUDGETS.lite
    local fo = FA.new({budget = opts.budget or "lite", seer = b.seer,
        net_propose = opts.weights and opts.weights ~= "" and T.net_proposer(opts.weights, opts.net_sims or 16) or nil})
    local t0 = os.clock()
    local line, fs = fo:play(setup, nil, opts.stop_ante)
    local tm = os.clock() - t0
    local s = E.new_run(setup)
    local recs, skipped = {}, {}
    for i = 1, #line do
        local a = line[i]
        local rec, why = T.encode(s, a, opts, fo.scores[i])
        if rec then recs[#recs + 1] = rec end
        if why then skipped[why] = (skipped[why] or 0) + 1 end
        if not E.step(s, a) then
            skipped.replay_break = (skipped.replay_break or 0) + 1
            break
        end
    end
    local won = fs.won == 1 and 1 or 0
    local final_ante = won == 1 and fs.win_ante + 1 or fs.ante
    local blob = REC.encode_run(recs, won, final_ante, FE.DECK_IDX[setup.deck] or 0, setup.stake or 1, index or 0)
    return blob, {records = #recs, skipped = skipped, won = won, final_ante = final_ante, line = line, state = fs, time = tm,
        decisions = fo.decisions, searched = fo.searched, net_picks = fo.net_picks}
end

function T.run(setup, opts, index)
    opts = opts or {}
    T.reseed(index)
    if opts.mode == "solve" then return T.solved(setup, opts, index) end
    if opts.mode == "fair" then return T.fair(setup, opts, index) end
    local seer = S.new(opts.seer)
    local s = E.new_run(setup)
    local recs, skipped = {}, {}
    local line = {}
    for _ = 1, 5000 do
        if s.won == 1 or s.phase == "game_over" then break end
        if opts.stop_ante and s.ante > opts.stop_ante then break end
        local a = seer:choose(s)
        if not a then break end
        local r, why = T.encode(s, a, opts)
        if r then recs[#recs + 1] = r end
        if why then skipped[why] = (skipped[why] or 0) + 1 end
        if not E.step(s, a) then
            seer.plan = nil
            break
        end
        line[#line + 1] = a
    end
    local won = s.won == 1 and 1 or 0
    local final_ante = won == 1 and s.win_ante + 1 or s.ante
    local blob = REC.encode_run(recs, won, final_ante, FE.DECK_IDX[setup.deck] or 0, setup.stake or 1, index or 0)
    return blob, {records = #recs, skipped = skipped, won = won, final_ante = final_ante, line = line, state = s}
end

if arg and arg[0] and arg[0]:match("teacher%.lua$") then
    local opt = {seeds = 4, decks = "b_red", stakes = "1", out = "tools/botsim/train/out/seer_teacher.bspr", prefix = "TEACH", K = 32, neg = 16, n_sims = 800, stop_ante = 0, start = 1,
        mode = "play", max_lines = 8, time_limit = 0, wins_only = 0, budget = "lite", jsonl = "", weights = "", net_sims = 16}
    for _, a in ipairs(arg) do
        local k, v = a:match("^%-*([%w_]+)=(.*)$")
        if k then opt[k] = tonumber(v) or v end
    end
    local ALL = require("botsim.train.evalset").ALL_DECKS
    local decks, stakes = {}, {}
    for w in tostring(opt.decks):gmatch("[^,]+") do decks[#decks + 1] = w end
    for w in tostring(opt.stakes):gmatch("[^,]+") do stakes[#stakes + 1] = tonumber(w) end
    local fh = assert(io.open(opt.out, "wb"))
    fh:write(REC.file_header())
    local jf = opt.jsonl ~= "" and assert(io.open(opt.jsonl, "w")) or nil
    local t0 = os.clock()
    local n, tot_rec, tot_skip, wins = 0, 0, {}, 0
    for _, d in ipairs(decks) do
        for _, st in ipairs(stakes) do
            for i = opt.start, opt.start + opt.seeds - 1 do
                n = n + 1
                local deck = d == "all" and ALL[(i - 1) % #ALL + 1] or d
                local setup = {seed = string.format("%s%04d", opt.prefix, i), deck = deck, stake = st}
                local blob, info = T.run(setup, {K = opt.K, neg = opt.neg, n_sims = opt.n_sims, stop_ante = opt.stop_ante > 0 and opt.stop_ante or nil,
                    mode = opt.mode, budget = opt.budget, max_lines = opt.max_lines, time_limit = opt.time_limit, weights = opt.weights, net_sims = opt.net_sims}, n)
                if opt.wins_only == 0 or info.won == 1 then
                    fh:write(blob)
                    tot_rec = tot_rec + info.records
                end
                if jf then
                    jf:write(string.format('{"deck":"%s","stake":%d,"seed":"%s","won":%d,"ante":%d,"time":%.2f,"records":%d,"dec":%d,"searched":%d,"net_picks":%d}\n',
                        deck, st, setup.seed, info.won, info.final_ante, info.time or 0, info.records, info.decisions or 0, info.searched or 0, info.net_picks or 0))
                    jf:flush()
                end
                wins = wins + info.won
                for k, v in pairs(info.skipped) do tot_skip[k] = (tot_skip[k] or 0) + v end
                print(string.format("run %d %s stake %d seed %s ante %d won %d records %d", n, deck, st, setup.seed, info.final_ante, info.won, info.records))
            end
        end
    end
    fh:close()
    if jf then jf:close() end
    local keys = {}
    for k in pairs(tot_skip) do keys[#keys + 1] = k end
    table.sort(keys)
    local sk = {}
    for _, k in ipairs(keys) do sk[#sk + 1] = k .. "=" .. tot_skip[k] end
    print(string.format("runs %d wins %d records %d skipped %s time %.1fs -> %s", n, wins, tot_rec, table.concat(sk, " "), os.clock() - t0, opt.out))
end

return T
