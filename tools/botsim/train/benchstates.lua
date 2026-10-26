local E = require("bot.sim.engine")
local ST = require("bot.sim.state")
local FE = require("bot.nn.features")
local P = require("botsim.policy")

return function(max_states, prefix)
    max_states = max_states or 200
    local states = {}
    for seed = 1, 400 do
        if #states >= max_states then break end
        local s = E.new_run({seed = (prefix or "BMC") .. seed, deck = FE.DECK_KEYS[seed % 15 + 1], stake = 1})
        for _ = 1, 3 do E.add_joker(s, (seed * 37) % 150 + 1) end
        local guard = 0
        while s.phase ~= "game_over" and s.won ~= 1 and guard < 400 do
            guard = guard + 1
            if s.phase == "play" and #states < max_states then states[#states + 1] = ST.clone(s) end
            local a = P.choose(s)
            if not a or not E.step(s, a) then break end
        end
    end
    return states
end
