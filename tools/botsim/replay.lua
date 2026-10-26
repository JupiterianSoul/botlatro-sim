package.path = "assets/?.lua;tools/?.lua;" .. package.path
local E = require("bot.sim.engine")
local SN = require("bot.sim.snapshot")
local json = require("bot.sim.json")

local in_path, out_path = arg[1], arg[2]
if not in_path then
    io.stderr:write("usage: luajit tools/botsim/replay.lua <log.jsonl> [out.jsonl]\n")
    os.exit(2)
end
local f = assert(io.open(in_path, "r"))
local out = out_path and assert(io.open(out_path, "w")) or io.stdout
local setup
local s
local n = 0
for line in f:lines() do
    if line:match("%S") then
        local v = json.decode(line)
        if not setup then
            setup = v
            s = E.new_run({seed = v.seed, deck = v.deck, stake = v.stake, challenge = v.challenge})
            out:write(SN.line(s), "\n")
        else
            n = n + 1
            local ok = E.step(s, v)
            if not ok then
                io.stderr:write(string.format("action %d (%s) is not legal or not modelled in the sim, stopping\n", n, tostring(v.type)))
                break
            end
            out:write(SN.line(s), "\n")
        end
    end
end
f:close()
if out ~= io.stdout then out:close() end
