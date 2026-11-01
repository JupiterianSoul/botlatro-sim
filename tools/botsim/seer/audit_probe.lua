package.path = "assets/?.lua;tools/?.lua;" .. package.path

local E = require("bot.sim.engine")
local D = require("bot.sim.data")

local target = table.remove(arg, 1)
local script = table.remove(arg, 1)

local function bones(s)
    local n = 0
    for k = 1, s.n_jok do
        local j = D.JOKERS[s.j_id[k]]
        if j and j.key == "j_mr_bones" then n = n + 1 end
    end
    return n
end

local function rentals(s)
    local n = 0
    for k = 1, s.n_jok do
        if s.j_rental[k] == 1 then n = n + 1 end
    end
    return n
end

local step0 = E.step
E.step = function(s, a)
    if tostring(s.seed):sub(1, 5) ~= "BENCH" then return step0(s, a) end
    local m0, ty, bl, rent = s.money, a.type, s.blind, rentals(s)
    local fin = s.seed == target and s.phase == "play" and s.ante == s.win_ante and s.blind > 2
    local b0, nj0, need = fin and bones(s) or 0, s.n_jok, s.blind_chips
    local r = step0(s, a)
    if s.money < m0 and s.money < s.bankrupt_at then
        print(string.format("debt %s %s blind=%s rentals=%d drop=%d now=%d limit=%d", tostring(s.seed), ty,
            bl > 0 and D.BLINDS[bl].key or "none", rent, m0 - s.money, s.money, s.bankrupt_at))
    end
    if fin then
        print(string.format("final %s %s blind=%s chips=%.0f need=%.0f jokers %d to %d bones %d to %d won=%d phase=%s", s.seed, ty,
            D.BLINDS[bl].key, s.chips, need, nj0, s.n_jok, b0, bones(s), s.won, s.phase))
        if s.won == 1 or s.phase == "game_over" then
            io.stdout:flush()
            os.exit(0)
        end
    end
    return r
end

arg[0] = script
dofile(script)
