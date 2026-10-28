package.path = "assets/?.lua;tools/?.lua;" .. package.path

local opt = {budget = "lite", decks = "b_red", stakes = "1", seeds = 4, first = 1, prefix = "BENCH", sampler = "FAIR", jitopt = 1, quick = 0, fast_top = -1, proxy = 1, again = 1, cache = 1, reuse = 1, kid_top = -1, repeats = 0, memo = -1}
for _, a in ipairs(arg or {}) do
    local k, v = a:match("^%-*([%w_]+)=(.*)$")
    if k then opt[k] = type(opt[k]) == "number" and (tonumber(v) or opt[k]) or v end
end

if opt.jitopt == 1 then require("botsim.jitopt") end
local ST = require("bot.sim.state")
ST.PREVIEW_PROXY = opt.proxy == 1
ST.PREVIEW_AGAIN = opt.again == 1
require("bot.sim.engine").PREVIEW_CACHE = opt.cache == 1

local clock = os.clock
local T, N = {}, {}
local depth = {}

local function add(name, dt)
    T[name] = (T[name] or 0) + dt
    N[name] = (N[name] or 0) + 1
end

local function wrap(tbl, fname, label, outer_only)
    local f = tbl[fname]
    tbl[fname] = function(...)
        if outer_only and (depth[label] or 0) > 0 then return f(...) end
        depth[label] = (depth[label] or 0) + 1
        local t0 = clock()
        local r = {f(...)}
        add(label, clock() - t0)
        depth[label] = depth[label] - 1
        return unpack(r)
    end
end

wrap(ST, "clone", "state.clone", false)

local F = require("bot.seer.fair")
local S = require("bot.seer.seer")
local PL = require("bot.seer.play")
PL.REUSE_SCAN = opt.reuse == 1
if opt.kid_top >= 0 then PL.KID_TOP = opt.kid_top end

local phase_now = "?"
local base_decide = F.decide_base
F.decide_base = function(self, base, n)
    phase_now = base.phase
    local t0 = clock()
    local a, b = base_decide(self, base, n)
    add("decide." .. phase_now, clock() - t0)
    return a, b
end
local base_propose = F.propose
F.propose = function(self, w)
    local t0 = clock()
    local r = base_propose(self, w)
    add("propose." .. phase_now, clock() - t0)
    return r
end
local base_eval = F.evaluate
F.evaluate = function(self, w, plan, phase, ev)
    local t0 = clock()
    local v, won = base_eval(self, w, plan, phase, ev)
    add("evaluate." .. phase, clock() - t0)
    return v, won
end

wrap(S, "rollout", "seer.rollout", true)
wrap(S, "shop_search", "seer.shop_search", true)
wrap(S, "decide_blind", "seer.decide_blind", true)
wrap(S, "decide_pack", "seer.decide_pack", true)
wrap(S, "play_cons", "seer.play_cons", true)
local E = require("bot.sim.engine")
local pv_n = 0
local base_pv = E.preview_into
E.preview_into = function(...)
    pv_n = pv_n + 1
    return base_pv(...)
end
local base_scan = PL.scan
PL.scan = function(s, ov, oc, fast, top)
    local tag = ((depth["play.solve"] or 0) > 0 and "solve" or "other") .. (fast and ".fast" or ".full")
    local p0, t0 = pv_n, clock()
    local n = base_scan(s, ov, oc, fast, top)
    add("scan." .. tag, clock() - t0)
    N["pv." .. tag] = (N["pv." .. tag] or 0) + (pv_n - p0)
    return n
end
local rep_d, rep_s, rep_hit = {}, {}, {}
local kbuf = {}
local function state_key(s, fast, top)
    local n = 0
    local function put(v) n = n + 1 kbuf[n] = tostring(v) end
    put(fast and 1 or 0) put(top or -1)
    for _, f in ipairs(ST.SCALARS) do if f ~= "step" then put(s[f]) end end
    for _, f in ipairs(ST.CARD_ARRAYS) do local a = s[f] for i = 1, s.n_cards do put(a[i]) end end
    for _, f in ipairs(ST.JOKER_ARRAYS) do local a = s[f] for i = 1, s.n_jok do put(a[i]) end end
    for _, f in ipairs(ST.FIXED_ARRAYS) do local a = s[f[1]] for i = 1, f[2] do put(a[i]) end end
    for i = 1, s.n_hand do put(s.hand[i]) end
    for i = 1, s.n_cons do put(s.cons[i]) end
    local ks = {}
    for k in pairs(s.rng) do ks[#ks + 1] = tostring(k) end
    table.sort(ks)
    for _, k in ipairs(ks) do put(k) put(s.rng[k]) end
    return table.concat(kbuf, ",", 1, n)
end
if opt.repeats == 1 then
    local inner_scan = PL.scan
    PL.scan = function(s, ov, oc, fast, top)
        local tag = ((depth["play.solve"] or 0) > 0 and "solve" or "other") .. (fast and ".fast" or ".full")
        local k = state_key(s, fast, top)
        local p0 = pv_n
        local n = inner_scan(s, ov, oc, fast, top)
        local pv = pv_n - p0
        local function count(scope, seen)
            local h = scope .. "." .. tag
            local r = rep_hit[h] or {0, 0, 0, 0}
            rep_hit[h] = r
            r[1], r[2] = r[1] + 1, r[2] + pv
            if seen[k] then r[3], r[4] = r[3] + 1, r[4] + pv else seen[k] = true end
        end
        count("decide", rep_d)
        if (depth["play.solve"] or 0) > 0 then count("solve", rep_s) end
        return n
    end
    local base_solve = PL.solve
    PL.solve = function(...)
        if (depth["play.solve"] or 0) <= 1 then rep_s = {} end
        return base_solve(...)
    end
    local base_decide2 = F.decide
    F.decide = function(...)
        rep_d = {}
        return base_decide2(...)
    end
end
local base_step = E.step
E.step = function(...)
    if (depth["play.solve"] or 0) == 0 then return base_step(...) end
    local t0 = clock()
    local r = base_step(...)
    add("solve.step", clock() - t0)
    return r
end
wrap(PL, "solve", "play.solve", true)
wrap(PL, "fast_action", "play.fast_action", true)
wrap(PL, "scan", "play.scan", true)
wrap(F, "sanitize", "fair.sanitize", false)
wrap(F, "world", "fair.world", false)

local total, games = 0, 0
for deck in opt.decks:gmatch("[^,]+") do
    for stake in opt.stakes:gmatch("[^,]+") do
        for i = opt.first, opt.first + opt.seeds - 1 do
            local fo = F.new({budget = opt.budget, sampler_seed = opt.sampler, quick_clear = opt.quick == 1, fast_top = opt.fast_top >= 0 and opt.fast_top or nil, memo = opt.memo >= 0 and opt.memo == 1 or nil})
            local t0 = clock()
            local line, s = fo:play({seed = string.format("%s%04d", opt.prefix, i), deck = deck, stake = tonumber(stake)})
            local dt = clock() - t0
            total, games = total + dt, games + 1
            print(string.format("%s s%s %s%04d won=%d ante=%d time=%.1f actions=%d decisions=%d searched=%d quick=%d",
                deck, stake, opt.prefix, i, s.won == 1 and 1 or 0, S.final_ante(s), dt, #line, fo.decisions, fo.searched, fo.quick))
            io.stdout:flush()
        end
    end
end

local names = {}
for k in pairs(T) do names[#names + 1] = k end
table.sort(names, function(a, b) return T[a] > T[b] end)
print(string.format("\n%d games, %.1f s total, %.1f s per game", games, total, total / math.max(1, games)))
print(string.format("%-24s %9s %6s %9s %10s", "part", "s", "share", "calls", "ms/call"))
for k, r in pairs(rep_hit) do print(string.format("repeat %-18s scans %8d hits %8d (%.1f%%) previews %10d saved %10d (%.1f%%)", k, r[1], r[3], 100 * r[3] / r[1], r[2], r[4], 100 * r[4] / math.max(1, r[2]))) end
for k, v in pairs(N) do if k:sub(1, 3) == "pv." then print(string.format("previews %-14s %10d", k:sub(4), v)) end end
for _, k in ipairs(names) do
    print(string.format("%-24s %9.1f %5.1f%% %9d %10.2f", k, T[k], 100 * T[k] / total, N[k], 1000 * T[k] / N[k]))
end
