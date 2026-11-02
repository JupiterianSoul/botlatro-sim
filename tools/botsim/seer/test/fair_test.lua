package.path = "assets/?.lua;tools/?.lua;" .. package.path

local E = require("bot.sim.engine")
local ST = require("bot.sim.state")
local SN = require("bot.sim.snapshot")
local rng = require("bot.sim.rng")
local S = require("bot.seer.seer")
local F = require("bot.seer.fair")
local D = require("bot.sim.data")
local LK = require("botsim.seer.leaks")

local passed, failed = 0, 0
local current = ""
local function ok(v, msg)
    if v then passed = passed + 1 else
        failed = failed + 1
        print(string.format("FAIL [%s] %s", current, msg or ""))
    end
end

local QUICK = {horizon = 1, tight_horizon = 1, beam = 2, tight_beam = 2, depth = 2}
local TINY = {worlds = 2, eval_h = 1, max_cands = 2, seer = QUICK, solve = {beam = 2, plays = 2, discards = 2}, sampler_seed = "LEAK"}
local slow = not (arg and arg[1] == "quick")

local function ser(v, out, skip)
    local t = type(v)
    if t ~= "table" then
        out[#out + 1] = t == "number" and string.format("%.17g", v) or tostring(v)
        return
    end
    local keys = {}
    for k in pairs(v) do
        if not skip[k] then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b)
        if type(a) ~= type(b) then return type(a) < type(b) end
        return a < b
    end)
    out[#out + 1] = "{"
    for _, k in ipairs(keys) do
        out[#out + 1] = tostring(k) .. "="
        ser(v[k], out, {})
        out[#out + 1] = ","
    end
    out[#out + 1] = "}"
end

local function ser_state(s)
    local out = {}
    ser(s, out, {hcache = true})
    return table.concat(out)
end

local variant = require("botsim.seer.scramble").variant

local function collect(setup, limit, max_ante)
    local seer = S.new(QUICK)
    local s = E.new_run(setup)
    local states, seen = {}, {}
    for _ = 1, 600 do
        if s.won == 1 or s.phase == "game_over" or s.ante > max_ante then break end
        local key = s.phase .. s.round
        if not seen[key] and #states < limit then
            seen[key] = true
            states[#states + 1] = ST.clone(s)
        end
        local a = seer:choose(s)
        if not a or not E.step(s, a) then break end
    end
    return states
end

local states = {}
for _, setup in ipairs({{seed = "FAIRLEAK1", deck = "b_red", stake = 1}, {seed = "FAIRLEAK2", deck = "b_plasma", stake = 2}}) do
    for _, st in ipairs(collect(setup, slow and 10 or 5, 2)) do states[#states + 1] = st end
end
for _, st in ipairs(states) do
    if st.phase == "play" and st.n_hand >= 2 then
        local f = ST.clone(st)
        f.c_flip[f.hand[1]] = 1
        f.c_flip[f.hand[2]] = 1
        if f.n_jok >= 2 then for k = 1, f.n_jok do f.j_flip[k] = 1 end end
        states[#states + 1] = f
        break
    end
end

local function late(boss, ante, jokers, after)
    local s = E.new_run({seed = "FAIRLATE" .. boss, deck = "b_red", stake = 8})
    E.step(s, {type = "skip"})
    E.step(s, {type = "skip"})
    s.ante = ante
    for _, j in ipairs(jokers) do E.add_joker(s, j) end
    s.boss_choice = D.BLIND_ID[boss]
    s.money = 30
    assert(E.step(s, {type = "select"}))
    if after then after(s) end
    states[#states + 1] = s
    return s
end

local JK = {"j_joker", "j_mime", "j_duo", "j_blackboard"}
for _, boss in ipairs({"bl_final_acorn", "bl_final_leaf", "bl_final_vessel", "bl_final_bell", "bl_final_heart"}) do late(boss, 8, JK) end
late("bl_house", 6, JK)
late("bl_mark", 6, JK)
late("bl_wheel", 7, JK)
late("bl_fish", 7, JK, function(s) E.step(s, {type = "play", cards = {1}}) end)
late("bl_final_acorn", 8, JK, function(s) E.add_joker(s, "j_splash") end)
do
    local s = late("bl_hook", 7, JK, function(s)
        s.chips = s.blind_chips
        E.step(s, {type = "play", cards = {1}})
    end)
    states[#states] = nil
    states[#states + 1] = ST.clone(s)
    E.step(s, {type = "cash_out"})
    states[#states + 1] = ST.clone(s)
    if s.phase == "shop" then
        E.step(s, {type = "leave"})
        states[#states + 1] = ST.clone(s)
    end
end

current = "sanitized view ignores hidden info"
do
    local phases = {}
    for i, s in ipairs(states) do
        phases[s.phase] = true
        local v = variant(s, i)
        if s.n_deck > 2 then ok(table.concat(s.deck, ",") ~= table.concat(v.deck, ","), "variant really reorders the deck") end
        ok(s.seed ~= v.seed, "variant has another seed")
        ok(ser_state(F.sanitize(s)) == ser_state(F.sanitize(v)), "same fair view (" .. s.phase .. " step " .. s.step .. ")")
    end
    ok(phases.play and phases.shop and phases.blind_select, "covered play, shop and blind select")
end

current = "worlds keep every visible fact"
do
    for i, s in ipairs(states) do
        local b = F.sanitize(s)
        local w = F.world(b, "WTEST" .. i)
        ok(w.money == s.money and w.ante == s.ante and w.phase == s.phase and w.n_deck == s.n_deck and w.n_hand == s.n_hand, "scalars kept")
        local same_vis = true
        for k = 1, s.n_hand do
            local cid = s.hand[k]
            if s.c_flip[cid] ~= 1 and w.hand[k] ~= cid then same_vis = false end
        end
        ok(same_vis, "face-up hand kept")
        local p1, p2 = {}, {}
        for k = 1, s.n_deck do p1[#p1 + 1] = s.deck[k] end
        for k = 1, w.n_deck do p2[#p2 + 1] = w.deck[k] end
        for k = 1, s.n_hand do
            if s.c_flip[s.hand[k]] == 1 then p1[#p1 + 1] = s.hand[k] end
            if w.c_flip[w.hand[k]] == 1 then p2[#p2 + 1] = w.hand[k] end
        end
        table.sort(p1)
        table.sort(p2)
        ok(table.concat(p1, ",") == table.concat(p2, ","), "unseen pool kept as a set")
        local own = w.seed ~= s.seed and (w.n_rk == 0 or b.fair_voucher_hidden == 1)
        for id, v in pairs(w.rng) do
            if s.rng[id] ~= nil and s.rng[id] == v then own = false end
        end
        ok(own, "world has its own RNG")
        local js = true
        for k = 1, s.n_jok do if s.j_flip[k] ~= 1 and (w.j_id[k] ~= s.j_id[k] or w.j_uid[k] ~= s.j_uid[k]) then js = false end end
        ok(js, "face-up jokers kept in order")
        if s.phase == "shop" then
            local sh = w.n_sj == s.n_sj
            for k = 1, s.n_sj do if w.sj_id[k] ~= s.sj_id[k] then sh = false end end
            ok(sh, "visible shop kept")
        end
    end
end

local function ser_full(s)
    local out = {}
    ser(s, out, {})
    return table.concat(out)
end

local function same_view(s, v)
    return ser_full(F.sanitize(s)) == ser_full(F.sanitize(v))
end

local function same_world(s, v, key)
    return ser_full(F.world(F.sanitize(s), key)) == ser_full(F.world(F.sanitize(v), key))
end

current = "same key gives the same world from any hidden state"
do
    for i, s in ipairs(states) do
        local v = variant(s, i)
        ok(same_view(s, v), "same view with its caches (" .. s.phase .. " step " .. s.step .. ")")
        ok(same_world(s, v, "WSAME" .. i), "same world (" .. s.phase .. " step " .. s.step .. ")")
    end
end

current = "the world check catches every planted leak"
do
    local world0, san0 = F.world, F.sanitize
    for name, leak in pairs(LK.world) do
        local real
        F.sanitize = function(x)
            real = x
            return san0(x)
        end
        F.world = function(base, key)
            local w = world0(base, key)
            leak(w, real, base)
            return w
        end
        local caught = 0
        for i, s in ipairs(states) do
            if not same_world(s, variant(s, i), "WPLANT" .. i) then caught = caught + 1 end
        end
        F.sanitize, F.world = san0, world0
        print(string.format("info: planted world leak %s seen on %d of %d states", name, caught, #states))
        ok(caught > 0, "planted world leak seen: " .. name)
    end
    for name, leak in pairs(LK.sanitize) do
        F.sanitize = function(x)
            local b = san0(x)
            leak(b, x)
            return b
        end
        local caught = 0
        for i, s in ipairs(states) do
            if not same_view(s, variant(s, i)) then caught = caught + 1 end
        end
        F.sanitize = san0
        print(string.format("info: planted view leak %s seen on %d of %d states", name, caught, #states))
        ok(caught > 0, "planted view leak seen: " .. name)
    end
end

current = "worlds do not correlate with the real future"
do
    local same, total, worlds, boss_same, boss_n = 0, 0, 0, 0, 0
    for _, s in ipairs(states) do
        if s.n_deck >= 20 then
            local flipped = false
            for i = 1, s.n_hand do flipped = flipped or s.c_flip[s.hand[i]] == 1 end
            local base = F.sanitize(s)
            local real_boss = E.get_new_boss(ST.clone(s))
            for k = 1, 30 do
                local w = F.world(base, string.format("FW%s_%d", s.seed, k))
                if not flipped then
                    worlds = worlds + 1
                    for p = 1, s.n_deck do
                        total = total + 1
                        if w.deck[p] == s.deck[p] then same = same + 1 end
                    end
                end
                boss_n = boss_n + 1
                if E.get_new_boss(ST.clone(w)) == real_boss then boss_same = boss_same + 1 end
            end
        end
    end
    print(string.format("info: deck slots equal to the truth %d of %d, %.2f per world (a fair shuffle gives 1), next boss equal %d of %d", same, total, same / worlds, boss_same, boss_n))
    ok(worlds > 0 and same / worlds < 1.5, "a world deck matches the truth no more than chance")
    ok(boss_n > 0 and boss_same / boss_n < 0.4, "a world next boss matches the truth no more than chance")
end

current = "decisions ignore hidden info and leave the real state alone"
do
    local differ = 0
    local limit = slow and #states or 4
    for i = 1, limit do
        local s = states[i]
        local v = variant(s, i)
        local before, vbefore = SN.line(s), SN.line(v)
        local rb = {}
        for k = 1, s.n_rk do rb[k] = s.rng[s.rng_ids[k]] end
        local a1 = F.new(TINY):decide(s)
        local a2 = F.new(TINY):decide(v)
        ok(a1 ~= nil and a2 ~= nil, "decision exists (" .. s.phase .. ")")
        ok(F.plan_key(a1 or {}) == F.plan_key(a2 or {}), "same decision (" .. s.phase .. " step " .. s.step .. ")")
        ok(SN.line(s) == before and SN.line(v) == vbefore, "real state unchanged")
        local same = true
        for k = 1, #rb do if s.rng[s.rng_ids[k]] ~= rb[k] then same = false end end
        ok(same, "real RNG unchanged")
        local c1 = S.new(QUICK):choose(ST.clone(s))
        local c2 = S.new(QUICK):choose(ST.clone(v))
        if c1 and c2 and F.action_key(c1) ~= F.action_key(c2) then differ = differ + 1 end
        ok(a1 and E.step(ST.clone(s), a1[1]), "decision accepted by the real state")
    end
    print(string.format("info: cheating Seer changed its move on %d of %d variant pairs", differ, limit))
end

current = "fair run is legal and deterministic"
do
    local setup = {seed = "FAIRRUN1", deck = "b_red", stake = 1}
    local o = {}
    for k, v in pairs(TINY) do o[k] = v end
    local function short(fo)
        local s = E.new_run(setup)
        local line = {}
        for _ = 1, 400 do
            if s.won == 1 or s.phase == "game_over" or s.ante > 1 then break end
            local acts = fo:decide(s)
            if not acts then break end
            for _, a in ipairs(acts) do
                ok(E.step(s, a), "action accepted")
                line[#line + 1] = F.action_key(a)
            end
        end
        return table.concat(line, " "), s
    end
    local l1, s1 = short(F.new(o))
    local l2, s2 = short(F.new(o))
    ok(#l1 > 0 and l1 == l2, "same line twice")
    ok(SN.line(s1) == SN.line(s2), "same end state")
    ok(s1.ante > 1 or s1.phase == "game_over", "reached ante 2 or died")
end

current = "solver_tie keeps money against The Ox"
do
    local s = late("bl_ox", 6, JK, function(s)
        s.money = 40
        s.chips = s.blind_chips - 1
    end)
    states[#states] = nil
    local w = F.world(F.sanitize(s), "WTIE")
    local function val(tie, mp)
        local o = {honest = 5, tie = tie}
        for k, v in pairs(TINY) do o[k] = o[k] or v end
        local c = ST.clone(w)
        c.most_played = mp
        return (F.new(o):evaluate(c, {{type = "play", cards = {1}}}, "play"))
    end
    ok(val(1, 12) < val(1, 1), "a clear that keeps the money ranks higher")
    ok(val(0, 12) == val(0, 1), "no money term when off")
    local function quick(tie)
        local o = {honest = 5, tie = tie, quick_clear = true}
        for k, v in pairs(TINY) do o[k] = o[k] or v end
        local fo = F.new(o)
        ok(fo:decide(ST.clone(s)) ~= nil, "a move")
        return fo.quick
    end
    ok(quick(0) == 1 and quick(1) == 0, "no quick clear against The Ox with tie")
end

current = "solver_h=6 digs for the flush from the visible deck"
do
    local PL = require("bot.seer.play")
    local s = E.new_run({seed = "FAIRDIG", deck = "b_black", stake = 8})
    assert(E.step(s, {type = "select"}))
    local ranks = {14, 12, 9, 6, 13, 7, 4, 2}
    for i = 1, s.n_hand do
        local id = s.hand[i]
        s.c_rank[id] = ranks[i]
        s.c_suit[id] = i <= 4 and 1 or (i % 3) + 2
    end
    local w = F.world(F.sanitize(s), "WDIG")
    local fb = PL.fast_action(w)
    ok(fb and fb.type == "discard", "the quick policy discards")
    local deck = {}
    for i = 1, w.n_deck do deck[i] = w.deck[i] end
    local a = F.dig(w, fb, 16)
    ok(a and a.type == "discard", "a discard")
    local hearts = true
    for _, p in ipairs(a and a.cards or {}) do hearts = hearts and w.c_suit[w.hand[p]] ~= 1 end
    ok(hearts and #a.cards == 4, "keeps the four hearts")
    local same = w.n_deck == #deck
    for i = 1, #deck do same = same and w.deck[i] == deck[i] end
    ok(same and w.n_hand == 8, "the world is not changed")
    local w2 = ST.clone(w)
    for i = 1, w2.n_deck do w2.deck[i] = deck[w2.n_deck + 1 - i] end
    ok(F.action_key(F.dig(w2, fb, 16)) == F.action_key(a), "the choice does not depend on the world's draw order")
end

print(string.format("fair tests: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
