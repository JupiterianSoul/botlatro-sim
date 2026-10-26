package.path = "assets/?.lua;tools/?.lua;" .. package.path
local E = require("bot.sim.engine")
local D = require("bot.sim.data")
local ST = require("bot.sim.state")
local SN = require("bot.sim.snapshot")

local N = tonumber(arg and arg[1]) or 300
local decks = {"b_red", "b_blue", "b_yellow", "b_green", "b_black", "b_magic", "b_nebula", "b_ghost", "b_abandoned",
    "b_checkered", "b_zodiac", "b_painted", "b_anaglyph", "b_plasma", "b_erratic"}
math.randomseed(7)
local seeds = {}
for i = 1, N do seeds[i] = math.random(1, 1e9) end
local errors, actions = 0, 0
for i = 1, N do
    local r = seeds[i]
    local function rnd(n) r = (r * 16807) % 2147483647 return r % n + 1 end
    local s = E.new_run({seed = string.format("FZ%06d", i), deck = decks[rnd(#decks)], stake = rnd(8)})
    for _ = 1, rnd(9) - 1 do
        E.add_joker(s, rnd(D.NUM_JOKERS), rnd(6) == 1 and D.ED_KEYS[rnd(4)] or nil)
    end
    for c = 1, s.n_cards do
        if rnd(5) == 1 then s.c_enh[c] = rnd(8) end
        if rnd(8) == 1 then s.c_seal[c] = rnd(4) end
        if rnd(10) == 1 then s.c_ed[c] = rnd(3) end
    end
    local guard = 0
    local ok, err = pcall(function()
        while s.phase ~= "game_over" and guard < 300 do
            guard = guard + 1
            local a
            if s.phase == "blind_select" then
                local t = rnd(4)
                a = {type = t == 1 and "skip" or (t == 2 and "reroll_boss" or "select")}
            elseif s.phase == "play" then
                local n = math.min(rnd(5), s.n_hand)
                local pos, used = {}, {}
                while #pos < n do
                    local p = rnd(s.n_hand)
                    if not used[p] then used[p] = true pos[#pos + 1] = p end
                end
                for q = 1, s.n_hand do
                    if s.c_forced[s.hand[q]] == 1 and not used[q] then pos[#pos] = q end
                end
                a = {type = (rnd(3) == 1 and s.discards_left > 0) and "discard" or "play", cards = pos}
            elseif s.phase == "round_eval" then a = {type = "cash_out"}
            elseif s.phase == "shop" then a = {type = "leave"} end
            if not a then break end
            if E.step(s, a) then actions = actions + 1 end
            if guard % 50 == 0 then
                local c = ST.clone(s)
                assert(SN.line(c) == SN.line(s), "clone snapshot differs")
            end
        end
    end)
    if not ok then
        errors = errors + 1
        if errors <= 5 then print("error in run", i, err) end
    end
end
print(string.format("fuzz: %d runs, %d actions, %d errors", N, actions, errors))
os.exit(errors == 0 and 0 or 1)
