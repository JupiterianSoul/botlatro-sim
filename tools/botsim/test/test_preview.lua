local T = ...
local ST = require("bot.sim.state")
local E = require("bot.sim.engine")
local PL = require("bot.seer.play")

local function subsets(n)
    local out = {}
    for mask = 1, 2 ^ n - 1 do
        local cs, c = {}, 0
        for i = 1, n do
            if math.floor(mask / 2 ^ (i - 1)) % 2 == 1 then c = c + 1 cs[c] = i end
        end
        if c <= 5 then out[#out + 1] = cs end
    end
    return out
end

local function rng_sig(s)
    local t = {}
    for i = 1, s.n_rk do
        local id = s.rng_ids[i]
        t[#t + 1] = tostring(id) .. "=" .. tostring(s.rng[id])
    end
    return table.concat(t, ",")
end

T.current = "preview with RNG lookup matches the full copy"
local fast, full = ST.scratch(), ST.scratch()
local checked, differ, leaks = 0, 0, 0
for _, seed in ipairs({"PREV0001", "PREV0002", "PREV0003", "PREV0004"}) do
    for _, deck in ipairs({"b_red", "b_plasma"}) do
        local s = E.new_run({seed = seed, deck = deck, stake = 1})
        for _ = 1, 600 do
            if s.won == 1 or s.phase == "game_over" then break end
            local a
            if s.phase == "play" then
                local before = rng_sig(s)
                for _, cs in ipairs(subsets(s.n_hand)) do
                    ST.PREVIEW_PROXY = true
                    local g1, t1 = E.preview_into(fast, s, cs)
                    ST.PREVIEW_PROXY = false
                    local g2, t2 = E.preview_into(full, s, cs)
                    checked = checked + 1
                    if g1 ~= g2 or t1 ~= t2 then differ = differ + 1 end
                end
                ST.PREVIEW_PROXY = true
                if rng_sig(s) ~= before then leaks = leaks + 1 end
                a = PL.fast_action(s)
            elseif s.phase == "blind_select" then a = {type = "select"}
            elseif s.phase == "round_eval" then a = {type = "cash_out"}
            elseif s.phase == "shop" then
                a = {type = "leave"}
                for i = 1, s.n_sj do
                    if s.n_jok < s.joker_limit and s.money >= E.shop_joker_cost(s, i) then a = {type = "buy", card = i} break end
                end
            elseif s.phase == "pack" then a = {type = "skip"}
            else break end
            if not E.step(s, a) then
                if a.type == "buy" then E.step(s, {type = "leave"}) else break end
            end
        end
    end
end
ST.PREVIEW_PROXY = true
T.ok(checked > 1000, "previews checked: " .. checked)
T.eq(differ, 0, "previews that differ")
T.eq(leaks, 0, "previews that changed the source RNG")
