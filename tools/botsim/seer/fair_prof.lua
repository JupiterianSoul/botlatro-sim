package.path = "assets/?.lua;tools/?.lua;" .. package.path

local opt = {budget = "lite", decks = "b_red", stakes = "1", seeds = 4, first = 1, prefix = "BENCH", sampler = "FAIR", jitopt = 1, quick = 0, fast_top = -1, proxy = 1, again = 1, cache = 1, reuse = 1, kid_top = -1}
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
wrap(PL, "solve", "play.solve", true)
wrap(PL, "fast_action", "play.fast_action", true)
wrap(PL, "scan", "play.scan", true)
wrap(F, "sanitize", "fair.sanitize", false)
wrap(F, "world", "fair.world", false)

local total, games = 0, 0
for deck in opt.decks:gmatch("[^,]+") do
    for stake in opt.stakes:gmatch("[^,]+") do
        for i = opt.first, opt.first + opt.seeds - 1 do
            local fo = F.new({budget = opt.budget, sampler_seed = opt.sampler, quick_clear = opt.quick == 1, fast_top = opt.fast_top >= 0 and opt.fast_top or nil})
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
for _, k in ipairs(names) do
    print(string.format("%-24s %9.1f %5.1f%% %9d %10.2f", k, T[k], 100 * T[k] / total, N[k], 1000 * T[k] / N[k]))
end
