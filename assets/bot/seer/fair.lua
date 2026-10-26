local E = require("bot.sim.engine")
local ST = require("bot.sim.state")
local rng = require("bot.sim.rng")
local S = require("bot.seer.seer")
local PL = require("bot.seer.play")

local F = {}
F.__index = F

local clone = ST.clone
local floor = math.floor
local pseudohash = rng.pseudohash
local JOKER_ARRAYS = ST.JOKER_ARRAYS

F.BUDGETS = {
    lite = {worlds = 4, eval_h = 1, max_cands = 3,
        seer = {horizon = 1, tight_horizon = 2, beam = 2, tight_beam = 3, depth = 2},
        solve = {beam = 3, plays = 2, discards = 3}},
    std = {worlds = 8, eval_h = 2, max_cands = 4,
        seer = {},
        solve = {beam = 4, plays = 2, discards = 4}},
}

F.DEFAULTS = {worlds = 4, eval_h = 1, max_cands = 3, sampler_seed = "FAIR", run_cap = 0}

F.REVEAL = {reroll = true, open = true, use = true, buy_and_use = true, pick = true, reroll_boss = true, skip = true,
    select = true, play = true, discard = true, cash_out = true, leave = true}

function F.new(opts)
    opts = opts or {}
    local self = setmetatable({}, F)
    local b = F.BUDGETS[opts.budget or "lite"] or F.BUDGETS.lite
    self.o = {}
    for k, v in pairs(F.DEFAULTS) do self.o[k] = v end
    for k, v in pairs(b) do self.o[k] = v end
    for k, v in pairs(opts) do self.o[k] = v end
    self.decisions, self.searched, self.world_plans = 0, 0, 0
    return self
end

local function action_key(a)
    local p = {a.type}
    if a.area then p[#p + 1] = a.area end
    if a.card then p[#p + 1] = a.card end
    if a.cards then p[#p + 1] = table.concat(a.cards, ".") end
    if a.targets then p[#p + 1] = "t" .. table.concat(a.targets, ".") end
    if a.order then p[#p + 1] = "o" .. table.concat(a.order, ".") end
    return table.concat(p, ":")
end
F.action_key = action_key

local function plan_key(acts)
    local t = {}
    for i = 1, #acts do t[i] = action_key(acts[i]) end
    return table.concat(t, " ")
end
F.plan_key = plan_key

local function unit(key, i)
    return pseudohash(key .. "#" .. i)
end

local function shuffle(list, n, key)
    for i = n, 2, -1 do
        local j = floor(unit(key, i) * i) + 1
        if j > i then j = i end
        list[i], list[j] = list[j], list[i]
    end
end

local function hidden_slots(s)
    local slots = {}
    for i = 1, s.n_deck do slots[#slots + 1] = {"deck", i} end
    for i = 1, s.n_hand do
        if s.c_flip[s.hand[i]] == 1 then slots[#slots + 1] = {"hand", i} end
    end
    return slots
end

local function place(s, slots, pool)
    for i = 1, #slots do
        local sl = slots[i]
        local cid = pool[i]
        if sl[1] == "deck" then
            s.deck[sl[2]] = cid
            s.c_flip[cid] = 0
        else
            s.hand[sl[2]] = cid
            s.c_flip[cid] = 1
        end
    end
end

local function pool_of(s, slots)
    local pool = {}
    for i = 1, #slots do
        local sl = slots[i]
        pool[i] = sl[1] == "deck" and s.deck[sl[2]] or s.hand[sl[2]]
    end
    return pool
end

local function jokers_hidden(s)
    if s.n_jok < 2 then return false end
    for k = 1, s.n_jok do
        if s.j_flip[k] ~= 1 then return false end
    end
    return true
end

local function permute_jokers(s, perm)
    local n = s.n_jok
    for a = 1, #JOKER_ARRAYS do
        local arr = s[JOKER_ARRAYS[a]]
        local old = {}
        for k = 1, n do old[k] = arr[k] end
        for k = 1, n do arr[k] = old[perm[k]] end
    end
end

local function joker_less(s)
    return function(a, b)
        if s.j_id[a] ~= s.j_id[b] then return s.j_id[a] < s.j_id[b] end
        return s.j_uid[a] < s.j_uid[b]
    end
end

local function voucher_hidden(s)
    local ph = s.phase
    if s.round == 0 then return true end
    if s.round == 1 and (ph == "play" or ph == "round_eval") then return true end
    return ph == "round_eval" and s.state_boss == 3
end
F.voucher_hidden = voucher_hidden

local CANON_SEED = "FAIRVIEW"

function F.sanitize(real)
    local b = clone(real)
    b.seed = CANON_SEED
    b.hashed_seed = pseudohash(CANON_SEED)
    b.hcache = {}
    b.rng = {}
    b.rng_ids = {}
    b.n_rk = 0
    local slots = hidden_slots(b)
    local pool = pool_of(b, slots)
    table.sort(pool)
    place(b, slots, pool)
    if jokers_hidden(b) then
        local perm = {}
        for k = 1, b.n_jok do perm[k] = k end
        table.sort(perm, joker_less(b))
        permute_jokers(b, perm)
    end
    b.fair_voucher_hidden = voucher_hidden(b) and 1 or 0
    if b.fair_voucher_hidden == 1 then b.voucher = 0 end
    return b
end

function F.world(base, key)
    local w = clone(base)
    w.seed = key
    w.hashed_seed = pseudohash(key)
    w.hcache = {}
    w.rng = {}
    w.rng_ids = {}
    w.n_rk = 0
    local slots = hidden_slots(w)
    local pool = pool_of(w, slots)
    shuffle(pool, #pool, key .. "deck")
    place(w, slots, pool)
    if jokers_hidden(w) then
        local perm = {}
        for k = 1, w.n_jok do perm[k] = k end
        shuffle(perm, #perm, key .. "jok")
        permute_jokers(w, perm)
    end
    if base.fair_voucher_hidden == 1 then w.voucher = E.get_next_voucher(w) end
    return w
end

local function copy_acts(acts)
    local r = {}
    for i = 1, #acts do r[i] = S.copy_action(acts[i]) end
    return r
end

function F:propose(w)
    local seer = S.new(self.o.seer)
    local c = clone(w)
    local a = seer:choose(c)
    if not a then return nil end
    self.world_plans = self.world_plans + 1
    if seer.plan and #seer.plan > 0 then return copy_acts(seer.plan) end
    return {S.copy_action(a)}
end

function F:finish_blind(c)
    local guard = 0
    while c.phase == "play" and guard < 40 do
        guard = guard + 1
        local acts = PL.solve(c, self.o.solve)
        if not acts or #acts == 0 then
            local fb = PL.fast_action(c)
            if not fb or not E.step(c, fb) then return end
        else
            local moved = false
            for i = 1, #acts do
                if c.phase ~= "play" then break end
                if not E.step(c, acts[i]) then break end
                moved = true
            end
            if not moved then
                local fb = PL.fast_action(c)
                if not fb or not E.step(c, fb) then return end
            end
        end
    end
end

function F:evaluate(w, plan, phase, evaluator)
    local c = clone(w)
    if phase == "play" then
        if not E.step(c, plan[1]) then return -1e9, 0 end
        self:finish_blind(c)
    else
        if not E.step(c, plan[1]) then return -1e9, 0 end
        for i = 2, #plan do
            if not E.step(c, plan[i]) then break end
        end
    end
    local v, e = evaluator:rollout(c, self.o.eval_h, w)
    return v, (e and e.won == 1) and 1 or 0
end

local function commit_prefix(plan, phase)
    if phase ~= "shop" then return {plan[1]} end
    local out = {}
    for i = 1, #plan do
        out[#out + 1] = plan[i]
        if F.REVEAL[plan[i].type] then break end
    end
    return out
end

function F:decide_base(base, n)
    local phase = base.phase
    if base.won == 1 or phase == "game_over" or phase == "win" then return nil end
    if phase == "round_eval" then return {{type = "cash_out"}} end
    local worlds = {}
    for k = 1, n do
        worlds[k] = F.world(base, string.format("W%s_%d_%d_%d", tostring(self.o.sampler_seed), base.step, base.ante, k))
    end
    local cands, by_key = {}, {}
    for k = 1, n do
        local plan = self:propose(worlds[k])
        if plan and #plan > 0 then
            local key = phase == "play" and action_key(plan[1]) or plan_key(plan)
            local c = by_key[key]
            if not c then
                c = {plan = plan, n = 0, first = k}
                by_key[key] = c
                cands[#cands + 1] = c
            end
            c.n = c.n + 1
        end
    end
    if #cands == 0 then return nil end
    table.sort(cands, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.first < b.first
    end)
    for i = #cands, self.o.max_cands + 1, -1 do cands[i] = nil end
    local best = cands[1]
    if #cands > 1 then
        self.searched = self.searched + 1
        local evaluator = S.new(self.o.seer)
        for _, c in ipairs(cands) do
            local sv, sw = 0, 0
            for k = 1, n do
                local v, won = self:evaluate(worlds[k], c.plan, phase, evaluator)
                sv, sw = sv + v, sw + won
            end
            c.v, c.w = sv / n, sw / n
        end
        table.sort(cands, function(a, b)
            if a.w ~= b.w then return a.w > b.w end
            if a.v ~= b.v then return a.v > b.v end
            if a.n ~= b.n then return a.n > b.n end
            return a.first < b.first
        end)
        best = cands[1]
    end
    return commit_prefix(best.plan, phase), best
end

function F:decide(real, n)
    self.decisions = self.decisions + 1
    local base = F.sanitize(real)
    return self:decide_base(base, n or self.o.worlds)
end

function F:play(setup, on_action)
    local s = E.new_run(setup)
    local t0 = os.clock()
    local line = {}
    local capped = false
    for _ = 1, 4000 do
        if s.won == 1 or s.phase == "game_over" or s.phase == "win" then break end
        local n = self.o.worlds
        if self.o.run_cap > 0 and os.clock() - t0 > self.o.run_cap then
            n = 1
            capped = true
        end
        local acts = self:decide(s, n)
        if not acts or #acts == 0 then break end
        local moved = false
        for i = 1, #acts do
            local a = acts[i]
            if not E.step(s, a) then break end
            moved = true
            line[#line + 1] = S.copy_action(a)
            if on_action then on_action(s, a) end
        end
        if not moved then
            local fb
            if s.phase == "play" then fb = PL.fast_action(s)
            elseif s.phase == "shop" then fb = {type = "leave"}
            elseif s.phase == "pack" then fb = {type = "skip"}
            elseif s.phase == "blind_select" then fb = {type = "select"} end
            if not fb or not E.step(s, fb) then break end
            line[#line + 1] = S.copy_action(fb)
            if on_action then on_action(s, fb) end
        end
    end
    return line, s, capped
end

return F
