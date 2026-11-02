local E = require("bot.sim.engine")
local ST = require("bot.sim.state")
local D = require("bot.sim.data")

local M = {}

local scratch = ST.scratch()
local LOG2 = math.log(2)
local STONE = D.ENH_ID.m_stone
local SMALL = D.BLIND_ID.bl_small
local SIZE = {{1}, {1, 2}, {1, 2, 3}, {1, 2, 3, 4}, {1, 2, 3, 4, 5}}

M.SCALE = {}

function M.load_scale(path)
    if M.loaded == path then return end
    M.loaded = path
    local f = io.open(path, "r")
    if not f then return end
    local t = require("bot.sim.json").decode(f:read("*a"))
    f:close()
    for k, e in pairs(t.categories.joker) do
        if e.scale then M.SCALE[e.key or k] = e.scale end
    end
end

local function tail(N, K, D2, m)
    if K < m or D2 < m then return 0 end
    local p, total = 0, 0
    local q = 1
    for i = 0, D2 - 1 do q = q * (N - K - i) / (N - i) end
    if N - K < D2 then q = 0 end
    local cur = q
    for x = 0, math.min(K, D2) do
        if q == 0 then
            local c = 1
            for i = 0, x - 1 do c = c * (K - i) / (x - i) end
            for i = 0, x - 1 do c = c * (D2 - i) / (N - i) end
            local left = D2 - x
            if N - K < left then c = 0 else
                for i = 0, left - 1 do c = c * (N - K - i) / (N - x - i) * (D2 - x - i) / (left - i) end
            end
            cur = c
        end
        total = total + cur
        if x >= m then p = p + cur end
        if q ~= 0 then
            local den = (x + 1) * (N - K - D2 + x + 1)
            if den <= 0 then cur = 0 else cur = cur * (K - x) * (D2 - x) / den end
        end
    end
    return math.max(0, math.min(1, p))
end
M.tail = tail

local function composition(w)
    local by_rank, by_suit = {}, {}
    for r = 2, 14 do by_rank[r] = {} end
    for x = 1, 4 do by_suit[x] = {} end
    local N = 0
    for c = 1, w.n_cards do
        if w.c_alive[c] == 1 then
            N = N + 1
            if w.c_enh[c] ~= STONE then
                local r = by_rank[w.c_rank[c]]
                if r then r[#r + 1] = c end
                local x = by_suit[w.c_suit[c]]
                if x then x[#x + 1] = c end
            end
        end
    end
    return by_rank, by_suit, N
end

local function chip_order(w)
    return function(a, b)
        local ca, cb = E.card_chips(w, a), E.card_chips(w, b)
        if ca ~= cb then return ca > cb end
        if w.c_rank[a] ~= w.c_rank[b] then return w.c_rank[a] > w.c_rank[b] end
        return a < b
    end
end

local function ranks_with(by_rank, m)
    local out = {}
    for r = 14, 2, -1 do
        if #by_rank[r] >= m then out[#out + 1] = r end
    end
    return out
end

local function candidates(w, by_rank, by_suit, N)
    local draw = math.min(N, w.hand_size + 4)
    local ord = chip_order(w)
    for r = 2, 14 do table.sort(by_rank[r], ord) end
    for x = 1, 4 do table.sort(by_suit[x], ord) end
    local out = {}
    local function add(h, cards, reach)
        if reach > 0 then out[#out + 1] = {h = h, cards = cards, reach = reach} end
    end
    local function lambda(m)
        local l = 0
        for r = 2, 14 do l = l + tail(N, #by_rank[r], draw, m) end
        return l
    end
    local function take(r, n, out2)
        for i = 1, n do out2[#out2 + 1] = by_rank[r][i] end
        return out2
    end
    local l2, l3, l4, l5 = lambda(2), lambda(3), lambda(4), lambda(5)
    local top1, top2, top3, top4, top5 = ranks_with(by_rank, 1), ranks_with(by_rank, 2), ranks_with(by_rank, 3), ranks_with(by_rank, 4), ranks_with(by_rank, 5)
    if top1[1] then add(D.H_HIGH, take(top1[1], 1, {}), 1) end
    if top2[1] then add(D.H_PAIR, take(top2[1], 2, {}), 1 - math.exp(-l2)) end
    if top2[2] then add(D.H_TWO_PAIR, take(top2[2], 2, take(top2[1], 2, {})), 1 - math.exp(-l2) * (1 + l2)) end
    if top3[1] then add(D.H_THREE, take(top3[1], 3, {}), 1 - math.exp(-l3)) end
    if top4[1] then add(D.H_FOUR, take(top4[1], 4, {}), 1 - math.exp(-l4)) end
    if top5[1] then add(D.H_FIVE, take(top5[1], 5, {}), 1 - math.exp(-l5)) end
    if top3[1] then
        local p
        for _, r in ipairs(top2) do
            if r ~= top3[1] then p = r break end
        end
        if p then add(D.H_FULL, take(p, 2, take(top3[1], 3, {})), (1 - math.exp(-l3)) * (1 - math.exp(-math.max(0, l2 - 1)))) end
    end
    local best_suit, lf = 1, 0
    for x = 1, 4 do
        lf = lf + tail(N, #by_suit[x], draw, 5)
        if #by_suit[x] > #by_suit[best_suit] then best_suit = x end
    end
    if #by_suit[best_suit] >= 5 then
        local c, run = {}, true
        local list = by_suit[best_suit]
        for i = 1, 4 do
            c[i] = list[i]
            if i > 1 and w.c_rank[c[i - 1]] ~= w.c_rank[c[i]] + 1 then run = false end
        end
        c[5] = list[5]
        if run and w.c_rank[c[4]] == w.c_rank[c[5]] + 1 and list[6] then c[5] = list[6] end
        add(D.H_FLUSH, c, 1 - math.exp(-lf))
    end
    for hi = 14, 6, -1 do
        local c, ok = {}, true
        local reach = 1
        for r = hi, hi - 4, -1 do
            local rr = r == 1 and 14 or r
            if not by_rank[rr] or #by_rank[rr] == 0 then ok = false break end
            local pick = by_rank[rr][1]
            if r == hi - 4 and c[1] then
                for _, id in ipairs(by_rank[rr]) do
                    if w.c_suit[id] ~= w.c_suit[c[1]] then
                        pick = id
                        break
                    end
                end
            end
            c[#c + 1] = pick
            reach = reach * tail(N, #by_rank[rr], draw, 1)
        end
        if ok then
            add(D.H_STRAIGHT, c, math.min(0.9, reach * 2.7))
            break
        end
    end
    return out
end

local function setup(w)
    local c = ST.clone(w)
    c.blind = SMALL
    c.blind_disabled = 0
    for i = 1, c.n_cards do
        c.c_debuff[i] = 0
        c.c_flip[i] = 0
    end
    return c
end

local function power_of(c, cands)
    local rows = {}
    local keep = c.hand_size
    for _, k in ipairs(cands) do
        local used = {}
        for i, id in ipairs(k.cards) do
            c.hand[i] = id
            used[id] = true
        end
        local n = #k.cards
        for id = 1, c.n_cards do
            if n >= keep then break end
            if c.c_alive[id] == 1 and not used[id] then
                n = n + 1
                c.hand[n] = id
            end
        end
        c.n_hand = n
        local v = E.preview_into(scratch, c, SIZE[#k.cards], false)
        rows[#rows + 1] = {h = k.h, v = v or 0, reach = k.reach}
    end
    table.sort(rows, function(a, b)
        if a.v ~= b.v then return a.v > b.v end
        return a.h < b.h
    end)
    return rows
end

function M.eval(w)
    local by_rank, by_suit, N = composition(w)
    if N == 0 then return 0, 0, 0 end
    local c = setup(w)
    local rows = power_of(c, candidates(w, by_rank, by_suit, N))
    M.last_rows = rows
    local mass, val, plan, plan_v = 0, 0, 0, -1
    for _, r in ipairs(rows) do
        val = val + r.v * r.reach * (1 - mass)
        mass = mass + r.reach * (1 - mass)
        if r.v * r.reach > plan_v then plan, plan_v = r.h, r.v * r.reach end
    end
    local grow = 1
    for k = 1, w.n_jok do
        local g = M.SCALE[D.JOKERS[w.j_id[k]].key]
        if g then grow = grow * g end
    end
    return val * grow, plan, plan_v
end

local PLANET = {}
for _, c in pairs(D.CONS) do
    if c.key and c.set == D.CONS[D.CONS_ID.c_pluto].set then PLANET[c.key] = true end
end
local OBSERVATORY = D.VOUCHER_ID and D.VOUCHER_ID.v_observatory
local USE = {type = "use", card = 1}

function M.use_planets(w, stepper)
    if w.n_cons == 0 then return end
    if OBSERVATORY and w.used_v[OBSERVATORY] and w.used_v[OBSERVATORY] ~= 0 then return end
    if w.phase ~= "shop" and w.phase ~= "blind_select" and w.phase ~= "play" then return end
    local k = w.n_cons
    while k >= 1 do
        if PLANET[w.cons[k]] then
            USE.card = k
            stepper(w, USE)
        end
        k = math.min(k - 1, w.n_cons)
    end
end

function M.any_flipped(w)
    for k = 1, w.n_jok do
        if w.j_flip[k] == 1 then return true end
    end
    return false
end

function M.best_order(w)
    local n = w.n_jok
    if n < 2 then return nil end
    local order = {}
    for i = 1, n do order[i] = i end
    local c = ST.clone(w)
    local best = M.eval(c)
    local start = best
    local trial = {}
    for _ = 1, 3 do
        local moved = false
        for i = 1, n - 1 do
            for j = i + 1, n do
                for k = 1, n do trial[k] = k end
                trial[i], trial[j] = j, i
                local x = ST.clone(c)
                if E.reorder(x, trial) then
                    local v = M.eval(x)
                    if v > best * 1.005 then
                        best = v
                        E.reorder(c, trial)
                        order[i], order[j] = order[j], order[i]
                        moved = true
                    end
                end
            end
        end
        if not moved then break end
    end
    if best <= start then return nil end
    return order, best, start
end

function M.need(w)
    return E.get_blind_amount(w, w.ante + 1) * 2 * w.ante_scaling
end

function M.score(w)
    local v = M.eval(w)
    if v <= 0 then return -4 end
    return math.max(-4, math.min(2, math.log(v * 4 / M.need(w)) / LOG2))
end

return M
