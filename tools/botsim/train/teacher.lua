package.path = "assets/?.lua;tools/?.lua;" .. package.path
require("botsim.jitopt")

local E = require("bot.sim.engine")
local FE = require("bot.nn.features")
local MC = require("bot.nn.mcts")
local REC = require("botsim.train.records")
local POL = require("botsim.policy")

local opt = {runs = 4, seed = 1, first = 1, out = "", deck = "", stake = 1, eps = 0, K = 24, quiet = 0, max_moves = 3000,
    max_shop = 40, shop = 1, cut = 0}
for _, a in ipairs(arg or {}) do
    local k, v = a:match("^([%w_]+)=(.*)$")
    if k then opt[k] = tonumber(v) or v end
end
POL.shop = opt.shop == 1

local rnd = MC.new_rng(opt.seed * 104729 + 7)
local fh
if opt.out ~= "" then
    fh = assert(io.open(opt.out, "wb"))
    fh:write(REC.file_header())
end

local F, AB = FE.new_state_buf(), FE.new_action_buf(1024)
local st = {}
local LEAVE, SKIP = {type = "leave"}, {type = "skip"}
local t0 = os.clock()
local decisions, wins, ante_sum, runs_done = 0, 0, 0, 0
local by_type = {}

for r = opt.first, opt.first + opt.runs - 1 do
    local deck = opt.deck ~= "" and opt.deck or FE.DECK_KEYS[(opt.seed + r) % #FE.DECK_KEYS + 1]
    if deck == "b_challenge" then deck = "b_red" end
    local s = E.new_run({seed = string.format("SP%d_%d", opt.seed, r), deck = deck, stake = opt.stake})
    if opt.cut == 1 then E.apply_voucher(s, "v_directors_cut") end
    local recs = {}
    local moves, econ_run = 0, 0
    while moves < opt.max_moves do
        MC.advance_forced(s)
        if MC.terminal(s) then break end
        local ph = s.phase
        if ph == "shop" or ph == "pack" then econ_run = econ_run + 1 else econ_run = 0 end
        if econ_run > opt.max_shop then
            if not E.step(s, ph == "pack" and SKIP or LEAVE) then break end
        else
            FE.state(s, F)
            local n = FE.list_actions(s, AB, F)
            if n == 0 then break end
            local a = POL.choose(s)
            local k = a and FE.find_action(AB, a, s) or -1
            if k < 0 or (ph ~= "play" and rnd() < opt.eps) then k = math.floor(rnd() * n) end
            if fh then
                local picks, used = {{k = k, visits = 1, prior = 1}}, {[k] = true}
                local want = math.min(opt.K, n)
                while #picks < want do
                    local q = math.floor(rnd() * n)
                    if not used[q] then
                        used[q] = true
                        picks[#picks + 1] = {k = q, visits = 0, prior = 0}
                    end
                end
                recs[#recs + 1] = REC.encode_choice(F, AB, picks, {chosen = 1, phase = FE.PHASES[ph] or 0, n_sims = 1})
            end
            local tn = FE.TYPES[AB.type[k]]
            by_type[tn] = (by_type[tn] or 0) + 1
            if not E.step(s, FE.to_step(AB, k, st, s)) then
                io.stderr:write(string.format("illegal %s in run %d phase %s\n", tn, r, ph))
                break
            end
            moves = moves + 1
            decisions = decisions + 1
        end
    end
    local won = s.won == 1 and 1 or 0
    local final_ante = won == 1 and s.win_ante + 1 or s.ante
    wins = wins + won
    ante_sum = ante_sum + final_ante
    runs_done = runs_done + 1
    if fh then fh:write(REC.encode_run(recs, won, final_ante, FE.DECK_IDX[deck] or 0, opt.stake, r)) end
    if opt.quiet == 0 then print(string.format("run %d deck %s ante %d won %d moves %d", r, deck, final_ante, won, moves)) end
end
if fh then fh:close() end
local parts = {}
for _, t in ipairs(FE.TYPES) do
    if by_type[t] then parts[#parts + 1] = t .. "=" .. by_type[t] end
end
if opt.quiet < 2 then print("decisions by type: " .. table.concat(parts, " ")) end
local dt = os.clock() - t0
print(string.format("teacher runs %d decisions %d time %.2fs | %.1f decisions/s | avg ante %.2f wins %d",
    runs_done, decisions, dt, decisions / dt, ante_sum / runs_done, wins))
