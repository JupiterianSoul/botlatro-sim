local E = require("bot.sim.engine")
local MC = require("bot.nn.mcts")
local F = require("bot.seer.fair")
local S = require("bot.seer.seer")
local P = require("botsim.train.plan")
local PL = require("bot.seer.play")

local M = {}

local LEAVE, SKIP = {type = "leave"}, {type = "skip"}

local function score(w)
    if w.won == 1 then return w.win_ante + 2 end
    return w.ante + (w.blind_on_deck - 1) / 3
end

function M.chooser(mc, rmc, opt)
    if (opt.ro_book or "") ~= "" then P.load_scale(opt.ro_book) end
    local step = {type = "play", cards = {}}

    local function run(w, stop_ante)
        local moves, econ_run = 0, 0
        while moves < 400 do
            MC.advance_forced(w)
            if MC.terminal(w) or (stop_ante > 0 and w.ante >= stop_ante) then break end
            if (opt.ro_useplanet or 0) > 0 then P.use_planets(w, E.step) end
            local ph = w.phase
            if ph == "shop" or ph == "pack" then econ_run = econ_run + 1 else econ_run = 0 end
            if econ_run > opt.max_shop then
                if not E.step(w, ph == "pack" and SKIP or LEAVE) then break end
            elseif ph == "play" and (opt.ro_fast or 0) == 1 then
                local a = PL.fast_action(w, true)
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
        if stop_ante > 0 and not MC.terminal(w) then
            if opt.ro_mon ~= 0 then v = v + opt.ro_mon * math.min(math.max(w.money, 0), 50) / 50 end
            if opt.ro_net ~= 0 then
                rmc:search(w, 0, {noise = 0, reuse = false, adaptive = true})
                v = v + opt.ro_net * rmc.n_val[rmc.root]
            end
            if (opt.ro_planh or 0) ~= 0 then v = v + opt.ro_planh * P.score(w) end
        end
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
        local stop_ante = opt.ro_h > 0 and s.ante + opt.ro_h or 0
        local alive = cands
        local check = opt.ro_a > 0 and opt.ro_a or opt.ro + 1
        for r = 1, opt.ro do
            local key = string.format("RO%s_%d_%d", seed, moves, r)
            for _, c in ipairs(alive) do
                local w = F.world(base, key)
                local v = (E.step(w, c.a) and run(w, stop_ante) or -100) + (c.p or 0)
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
        return best.a, best.e
    end
end

return M
