package.path = "assets/?.lua;tools/?.lua;" .. package.path
require("botsim.jitopt")

local FA = require("bot.seer.fair")
local PL = require("bot.seer.play")

local opt = {seed = "TEACH14098", deck = "b_anaglyph", stake = 1, cap = 600, slow = 2, budget = "lite"}
for _, a in ipairs(arg) do
    local k, v = a:match("^([%w_]+)=(.*)$")
    if k then opt[k] = tonumber(v) or v end
end

local solves, solve_t = 0, 0
local solve = PL.solve
PL.solve = function(...)
    local t = os.clock()
    local r = solve(...)
    solves, solve_t = solves + 1, solve_t + os.clock() - t
    return r
end

local by_phase, t_phase = {}, {}
local t_start = os.clock()
local decide = FA.decide
FA.decide = function(self, real, n)
    if os.clock() - t_start > opt.cap then error("cap") end
    local s0, st0 = solves, solve_t
    local t = os.clock()
    local acts, best = decide(self, real, n)
    local dt = os.clock() - t
    local ph = real.phase
    by_phase[ph] = (by_phase[ph] or 0) + 1
    t_phase[ph] = (t_phase[ph] or 0) + dt
    if dt > opt.slow then
        local plans = {}
        for _, c in ipairs(self.last_cands or {}) do
            local ty = {}
            for i = 1, #c.plan do ty[i] = c.plan[i].type end
            plans[#plans + 1] = table.concat(ty, ",")
        end
        local tags = {}
        for i = 1, real.n_tags or 0 do tags[i] = tostring(real.tags[i]) .. ":" .. tostring(real.tag_trig[i]) end
        local a1 = acts and acts[1] and acts[1].type or "nil"
        print(string.format("slow %.1fs dec %d ante %d phase %s money %d jokers %d tags[%s] solves %d (%.1fs) act %s cands %s",
            dt, self.decisions, real.ante, ph, real.money or 0, real.n_jok or 0, table.concat(tags, " "),
            solves - s0, solve_t - st0, a1, table.concat(plans, " | ")))
        io.stdout:flush()
    end
    return acts, best
end

local fo = FA.new({budget = opt.budget})
local ok, line, fs = pcall(fo.play, fo, {seed = opt.seed, deck = opt.deck, stake = opt.stake})
local parts = {}
for ph, n in pairs(by_phase) do parts[#parts + 1] = string.format("%s=%d/%.1fs", ph, n, t_phase[ph]) end
table.sort(parts)
print(string.format("%s %s stake %d: %s time %.1fs decisions %d searched %d solves %d (%.1fs) by phase %s",
    opt.seed, opt.deck, opt.stake, ok and string.format("ante %d won %d", fs.ante, fs.won) or ("stopped " .. tostring(line)),
    os.clock() - t_start, fo.decisions, fo.searched, solves, solve_t, table.concat(parts, " ")))
