package.path = "assets/?.lua;tools/?.lua;" .. package.path

local S = require("bot.seer.seer")
local D = require("bot.sim.data")

local ALL_DECKS = {}
for k in pairs(D.DECKS) do
    if k ~= "b_challenge" then ALL_DECKS[#ALL_DECKS + 1] = k end
end
table.sort(ALL_DECKS)

local opt = {seeds = 200, decks = "b_red", stakes = "1", mode = "play", jobs = 1, part = "", out = "", max_lines = 6,
    time_limit = 0, label = "", quiet = false, prefix = "SEER", set = "", merge = "", n_portfolio = 0, boost_antes = 1, restart_every = 2, noise = 1.5, out_dir = "", runs_file = ""}
local i = 1
while arg and i <= #arg do
    local a = arg[i]
    local k, v = a:match("^%-%-([%w_]+)=(.*)$")
    if not k then
        k = a:match("^%-%-([%w_]+)$")
        if k and arg[i + 1] and not arg[i + 1]:match("^%-%-") then
            v = arg[i + 1]
            i = i + 1
        elseif k then
            v = "1"
        end
    end
    if k then
        if type(opt[k]) == "number" then opt[k] = tonumber(v) elseif type(opt[k]) == "boolean" then opt[k] = v ~= "0" else opt[k] = v end
    end
    i = i + 1
end

local function split(str)
    local t = {}
    for w in str:gmatch("[^,]+") do t[#t + 1] = w end
    return t
end

local decks = opt.decks == "all" and ALL_DECKS or split(opt.decks)
local stakes = {}
for _, w in ipairs(split(opt.stakes == "all" and "1,2,3,4,5,6,7,8" or opt.stakes)) do stakes[#stakes + 1] = tonumber(w) end

local jobs = {}
for _, d in ipairs(decks) do
    for _, st in ipairs(stakes) do
        for n = 1, opt.seeds do
            jobs[#jobs + 1] = {deck = d, stake = st, seed = string.format("%s%04d", opt.prefix, n)}
        end
    end
end

local seer_opts = {}
for kv in opt.set:gmatch("[^,]+") do
    local k, v = kv:match("^([%w_]+)=(.*)$")
    if k then seer_opts[k] = tonumber(v) or v end
end

local function run_one(j)
    local setup = {seed = j.seed, deck = j.deck, stake = j.stake}
    local seer = S.new(seer_opts)
    local t0 = os.clock()
    local won, ante, nact, lines
    local origin = "-"
    if opt.mode == "solve" then
        local r = seer:solve(setup, {max_lines = opt.max_lines, time_limit = opt.time_limit,
            n_portfolio = opt.n_portfolio > 0 and opt.n_portfolio or nil, boost_antes = opt.boost_antes,
            restart_every = opt.restart_every, noise = opt.noise})
        won, ante, nact, lines = r.won, r.final_ante, #r.line, r.lines
        origin = r.origin or "-"
    else
        local line, s = seer:play(setup)
        won, ante, nact, lines = s.won == 1, S.final_ante(s), #line, 1
    end
    return string.format("RUN %s %d %s %d %d %.3f %d %d %s", j.deck, j.stake, j.seed, won and 1 or 0, ante, os.clock() - t0, nact, lines, origin)
end

local function job_key(j)
    return j.deck .. " " .. j.stake .. " " .. j.seed
end

local function read_runs(f, into, done)
    local fh = io.open(f, "r")
    if not fh then return end
    for l in fh:lines() do
        local d, st, sd = l:match("^RUN (%S+) (%d+) (%S+) %d %d+ [%d%.]+")
        if d then
            into[#into + 1] = l
            if done then done[d .. " " .. st .. " " .. sd] = true end
        end
    end
    fh:close()
end

if opt.part ~= "" then
    local k, n = opt.part:match("^(%d+)/(%d+)$")
    k, n = tonumber(k), tonumber(n)
    local done, fh = {}, nil
    if opt.runs_file ~= "" then
        local old = {}
        read_runs(opt.runs_file, old, done)
        for _, l in ipairs(old) do print(l) end
        fh = assert(io.open(opt.runs_file, "a"))
    end
    for idx = k, #jobs, n do
        if not done[job_key(jobs[idx])] then
            local l = run_one(jobs[idx])
            print(l)
            io.stdout:flush()
            if fh then
                fh:write(l, "\n")
                fh:flush()
            end
        end
    end
    if fh then fh:close() end
    return
end

local tag = opt.label ~= "" and opt.label:gsub("[^%w_%-]", "_") or ("seer_" .. opt.mode)
if opt.out_dir ~= "" then
    os.execute("mkdir -p " .. opt.out_dir)
    if opt.out == "" then opt.out = opt.out_dir .. "/" .. tag .. ".md" end
end

local results = {}
local wall0 = os.time()
if opt.merge ~= "" then
    for _, f in ipairs(split(opt.merge)) do
        for l in io.lines(f) do
            if l:match("^RUN ") then results[#results + 1] = l end
        end
    end
elseif opt.jobs <= 1 and opt.out_dir == "" then
    for idx = 1, #jobs do
        local l = run_one(jobs[idx])
        results[#results + 1] = l
        if not opt.quiet then print(l) end
    end
else
    local self_args = {}
    for _, a in ipairs(arg) do
        if not a:match("^%-%-jobs") and not a:match("^%-%-out") then self_args[#self_args + 1] = a end
    end
    local pipes = {}
    local jn = math.max(1, opt.jobs)
    for k = 1, jn do
        local rf = opt.out_dir ~= "" and string.format(" --runs_file=%s/%s.part%d.txt", opt.out_dir, tag, k) or ""
        local cmd = string.format("luajit tools/botsim/seer/bench.lua %s --seeds=%d --decks=%s --stakes=%s --mode=%s --max_lines=%d --time_limit=%s --prefix=%s --set=%s --n_portfolio=%d --boost_antes=%d --restart_every=%d --noise=%s --part=%d/%d",
            "", opt.seeds, opt.decks, opt.stakes, opt.mode, opt.max_lines, tostring(opt.time_limit), opt.prefix, opt.set == "" and "," or opt.set,
            opt.n_portfolio, opt.boost_antes, opt.restart_every, tostring(opt.noise), k, jn) .. rf
        pipes[k] = assert(io.popen(cmd, "r"))
    end
    for k = 1, jn do
        for l in pipes[k]:lines() do
            if l:match("^RUN ") then
                results[#results + 1] = l
                if not opt.quiet then print(l) end
            end
        end
        pipes[k]:close()
    end
end
local wall = os.time() - wall0

local agg, order = {}, {}
local tot = {n = 0, w = 0, t = 0, ante = 0, dsum = 0, dn = 0}
for _, l in ipairs(results) do
    local d, st, _, w, ante, t = l:match("^RUN (%S+) (%d+) (%S+) (%d) (%d+) ([%d%.]+)")
    local key = d .. " " .. st
    local a = agg[key]
    if not a then
        a = {deck = d, stake = tonumber(st), n = 0, w = 0, t = 0, ante = 0, dsum = 0, dn = 0}
        agg[key] = a
        order[#order + 1] = key
    end
    for _, x in ipairs({a, tot}) do
        x.n = x.n + 1
        x.w = x.w + tonumber(w)
        x.t = x.t + tonumber(t)
        x.ante = x.ante + tonumber(ante)
        if tonumber(w) == 0 then x.dsum = x.dsum + tonumber(ante) x.dn = x.dn + 1 end
    end
end
table.sort(order, function(a, b)
    if agg[a].deck ~= agg[b].deck then return agg[a].deck < agg[b].deck end
    return agg[a].stake < agg[b].stake
end)

local md = {}
md[#md + 1] = string.format("# Seer bench %s", opt.label ~= "" and opt.label or os.date("%Y-%m-%d"))
md[#md + 1] = ""
md[#md + 1] = string.format("Mode `%s`, seeds `%s0001..%s%04d` per deck and stake%s, %d runs, %d jobs, wall %ds.",
    opt.mode, opt.prefix, opt.prefix, opt.seeds, opt.mode == "solve" and string.format(", up to %d lines per seed", opt.max_lines) or "",
    #results, opt.jobs, wall)
if opt.mode == "solve" then
    md[#md + 1] = string.format("Solve budget per seed: %d lines, %s CPU s; restart every %d, noise %s, boost antes %d.",
        opt.max_lines, opt.time_limit > 0 and tostring(opt.time_limit) or "no", opt.restart_every, tostring(opt.noise), opt.boost_antes)
end
if opt.set ~= "" then md[#md + 1] = string.format("Settings: `%s`.", opt.set) end
md[#md + 1] = ""
md[#md + 1] = "| deck | stake | runs | wins | win rate | avg death ante | avg final ante | cpu s per run |"
md[#md + 1] = "| --- | --- | --- | --- | --- | --- | --- | --- |"
local function row(name, st, x)
    return string.format("| %s | %s | %d | %d | %.1f%% | %s | %.2f | %.1f |", name, st, x.n, x.w, 100 * x.w / math.max(1, x.n),
        x.dn > 0 and string.format("%.2f", x.dsum / x.dn) or "-", x.ante / math.max(1, x.n), x.t / math.max(1, x.n))
end
local by_stake, stake_order = {}, {}
for _, key in ipairs(order) do
    local a = agg[key]
    md[#md + 1] = row(a.deck, tostring(a.stake), a)
    local x = by_stake[a.stake]
    if not x then
        x = {n = 0, w = 0, t = 0, ante = 0, dsum = 0, dn = 0}
        by_stake[a.stake] = x
        stake_order[#stake_order + 1] = a.stake
    end
    for _, f in ipairs({"n", "w", "t", "ante", "dsum", "dn"}) do x[f] = x[f] + a[f] end
end
table.sort(stake_order)
for _, st in ipairs(stake_order) do md[#md + 1] = row("all decks", tostring(st), by_stake[st]) end
md[#md + 1] = row("all", "", tot)
md[#md + 1] = ""
local text = table.concat(md, "\n") .. "\n"
print(text)
if opt.out ~= "" then
    local f = assert(io.open(opt.out, "w"))
    f:write(text)
    f:write("\n```\n" .. table.concat(results, "\n") .. "\n```\n")
    f:close()
end
if opt.out_dir ~= "" then
    local f = assert(io.open(opt.out_dir .. "/" .. tag .. ".summary.tsv", "w"))
    f:write("deck\tstake\truns\twins\twin_rate\tavg_final_ante\tcpu_s_per_run\tcpu_s_total\n")
    local function line(name, st, x)
        f:write(string.format("%s\t%s\t%d\t%d\t%.4f\t%.3f\t%.2f\t%.1f\n", name, st, x.n, x.w, x.w / math.max(1, x.n),
            x.ante / math.max(1, x.n), x.t / math.max(1, x.n), x.t))
    end
    for _, key in ipairs(order) do line(agg[key].deck, tostring(agg[key].stake), agg[key]) end
    for _, st in ipairs(stake_order) do line("all", tostring(st), by_stake[st]) end
    line("all", "all", tot)
    f:close()
end
