package.path = "assets/?.lua;tools/?.lua;" .. package.path
local E = require("bot.sim.engine")
local SN = require("bot.sim.snapshot")
local json = require("bot.sim.json")

local dir, out_path = arg[1], arg[2]
if not dir then
    io.stderr:write("usage: luajit tools/botsim/diff/log_check.lua <log dir> [out.jsonl]\n")
    os.exit(2)
end
local out = out_path and assert(io.open(out_path, "w")) or io.stdout
local total, same, illegal = 0, 0, 0
local ls = assert(io.popen('ls "' .. dir .. '"'))
for name in ls:lines() do
    if name:match("%.jsonl$") then
        local path = dir .. "/" .. name
        local s, setup
        local n, bad = 0, 0
        for line in io.lines(path) do
            local v = json.decode(line)
            if not setup then
                setup = v
                s = E.new_run({seed = v.seed, deck = v.deck, stake = v.stake})
            elseif bad == 0 then
                n = n + 1
                if not E.step(s, v) then bad = n end
            end
        end
        local final = SN.line(s)
        local ff = io.open((path:gsub("%.jsonl$", ".final")), "r")
        local want = ff and ff:read("*l")
        if ff then ff:close() end
        local match = want == final
        total = total + 1
        if match then same = same + 1 end
        if bad > 0 then illegal = illegal + 1 end
        out:write(string.format('{"deck":"%s","stake":%d,"seed":"%s","actions":%d,"illegal_at":%d,"won":%d,"ante":%d,"money":%d,"phase":"%s","final_same":%s}\n',
            setup.deck, setup.stake, setup.seed, n, bad, s.won == 1 and 1 or 0, s.won == 1 and s.win_ante + 1 or s.ante, s.money, s.phase, match and "true" or "false"))
    end
end
ls:close()
if out ~= io.stdout then out:close() end
print(string.format("logs %d final_same %d illegal %d", total, same, illegal))
