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
    mix = -1, score_prior = 0, score_top = 6, score_temp = 4, skip_pen = 1, skip_ante = 1, type_mass = 0, tm_plays = 0, quick_clear = 0, pace = 0, pace_net = 0, prefix = "", first = 1, seeds = 10, jsonl = "", fair = 0, search_ph = "", rec = "", solver = "", solver_qc = 0, set = "", curve = 0, trace = 0, list = "", leaf_money = 0, leaf_rent = 0, leaf_dead = 0, rent_prior = 1, rent_from = 0, sell_dead = 0, c_puct = 1.5, worlds = 1, ro = 0, ro_a = 0, ro_z = 2, ro_c = 3, ro_h = 0, ro_ph = "shop,pack,blind_select", ro_from = 0, ro_mon = 0, ro_net = 0, ro_t = 0.25}
for _, a in ipairs(arg or {}) do
    local k, v = a:match("^([%w_]+)=(.*)$")
    if k then opt[k] = tonumber(v) or v end
end

local mc, rmc
if opt.who == "net" then
    local W = WT.load(opt.weights)
    local function new_mc() return MC.new(NET.new(W), {K = opt.K, seed = 99991, alpha = 0.5, mix = opt.mix >= 0 and opt.mix or nil,
        score_prior = opt.score_prior, score_top = opt.score_top, score_temp = opt.score_temp, skip_pen = opt.skip_pen, skip_ante = opt.skip_ante, type_mass = opt.type_mass, tm_plays = opt.tm_plays, quick_clear = opt.quick_clear, pace = opt.pace, pace_net = opt.pace_net, leaf_money = opt.leaf_money, leaf_rent = opt.leaf_rent, leaf_dead = opt.leaf_dead, rent_prior = opt.rent_prior, rent_from = opt.rent_from, c_puct = opt.c_puct, nodes = opt.sims + 2, full = true}) end
    mc = new_mc()
    if opt.ro > 0 then rmc = new_mc() end
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

local ro_choose = opt.ro > 0 and require("botsim.train.rollout").chooser(mc, rmc, opt) or nil

local D = require("bot.sim.data")

local function trace_new()
    return {a = {}, r = {}, offer = {}, act = {}, buy = {}}
end

local function trace_ante(tr, s)
    local j, lv = {}, {}
    for k = 1, s.n_jok do
        j[k] = {D.JOKERS[s.j_id[k]].key, s.j_ed[k], s.j_mult[k], s.j_x[k], s.j_ex[k]}
    end
    for k = 1, 12 do lv[k] = s.h_level[k] end
    local v = {}
    for k = 1, #D.VOUCHERS do
        if s.used_v[k] ~= 0 and s.used_v[k] ~= false then v[#v + 1] = D.VOUCHERS[k].key end
    end
    tr.a[#tr.a + 1] = {ante = s.ante, money = s.money, jok = j, lv = lv, n_deck = s.n_cards, v = v, limit = s.joker_limit}
end

local function trace_top(tr, s)
    local r = tr.cur
    if r then
        local d = s.chips - r.chips
        if d > 0 then
            r.chips = s.chips
            if d > r.best then r.best = d end
        end
    end
end

local function trace_phase(tr, s, ph)
    if ph == "play" and (not tr.cur or tr.cur.round ~= s.round) then
        tr.cur = {round = s.round, ante = s.ante, blind = D.BLINDS[s.blind].key, need = s.blind_chips, chips = 0, best = 0, plays = 0, discards = 0, money = s.money}
        tr.r[#tr.r + 1] = tr.cur
    elseif ph == "shop" or ph == "pack" then
        local o = tr.offer[s.ante]
        if not o then
            o = {}
            tr.offer[s.ante] = o
        end
        if ph == "shop" then
            for k = 1, s.n_sj do
                if s.sj_kind[k] == 1 then o[D.JOKERS[s.sj_id[k]].key] = 1 end
            end
        end
    end
end

local function trace_act(tr, s, a)
    local c = tr.act[s.ante]
    if not c then
        c = {}
        tr.act[s.ante] = c
    end
    c[a.type] = (c[a.type] or 0) + 1
    if tr.cur and a.type == "play" then tr.cur.plays = tr.cur.plays + 1 end
    if tr.cur and a.type == "discard" then tr.cur.discards = tr.cur.discards + 1 end
    if (a.type == "buy" or a.type == "buy_and_use") and s.sj_kind[a.card] == 1 then
        tr.buy[#tr.buy + 1] = {s.ante, D.JOKERS[s.sj_id[a.card]].key, s.money}
    end
end

local function trace_json(tr, s)
    local offer, act = {}, {}
    for a, o in pairs(tr.offer) do
        local l = {}
        for k in pairs(o) do l[#l + 1] = k end
        table.sort(l)
        offer[tostring(a)] = l
    end
    for a, c in pairs(tr.act) do act[tostring(a)] = c end
    return json.encode({a = tr.a, r = tr.r, offer = offer, act = act, buy = tr.buy, n_hand = s.n_hand, n_deck = s.n_deck, phase = s.phase})
end

local function play(deck, stake, seed)
    local s = E.new_run({seed = seed, deck = deck, stake = stake})
    for k, v in tostring(opt.set):gmatch("([%w_]+):(-?[%d%.]+)") do s[k] = tonumber(v) end
    local moves, econ_run, why = 0, 0, "max_moves"
    local curve, curve_ante = {}, 0
    local recs = rf and {}
    local tr = opt.trace > 0 and trace_new() or nil
    while moves < opt.max_moves do
        if tr then trace_top(tr, s) end
        MC.advance_forced(s)
        if MC.terminal(s) then why = "end" break end
        local ph = s.phase
        if tr then trace_phase(tr, s, ph) end
        if opt.curve > 0 and s.ante ~= curve_ante then
            curve_ante = s.ante
            if tr then trace_ante(tr, s) end
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
            local ro_act, ro_e = nil, nil
            if ro_choose and sims > 0 and e and ("," .. opt.ro_ph .. ","):find("," .. ph .. ",", 1, true) and stake >= opt.ro_from then
                ro_act, ro_e = ro_choose(s, seed, moves)
            end
            if ro_act then
                if recs then recs[#recs + 1] = REC.encode_record(mc.F_root, mc, ro_e, sims, FE.PHASES[ph] or 0) end
                if tr then trace_act(tr, s, ro_act) end
                if not E.step(s, ro_act) then why = "step_failed:ro" break end
                moves = moves + 1
                goto continue
            end
            if FAIR and sims > 0 and opt.worlds > 1 and e then
                local ef, ec = mc:root_edges()
                local sum = {}
                for i = 0, ec - 1 do sum[i] = mc.e_N[ef + i] end
                for w = 2, opt.worlds do
                    view = FAIR.world(FAIR.sanitize(s), string.format("FW%s_%d_%d", seed, moves, w))
                    mc:search(view, sims, {noise = 0, reuse = false, adaptive = true})
                    ef, ec = mc:root_edges()
                    for i = 0, ec - 1 do sum[i] = (sum[i] or 0) + mc.e_N[ef + i] end
                end
                local bi = 0
                for i = 1, ec - 1 do
                    if sum[i] > sum[bi] then bi = i end
                end
                e = ef + bi
            end
            if not e then why = "no_edge:" .. ph break end
            if recs then recs[#recs + 1] = REC.encode_record(mc.F_root, mc, e, sims, FE.PHASES[ph] or 0) end
            mc:edge_action(e, step, view)
            if not FAIR then mc:commit(e) end
            if tr then trace_act(tr, s, step) end
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
        ::continue::
    end
    local won = s.won == 1 and 1 or 0
    local ante = won == 1 and s.win_ante + 1 or s.ante
    if recs then
        nrun = nrun + 1
        rf:write(REC.encode_run(recs, won, math.min(ante, 255), FE.DECK_IDX[deck] or 0, stake, nrun))
    end
    s.eval_curve = table.concat(curve, ",")
    if tr then
        trace_top(tr, s)
        s.eval_trace = trace_json(tr, s)
    end
    return won, ante, why, moves, s
end

local function death_fields(s)
    return string.format(',"blind":%d,"chips":%.0f,"need":%.0f,"money":%d,"n_jok":%d,"disc_left":%d', s.blind, s.chips, s.blind_chips, s.money, s.n_jok, s.discards_left) .. (opt.curve > 0 and string.format(',"curve":"%s"', s.eval_curve) or "") .. (s.eval_trace and ',"trace":' .. s.eval_trace or "")
end

local DECKS, STAKES = ES.parse(opt.decks, tostring(opt.stakes))
local fh = opt.out ~= "" and assert(io.open(opt.out, "wb")) or io.stdout
local jf = opt.jsonl ~= "" and assert(io.open(opt.jsonl, "w")) or nil
if opt.list ~= "" then
    local i = 0
    for line in io.lines(opt.list) do
        local d, seed = line:match("^(%S+)%s+(%S+)")
        if d then
            i = i + 1
            if (i - 1) % opt.parts == opt.part then
                local t0 = os.clock()
                local w, a, why, mv, fs = play(d, STAKES[1], seed)
                jf:write(string.format('{"deck":"%s","stake":%d,"seed":"%s","won":%d,"ante":%d,"time":%.2f,"end":"%s","moves":%d%s}\n', d, STAKES[1], seed, w, a, os.clock() - t0, why, mv, death_fields(fs)))
                jf:flush()
            end
        end
    end
elseif opt.prefix ~= "" then
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
