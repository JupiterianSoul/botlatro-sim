local E = require("bot.sim.engine")
local MC = require("bot.nn.mcts")
local F = require("bot.seer.fair")
local S = require("bot.seer.seer")
local P = require("botsim.train.plan")
local PL = require("bot.seer.play")
local D = require("bot.sim.data")
local ST = require("bot.sim.state")

local M = {}

local HAND_JOKER = {
    j_jolly = "Pair", j_sly = "Pair", j_duo = "Pair", j_zany = "Three of a Kind", j_wily = "Three of a Kind", j_trio = "Three of a Kind",
    j_mad = "Two Pair", j_clever = "Two Pair", j_trousers = "Two Pair", j_family = "Four of a Kind",
    j_crazy = "Straight", j_devious = "Straight", j_order = "Straight", j_runner = "Straight", j_superposition = "Straight",
    j_droll = "Flush", j_crafty = "Flush", j_tribe = "Flush", j_seance = "Straight Flush",
}
local CONTAINS = {
    ["Pair"] = {"Pair", "Two Pair", "Three of a Kind", "Full House", "Four of a Kind", "Five of a Kind", "Flush House", "Flush Five"},
    ["Two Pair"] = {"Two Pair", "Full House", "Flush House"},
    ["Three of a Kind"] = {"Three of a Kind", "Full House", "Four of a Kind", "Five of a Kind", "Flush House", "Flush Five"},
    ["Four of a Kind"] = {"Four of a Kind", "Five of a Kind", "Flush Five"},
    ["Straight"] = {"Straight", "Straight Flush"},
    ["Flush"] = {"Flush", "Straight Flush", "Flush House", "Flush Five"},
    ["Straight Flush"] = {"Straight Flush"},
}

function M.load_jtab(path, pos)
    local f = assert(io.open(path))
    local jt = {lo = 99, hi = 0}
    for line in f:lines() do
        local w = {}
        for x in line:gmatch("%S+") do w[#w + 1] = x end
        local kind, a, x, y = w[1], tonumber(w[2]), w[3], w[4]
        local v = tonumber(kind == "P" and w[5] or y)
        if pos and v and v < 0 then v = 0 end
        if kind and a then
            jt[a] = jt[a] or {j = {}, fit = {}, off = {}, pair = {}, ed = {}}
            jt.lo, jt.hi = math.min(jt.lo, a), math.max(jt.hi, a)
            local t = jt[a]
            if kind == "J" then t.j[D.JOKER_ID[x] or -1] = v
            elseif kind == "F" then t.fit[D.JOKER_ID[x] or -1] = v
            elseif kind == "O" then t.off[D.JOKER_ID[x] or -1] = v
            elseif kind == "E" then t.ed[tonumber(x) or -1] = v
            elseif kind == "T" then t.et = tonumber(x)
            elseif kind == "B" then t.bp = tonumber(x)
            elseif kind == "C" then t.deck = t.deck or {}; t.deck[x] = v
            elseif kind == "P" then
                local i, k = D.JOKER_ID[x], D.JOKER_ID[y]
                if i and k then t.pair[math.min(i, k) * 1000 + math.max(i, k)] = v end
            end
        end
    end
    f:close()
    local fits = {}
    for key, h in pairs(HAND_JOKER) do
        local id = D.JOKER_ID[key]
        if id then
            fits[id] = {}
            for _, n in ipairs(CONTAINS[h]) do fits[id][D.HAND_ID[n]] = true end
        end
    end
    jt.fits = fits
    return jt
end

function M.top_hand(w)
    local top, tl = 1, -1
    for h = 1, D.NUM_HANDS do
        if w.h_level[h] > tl or (w.h_level[h] == tl and w.h_played[h] > w.h_played[top]) then top, tl = h, w.h_level[h] end
    end
    return top
end

function M.jvalue(jt, w, ante)
    if jt.hi == 0 then return 0 end
    local t = jt[math.max(jt.lo, math.min(jt.hi, ante))]
    if not t then return 0 end
    local top = M.top_hand(w)
    local v = 0
    for k = 1, w.n_jok do
        local id = w.j_id[k]
        local f = jt.fits[id]
        if f and f[top] and t.fit[id] then v = v + t.fit[id]
        elseif f and not f[top] and t.off[id] then v = v + t.off[id]
        else v = v + (t.j[id] or 0) end
        v = v + (t.ed[w.j_ed[k]] or 0)
        if t.et and (w.j_eternal[k] or 0) ~= 0 then v = v + t.et end
        for q = k + 1, w.n_jok do
            local a, b = id, w.j_id[q]
            v = v + (t.pair[math.min(a, b) * 1000 + math.max(a, b)] or 0)
        end
    end
    if t.bp then v = v + t.bp * math.log(math.max(P.eval(w) or 0, 1)) end
    if t.deck then v = v + M.deck_value(t.deck, w) end
    return v
end

local DECK_ENH = {"bonus", "mult", nil, "glass", "steel", nil, "gold", "lucky"}
local DECK_SEAL = {"oseal", "redseal", "oseal", "oseal"}
local DECK_ED = {"foilholo", "foilholo", "poly"}

function M.deck_value(t, w)
    local v = 0
    for c = 1, w.n_cards do
        if w.c_alive[c] == 1 then
            local e, sl, ed = DECK_ENH[w.c_enh[c] or 0], DECK_SEAL[w.c_seal[c] or 0], DECK_ED[w.c_ed[c] or 0]
            if e then v = v + (t[e] or 0) end
            if sl then v = v + (t[sl] or 0) end
            if ed then v = v + (t[ed] or 0) end
        end
    end
    for _, k in ipairs({"telescope", "observatory"}) do
        local id = t[k] and D.VOUCHER_ID and D.VOUCHER_ID["v_" .. k]
        if id and w.used_v[id] ~= 0 and w.used_v[id] ~= false then v = v + t[k] end
    end
    return v
end

function M.log_power(w)
    local pv = P.eval(w)
    local need = P.need(w)
    if not pv or pv <= 0 or not need or need <= 0 then return nil end
    return math.log(pv / need)
end

local LEAVE, SKIP = {type = "leave"}, {type = "skip"}

local function score(w)
    if w.won == 1 then return w.win_ante + 2 end
    return w.ante + (w.blind_on_deck - 1) / 3
end

local function load_res(path)
    local f = assert(io.open(path, "r"))
    local t = require("bot.sim.json").decode(f:read("*a"))
    f:close()
    local jok = {}
    for i = 1, #D.JOKERS do jok[i] = t.j[D.JOKERS[i].key] or 0 end
    t.jok = jok
    return t
end

local function res_adj(t, w)
    local c = w.ante <= 3 and t.E or t.L
    local a = 0
    local top, second, sum = 0, 0, 0
    for k = 1, 12 do
        local l = w.h_level[k]
        sum = sum + l
        if l > top then top, second = l, top elseif l > second then second = l end
    end
    local et = 0
    for k = 1, w.n_jok do
        a = a + t.jok[w.j_id[k]]
        et = et + w.j_eternal[k]
    end
    a = a + c.money * math.min(math.max(w.money, 0), 60) / 25
    a = a + c.njok * w.n_jok + c.free * (w.joker_limit - w.n_jok)
    a = a + c.deck * (w.n_cards - 52) / 10 + c.hsize * (w.hand_size - 8)
    a = a + c.top * top + c.second * second + c.sumlv * (sum - 12)
    a = a + c.ncons * w.n_cons + c.eter * et
    if c.pow ~= 0 then
        local v = P.eval(w)
        local pw = v > 0 and v * 4 / P.need(w) or 1 / 16
        a = a + c.pow * math.max(-4, math.min(4, math.log(pw) / math.log(2)))
    end
    return a
end

local function apply(w, c)
    if c.seq then
        for i = 1, #c.seq do
            if not E.step(w, c.seq[i]) then return false end
        end
        return true
    end
    return E.step(w, c.a)
end

local function same_action(x, y)
    if x.type ~= y.type or x.card ~= y.card then return false end
    if x.type == "sell" then return x.area == y.area end
    return true
end


local function same_pick(x, y)
    if x.type ~= y.type or x.card ~= y.card then return false end
    local a, b = x.targets or {}, y.targets or {}
    if #a ~= #b then return false end
    local sa, sb = {}, {}
    for i = 1, #a do sa[i], sb[i] = a[i], b[i] end
    table.sort(sa)
    table.sort(sb)
    for i = 1, #sa do
        if sa[i] ~= sb[i] then return false end
    end
    return true
end

local function joker_extras(base, cands, jt)
    if base.phase ~= "shop" then return {} end
    local out = {}
    local function have(a)
        for _, c in ipairs(cands) do
            if not c.seq and same_action(c.a, a) then return true end
        end
        return false
    end
    local sell
    if base.n_jok >= base.joker_limit then
        local bv
        for j = 1, base.n_jok do
            if base.j_eternal[j] == 0 then
                local w = ST.clone(base)
                if E.sell(w, "jokers", j) then
                    local v = P.eval(w)
                    if not bv or v > bv then bv, sell = v, j end
                end
            end
        end
        if not sell then return out end
    end
    local sell2
    if sell and jt then
        local bv
        for j = 1, base.n_jok do
            if base.j_eternal[j] == 0 then
                local w = ST.clone(base)
                if E.sell(w, "jokers", j) then
                    local v = M.jvalue(jt, w, base.ante)
                    if not bv or v > bv then bv, sell2 = v, j end
                end
            end
        end
        if sell2 == sell then sell2 = nil end
    end
    for k = 1, base.n_sj do
        if base.sj_kind[k] == 1 then
            local buy = {type = "buy", card = k}
            local w = ST.clone(base)
            if sell then
                local sa = {type = "sell", area = "jokers", card = sell}
                if E.step(w, sa) and E.step(w, buy) then out[#out + 1] = {a = sa, seq = {sa, buy}} end
                if sell2 then
                    local w2 = ST.clone(base)
                    local sb = {type = "sell", area = "jokers", card = sell2}
                    if E.step(w2, sb) and E.step(w2, buy) then out[#out + 1] = {a = sb, seq = {sb, buy}} end
                end
            elseif not have(buy) and E.step(w, buy) then
                out[#out + 1] = {a = buy}
            end
        end
    end
    return out
end

M.joker_extras = joker_extras

function M.chooser(mc, rmc, opt)
    local RES = (opt.ro_res or "") ~= "" and load_res(opt.ro_res) or nil
    local RW = tonumber(opt.ro_resw) or 1
    if (opt.ro_book or "") ~= "" then P.load_scale(opt.ro_book) end
    local step = {type = "play", cards = {}}
    local ORDRO = (tonumber(opt.ro_ordro) or 0) > 0
    local ORDMEMO = (tonumber(opt.ro_ordro) or 0) == 2
    local omemo = {}
    local BASEK = tonumber(opt.ro_base) or 1
    local MINT = (tonumber(opt.ro_mint) or 0) > 0
    local CVX = tonumber(opt.ro_cvx) or 0
    local WINB = tonumber(opt.ro_winb) or 0
    local TOP = tonumber(opt.ro_top) or 0
    local VM = tonumber(opt.ro_vm) or 1
    local ECON = tonumber(opt.ro_econ) or 0
    local ECON_A = tonumber(opt.ro_econ_a) or 3
    local DK = tonumber(opt.ro_deck) or 0
    local JTW = tonumber(opt.ro_jt) or 0
    local JT = JTW ~= 0 and M.load_jtab(opt.ro_jtab, (tonumber(opt.ro_jtp) or 0) > 0) or nil
    local JTA = tonumber(opt.ro_jt_a) or 0
    local root_jv, jt_on = 0, false
    local JTS = (tonumber(opt.ro_jts) or 0) > 0
    local JTH = (tonumber(opt.ro_jth) or 0) > 0
    local PW = tonumber(opt.ro_pw) or 0
    local PW_A = tonumber(opt.ro_pw_a) or 0
    local root_lp = 0
    local root_s, root_jva = nil, {}
    local DKC = (tonumber(opt.ro_deckc) or 0) > 0 and require("botsim.train.teach").new({t_all = 1, t_deck = opt.t_deck}) or nil
    local DKC2 = DKC and (tonumber(opt.ro_deckc) or 0) >= 2
    local function deck_step(w)
        local m = DKC:deck_moves(w)[1]
        return m and E.step(w, m)
    end
    local root_plan, root_reach = nil, 0
    local H2 = {}
    for a, n in tostring(opt.ro_h2 or ""):gmatch("(%d+):?(%d*)") do H2[tonumber(a)] = tonumber(n) or 1 end
    local TT = (tonumber(opt.ro_tarot) or 0) > 0 and require("botsim.train.teach").new({t_all = 1, t_deck = opt.t_deck}) or nil
    local function use_tarot(w)
        local u = TT:use_now(w)
        return u and E.step(w, u)
    end
    local root_money, root_ante = 0, 0

    local function jkey(w)
        local key = w.n_jok
        for k = 1, w.n_jok do key = key .. "," .. w.j_uid[k] end
        return key
    end

    local function idkey(w)
        local key = w.n_jok
        for k = 1, w.n_jok do key = key .. "," .. w.j_id[k] .. ":" .. w.j_ed[k] end
        return key
    end

    local function order_for(w)
        if not ORDMEMO then return P.best_order(w) end
        local ik = idkey(w)
        local o = omemo[ik]
        if o == nil then
            o = P.best_order(w) or false
            omemo[ik] = o
        end
        return o
    end

    local function run_body(w, stop_ante)
        local moves, econ_run = 0, 0
        local okey
        while moves < 400 do
            MC.advance_forced(w)
            if MC.terminal(w) or (stop_ante > 0 and w.ante >= stop_ante) then break end
            if (opt.ro_useplanet or 0) > 0 then P.use_planets(w, E.step) end
            if ORDRO and w.phase == "blind_select" and not P.any_flipped(w) then
                local key = jkey(w)
                if key ~= okey then
                    local o = order_for(w)
                    if o then E.step(w, {type = "reorder_jokers", order = o}) end
                    okey = jkey(w)
                end
            end
            local ph = w.phase
            if ph == "shop" or ph == "pack" then econ_run = econ_run + 1 else econ_run = 0 end
            if TT and ph == "play" and w.n_cons > 0 and use_tarot(w) then
            elseif DKC2 and (ph == "pack" or (ph == "play" and w.n_cons > 0)) and deck_step(w) then
            elseif econ_run > opt.max_shop then
                if not E.step(w, ph == "pack" and SKIP or LEAVE) then break end
            elseif ph == "play" and (opt.ro_fast or 0) == 1 then
                local a = PL.fast_action(w, true)
                if not a or not E.step(w, a) then break end
            elseif ph == "play" and (opt.ro_fast or 0) == 3 then
                local a = PL.fast_action(w, true)
                if a and a.type == "discard" then a = F.draw_keep(w) or a end
                if not a or not E.step(w, a) then break end
            elseif ph == "play" and (opt.ro_fast or 0) == 2 then
                local acts = PL.solve(w, {beam = 3, plays = 2, discards = 3, kid_top = 8})
                local stepped = false
                for i = 1, #acts do
                    if w.phase ~= "play" or not E.step(w, acts[i]) then break end
                    stepped = true
                    moves = moves + 1
                end
                if not stepped then
                    local a = PL.fast_action(w, true)
                    if not a or not E.step(w, a) then break end
                end
            else
                rmc:search(w, 0, {noise = 0, reuse = false, adaptive = true})
                local e = rmc:choose(0)
                if not e then break end
                rmc:edge_action(e, step, w)
                if not E.step(w, step) then break end
            end
            moves = moves + 1
        end
        local v = score(w)
        if WINB ~= 0 and w.won == 1 then v = v + WINB end
        if RES and RES.cal and stop_ante > 0 and not MC.terminal(w) then
            rmc:search(w, 0, {noise = 0, reuse = false, adaptive = true})
            local A = tostring(math.min(w.ante, 8))
            return math.max(w.ante, (RES.a[A] or w.ante) + (RES.nv[A] or opt.ro_net) * rmc.n_val[rmc.root] + RW * res_adj(RES, w))
        end
        if stop_ante > 0 and not MC.terminal(w) then
            if BASEK ~= 1 then v = v * BASEK end
            if MINT then
                local cap = w.interest_cap or 25
                if opt.ro_mon ~= 0 and (w.no_interest or 0) == 0 and w.money >= 5 then
                    v = v + opt.ro_mon * (w.interest_amount or 1) * math.min(math.floor(w.money / 5), cap / 5) / 5
                end
                w.money = math.min(w.money, cap + 5)
            elseif opt.ro_mon ~= 0 then v = v + opt.ro_mon * math.min(math.max(w.money, 0), 50) / 50 end
            if ECON ~= 0 and root_ante <= ECON_A and (w.no_interest or 0) == 0 then
                v = v + ECON * (w.interest_amount or 1) * math.min(math.floor(math.max(w.money, 0) / 5), (w.interest_cap or 25) / 5) / 5
            end
            if DK ~= 0 and root_plan then v = v + DK * (P.reach(w, root_plan) - root_reach) end
            if PW ~= 0 and w.ante >= PW_A then
                local lp = M.log_power(w)
                if lp then v = v + PW * (lp - root_lp) end
            end
            if jt_on and JTH then
                local a = w.ante
                local r = root_jva[a]
                if not r then
                    r = M.jvalue(JT, root_s, a)
                    root_jva[a] = r
                end
                v = v + JTW * (M.jvalue(JT, w, a) - r)
            elseif jt_on then v = v + JTW * (M.jvalue(JT, w, root_ante) - root_jv) end
            if VM ~= 1 then w.money = math.floor(root_money + VM * (w.money - root_money) + 0.5) end
            if opt.ro_net ~= 0 then
                rmc:search(w, 0, {noise = 0, reuse = false, adaptive = true})
                v = v + opt.ro_net * rmc.n_val[rmc.root]
            end
            if (opt.ro_planh or 0) ~= 0 then v = v + opt.ro_planh * P.score(w) end
            if RES then v = v + RW * res_adj(RES, w) end
        end
        if CVX > 0 then v = 9 * (math.max(v, 0) / 9) ^ CVX end
        return v
    end

    local function run(w, stop_ante)
        if TOP <= 0 then return run_body(w, stop_ante) end
        local top0 = PL.FAST_TOP
        PL.FAST_TOP = TOP
        local v = run_body(w, stop_ante)
        PL.FAST_TOP = top0
        return v
    end

    local function race(alive, r)
        local best = alive[1]
        for i = 2, #alive do
            if alive[i].v > best.v then best = alive[i] end
        end
        local keep = {}
        for _, c in ipairs(alive) do
            local sum, sq = 0, 0
            for i = 1, r do
                local d = best.h[i] - c.h[i]
                sum = sum + d
                sq = sq + d * d
            end
            local se2 = (sq - sum * sum / r) / (r - 1) / r
            if c == best or (se2 > 0 and sum / r < opt.ro_z * math.sqrt(se2)) then keep[#keep + 1] = c end
        end
        return keep
    end

    return function(s, seed, moves)
        root_money, root_ante = s.money, s.ante
        jt_on = JT ~= nil and (s.phase == "shop" or s.phase == "pack") and s.ante >= JTA
        local rs = (jt_on or PW ~= 0) and F.sanitize(s) or s
        if jt_on then root_jv, root_s, root_jva = M.jvalue(JT, rs, s.ante), rs, {} end
        if PW ~= 0 then root_lp = M.log_power(rs) or 0 end
        if ORDMEMO then omemo = {} end
        if TT then TT:update_plan(s) end
        local ef, ec = mc:root_edges()
        if ec < 2 then return nil end
        local order = {}
        for i = 0, ec - 1 do order[i + 1] = ef + i end
        table.sort(order, function(a, b)
            if mc.e_N[a] ~= mc.e_N[b] then return mc.e_N[a] > mc.e_N[b] end
            return a < b
        end)
        local base = F.sanitize(s)
        local cands = {}
        for i = 1, math.min(opt.ro_c, ec) do
            mc:edge_action(order[i], step, base)
            cands[i] = {a = S.copy_action(step), e = order[i], v = 0, n = 0, h = {}}
        end
        if (opt.ro_plan or 0) ~= 0 then
            local key = string.format("RP%s_%d", seed, moves)
            local function worth(a)
                local w = F.world(base, key)
                if not E.step(w, a) then return nil end
                return P.score(w)
            end
            for _, c in ipairs(cands) do c.p = opt.ro_plan * (worth(c.a) or 0) end
            if (opt.ro_plan_c or 0) > 0 and ec > #cands then
                local have = {}
                for _, c in ipairs(cands) do have[c.e] = true end
                local bv, be, ba = -math.huge, nil, nil
                for i = 0, ec - 1 do
                    local e = ef + i
                    if not have[e] then
                        mc:edge_action(e, step, base)
                        if step.type ~= "leave" and step.type ~= "skip" then
                            local a = S.copy_action(step)
                            local v = worth(a)
                            if v and v > bv then bv, be, ba = v, e, a end
                        end
                    end
                end
                if be then cands[#cands + 1] = {a = ba, e = be, v = 0, n = 0, h = {}, p = opt.ro_plan * bv} end
            end
        end
        if (tonumber(opt.ro_swap) or 0) > 0 then
            for _, x in ipairs(joker_extras(base, cands, JTS and JT or nil)) do
                local e
                for i = 0, ec - 1 do
                    mc:edge_action(ef + i, step, base)
                    if same_action(step, x.a) then e = ef + i break end
                end
                if e then cands[#cands + 1] = {a = S.copy_action(x.a), seq = x.seq, e = e, v = 0, n = 0, h = {}} end
            end
        end
        local sx = tonumber(opt.ro_shopx) or 0
        if sx > 0 and #cands < ec then
            local have = {}
            for _, c in ipairs(cands) do if not c.seq then have[c.e] = true end end
            for i = 0, ec - 1 do
                local e = ef + i
                if not have[e] then
                    mc:edge_action(e, step, base)
                    local t = step.type
                    local want = (base.phase == "shop" and (((t == "open" or t == "redeem") and sx % 2 == 1)
                        or (t == "reroll" and math.floor(sx / 2) % 2 == 1)
                        or (t == "sell" and math.floor(sx / 8) % 2 == 1)
                        or ((t == "use" or t == "buy_and_use") and math.floor(sx / 16) % 2 == 1)
                        or (t == "buy" and math.floor(sx / 32) % 2 == 1)))
                        or (base.phase == "pack" and math.floor(sx / 4) % 2 == 1)
                    if want then cands[#cands + 1] = {a = S.copy_action(step), e = e, v = 0, n = 0, h = {}} end
                end
            end
        end
        if (tonumber(opt.ro_teach) or 0) > 0 then
            local ta = require("botsim.train.teach").new(opt):move(base)
            local dup = false
            for _, c in ipairs(cands) do
                if not c.seq and ta and same_action(c.a, ta) then dup = true end
            end
            if ta and not dup and (base.phase == "shop" or base.phase == "pack") then
                local e
                for i = 0, ec - 1 do
                    mc:edge_action(ef + i, step, base)
                    if same_action(step, ta) then e = ef + i break end
                end
                if e or opt.rec == "" then cands[#cands + 1] = {a = ta, e = e or cands[1].e, v = 0, n = 0, h = {}} end
            end
        end
        if DK ~= 0 or DKC then
            local _, plan = P.eval(base)
            root_plan = plan and plan > 0 and plan or nil
            root_reach = root_plan and P.reach(base, root_plan) or 0
        end
        if DKC then DKC.plan, DKC.plan_ante = root_plan, base.ante end
        if DKC and base.phase == "pack" then
            for _, a in ipairs(DKC:deck_moves(base)) do
                local dup, e = false, nil
                for _, x in ipairs(cands) do
                    if not x.seq and same_pick(x.a, a) then dup = true end
                end
                for k = 0, ec - 1 do
                    mc:edge_action(ef + k, step, base)
                    if same_pick(step, a) then e = ef + k break end
                end
                if not dup and (e or opt.rec == "") then cands[#cands + 1] = {a = a, e = e or cands[1].e, v = 0, n = 0, h = {}} end
            end
        end
        local stop_ante = opt.ro_h > 0 and s.ante + opt.ro_h + (H2[s.ante] or 0) or 0
        local alive = cands
        local check = opt.ro_a > 0 and opt.ro_a or opt.ro + 1
        for r = 1, opt.ro do
            local key = string.format("RO%s_%d_%d", seed, moves, r)
            for _, c in ipairs(alive) do
                local w = F.world(base, key)
                local v = (apply(w, c) and run(w, stop_ante) or -100) + (c.p or 0)
                c.v = c.v + v
                c.n = r
                c.h[r] = v
            end
            if r == check then
                alive = race(alive, r)
                if #alive == 1 then break end
                check = check * 2
            end
        end
        local best = alive[1]
        for i = 2, #alive do
            if alive[i].v > best.v then best = alive[i] end
        end
        if opt.rec ~= "" then
            local ef2, ec2 = mc:root_edges()
            for e = ef2, ef2 + ec2 - 1 do mc.e_N[e] = 0 end
            local top, sum = best.v / best.n, 0
            for _, c in ipairs(cands) do
                c.w = math.exp((c.v / c.n - top) / opt.ro_t)
                sum = sum + c.w
            end
            for _, c in ipairs(cands) do mc.e_N[c.e] = math.floor(32 * c.w / sum + 0.5) end
            mc.rec_judged = nil
            if (tonumber(opt.rec_mask) or 0) > 0 then
                mc.rec_judged = {}
                for _, c in ipairs(cands) do mc.rec_judged[c.e] = true end
            end
        end
        if (tonumber(opt.ro_seq) or 0) > 0 and best.seq then return best.a, best.e, best.seq end
        return best.a, best.e
    end
end

return M
