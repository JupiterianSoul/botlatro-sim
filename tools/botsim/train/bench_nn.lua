package.path = "assets/?.lua;tools/?.lua;" .. package.path
require("botsim.jitopt")

local E = require("bot.sim.engine")
local BUF = require("bot.nn.buf")
local FE = require("bot.nn.features")
local WT = require("bot.nn.weights")
local NET = require("bot.nn.net")
local P = require("botsim.policy")

local secs = tonumber(arg[1]) or 1.0
local clock = os.clock

local function collect_states(n)
    local out = {}
    local seed = 1
    while #out < n do
        local s = E.new_run({seed = "BNCH" .. seed, deck = FE.DECK_KEYS[seed % #FE.DECK_KEYS + 1], stake = 1})
        local guard = 0
        while s.phase ~= "game_over" and s.won ~= 1 and guard < 200 do
            guard = guard + 1
            if s.phase == "play" then
                out[#out + 1] = require("bot.sim.state").clone(s)
                if s.n_jok < 4 then E.add_joker(s, (seed * 7 + guard * 13) % 150 + 1) end
            end
            local a = P.choose(s)
            if not a or not E.step(s, a) then break end
        end
        seed = seed + 1
    end
    return out
end

local states = collect_states(64)

local function bench(label, fn)
    local n, t0 = 0, clock()
    local t = t0
    while t - t0 < secs do
        for _ = 1, 50 do fn(n) n = n + 1 end
        t = clock()
    end
    local per = (t - t0) / n
    print(string.format("%-34s %9.1f us  %9.0f /s", label, per * 1e6, 1 / per))
    return per
end

local results = {}
for _, mode in ipairs({true, false}) do
    BUF.set_ffi(mode)
    local tag = mode and "ffi" or "plain"
    local F = FE.new_state_buf()
    local AB = FE.new_action_buf(1024)
    bench(tag .. " features.state", function(i) FE.state(states[i % #states + 1], F) end)
    local na = 0
    bench(tag .. " features.actions", function(i) na = na + FE.actions(states[i % #states + 1], AB) end)
    for _, sz in ipairs({{16, 64, 16}, {32, 128, 32}, {64, 256, 64}}) do
        local cfg = WT.default_cfg(FE, {E = sz[1], H = sz[2], VH = sz[3]})
        local net = NET.new(WT.random(cfg, 7))
        local fs = {}
        for i = 1, #states do
            fs[i] = FE.new_state_buf()
            FE.state(states[i], fs[i])
        end
        local per_f = bench(string.format("%s forward E%d H%d (%d w)", tag, sz[1], sz[2], WT.count(cfg)), function(i)
            net:forward(fs[i % #fs + 1])
        end)
        FE.actions(states[1], AB)
        local nact = AB.n
        local per_p = bench(string.format("%s fwd+policy(%d acts)", tag, nact), function()
            net:forward(fs[1])
            net:policy(AB)
        end)
        results[#results + 1] = {tag, sz[1], sz[2], WT.count(cfg), per_f, per_p, nact}
    end
end
BUF.set_ffi(true)

print("")
print("mode   E   H   weights   forward_us  evals/s   fwd+policy_us")
for _, r in ipairs(results) do
    print(string.format("%-5s %3d %4d %8d %10.1f %9.0f %12.1f", r[1], r[2], r[3], r[4], r[5] * 1e6, 1 / r[5], r[6] * 1e6))
end
