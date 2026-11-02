local E = require("bot.sim.engine")
local MC = require("bot.nn.mcts")
local F = require("bot.seer.fair")
local S = require("bot.seer.seer")
local P = require("botsim.train.plan")
local PL = require("bot.seer.play")
local D = require("bot.sim.data")
local ST = require("bot.sim.state")

local M = {}

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

local function joker_extras(base, cands)
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
    for k = 1, base.n_sj do
        if base.sj_kind[k] == 1 then
            local buy = {type = "buy", card = k}
            local w = ST.clone(base)
            if sell then
                local sa = {type = "sell", area = "jokers", card = sell}
                if E.step(w, sa) and E.step(w, buy) then out[#out + 1] = {a = sa, seq = {sa, buy}} end
            elseif not have(buy) and E.step(w, buy) then
                out[#out + 1] = {a = buy}
            end
        end
    end
    return out
end

function M.chooser(mc, rmc, opt)
    local RES = (opt.ro_res or "") ~= "" and load_res(opt.ro_res) or nil
    local RW = tonumber(opt.ro_resw) or 1
    if (opt.ro_book or "") ~= "" then P.load_scale(opt.ro_book) end
    local step = {type = "play", cards = {}}
    local ORDRO = (tonumber(opt.ro_ordro) or 0) > 0
    local BASEK = tonumber(opt.ro_base) or 1
    local MINT = (tonumber(opt.ro_mint) or 0) > 0
    local CVX = tonumber(opt.ro_cvx) or 0
    local TOP = tonumber(opt.ro_top) or 0

    local function jkey(w)
        local key = w.n_jok
        for k = 1, w.n_jok do key = key .. "," .. w.j_uid[k] end
        return key
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
                    local o = P.best_order(w)
                    if o then E.step(w, {type = "reorder_jokers", order = o}) end
                    okey = jkey(w)
                end
            end
            local ph = w.phase
            if ph == "shop" or ph == "pack" then econ_run = econ_run + 1 else econ_run = 0 end
            if econ_run > opt.max_shop then
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
            for _, x in ipairs(joker_extras(base, cands)) do
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
                        or ((t == "use" or t == "buy_and_use") and math.floor(sx / 16) % 2 == 1)))
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
        local stop_ante = opt.ro_h > 0 and s.ante + opt.ro_h or 0
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
        end
        if (tonumber(opt.ro_seq) or 0) > 0 and best.seq then return best.a, best.e, best.seq end
        return best.a, best.e
    end
end

return M
