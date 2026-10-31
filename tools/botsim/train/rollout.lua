local E = require("bot.sim.engine")
local MC = require("bot.nn.mcts")
local F = require("bot.seer.fair")
local S = require("bot.seer.seer")
local PL = require("bot.seer.play")

local M = {}

local LEAVE, SKIP, SELECT = {type = "leave"}, {type = "skip"}, {type = "select"}

local LOG2 = math.log(2)

local function score(w)
    if w.won == 1 then return w.win_ante + 2 end
    return w.ante + (w.blind_on_deck - 1) / 3
end

function M.power(w, key)
    local c = F.world(w, key)
    for _ = 1, 8 do
        if c.phase == "play" then break end
        local a = c.phase == "shop" and LEAVE or c.phase == "pack" and SKIP or c.phase == "blind_select" and SELECT or nil
        if c.phase == "round_eval" then
            MC.advance_forced(c)
        elseif not a or not E.step(c, a) then
            return 0
        end
    end
    if c.phase ~= "play" then return 0 end
    c.blind_chips = 1e18
    for _ = 1, 40 do
        if c.phase ~= "play" then break end
        local a = PL.fast_action(c, true)
        if not a or not E.step(c, a) then break end
    end
    return c.chips
end

function M.need(w)
    return E.get_blind_amount(w, w.ante + 1) * 2 * w.ante_scaling
end

function M.chooser(mc, rmc, opt)
    local step = {type = "play", cards = {}}

    local function run(w, stop_ante, key)
        local moves, econ_run = 0, 0
        while moves < 400 do
            MC.advance_forced(w)
            if MC.terminal(w) or (stop_ante > 0 and w.ante >= stop_ante) then break end
            local ph = w.phase
            if ph == "shop" or ph == "pack" then econ_run = econ_run + 1 else econ_run = 0 end
            if econ_run > opt.max_shop then
                if not E.step(w, ph == "pack" and SKIP or LEAVE) then break end
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
        end
        if opt.ro_bld ~= 0 then
            local b = -2
            if w.won == 1 then
                b = 2
            elseif not MC.terminal(w) then
                local p = M.power(w, key .. "P")
                if p > 0 then b = math.max(-2, math.min(2, math.log(p / M.need(w)) / LOG2)) end
            end
            v = v + opt.ro_bld * b
        end
        return v
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
            cands[i] = {a = S.copy_action(step), e = order[i], v = 0}
        end
        local stop_ante = opt.ro_h > 0 and s.ante + opt.ro_h or 0
        for r = 1, opt.ro do
            local key = string.format("RO%s_%d_%d", seed, moves, r)
            for _, c in ipairs(cands) do
                local w = F.world(base, key)
                if E.step(w, c.a) then c.v = c.v + run(w, stop_ante, key) else c.v = c.v - 100 end
            end
        end
        local best = cands[1]
        for i = 2, #cands do
            if cands[i].v > best.v then best = cands[i] end
        end
        if opt.rec ~= "" then
            local ef2, ec2 = mc:root_edges()
            for e = ef2, ef2 + ec2 - 1 do mc.e_N[e] = 0 end
            local top, sum = best.v / opt.ro, 0
            for _, c in ipairs(cands) do
                c.w = math.exp((c.v / opt.ro - top) / opt.ro_t)
                sum = sum + c.w
            end
            for _, c in ipairs(cands) do mc.e_N[c.e] = math.floor(32 * c.w / sum + 0.5) end
        end
        return best.a, best.e
    end
end

return M
