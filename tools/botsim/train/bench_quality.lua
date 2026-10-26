package.path = "assets/?.lua;tools/?.lua;" .. package.path
require("botsim.jitopt")

local FE = require("bot.nn.features")
local WT = require("bot.nn.weights")
local NET = require("bot.nn.net")
local MC = require("bot.nn.mcts")

local opt = {ref = 800, sims = "32,64,128,256", n = 200, weights = "", K = 24, seed = 5, E = 32, H = 128, VH = 32,
    cfgs = "base,pw,adapt,pw+adapt,adapt+ext"}
for _, a in ipairs(arg or {}) do
    local k, v = a:match("^([%w_]+)=(.*)$")
    if k then opt[k] = tonumber(v) or v end
end
local function list(v, num)
    local out = {}
    for x in tostring(v):gmatch("[^,]+") do out[#out + 1] = num and tonumber(x) or x end
    return out
end
local clock = os.clock

local states = require("botsim.train.benchstates")(opt.n, "BQ")
local W = opt.weights ~= "" and WT.load(opt.weights) or WT.random(WT.default_cfg(FE, {E = opt.E, H = opt.H, VH = opt.VH}), 3)
local net = NET.new(W)

local CFG = {
    base = {},
    pw = {pw_c = 2, pw_a = 0.5, pw_min = 4},
    adapt = {adaptive = true},
    ["pw+adapt"] = {pw_c = 2, pw_a = 0.5, pw_min = 4, adaptive = true},
    ["adapt+ext"] = {adaptive = true, extend = 2, close = 0.25},
    conf = {adaptive = true, conf_prior = 0.9, conf_frac = 0.25},
    conf8 = {adaptive = true, conf_prior = 0.8, conf_frac = 0.25},
    ["pw+adapt+ext"] = {pw_c = 2, pw_a = 0.5, pw_min = 4, adaptive = true, extend = 2, close = 0.25},
}

local function akey(mc, e)
    if not e then return "none" end
    local k = mc.e_type[e] .. ":"
    for i = 0, mc.e_nc[e] - 1 do k = k .. mc.e_c[e * 5 + i] .. "," end
    return k
end

local function run(cfg, n_sims, seed)
    local mc = MC.new(net, {K = opt.K, seed = seed, nodes = 1024, full = false, pw_c = cfg.pw_c, pw_a = cfg.pw_a, pw_min = cfg.pw_min})
    local out, used = {}, 0
    local t0 = clock()
    for i = 1, #states do
        mc.rnd = MC.new_rng(seed * 100003 + i)
        mc:search(states[i], n_sims, {adaptive = cfg.adaptive, extend = cfg.extend, close = cfg.close, conf_prior = cfg.conf_prior, conf_frac = cfg.conf_frac})
        out[i] = akey(mc, mc:choose(0))
        used = used + mc.sims_done
    end
    return out, used / #states, (clock() - t0) / #states
end

local warm = MC.new(net, {K = opt.K, seed = 1, nodes = 1024, full = false})
for i = 1, #states do warm:search(states[i], 48, {}) end

local ref = run(CFG.base, opt.ref, 777)
local ref2 = run(CFG.base, opt.ref, 778)
local function agree(a, b)
    local c = 0
    for i = 1, #a do if a[i] == b[i] then c = c + 1 end end
    return 100 * c / #a
end
print(string.format("%d states, reference = unpruned %d sims; two reference seeds agree %.1f%%", #states, opt.ref, agree(ref, ref2)))
print("config         sims  avg_sims  ms/dec  agree_ref%  agree_base_same_sims%  base_seed2%")
for _, n in ipairs(list(opt.sims, true)) do
    local base = run(CFG.base, n, opt.seed)
    local base2 = run(CFG.base, n, opt.seed + 1)
    for _, name in ipairs(list(opt.cfgs)) do
        local res, avg, per
        if name == "base" then res, avg, per = run(CFG.base, n, opt.seed) else res, avg, per = run(CFG[name], n, opt.seed) end
        print(string.format("%-13s %5d %9.1f %7.2f %11.1f %22.1f %12.1f", name, n, avg, per * 1000, agree(res, ref), agree(res, base), agree(base2, base)))
    end
end
