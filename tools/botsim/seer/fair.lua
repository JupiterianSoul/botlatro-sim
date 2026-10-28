package.path = "assets/?.lua;tools/?.lua;" .. package.path
require("botsim.jitopt")

local F = require("bot.seer.fair")
local S = require("bot.seer.seer")

local opt = {budget = "lite", worlds = 0, eval_h = 0, max_cands = 0, seer = "", decks = "b_red", stakes = "1", seeds = 10,
    first = 1, prefix = "FAIR", sampler = "FAIR", run_cap = 0, part = "", jobs = 1, out = "", summary = "", quick = 0, fast_top = 0}
local raw = {}
for _, a in ipairs(arg or {}) do
    local k, v = a:match("^%-*([%w_]+)=(.*)$")
    if k then
        raw[k] = v
        if type(opt[k]) == "number" then opt[k] = tonumber(v) or opt[k] else opt[k] = v end
    end
end

local function split(str)
    local t = {}
    for w in str:gmatch("[^,]+") do t[#t + 1] = w end
    return t
end

local function summarize(lines, label)
    local n, w, ante, t, dec = 0, 0, 0, 0, 0
    local by = {}
    local order = {}
    for _, l in ipairs(lines) do
        local d = l:match('"deck":"([^"]+)"')
        local st = tonumber(l:match('"stake":(%d+)'))
        local won = tonumber(l:match('"won":(%d)'))
        local a = tonumber(l:match('"ante":(%d+)'))
        local tm = tonumber(l:match('"time":([%d%.]+)'))
        local de = tonumber(l:match('"decisions":(%d+)')) or 0
        if d and won then
            n, w, ante, t, dec = n + 1, w + won, ante + a, t + tm, dec + de
            local key = d .. " " .. st
            if not by[key] then by[key] = {n = 0, w = 0, ante = 0, t = 0} order[#order + 1] = key end
            local b = by[key]
            b.n, b.w, b.ante, b.t = b.n + 1, b.w + won, b.ante + a, b.t + tm
        end
    end
    table.sort(order)
    print(string.format("# fair Seer %s", label or ""))
    print("| deck stake | runs | wins | win rate | avg final ante | cpu s per run |")
    print("| --- | --- | --- | --- | --- | --- |")
    for _, key in ipairs(order) do
        local b = by[key]
        print(string.format("| %s | %d | %d | %.1f%% | %.2f | %.1f |", key, b.n, b.w, 100 * b.w / b.n, b.ante / b.n, b.t / b.n))
    end
    if n > 0 then
        print(string.format("| all | %d | %d | %.1f%% | %.2f | %.1f |", n, w, 100 * w / n, ante / n, t / n))
        print(string.format("cpu s per decision: %.2f", t / math.max(1, dec)))
    end
end

if opt.summary ~= "" then
    local lines = {}
    for _, f in ipairs(split(opt.summary)) do
        local fh = io.open(f, "r")
        if fh then
            for l in fh:lines() do lines[#lines + 1] = l end
            fh:close()
        end
    end
    summarize(lines, opt.summary)
    return
end

local jobs = {}
for _, d in ipairs(split(opt.decks)) do
    for _, st in ipairs(split(opt.stakes)) do
        for n = opt.first, opt.first + opt.seeds - 1 do
            jobs[#jobs + 1] = {deck = d, stake = tonumber(st), seed = string.format("%s%04d", opt.prefix, n)}
        end
    end
end

local fopts = {budget = opt.budget, sampler_seed = opt.sampler, run_cap = opt.run_cap, quick_clear = opt.quick == 1}
require("bot.seer.play").FAST_TOP = opt.fast_top
local b = F.BUDGETS[opt.budget] or F.BUDGETS.lite
if opt.worlds > 0 then fopts.worlds = opt.worlds end
if opt.eval_h > 0 then fopts.eval_h = opt.eval_h end
if opt.max_cands > 0 then fopts.max_cands = opt.max_cands end
local sopts = {}
for k, v in pairs(b.seer) do sopts[k] = v end
for kv in opt.seer:gmatch("[^,]+") do
    local k, v = kv:match("^([%w_]+):(.*)$")
    if k then sopts[k] = tonumber(v) or v end
end
fopts.seer = sopts

local function run_one(j)
    local fo = F.new(fopts)
    local t0 = os.clock()
    local line, s, capped = fo:play({seed = j.seed, deck = j.deck, stake = j.stake})
    local tm = os.clock() - t0
    return string.format('{"deck":"%s","stake":%d,"seed":"%s","won":%d,"ante":%d,"time":%.2f,"actions":%d,"decisions":%d,"searched":%d,"world_plans":%d,"capped":%s,"budget":"%s","worlds":%d,"s_per_decision":%.3f}',
        j.deck, j.stake, j.seed, s.won == 1 and 1 or 0, S.final_ante(s), tm, #line, fo.decisions, fo.searched, fo.world_plans,
        capped and "true" or "false", opt.budget, fo.o.worlds, tm / math.max(1, fo.decisions))
end

local function write_lines(path, lines, mode)
    local fh = assert(io.open(path, mode))
    for _, l in ipairs(lines) do fh:write(l, "\n") end
    fh:close()
end

if opt.part ~= "" or opt.jobs <= 1 then
    local k, n = 1, 1
    if opt.part ~= "" then
        k, n = opt.part:match("^(%d+)/(%d+)$")
        k, n = tonumber(k), tonumber(n)
    end
    if opt.out ~= "" then write_lines(opt.out, {}, "w") end
    local all = {}
    for idx = k, #jobs, n do
        local l = run_one(jobs[idx])
        all[#all + 1] = l
        print(l)
        io.stdout:flush()
        if opt.out ~= "" then write_lines(opt.out, {l}, "a") end
    end
    if opt.part == "" then summarize(all, opt.budget) end
    return
end

local passthru = {}
for key, v in pairs(raw) do
    if key ~= "jobs" and key ~= "out" and key ~= "part" then passthru[#passthru + 1] = key .. "=" .. v end
end
table.sort(passthru)
local base_out = opt.out ~= "" and opt.out or "fair_runs.jsonl"
local pipes, parts = {}, {}
for k = 1, opt.jobs do
    parts[k] = string.format("%s.part%d", base_out, k)
    local cmd = string.format("luajit tools/botsim/seer/fair.lua %s part=%d/%d out=%s", table.concat(passthru, " "), k, opt.jobs, parts[k])
    pipes[k] = assert(io.popen(cmd, "r"))
end
local all = {}
for k = 1, opt.jobs do
    for l in pipes[k]:lines() do
        if l:match("^{") then
            all[#all + 1] = l
            print(l)
        end
    end
    pipes[k]:close()
end
write_lines(base_out, all, "w")
summarize(all, opt.budget)
