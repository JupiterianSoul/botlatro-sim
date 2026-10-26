package.path = "assets/?.lua;tools/?.lua;" .. package.path
require("botsim.jitopt")

local E = require("bot.sim.engine")
local FE = require("bot.nn.features")
local WT = require("bot.nn.weights")
local NET = require("bot.nn.net")
local MC = require("bot.nn.mcts")
local REC = require("botsim.train.records")
local GL = require("botsim.train.gamelog")
local POL = require("botsim.policy")

local opt = {runs = 4, sims = 64, K = 24, out = "", weights = "", seed = 1, deck = "", stake = 1, secs = 0, first = 1,
    temp_moves = 8, noise = 0.25, reuse = 1, adaptive = 1, conf = 0, conf_frac = 0.25, fast_sims = 0, full_frac = 1, alpha = 0.5,
    mix = -1, score_prior = 0, score_top = 6, score_temp = 4, skip_pen = 1, skip_ante = 1, start_ante = "", start_frac = 0.5, start_who = "greedy", start_sims = 16,
    quiet = 0, E = 32, H = 128, VH = 32, full = 1, max_moves = 3000, max_shop = 40, games = "", recs = "", rec_runs = 0}
for _, a in ipairs(arg or {}) do
    local k, v = a:match("^([%w_]+)=(.*)$")
    if k then opt[k] = tonumber(v) or v end
end
local full = opt.full == 1

local W
if opt.weights ~= "" then
    W = WT.load(opt.weights)
else
    W = WT.random(WT.default_cfg(FE, {E = opt.E, H = opt.H, VH = opt.VH}), opt.seed)
end
local net = NET.new(W)
local mc = MC.new(net, {K = opt.K, seed = opt.seed * 7919 + 1, alpha = opt.alpha, mix = opt.mix >= 0 and opt.mix or nil,
    score_prior = opt.score_prior, score_top = opt.score_top, score_temp = opt.score_temp, skip_pen = opt.skip_pen, skip_ante = opt.skip_ante, nodes = opt.sims + 2, full = full})

local fh
if opt.out ~= "" then
    fh = assert(io.open(opt.out, "wb"))
    fh:write(REC.file_header())
end

local clock = os.clock
local t0 = clock()
local decisions, wins, ante_sum, runs_done, sim_steps = 0, 0, 0, 0, 0
local by_type = {}
local step = {type = "play", cards = {}}
local LEAVE, SKIP = {type = "leave"}, {type = "skip"}
local start_lo, start_hi = tostring(opt.start_ante):match("^(%d+)%-?(%d*)$")
start_lo = tonumber(start_lo)
start_hi = tonumber(start_hi) or start_lo
if start_lo and start_hi < start_lo then start_hi = start_lo end
POL.shop = true
local PF, PAB, pst = FE.new_state_buf(), FE.new_action_buf(1024), {}
local skipped = 0

local function curriculum(r)
    if not start_lo or start_lo <= 1 then return nil end
    if ((r * 2654435761 + opt.seed * 40503) % 1000) / 1000 >= opt.start_frac then return nil end
    return start_lo + r % (start_hi - start_lo + 1)
end

local function prefix(s, target)
    local moves, econ_run = 0, 0
    while moves < opt.max_moves do
        MC.advance_forced(s)
        if MC.terminal(s) then return false end
        if s.ante >= target then break end
        local ph = s.phase
        if ph == "shop" or ph == "pack" then econ_run = econ_run + 1 else econ_run = 0 end
        if econ_run > opt.max_shop then
            if not E.step(s, ph == "pack" and SKIP or LEAVE) then return false end
        elseif opt.start_who == "net" then
            mc:search(s, opt.start_sims, {noise = 0, reuse = true, adaptive = true})
            local e = mc:choose(0)
            if not e then return false end
            mc:edge_action(e, step, s)
            mc:commit(e)
            if not E.step(s, step) then return false end
        else
            FE.state(s, PF)
            local n = FE.list_actions(s, PAB, PF)
            if n == 0 then return false end
            local a = POL.choose(s)
            local k = a and FE.find_action(PAB, a, s) or -1
            if k < 0 then k = 0 end
            if not E.step(s, FE.to_step(PAB, k, pst, s)) then return false end
        end
        moves = moves + 1
    end
    mc.commit_edge = nil
    return s.ante >= target
end

for r = opt.first, opt.first + opt.runs - 1 do
    local deck = opt.deck ~= "" and opt.deck or FE.DECK_KEYS[(opt.seed + r) % #FE.DECK_KEYS + 1]
    if deck == "b_challenge" then deck = "b_red" end
    local s = E.new_run({seed = string.format("SP%d_%d", opt.seed, r), deck = deck, stake = opt.stake})
    local target = curriculum(r)
    local live = not target or prefix(s, target)
    if not live then skipped = skipped + 1 end
    local recs = {}
    local moves, econ_run = 0, 0
    local mpa, last_blind, run_sims, run_t0 = {}, nil, 0, clock()
    local rec_moves = opt.recs ~= "" and r - opt.first < opt.rec_runs and {} or nil
    while live do
        if full then MC.advance_forced(s) else MC.advance(s) end
        if MC.terminal(s) or moves >= opt.max_moves then break end
        if not full and s.phase ~= "play" then break end
        local ph = s.phase
        if s.blind > 0 then last_blind = s.blind end
        if ph == "shop" or ph == "pack" then econ_run = econ_run + 1 else econ_run = 0 end
        if econ_run > opt.max_shop then
            if not E.step(s, ph == "pack" and SKIP or LEAVE) then break end
        else
            local temp = moves < opt.temp_moves and 1 or 0
            local fast = opt.fast_sims > 0 and temp == 0 and mc.rnd() >= opt.full_frac
            local n = fast and opt.fast_sims or opt.sims
            mc:search(s, n, {noise = fast and 0 or opt.noise, reuse = opt.reuse == 1, adaptive = temp == 0 and opt.adaptive == 1,
                conf_prior = opt.conf > 0 and opt.conf or nil, conf_frac = opt.conf_frac})
            local e = mc:choose(temp)
            if not e then break end
            local tag = n
            if opt.conf > 0 and temp == 0 and mc.top_prior >= opt.conf then tag = math.ceil(n * opt.conf_frac) end
            if fh then recs[#recs + 1] = REC.encode_record(mc.F_root, mc, e, tag, FE.PHASES[ph] or 0) end
            local tn = FE.TYPES[mc.e_type[e]]
            by_type[tn] = (by_type[tn] or 0) + 1
            mc:edge_action(e, step, s)
            if rec_moves and #rec_moves < 400 then rec_moves[#rec_moves + 1] = GL.move(s, mc, step, e, tn, n, ph) end
            if tn == "leave" then mpa[s.ante] = s.money end
            run_sims = run_sims + mc.sims_done
            mc:commit(e)
            if not E.step(s, step) then
                io.stderr:write(string.format("illegal %s in run %d phase %s\n", tn, r, ph))
                break
            end
            moves = moves + 1
            decisions = decisions + 1
            sim_steps = sim_steps + mc.sims_done
        end
    end
    if live then
    local won = s.won == 1 and 1 or 0
    local final_ante = won == 1 and s.win_ante + 1 or s.ante
    wins = wins + won
    ante_sum = ante_sum + final_ante
    runs_done = runs_done + 1
    local run_seed = string.format("SP%d_%d", opt.seed, r)
    if opt.games ~= "" then
        GL.append(GL.path(opt.games, opt.seed), GL.game(s, {won = won, ante = final_ante, deck = deck, stake = opt.stake,
            seed = run_seed, mpa = mpa, dec = moves, sims = moves > 0 and math.floor(run_sims / moves) or 0,
            dur = math.floor((clock() - run_t0) * 100) / 100, last_blind = last_blind}))
    end
    if rec_moves and #rec_moves > 0 then
        GL.append(GL.path(opt.recs, opt.seed), {type = "record", id = run_seed, deck = deck, stake = opt.stake, seed = run_seed,
            won = won, ante = final_ante, death = won == 0 and GL.blind_key(s, last_blind) or nil, moves = rec_moves})
    end
    if fh then fh:write(REC.encode_run(recs, won, final_ante, FE.DECK_IDX[deck] or 0, opt.stake, r)) end
    if opt.quiet == 0 then
        print(string.format("run %d deck %s ante %d won %d moves %d start %d", r, deck, final_ante, won, moves, target or 1))
    end
    end
    if opt.secs > 0 and clock() - t0 > opt.secs then break end
end
if fh then fh:close() end
local dt = clock() - t0
local parts = {}
for _, t in ipairs(FE.TYPES) do
    if by_type[t] then parts[#parts + 1] = t .. "=" .. by_type[t] end
end
if opt.quiet < 2 then print("decisions by type: " .. table.concat(parts, " ")) end
print(string.format("sims %d K %d runs %d decisions %d time %.2fs | %.1f decisions/s %.3f runs/s %.0f sims/s | avg ante %.2f wins %d",
    opt.sims, opt.K, runs_done, decisions, dt, decisions / dt, runs_done / dt, sim_steps / dt, ante_sum / math.max(1, runs_done), wins))
if skipped > 0 then print(string.format("curriculum prefix died in %d runs (not recorded)", skipped)) end
