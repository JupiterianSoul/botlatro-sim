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

T.current = "repeat previews restore only hand cards"
local function state_diff(a, s)
    for _, k in ipairs(ST.SCALARS) do if a[k] ~= s[k] then return k end end
    for _, f in ipairs(ST.CARD_ARRAYS) do
        if f ~= "c_forced" then
            for i = 1, s.n_cards do if a[f][i] ~= s[f][i] then return f end end
        end
    end
    for _, f in ipairs(ST.JOKER_ARRAYS) do
        for i = 1, s.n_jok do if a[f][i] ~= s[f][i] then return f end end
    end
    for _, f in ipairs(ST.FIXED_ARRAYS) do
        for i = 1, f[2] do if a[f[1]][i] ~= s[f[1]][i] then return f[1] end end
    end
    for _, f in ipairs(ST.VAR_ARRAYS) do
        for i = 1, s[f[2]] do if a[f[1]][i] ~= s[f[1]][i] then return f[1] end end
    end
    for _, f in ipairs({{"deck", "n_deck"}, {"hand", "n_hand"}, {"disc", "n_disc"}, {"tags", "n_tags"}, {"cons", "n_cons"}}) do
        for i = 1, s[f[2]] do if a[f[1]][i] ~= s[f[1]][i] then return f[1] end end
    end
    for i = 1, s.n_rk do
        local id = s.rng_ids[i]
        if a.rng[id] ~= s.rng[id] then return "rng" end
    end
    if next(a.rng_proxy) ~= nil then return "rng_proxy" end
    return nil
end

local joker_sets = {
    {"j_dna", "j_midas_mask", "j_hiker"},
    {"j_vampire", "j_sixth_sense", "j_space", "j_blueprint"},
    {"j_todo_list", "j_ice_cream", "j_gros_michel", "j_brainstorm"},
    {"j_stone", "j_steel_joker", "j_trousers", "j_runner", "j_square"},
}
local enh = {1, 2, 3, 4, 5, 6, 7, 8}
local again, fresh = ST.scratch(), ST.scratch()
local rchecked, rdiffer, rbad, added = 0, 0, 0, 0
for si, set in ipairs(joker_sets) do
    for _, deck in ipairs({"b_red", "b_plasma"}) do
        local s = E.new_run({seed = "AGAIN00" .. si, deck = deck, stake = 1})
        for _, key in ipairs(set) do
            if pcall(E.add_joker, s, key) then added = added + 1 end
        end
        for c = 1, s.n_cards do
            if c % 3 == 0 then s.c_enh[c] = enh[1 + c % #enh] end
            if c % 7 == 0 then s.c_seal[c] = 1 + c % 4 end
            if c % 5 == 0 then s.c_ed[c] = 1 + c % 3 end
        end
        for _ = 1, 300 do
            if s.won == 1 or s.phase == "game_over" then break end
            local a
            if s.phase == "play" then
                local list = PL.combos(s.n_hand)
                for idx, cs in ipairs(list) do
                    if idx > 1 then
                        ST.copy_preview_again(again, s)
                        local bad = state_diff(again, s)
                        if bad then
                            if rbad < 5 then print("restore differs", si, deck, bad) end
                            rbad = rbad + 1
                        end
                    end
                    local g1, t1 = E.preview_into(again, s, cs, idx > 1)
                    local g2, t2 = E.preview_into(fresh, s, cs)
                    rchecked = rchecked + 1
                    if g1 ~= g2 or t1 ~= t2 then rdiffer = rdiffer + 1 end
                end
                a = PL.fast_action(s)
            elseif s.phase == "blind_select" then a = {type = "select"}
            elseif s.phase == "round_eval" then a = {type = "cash_out"}
            elseif s.phase == "shop" then a = {type = "leave"}
            elseif s.phase == "pack" then a = {type = "skip"}
            else break end
            if not E.step(s, a) then break end
        end
    end
end
T.ok(added >= 24, "jokers added: " .. added)
T.ok(rchecked > 1000, "repeat previews checked: " .. rchecked)
T.eq(rbad, 0, "restored states that differ from a full copy")
T.eq(rdiffer, 0, "repeat previews that differ")
