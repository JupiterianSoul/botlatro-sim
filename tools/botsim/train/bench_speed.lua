package.path = "assets/?.lua;tools/?.lua;" .. package.path
require("botsim.jitopt")

local E = require("bot.sim.engine")
local ST = require("bot.sim.state")
local FE = require("bot.nn.features")
local WT = require("bot.nn.weights")
local NET = require("bot.nn.net")
local MC = require("bot.nn.mcts")

local opt = {sims = "16,64,256,800", n = "600,300,100,30", reuse = 1, moves = 6, adaptive = 0, conf = 0, starts = 40, weights = "", K = 24, part = "all", seed = 9, E = 32, H = 128, VH = 32, full = 0}
for _, a in ipairs(arg or {}) do
    local k, v = a:match("^([%w_]+)=(.*)$")
    if k then opt[k] = tonumber(v) or v end
end
local function list(v)
    local out = {}
    for x in tostring(v):gmatch("[^,]+") do out[#out + 1] = tonumber(x) end
    return out
end
local clock = os.clock

local states = require("botsim.train.benchstates")(200)

local W = opt.weights ~= "" and WT.load(opt.weights) or WT.random(WT.default_cfg(FE, {E = opt.E, H = opt.H, VH = opt.VH}), 3)
local net = NET.new(W)

local function timeit(label, reps, fn)
    fn(1)
    local t0 = clock()
    for i = 1, reps do fn(i) end
    local per = (clock() - t0) / reps
    print(string.format("%-28s %8.2f us", label, per * 1e6))
    return per
end

if opt.part == "all" or opt.part == "parts" then
    local AB = FE.new_action_buf(1024)
    local F = FE.new_state_buf()
    local fs = {}
    for i = 1, #states do
        fs[i] = FE.new_state_buf()
        FE.state(states[i], fs[i])
    end
    local na = 0
    for i = 1, #states do na = na + FE.actions(states[i], AB) end
    print(string.format("avg actions per state %.1f", na / #states))
    timeit("features.state", 20000, function(i) FE.state(states[i % #states + 1], F) end)
    if FE.actions_ref then timeit("features.actions_ref", 4000, function(i) FE.actions_ref(states[i % #states + 1], AB) end) end
    timeit("features.actions", 4000, function(i) FE.actions(states[i % #states + 1], AB) end)
    if FE.actions_compact then timeit("features.actions_compact", 4000, function(i) FE.actions_compact(states[i % #states + 1], AB) end) end
    timeit("forward", 20000, function(i) net:forward(fs[i % #fs + 1]) end)
    if net.forward_delta then
        local base_of = {}
        for i = 1, #states do
            local s = states[i]
            local j = i
            while j > 1 and states[j - 1].ante == s.ante and states[j - 1].round == s.round do j = j - 1 end
            base_of[i] = j
        end
        timeit("forward_delta (same round root)", 20000, function(i)
            local k = i % #fs + 1
            net:set_base(fs[base_of[k]])
            net:forward_delta(fs[k])
        end)
        net:set_base(fs[1])
        timeit("set_base", 20000, function(i) net:set_base(fs[i % #fs + 1]) end)
    end
    FE.actions(states[1], AB)
    timeit("forward+policy(" .. AB.n .. ")", 10000, function() net:forward(fs[1]) net:policy(AB) end)
end

if opt.part == "all" or opt.part == "mcts" then
    local warm = MC.new(net, {K = opt.K, seed = 1, nodes = 1024, full = opt.full == 1})
    for i = 1, #states do warm:search(states[i], 48, {noise = 0.25}) end
    if opt.prof ~= nil then require("jit.p").start(opt.prof) end
    print("sims  decisions  decisions/s  sims/s  avg_sims  nodes/dec  checksum")
    local ns = list(opt.n)
    for si, n in ipairs(list(opt.sims)) do
        local mc = MC.new(net, {K = opt.K, seed = opt.seed, nodes = 1024, full = opt.full == 1})
        local cnt = ns[si] or ns[#ns]
        local sum, nodes, used = 0, 0, 0
        local t0 = clock()
        for d = 1, cnt do
            local s = states[(d - 1) % #states + 1]
            mc:search(s, n, {noise = 0.25, adaptive = opt.adaptive == 1, conf_prior = opt.conf > 0 and opt.conf or nil})
            local e = mc:choose(0)
            nodes = nodes + mc.nn
            used = used + (mc.sims_done or n)
            if e then
                local ef = mc:root_edges()
                sum = (sum * 31 + (e - ef + 1) * 1000 + mc.e_N[e]) % 1000000007
            end
        end
        local dt = clock() - t0
        if opt.prof ~= nil then require("jit.p").stop() end
        print(string.format("%4d %9d %11.1f %8.0f %9.1f %9.1f  %d", n, cnt, cnt / dt, used / dt, used / cnt, nodes / cnt, sum))
    end
end

if opt.part == "play" then
    local warm = MC.new(net, {K = opt.K, seed = 1, nodes = 1024, full = opt.full == 1})
    for i = 1, #states do warm:search(states[i], 48, {noise = 0.25}) end
    print(string.format("play: %d starts x up to %d moves, reuse %d", opt.starts, opt.moves, opt.reuse))
    print("sims  decisions  decisions/s  new_sims/dec  reused%  checksum")
    local step = {type = "play", cards = {}}
    for _, n in ipairs(list(opt.sims)) do
        local mc = MC.new(net, {K = opt.K, seed = opt.seed, nodes = 1024, full = opt.full == 1})
        local dec, used, reused, sum = 0, 0, 0, 0
        local t0 = clock()
        for si = 1, opt.starts do
            local s = ST.clone(states[(si * 5 - 1) % #states + 1])
            for _ = 1, opt.moves do
                MC.advance(s)
                if MC.terminal(s) or s.phase ~= "play" then break end
                mc:search(s, n, {noise = 0.25, reuse = opt.reuse == 1})
                local e = mc:choose(0)
                if not e then break end
                dec = dec + 1
                used = used + mc.sims_done
                if mc.reused then reused = reused + 1 end
                local ef = mc:root_edges()
                sum = (sum * 31 + (e - ef + 1) * 1000 + mc.e_N[e]) % 1000000007
                mc:edge_action(e, step, s)
                mc:commit(e)
                if not E.step(s, step) then break end
            end
        end
        local dt = clock() - t0
        print(string.format("%4d %9d %11.1f %12.1f %8.1f  %d", n, dec, dec / dt, used / dec, 100 * reused / dec, sum))
    end
end
