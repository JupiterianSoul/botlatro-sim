package.path = "assets/?.lua;tools/?.lua;" .. package.path

local E = require("bot.sim.engine")
local ST = require("bot.sim.state")
local SN = require("bot.sim.snapshot")
local rng = require("bot.sim.rng")
local S = require("bot.seer.seer")
local F = require("bot.seer.fair")

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

print(string.format("fair tests: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
