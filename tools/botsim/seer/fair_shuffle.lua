package.path = "assets/?.lua;tools/?.lua;" .. package.path

local E = require("bot.sim.engine")
local S = require("bot.seer.seer")
local F = require("bot.seer.fair")
local PL = require("bot.seer.play")
local SC = require("botsim.seer.scramble")

local opt = {who = "fair", budget = "lite", weights = "", prefix = "BENCH", first = 1, seeds = 1, decks = "b_red", stakes = "1",
    max_steps = 4000, out = "", sims = 32, K = 24, quick_clear = 0, pace = 0, pace_net = 0, type_mass = 0, tm_plays = 0, fair = 0, search_ph = "", solver = "", solver_qc = 0,
    ro = 0, ro_c = 3, ro_h = 0, ro_ph = "shop,pack,blind_select", ro_from = 0, ro_mon = 0, ro_net = 0, ro_t = 0.25, max_shop = 40, rec = ""}
for _, a in ipairs(arg or {}) do
    local k, v = a:match("^%-*([%w_]+)=(.*)$")
    if k then
        if type(opt[k]) == "number" then opt[k] = tonumber(v) or opt[k] else opt[k] = v end
    end
end

local function split(str)
    local t = {}
    for w in str:gmatch("[^,]+") do t[#t + 1] = w end
    return t
end

local b = F.BUDGETS[opt.budget] or F.BUDGETS.lite
local sopts = {}
for k, v in pairs(b.seer) do sopts[k] = v end

local chooser, forced
if opt.who == "fair" then
    chooser = function()
        local fo = F.new({budget = opt.budget})
        return function(view) return fo:decide(view) end
    end
elseif opt.who == "cheat" then
    chooser = function()
        return function(view)
            local a = S.new(sopts):choose(view)
            if not a then return nil end
            return {S.copy_action(a)}
        end
    end
elseif opt.who == "net" then
    require("botsim.jitopt")
    local WT = require("bot.nn.weights")
    local NET = require("bot.nn.net")
    local MC = require("bot.nn.mcts")
    local net = NET.new(WT.load(opt.weights))
    local RO = require("botsim.train.rollout")
    forced = MC.advance_forced
    local function new_mc(nn)
        return MC.new(nn, {K = opt.K, seed = 99991, alpha = 0.5, nodes = opt.sims + 2, full = true, quick_clear = opt.quick_clear,
            type_mass = opt.type_mass, tm_plays = opt.tm_plays, pace = opt.pace, pace_net = opt.pace_net})
    end
    chooser = function()
        local n = 0
        local fo = opt.solver ~= "" and F.new({budget = opt.solver, quick_clear = opt.solver_qc > 0}) or nil
        local rmc = opt.ro > 0 and new_mc(NET.new(WT.load(opt.weights))) or nil
        return function(view)
            MC.advance_forced(view)
            if MC.terminal(view) then return nil end
            n = n + 1
            if fo and view.phase == "play" then return fo:decide(view) end
            local w = opt.fair > 0 and F.world(F.sanitize(view), "FW_" .. n) or view
            local sims = opt.sims
            if opt.search_ph ~= "" and not ("," .. opt.search_ph .. ","):find("," .. view.phase .. ",", 1, true) then sims = 0 end
            local mc = new_mc(net)
            mc:search(w, sims, {noise = 0, reuse = false, adaptive = true})
            local e = mc:choose(0)
            if not e then return nil end
            if opt.ro > 0 and sims > 0 and ("," .. opt.ro_ph .. ","):find("," .. view.phase .. ",", 1, true) and view.stake >= opt.ro_from then
                local a = RO.chooser(mc, rmc, opt)(view, "", n)
                if a then return {a} end
            end
            local st = {type = "play", cards = {}}
            mc:edge_action(e, st, w)
            return {S.copy_action(st)}
        end
    end
else
    print("unknown who=" .. tostring(opt.who))
    os.exit(2)
end

local function fallback(s)
    if s.phase == "play" then return PL.fast_action(s) end
    if s.phase == "shop" then return {type = "leave"} end
    if s.phase == "pack" then return {type = "skip"} end
    if s.phase == "blind_select" then return {type = "select"} end
    return nil
end

local function run(setup, scrambled)
    local s = E.new_run(setup)
    local pick = chooser()
    local line = {}
    local dec = 0
    while #line < opt.max_steps do
        if forced then forced(s) end
        if s.won == 1 or s.phase == "game_over" or s.phase == "win" then break end
        dec = dec + 1
        local view = scrambled and SC.shuffled(s, string.format("SHUF%s_%d_%d", setup.seed, dec, s.step)) or s
        local phase = s.phase
        local acts = pick(view)
        if not acts or #acts == 0 then break end
        local moved = false
        for i = 1, #acts do
            if #line >= opt.max_steps then break end
            if not E.step(s, acts[i]) then break end
            moved = true
            line[#line + 1] = {key = F.action_key(acts[i]), phase = phase}
        end
        if not moved then
            local fb = fallback(s)
            if not fb or not E.step(s, fb) then
                line[#line + 1] = {key = "stuck", phase = phase}
                break
            end
            line[#line + 1] = {key = "fb:" .. F.action_key(fb), phase = phase}
        end
    end
    return line
end

local diffs, games, identical = {}, 0, 0
for _, d in ipairs(split(opt.decks)) do
    for _, st in ipairs(split(opt.stakes)) do
        for n = opt.first, opt.first + opt.seeds - 1 do
            local setup = {seed = string.format("%s%04d", opt.prefix, n), deck = d, stake = tonumber(st)}
            local l1 = run(setup, false)
            local l2 = run(setup, true)
            games = games + 1
            local at
            for i = 1, math.max(#l1, #l2) do
                local x, y = l1[i], l2[i]
                if not x or not y or x.key ~= y.key then at = i break end
            end
            if at then
                local p = (l1[at] or l2[at]).phase
                diffs[#diffs + 1] = {seed = setup.seed, deck = d, stake = setup.stake, step = at, phase = p}
                print(string.format("diff %s %s stake %d at step %d (%s): %s vs %s", setup.seed, d, setup.stake, at, p,
                    l1[at] and l1[at].key or "end", l2[at] and l2[at].key or "end"))
            else
                identical = identical + 1
                print(string.format("same %s %s stake %d (%d steps)", setup.seed, d, setup.stake, #l1))
            end
            io.stdout:flush()
        end
    end
end

local parts = {}
for _, x in ipairs(diffs) do
    parts[#parts + 1] = string.format('{"seed":"%s","deck":"%s","stake":%d,"step":%d,"phase":"%s"}', x.seed, x.deck, x.stake, x.step, x.phase)
end
local js = string.format('{"who":"%s","games":%d,"identical":%d,"diffs":[%s]}', opt.who, games, identical, table.concat(parts, ","))
print(js)
if opt.out ~= "" then
    local fh = assert(io.open(opt.out, "w"))
    fh:write(js, "\n")
    fh:close()
end

if opt.who == "cheat" then
    if #diffs > 0 then
        print(string.format("control ok: cheating Seer changed its line on %d of %d games", #diffs, games))
        os.exit(0)
    end
    print("CONTROL FAILED: cheating Seer played identical lines on every game, the shuffle check is not scrambling anything")
    os.exit(1)
end
if #diffs == 0 then
    print(string.format("shuffle check passed: %d of %d games identical", identical, games))
    os.exit(0)
end
print(string.format("SHUFFLE CHECK FAILED: %d of %d games differ", #diffs, games))
os.exit(1)
