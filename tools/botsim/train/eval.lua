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
    mix = -1, score_prior = 0, score_top = 6, score_temp = 4, skip_pen = 1, skip_ante = 1, type_mass = 0, tm_plays = 0, quick_clear = 0, pace = 0, pace_net = 0, prefix = "", first = 1, seeds = 10, jsonl = "", fair = 0, search_ph = "", rec = "", solver = "", solver_qc = 0, set = "", curve = 0, trace = 0, list = "", leaf_money = 0, leaf_rent = 0, leaf_dead = 0, rent_prior = 1, rent_from = 0, sell_dead = 0, c_puct = 1.5, worlds = 1, ro = 0, ro_a = 0, ro_z = 2, ro_c = 3, ro_h = 0, ro_ph = "shop,pack,blind_select", ro_from = 0, ro_mon = 0, ro_net = 0, ro_t = 0.25, log = ""}
opt.digest = 0
opt.solver_h, opt.solver_en, opt.solver_hb = 0, 0, 0
opt.swap_play, opt.swap_shop = 0, 0
opt.ro_plan, opt.ro_plan_c, opt.ro_planh, opt.ro_fast, opt.ro_useplanet, opt.ro_order, opt.ro_book = 0, 0, 0, 0, 0, 0, ""
for _, a in ipairs(arg or {}) do
    local k, v = a:match("^([%w_]+)=(.*)$")
    if k then opt[k] = tonumber(v) or v end
end

local mc, rmc
if opt.who == "net" then
    local W = WT.load(opt.weights)
    local function new_mc() return MC.new(NET.new(W), {K = opt.K, seed = 99991, alpha = 0.5, mix = opt.mix >= 0 and opt.mix or nil,
        score_prior = opt.score_prior, score_top = opt.score_top, score_temp = opt.score_temp, skip_pen = opt.skip_pen, skip_ante = opt.skip_ante, type_mass = opt.type_mass, tm_plays = opt.tm_plays, quick_clear = opt.quick_clear, pace = opt.pace, pace_net = opt.pace_net, leaf_money = opt.leaf_money, leaf_rent = opt.leaf_rent, leaf_dead = opt.leaf_dead, rent_prior = opt.rent_prior, rent_from = opt.rent_from, c_puct = opt.c_puct, nodes = 2 * opt.sims + 2, full = true}) end
    mc = new_mc()
    if opt.ro > 0 then rmc = new_mc() end
end
POL.shop = true
local FAIR = opt.fair > 0 and require("bot.seer.fair") or nil
local PL = require("bot.seer.play")
local SOLVER = FAIR and opt.solver ~= "" and FAIR.new({budget = opt.solver, quick_clear = opt.solver_qc > 0, honest = opt.solver_h, eval_n = opt.solver_en, honest_final = opt.solver_hb > 0 and 0 or 1}) or nil
local SWAP = (opt.swap_play > 0 or opt.swap_shop > 0) and require("bot.seer.seer").new({}) or nil
local SWAP_PH = {play = opt.swap_play > 0, shop = opt.swap_shop > 0, pack = opt.swap_shop > 0, blind_select = opt.swap_shop > 0}
local REC = opt.rec ~= "" and mc and require("botsim.train.records") or nil
local TCH = REC and SOLVER and require("botsim.seer.teacher") or nil
local rf, nrun = REC and assert(io.open(opt.rec, "wb")), 0
if rf then rf:write(REC.file_header()) end

local LEAVE, SKIP = {type = "leave"}, {type = "skip"}
local step = {type = "play", cards = {}}
local F, AB = FE.new_state_buf(), FE.new_action_buf(1024)
local st = {}

local PLAN = require("botsim.train.plan")
local ro_choose = opt.ro > 0 and require("botsim.train.rollout").chooser(mc, rmc, opt) or nil

local D = require("bot.sim.data")
local BOOSTER = require("bot.sim.data_centers").Booster

local function trace_new()
    return {a = {}, r = {}, offer = {}, act = {}, buy = {}, spend = {}, shops = {}}
end

local function joker_keys(s)
    local j = {}
    for k = 1, s.n_jok do j[k] = D.JOKERS[s.j_id[k]].key end
    return j
end

local function cons_keys(s)
    local c = {}
    for k = 1, s.n_cons do c[k] = s.cons[k] end
    return c
end

local function hand_cards(s)
    local h = {}
    for k = 1, s.n_hand do
        local c = s.hand[k]
        h[k] = {s.c_rank[c], s.c_suit[c], s.c_enh[c], s.c_ed[c], s.c_seal[c]}
    end
    return h
end

local function shop_item(s, k)
    local kind, id = s.sj_kind[k], s.sj_id[k]
    if kind == E.K_JOKER then return D.JOKERS[id].key end
    if kind == E.K_CONS then return D.CONS[id].key end
    return "card"
end

local function solver_clears(s)
    local _, ok = PL.solve(s, {beam = 6, plays = 3, discards = 6})
    return ok and 1 or 0
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
    local pv, ph = PLAN.eval(s)
    tr.a[#tr.a + 1] = {ante = s.ante, money = s.money, jok = j, lv = lv, n_deck = s.n_cards, v = v, limit = s.joker_limit, plan = ph, pv = pv}
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
        tr.cur = {round = s.round, ante = s.ante, blind = D.BLINDS[s.blind].key, need = s.blind_chips, chips = 0, best = 0, plays = 0, discards = 0, money = s.money, hands = s.hands_left, disc = s.discards_left,
            jok = joker_keys(s), lv = {}, cons = cons_keys(s), hsize = s.hand_size, sv = solver_clears(s), log = {}}
        for k = 1, 12 do tr.cur.lv[k] = s.h_level[k] end
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
            local v = tr.shops[#tr.shops]
            if not v or v.round ~= s.round then
                v = {round = s.round, ante = s.ante, money = s.money, jok = {}, vou = {}, pack = {}}
                tr.shops[#tr.shops + 1] = v
                for k = 1, s.n_sv do v.vou[k] = D.VOUCHERS[s.sv_id[k]].key end
                for k = 1, s.n_sb do v.pack[k] = BOOSTER[s.sb_id[k]].key end
            end
            for k = 1, s.n_sj do
                local key = shop_item(s, k)
                v.jok[key] = E.shop_joker_cost(s, k)
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
    if tr.cur and s.phase == "play" and (a.type == "play" or a.type == "discard") then
        local _, bv = PL.best_play(s)
        local l = tr.cur.log
        l[#l + 1] = {t = a.type, c = {unpack(a.cards)}, best = bv, chips = s.chips, h = hand_cards(s)}
    end
    if a.type == "buy" or a.type == "buy_and_use" then
        tr.spend[#tr.spend + 1] = {s.ante, a.type, shop_item(s, a.card), s.money, E.shop_joker_cost(s, a.card)}
    elseif a.type == "redeem" then
        tr.spend[#tr.spend + 1] = {s.ante, a.type, D.VOUCHERS[s.sv_id[a.card]].key, s.money, E.shop_voucher_cost(s, a.card)}
    elseif a.type == "open" then
        tr.spend[#tr.spend + 1] = {s.ante, a.type, BOOSTER[s.sb_id[a.card]].key, s.money}
    elseif a.type == "sell" and a.area == "jokers" then
        tr.spend[#tr.spend + 1] = {s.ante, a.type, D.JOKERS[s.j_id[a.card]].key, s.money}
    elseif a.type == "use" then
        tr.spend[#tr.spend + 1] = {s.ante, a.type, s.cons[a.card], s.money}
    end
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
    for k = 1, #tr.r - 1 do tr.r[k].log = nil end
    return json.encode({a = tr.a, r = tr.r, offer = offer, act = act, buy = tr.buy, spend = tr.spend, shops = tr.shops, n_hand = s.n_hand, n_deck = s.n_deck, phase = s.phase})
end

local function game_key(deck, stake, seed)
    local h, key = 7, deck .. "|" .. stake .. "|" .. seed
    for i = 1, #key do h = (h * 1000003 + key:byte(i)) % 2147483629 end
    return h * 1000003 % 2147483629
end
local function positions(list)
    local out = {}
    for i = 1, #list do out[i] = string.format("%d", list[i]) end
    return "[" .. table.concat(out, ",") .. "]"
end

local function action_line(a)
    local t = a.type
    if t == "play" or t == "discard" then
        return string.format('{"type":"%s","cards":%s}', t, positions(a.cards))
    elseif t == "use" or t == "pick" then
        if a.targets and #a.targets > 0 then
            return string.format('{"type":"%s","card":%d,"targets":%s}', t, a.card, positions(a.targets))
        end
        return string.format('{"type":"%s","card":%d}', t, a.card)
    elseif t == "sell" then
        return string.format('{"type":"sell","area":"%s","card":%d}', a.area, a.card)
    elseif t == "reorder_jokers" then
        return string.format('{"type":"reorder_jokers","order":%s}', positions(a.order))
    elseif t == "buy" or t == "buy_and_use" or t == "redeem" or t == "open" then
        return string.format('{"type":"%s","card":%d}', t, a.card)
    end
    return string.format('{"type":"%s"}', t)
end

local function open_log(deck, stake, seed)
    if opt.log == "" then return nil end
    return {path = string.format("%s/%s_s%d_%s", opt.log, deck, stake, seed),
        string.format('{"seed":"%s","deck":"%s","stake":%d,"challenge":null}', seed, deck, stake)}
end

local function close_log(alog, s)
    if not alog then return end
    local f = assert(io.open(alog.path .. ".jsonl", "w"))
    f:write(table.concat(alog, "\n"), "\n")
    f:close()
    f = assert(io.open(alog.path .. ".final", "w"))
    f:write(require("bot.sim.snapshot").line(s), "\n")
    f:close()
end

local CASH = {type = "cash_out"}

local function play(deck, stake, seed)
    local s = E.new_run({seed = seed, deck = deck, stake = stake})
    if mc then
        local h = game_key(deck, stake, seed)
        mc:new_game(h)
        if rmc then rmc:new_game(h + 1) end
    end
    local dig = 7
    for k, v in tostring(opt.set):gmatch("([%w_]+):(-?[%d%.]+)") do s[k] = tonumber(v) end
    local moves, econ_run, why = 0, 0, "max_moves"
    local order_key, order_moves = nil, 0
    local curve, curve_ante = {}, 0
    local recs = rf and {}
    local tr = opt.trace > 0 and trace_new() or nil
    local alog = open_log(deck, stake, seed)
    local function do_step(w, act)
        local line = alog and action_line(act)
        local ok = E.step(w, act)
        if ok and alog then alog[#alog + 1] = line end
        return ok
    end
    local function do_forced(w)
        if not alog then return MC.advance_forced(w) end
        for _ = 1, 8 do
            if w.phase ~= "round_eval" or w.won == 1 then return end
            if not do_step(w, CASH) then return end
        end
    end
    while moves < opt.max_moves do
        if tr then trace_top(tr, s) end
        do_forced(s)
        if opt.digest > 0 then dig = (dig * 1000003 + MC.obs_key(s, true)) % 4294967291 end
        if MC.terminal(s) then why = "end" break end
        if opt.ro_useplanet > 0 then
            PLAN.use_planets(s, function(w, a)
                if tr then trace_act(tr, w, a) end
                return do_step(w, a)
            end)
        end
        if opt.ro_order > 0 and s.phase == "blind_select" then
            local key = s.n_jok
            for k = 1, s.n_jok do key = key .. "," .. s.j_uid[k] end
            if key ~= order_key then
                order_key = key
                local o = PLAN.best_order(FAIR and FAIR.world(FAIR.sanitize(s), "ORD_" .. s.ante) or s)
                if o and do_step(s, {type = "reorder_jokers", order = o}) then order_moves = order_moves + 1 end
                order_key = s.n_jok
                for k = 1, s.n_jok do order_key = order_key .. "," .. s.j_uid[k] end
            end
        end
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
                if s.j_perish[k] == 0 then do_step(s, {type = "sell", area = "jokers", card = k}) end
            end
        end
        if ph == "shop" or ph == "pack" then econ_run = econ_run + 1 else econ_run = 0 end
        if econ_run > opt.max_shop then
            if not do_step(s, ph == "pack" and SKIP or LEAVE) then why = "stuck_econ:" .. ph break end
        elseif SOLVER and ph == "play" then
            SOLVER.last_cands = nil
            local acts = SOLVER:decide(s)
            if recs and acts and acts[1] then
                local r = TCH.encode(s, acts[1], {K = 32, neg = 16, n_sims = opt.sims}, FAIR.scores_of(SOLVER.last_cands or {}))
                if r then recs[#recs + 1] = r end
            end
            if not acts or not acts[1] or not do_step(s, acts[1]) then
                local fb = PL.fast_action(s)
                if not fb or not do_step(s, fb) then why = "step_failed:play:solver" break end
            end
            moves = moves + 1
        elseif SWAP and SWAP_PH[ph] then
            local a = SWAP:choose(s)
            if tr and a then trace_act(tr, s, a) end
            if not a or not do_step(s, a) then
                SWAP.plan = nil
                local fb = ph == "play" and PL.fast_action(s) or ph == "shop" and LEAVE or ph == "pack" and SKIP or {type = "select"}
                if not do_step(s, fb) then why = "step_failed:swap:" .. ph break end
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
                if not do_step(s, ro_act) then why = "step_failed:ro" break end
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
            if not do_step(s, step) then why = "step_failed:" .. ph .. ":" .. tostring(step.type) break end
            moves = moves + 1
        else
            FE.state(s, F)
            local n = FE.list_actions(s, AB, F)
            if n == 0 then why = "no_actions:" .. ph break end
            local a = POL.choose(s)
            local k = a and FE.find_action(AB, a, s) or -1
            if k < 0 then k = 0 end
            local fs = FE.to_step(AB, k, st, s)
            if not do_step(s, fs) then why = "step_failed:" .. ph .. ":" .. tostring(fs.type) break end
            moves = moves + 1
        end
        ::continue::
    end
    local won = s.won == 1 and s.phase ~= "game_over" and 1 or 0
    local ante = won == 1 and s.win_ante + 1 or s.ante
    if recs then
        nrun = nrun + 1
        local flag = s.won == 1 and 1 or 0
        rf:write(REC.encode_run(recs, flag, math.min(flag == 1 and s.win_ante + 1 or s.ante, 255), FE.DECK_IDX[deck] or 0, stake, nrun))
    end
    s.eval_curve = table.concat(curve, ",")
    if tr then
        trace_top(tr, s)
        s.eval_trace = trace_json(tr, s)
    end
    s.eval_dig = dig
    close_log(alog, s)
    return won, ante, why, moves, s
end

local function finite(x)
    if x ~= x then return -1 end
    return math.min(x, 1e300)
end

local function death_fields(s)
    return string.format(',"blind":%d,"chips":%.0f,"need":%.0f,"money":%d,"n_jok":%d,"disc_left":%d', s.blind, finite(s.chips), finite(s.blind_chips), s.money, s.n_jok, s.discards_left) .. (opt.curve > 0 and string.format(',"curve":"%s"', s.eval_curve) or "") .. (opt.digest > 0 and string.format(',"dig":"%.0f"', s.eval_dig) or "") .. (s.eval_trace and ',"trace":' .. s.eval_trace or "")
end

local DECKS, STAKES = ES.parse(opt.decks, tostring(opt.stakes))
local fh = opt.out ~= "" and assert(io.open(opt.out, "wb")) or io.stdout
local jf = opt.jsonl ~= "" and assert(io.open(opt.jsonl, "w")) or nil
if opt.list ~= "" then
    local i = 0
    for line in io.lines(opt.list) do
        local d, seed, stk = line:match("^(%S+)%s+(%S+)%s*(%d*)")
        if d then
            i = i + 1
            if (i - 1) % opt.parts == opt.part then
                stk = tonumber(stk) or STAKES[1]
                local t0 = os.clock()
                local w, a, why, mv, fs = play(d, stk, seed)
                jf:write(string.format('{"deck":"%s","stake":%d,"seed":"%s","won":%d,"ante":%d,"time":%.2f,"end":"%s","moves":%d%s}\n', d, stk, seed, w, a, os.clock() - t0, why, mv, death_fields(fs)))
                jf:flush()
            end
        end
    end
elseif opt.prefix ~= "" then
    local i = 0
    for _, d in ipairs(DECKS) do
        for _, stk in ipairs(STAKES) do
            local wins, antes, sq, played = 0, 0, 0, 0
            for k = opt.first, opt.first + opt.seeds - 1 do
                i = i + 1
                if (i - 1) % opt.parts == opt.part then
                    local seed = string.format("%s%04d", opt.prefix, k)
                    local t0 = os.clock()
                    local w, a, why, mv, fs = play(d, stk, seed)
                    wins, antes, sq, played = wins + w, antes + a, sq + a * a, played + 1
                    if jf then
                        jf:write(string.format('{"deck":"%s","stake":%d,"seed":"%s","won":%d,"ante":%d,"time":%.2f,"end":"%s","moves":%d%s}\n', d, stk, seed, w, a, os.clock() - t0, why, mv, death_fields(fs)))
                        jf:flush()
                    end
                end
            end
            fh:write(json.encode({deck = d, stake = stk, n = played, wins = wins, ante_sum = antes, ante_sq = sq}) .. "\n")
            fh:flush()
        end
    end
else
for i, c in ipairs(ES.cells(opt.per, DECKS, STAKES)) do
    if (i - 1) % opt.parts == opt.part then
        local wins, antes, sq = 0, 0, 0
        for k = 1, c.per do
            local t0 = os.clock()
            local w, a, why, mv, fs = play(c.deck, c.stake, ES.seed(c.deck, c.stake, k))
            wins = wins + w
            antes = antes + a
            sq = sq + a * a
            if jf then
                jf:write(string.format('{"deck":"%s","stake":%d,"seed":"%s","won":%d,"ante":%d,"time":%.2f,"end":"%s","moves":%d%s}\n', c.deck, c.stake, ES.seed(c.deck, c.stake, k), w, a, os.clock() - t0, why, mv, death_fields(fs)))
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
