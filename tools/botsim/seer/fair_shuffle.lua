package.path = "assets/?.lua;tools/?.lua;" .. package.path

local E = require("bot.sim.engine")
local D = require("bot.sim.data")
local S = require("bot.seer.seer")
local F = require("bot.seer.fair")
local PL = require("bot.seer.play")
local SC = require("botsim.seer.scramble")
local ST = require("bot.sim.state")

local opt = {who = "fair", budget = "lite", weights = "", prefix = "BENCH", first = 1, seeds = 1, decks = "b_red", stakes = "1",
    max_steps = 4000, out = "", sims = 32, K = 24, quick_clear = 0, pace = 0, pace_net = 0, type_mass = 0, tm_plays = 0, fair = 0, search_ph = "", solver = "", solver_qc = 0,
    ro = 0, ro_a = 0, ro_z = 2, ro_c = 3, ro_h = 0, ro_ph = "shop,pack,blind_select", ro_from = 0, ro_mon = 0, ro_net = 0, ro_t = 0.25, ro_plan = 0, ro_plan_c = 0, ro_planh = 0, ro_fast = 0, ro_useplanet = 0, ro_order = 0, solver_h = 0, solver_en = 0, solver_hb = 0, ro_book = "", max_shop = 40, rec = "", min_ante = 0, strict = 1, force_jflip = 0}
opt.teach = 0
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

local digest = 7
local MOD = 2147483629
local str_h = {}

local function h_num(v)
    local x = (v % MOD) * 4096
    if x ~= x then return 11 end
    return math.floor(x) % MOD
end

local function h_str(x)
    local v = str_h[x]
    if not v then
        v = 7
        for i = 1, #x do v = (v * 131 + x:byte(i)) % MOD end
        str_h[x] = v
    end
    return v
end

local function h_val(v)
    local t = type(v)
    if t == "number" then return h_num(v) end
    if t == "string" then return h_str(v) end
    if t == "boolean" then return v and 5 or 3 end
    if t ~= "table" then return 1 end
    local sum = 0
    for k, x in pairs(v) do
        sum = (sum + ((h_val(k) * 131 + h_val(x)) * 1000003) % MOD) % MOD
    end
    return sum
end

local function mix(h)
    digest = (digest * 1000003 % MOD + h) % MOD
end

local function mix_buf(b, n)
    for i = 0, n - 1 do mix(h_num(b[i] or 0)) end
end

if opt.strict > 0 then
    local FE = require("bot.nn.features")
    local san0, world0, state0 = F.sanitize, F.world, FE.state
    F.sanitize = function(x)
        local v = san0(x)
        mix(h_val(v))
        return v
    end
    F.world = function(base, key)
        local w = world0(base, key)
        mix(h_val(w))
        return w
    end
    FE.state = function(s, buf)
        local r = state0(s, buf)
        mix_buf(buf.g, FE.GF)
        mix_buf(buf.c, buf.nc * FE.CF)
        mix_buf(buf.j, buf.nj * FE.JF)
        mix_buf(buf.i, buf.ni * FE.IF)
        return r
    end
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
    local PLAN = require("botsim.train.plan")
    forced = MC.advance_forced
    local function new_mc(nn)
        return MC.new(nn, {K = opt.K, seed = 99991, alpha = 0.5, nodes = opt.sims + 2, full = true, quick_clear = opt.quick_clear,
            type_mass = opt.type_mass, tm_plays = opt.tm_plays, pace = opt.pace, pace_net = opt.pace_net})
    end
    chooser = function()
        local n = 0
        local fo = opt.solver ~= "" and F.new({budget = opt.solver, quick_clear = opt.solver_qc > 0, honest = opt.solver_h, eval_n = opt.solver_en, honest_final = opt.solver_hb > 0 and 0 or 1}) or nil
        local rmc = opt.ro > 0 and new_mc(NET.new(WT.load(opt.weights))) or nil
        local order_key
        local tch = opt.teach > 0 and require("botsim.train.teach").new(opt) or nil
        return function(view)
            MC.advance_forced(view)
            if MC.terminal(view) then return nil end
            n = n + 1
            if tch then
                local ta = tch:move(view)
                if ta then return {ta} end
            end
            if opt.ro_order > 0 and view.phase == "blind_select" and not PLAN.any_flipped(view) then
                local key = view.n_jok
                for k = 1, view.n_jok do key = key .. "," .. view.j_uid[k] end
                if key ~= order_key then
                    order_key = key
                    local o = PLAN.best_order(F.world(F.sanitize(view), "ORD_" .. view.ante))
                    if o then
                        local after = view.n_jok
                        for k = 1, view.n_jok do after = after .. "," .. view.j_uid[o[k]] end
                        order_key = after
                        return {{type = "reorder_jokers", order = o}}
                    end
                end
            end
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

local function with_flips(s)
    local v = ST.clone(s)
    for k = 1, v.n_jok do v.j_flip[k] = 1 end
    return v
end

local function run(setup, scrambled)
    digest = 7
    local s = E.new_run(setup)
    local pick = chooser()
    local line = {}
    local dec = 0
    local econ_run = 0
    local cov = {flip = 0, jok = 0, vh = 0, caps = 0, final = "", top = 0, why = "steps"}
    while #line < opt.max_steps do
        if forced then forced(s) end
        if s.won == 1 or s.phase == "game_over" or s.phase == "win" then cov.why = s.phase break end
        if s.ante > cov.top then cov.top = s.ante end
        if s.phase == "shop" or s.phase == "pack" then econ_run = econ_run + 1 else econ_run = 0 end
        if econ_run > opt.max_shop then
            local out = s.phase == "pack" and {type = "skip"} or {type = "leave"}
            if not E.step(s, out) then
                line[#line + 1] = {key = "stuck", phase = s.phase}
                cov.why = "stuck"
                break
            end
            cov.caps = cov.caps + 1
            line[#line + 1] = {key = "cap:" .. F.action_key(out), phase = s.phase}
            goto continue
        end
        dec = dec + 1
        for i = 1, s.n_hand do
            if s.c_flip[s.hand[i]] == 1 then cov.flip = cov.flip + 1 break end
        end
        for k = 1, s.n_jok do
            if s.j_flip[k] == 1 then cov.jok = cov.jok + 1 break end
        end
        if F.voucher_hidden(s) then cov.vh = cov.vh + 1 end
        if s.phase == "play" and s.blind > 2 and D.BLINDS[s.blind].showdown then cov.final = D.BLINDS[s.blind].key end
        local seen = opt.force_jflip > 0 and with_flips(s) or s
        local view = scrambled and SC.shuffled(seen, string.format("SHUF%s_%d_%d", setup.seed, dec, s.step)) or seen
        local phase = s.phase
        local acts = pick(view)
        if not acts or #acts == 0 then cov.why = "no_action" break end
        local moved = false
        for i = 1, #acts do
            if #line >= opt.max_steps then break end
            if not E.step(s, acts[i]) then break end
            moved = true
            line[#line + 1] = {key = F.action_key(acts[i]), phase = phase, dg = digest}
        end
        if not moved then
            local fb = fallback(s)
            if not fb or not E.step(s, fb) then
                line[#line + 1] = {key = "stuck", phase = phase}
                cov.why = "stuck"
                break
            end
            line[#line + 1] = {key = "fb:" .. F.action_key(fb), phase = phase, dg = digest}
        end
        ::continue::
    end
    cov.won = s.won
    return line, cov
end

local diffs, games, identical = {}, 0, 0
local top_ante, by_ante, finals, flips, jok_flips, v_hidden, caps, early = 0, {}, {}, 0, 0, 0, 0, 0
for _, d in ipairs(split(opt.decks)) do
    for _, st in ipairs(split(opt.stakes)) do
        for n = opt.first, opt.first + opt.seeds - 1 do
            local setup = {seed = string.format("%s%04d", opt.prefix, n), deck = d, stake = tonumber(st)}
            local l1, cov = run(setup, false)
            local l2 = run(setup, true)
            games = games + 1
            if cov.top > top_ante then top_ante = cov.top end
            by_ante[cov.top] = (by_ante[cov.top] or 0) + 1
            if cov.final ~= "" then finals[cov.final] = (finals[cov.final] or 0) + 1 end
            flips, jok_flips, v_hidden, caps = flips + cov.flip, jok_flips + cov.jok, v_hidden + cov.vh, caps + cov.caps
            if cov.why ~= "game_over" and cov.why ~= "win" then early = early + 1 end
            print(string.format("reach %s %s stake %d: ante %d end %s won %d decisions with flipped hand %d flipped jokers %d hidden voucher %d shop caps %d final %s",
                setup.seed, d, setup.stake, cov.top, cov.why, cov.won, cov.flip, cov.jok, cov.vh, cov.caps, cov.final))
            local at
            for i = 1, math.max(#l1, #l2) do
                local x, y = l1[i], l2[i]
                if not x or not y or x.key ~= y.key or x.dg ~= y.dg then at = i break end
            end
            if at then
                local p = (l1[at] or l2[at]).phase
                diffs[#diffs + 1] = {seed = setup.seed, deck = d, stake = setup.stake, step = at, phase = p}
                print(string.format("diff %s %s stake %d at step %d (%s): %s vs %s%s", setup.seed, d, setup.stake, at, p,
                    l1[at] and l1[at].key or "end", l2[at] and l2[at].key or "end",
                    l1[at] and l2[at] and l1[at].key == l2[at].key and " (same move, the player saw different inputs)" or ""))
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
local ante_parts = {}
for a = 0, top_ante do
    if by_ante[a] then ante_parts[#ante_parts + 1] = string.format("%d:%d", a, by_ante[a]) end
end
local final_parts = {}
for k, v in pairs(finals) do final_parts[#final_parts + 1] = string.format("%s:%d", k, v) end
table.sort(final_parts)
local reach = string.format('{"top_ante":%d,"by_ante":"%s","finals":"%s","flipped_hand":%d,"flipped_jokers":%d,"hidden_voucher":%d,"caps":%d,"early":%d}',
    top_ante, table.concat(ante_parts, " "), table.concat(final_parts, " "), flips, jok_flips, v_hidden, caps, early)
local js = string.format('{"who":"%s","games":%d,"identical":%d,"reach":%s,"diffs":[%s]}', opt.who, games, identical, reach, table.concat(parts, ","))
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
if opt.min_ante > 0 and top_ante < opt.min_ante then
    print(string.format("SHUFFLE CHECK FAILED: no game reached ante %d (best %d), the check says nothing about later antes", opt.min_ante, top_ante))
    os.exit(1)
end
if #diffs == 0 then
    print(string.format("shuffle check passed: %d of %d games identical", identical, games))
    os.exit(0)
end
print(string.format("SHUFFLE CHECK FAILED: %d of %d games differ", #diffs, games))
os.exit(1)
