package.path = "assets/?.lua;tools/?.lua;" .. package.path
require("botsim.jitopt")

local E = require("bot.sim.engine")
local ST = require("bot.sim.state")
local FE = require("bot.nn.features")
local WT = require("bot.nn.weights")
local NET = require("bot.nn.net")
local MC = require("bot.nn.mcts")
local P = require("botsim.policy")

local secs = tonumber(arg[1]) or 2
local sims_list = {}
for i = 2, #arg do sims_list[#sims_list + 1] = tonumber(arg[i]) end
if #sims_list == 0 then sims_list = {16, 64, 256, 800} end
local clock = os.clock

local states, blinds, decisions = {}, 0, 0
for seed = 1, 40 do
    local s = E.new_run({seed = "BMC" .. seed, deck = FE.DECK_KEYS[seed % 15 + 1], stake = 1})
    for _ = 1, 3 do E.add_joker(s, (seed * 37) % 150 + 1) end
    local guard = 0
    while s.phase ~= "game_over" and s.won ~= 1 and guard < 400 do
        guard = guard + 1
        if s.phase == "play" then
            decisions = decisions + 1
            if #states < 200 then states[#states + 1] = ST.clone(s) end
        elseif s.phase == "blind_select" then
            blinds = blinds + 1
        end
        local a = P.choose(s)
        if not a or not E.step(s, a) then break end
    end
end
print(string.format("greedy reference: %.2f play-phase decisions per blind (%d blinds)", decisions / blinds, blinds))

local cfg = WT.default_cfg(FE)
local net = NET.new(WT.random(cfg, 3))
local mc = MC.new(net, {K = 24, seed = 9, nodes = 1024, full = false})
print("sims  decisions/s  sims/s  nodes/decision")
for _, n in ipairs(sims_list) do
    local t0, cnt, nodes = clock(), 0, 0
    while clock() - t0 < secs do
        local s = states[cnt % #states + 1]
        mc:search(s, n, {noise = 0.25})
        mc:choose(1)
        nodes = nodes + mc.nn
        cnt = cnt + 1
    end
    local dt = clock() - t0
    print(string.format("%4d %11.1f %8.0f %8.1f", n, cnt / dt, cnt * n / dt, nodes / cnt))
end
