package.path = "assets/?.lua;tools/?.lua;" .. package.path

local D = require("bot.sim.data")
local E = require("bot.sim.engine")
local ST = require("bot.sim.state")
local RNG = require("bot.sim.rng")
local BUF = require("bot.nn.buf")
local FE = require("bot.nn.features")
local WT = require("bot.nn.weights")
local NET = require("bot.nn.net")
local MC = require("bot.nn.mcts")
local REC = require("botsim.train.records")

local passed, failed = 0, 0
local function check(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL " .. msg)
    end
end

local function play_state(seed, jokers)
    local s = E.new_run({seed = seed, deck = "b_red", stake = 1})
    for _, j in ipairs(jokers or {}) do E.add_joker(s, j) end
    MC.advance(s)
    return s
end

local function choose(n, k)
    local r = 1
    for i = 1, k do r = r * (n - i + 1) / i end
    return r
end

do
    local ffi = require("ffi")
    local r = WT.rng(99)
    local vals = {0, -0.0, 1, -1, 1e-40, -3e-39, 3.4e38, 0.1, -123.456, 1e-7}
    for _ = 1, 500 do vals[#vals + 1] = (r() - 0.5) * 10 ^ math.floor(r() * 20 - 10) end
    local f = ffi.new("float[1]")
    local ok = true
    for _, v in ipairs(vals) do
        f[0] = v
        local ref = f[0]
        local b = WT.f32_bytes(v)
        local back = WT.f32_decode(b:byte(1, 4))
        if back ~= ref or ffi.string(f, 4) ~= b then ok = false print("f32", v, ref, back) break end
    end
    check(ok, "pure Lua float32 encode/decode matches ffi float")
end

local cfg = WT.default_cfg(FE, {E = 16, H = 48, VH = 16})
local W = WT.random(cfg, 11, 2)
local blob = WT.encode(W)
for _, mode in ipairs({true, false}) do
    BUF.set_ffi(mode)
    local W2 = WT.decode(blob)
    local ok = W2.cfg.H == 48 and W2.cfg.types == table.concat(FE.TYPES, ",")
    for _, name in ipairs(W.order) do
        local a, b = W.t[name], W2.t[name]
        for i = 0, a.n - 1 do
            if math.abs(a.data[i] - b.data[i]) > 1e-6 * math.max(1, math.abs(a.data[i])) then ok = false end
        end
    end
    check(ok, "weights roundtrip ffi=" .. tostring(mode))
    local tot = 0
    for _, name in ipairs(W2.order) do tot = tot + W2.t[name].n end
    check(tot == WT.count(cfg) and #blob > 4 * tot, "weight count")
end
BUF.set_ffi(true)

do
    local s = play_state("NNT1", {"j_joker", "j_blueprint", "j_greedy_joker"})
    local outs = {}
    for _, mode in ipairs({true, false}) do
        BUF.set_ffi(mode)
        local net = NET.new(WT.decode(blob))
        local F = FE.state(s, FE.new_state_buf())
        local AB = FE.new_action_buf(64)
        FE.actions(s, AB)
        local p, a = net:forward(F)
        net:policy(AB)
        local o = {p, a}
        for k = 0, AB.n - 1 do o[#o + 1] = AB.logit[k] end
        outs[#outs + 1] = o
    end
    BUF.set_ffi(true)
    local same = #outs[1] == #outs[2]
    for i = 1, #outs[1] do
        if math.abs(outs[1][i] - outs[2][i]) > 1e-12 then same = false end
    end
    check(same, "net ffi and plain agree")
    local nh = s.n_hand
    local want = 0
    for k = 1, math.min(5, nh) do want = want + choose(nh, k) end
    check(#outs[1] - 2 == 2 * want, "play+discard action count " .. (#outs[1] - 2) .. " vs " .. 2 * want)
end

do
    local s = play_state("NNT2")
    local F1 = FE.state(s, FE.new_state_buf())
    local t = ST.clone(s)
    for i = 1, t.n_deck do
        local j = (i * 17) % t.n_deck + 1
        t.deck[i], t.deck[j] = t.deck[j], t.deck[i]
    end
    for i = 1, #RNG.key_names do t.rng[i] = (i * 0.37) % 1 end
    t.hashed_seed = 0.123
    local F2 = FE.state(t, FE.new_state_buf())
    local same = true
    for i = 0, FE.GF - 1 do if F1.g[i] ~= F2.g[i] then same = false end end
    for i = 0, F1.nc * FE.CF - 1 do if F1.c[i] ~= F2.c[i] then same = false end end
    check(same, "features ignore hidden deck order and rng streams")
    local u = ST.clone(s)
    local h1, d1 = u.hand[1], u.deck[1]
    u.c_flip[h1] = 1
    local F3 = FE.state(u, FE.new_state_buf())
    u.hand[1], u.deck[1] = d1, h1
    u.c_flip[d1], u.c_flip[h1] = 1, 0
    local F4 = FE.state(u, FE.new_state_buf())
    same = true
    for i = 0, FE.GF - 1 do if F3.g[i] ~= F4.g[i] then same = false end end
    for i = 0, F3.nc * FE.CF - 1 do if F3.c[i] ~= F4.c[i] then same = false end end
    check(same, "features hide the identity of a face-down hand card")
end

do
    local s = play_state("NNT3", {"j_joker"})
    local before = ST.clone(s)
    local net = NET.new(WT.random(WT.default_cfg(FE), 5))
    local mc = MC.new(net, {K = 16, seed = 3})
    mc:search(s, 100, {noise = 0.25})
    local same = s.n_deck == before.n_deck and s.chips == before.chips and s.hands_left == before.hands_left
    for i = 1, s.n_deck do if s.deck[i] ~= before.deck[i] then same = false end end
    for i = 1, s.n_hand do if s.hand[i] ~= before.hand[i] then same = false end end
    for i = 1, #RNG.key_names do if (s.rng[i] or -1) ~= (before.rng[i] or -1) then same = false end end
    check(same, "search leaves the real state untouched")
    local ef, ec = mc:root_edges()
    local tot = 0
    for e = ef, ef + ec - 1 do tot = tot + mc.e_N[e] end
    check(tot == 100 and ec == 16, "root visits sum to n_sims (" .. tot .. ")")
    local ws = ST.clone(s)
    local cnt = {}
    for i = 1, ws.n_deck do cnt[ws.deck[i]] = true end
    mc:determinize(ws)
    local ok = true
    for i = 1, ws.n_deck do if not cnt[ws.deck[i]] then ok = false end end
    check(ok and ws.n_deck == s.n_deck, "determinize permutes only unseen cards")
    local e = mc:choose(0)
    local rec = REC.encode_record(mc.F_root, mc, e, 100)
    local data = REC.decode(REC.file_header() .. REC.encode_run({rec}, 0, 1, 3, 1, 7))
    local r = data.runs[1].recs[1]
    ok = r.nc == mc.F_root.nc and r.na == ec and r.chosen == e - ef and data.runs[1].index == 7
    for i = 0, FE.GF - 1 do
        if math.abs(r.g[i] - mc.F_root.g[i]) > 1e-6 then ok = false end
    end
    local vs = 0
    for _, a in ipairs(r.acts) do vs = vs + a.visits end
    check(ok and vs == 100, "record roundtrip")
end

do
    local s = play_state("NNT4")
    s.c_forced[s.hand[2]] = 1
    local AB = FE.new_action_buf(16)
    local n = FE.actions(s, AB)
    local ok = true
    for k = 0, n - 1 do
        local has = false
        for i = 0, AB.nc[k] - 1 do if AB.c[k * 5 + i] == 1 then has = true end end
        if not has then ok = false end
    end
    check(ok and n > 0, "forced card is in every action (and buffer growth keeps actions)")
end

do
    local J = E.J
    local A1, A2 = FE.new_action_buf(64), FE.new_action_buf(64)
    local seed = 1
    local function rnd(n)
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed % n
    end
    local jk = {J.four_fingers, J.shortcut, J.smeared, J.splash}
    local bad, tops = 0, {}
    for t = 1, 600 do
        local s = play_state("EQ" .. t)
        for b = 1, 4 do if rnd(3) == 0 then E.add_joker(s, jk[b]) end end
        local narrow = rnd(3)
        for i = 1, s.n_hand do
            local cid = s.hand[i]
            if narrow == 0 then s.c_rank[cid] = 2 + rnd(4) * (rnd(2) + 1) elseif narrow == 1 then s.c_rank[cid] = 10 + rnd(5) end
            if rnd(3) == 0 then s.c_suit[cid] = 1 + rnd(4) end
            if rnd(4) == 0 then s.c_enh[cid] = rnd(9) end
            if rnd(8) == 0 then s.c_debuff[cid] = 1 end
            if rnd(10) == 0 then s.c_flip[cid] = 1 end
            if rnd(6) == 0 then s.c_bonus[cid] = rnd(4) * 5 end
        end
        if rnd(10) == 0 then s.c_forced[s.hand[1 + rnd(s.n_hand)]] = 1 end
        if rnd(10) == 0 then s.discards_left = 0 end
        if rnd(15) == 0 then s.hands_left = 0 end
        if rnd(4) == 0 then s.chips = rnd(400) end
        local n1, n2 = FE.actions_ref(s, A1), FE.actions(s, A2)
        local ok = n1 == n2
        for k = 0, n1 - 1 do
            if not ok then break end
            if A1.type[k] ~= A2.type[k] or A1.nc[k] ~= A2.nc[k] then ok = false end
            for i = 0, 4 do if A1.c[k * 5 + i] ~= A2.c[k * 5 + i] then ok = false end end
            for f = 0, FE.FA - 1 do if A1.fa[k * FE.FA + f] ~= A2.fa[k * FE.FA + f] then ok = false end end
            tops[A2.top[k]] = true
        end
        if not ok then bad = bad + 1 end
    end
    local all = true
    for h = 1, 12 do if h ~= 1 and h ~= 3 and not tops[h] then all = false end end
    check(bad == 0 and all, "fast action listing matches the reference evaluator exactly (" .. bad .. " bad)")
end

do
    local net2 = NET.new(WT.random(WT.default_cfg(FE, {E = 16, H = 48, VH = 16}), 5))
    local mc = MC.new(net2, {K = 8, seed = 3})
    local s = play_state("NNT5", {E.J.splash})
    s.n_deck = 0
    s.hands_left, s.discards_left = 3, 2
    mc:search(s, 300, {})
    local function ser(id, out)
        out[#out + 1] = string.format("n%d,%.17g,%d,%d,%d[", mc.n_N[id], mc.n_val[id], mc.n_key[id], mc.n_term[id], mc.n_exp[id])
        local ef, ec = mc.n_ef[id], mc.n_ec[id]
        for e = ef, ef + ec - 1 do
            out[#out + 1] = string.format("e%d,%d,%d,%d,%.17g,%d,%.17g(", mc.e_type[e], mc.e_nc[e], mc.e_c[e * 5], mc.e_c[e * 5 + 1], mc.e_prior[e], mc.e_N[e], mc.e_W[e])
            local c = mc.e_child[e]
            while c ~= 0 do
                ser(c, out)
                c = mc.n_next[c]
            end
            out[#out + 1] = ")"
        end
        out[#out + 1] = "]"
        return out
    end
    local best, bn = 0, -1
    for id = 2, mc.nn do
        if mc.n_N[id] > bn then best, bn = id, mc.n_N[id] end
    end
    local before = table.concat(ser(best, {}))
    local nodes_before = mc.nn
    mc.n_next[best] = 0
    local rid = mc:keep_subtree(best)
    local after = table.concat(ser(rid, {}))
    check(rid == 1 and before == after and mc.nn < nodes_before and mc.nn > 0, "subtree reuse keeps the subtree exactly and compacts the pools")
end

do
    local net2 = NET.new(WT.random(WT.default_cfg(FE, {E = 16, H = 48, VH = 16}), 6))
    local s = play_state("NNT6", {E.J.joker})
    local function visits(st)
        local mc = MC.new(net2, {K = 8, seed = 42})
        mc:search(st, 200, {})
        local ef, ec = mc:root_edges()
        local out = {}
        for e = ef, ef + ec - 1 do out[#out + 1] = mc.e_N[e] .. "/" .. string.format("%.17g", mc.e_W[e]) end
        return table.concat(out, " ")
    end
    visits(s)
    local a = visits(s)
    local t = ST.clone(s)
    t.seed = "OTHERSEED"
    t.hcache = RNG.seed_cache("OTHERSEED")
    t.hashed_seed = 0.123
    for i = 1, #RNG.key_names do t.rng[i] = (i * 0.37) % 1 end
    check(a == visits(t), "search does not depend on the real seed, its hash cache or RNG streams")
end

do
    local net2 = NET.new(WT.random(WT.default_cfg(FE), 8, 3))
    local F0, F1 = FE.new_state_buf(), FE.new_state_buf()
    local root = play_state("NNT7", {E.J.joker, E.J.greedy_joker})
    FE.state(root, F0)
    net2:forward(F0)
    net2:set_base(F0)
    local worst = 0
    for t = 1, 30 do
        local s = play_state("NNT7_" .. t, {E.J.joker})
        s.chips = t * 7
        FE.state(s, F1)
        local p1, a1, z1 = net2:forward(F1)
        local p2, a2, z2 = net2:forward_delta(F1)
        worst = math.max(worst, math.abs(z1 - z2), math.abs(a1 - a2), math.abs(p1 - p2))
    end
    check(worst < 1e-9, "delta forward against the root matches the full forward (" .. worst .. ")")
end

local SNAP = require("bot.sim.snapshot")
local D = require("bot.sim.data")
local POL = require("botsim.policy")

local function lcg(seed)
    local x = seed
    return function(n)
        x = (x * 1103515245 + 12345) % 2147483648
        return x % n
    end
end

local function drive(seed, steps, on_state)
    POL.shop = true
    local rnd = lcg(seed)
    local s = E.new_run({seed = "DRV" .. seed, deck = FE.DECK_KEYS[seed % #FE.DECK_KEYS + 1] == "b_challenge" and "b_red" or FE.DECK_KEYS[seed % #FE.DECK_KEYS + 1], stake = 1 + seed % 8})
    if seed % 3 == 0 then s.used_v[D.VOUCHER_ID.v_directors_cut] = 1 end
    local F, AB = FE.new_state_buf(), FE.new_action_buf(64)
    local st = {}
    for _ = 1, steps do
        MC.advance_forced(s)
        if MC.terminal(s) then break end
        if s.phase == "shop" and s.money < 40 and rnd(2) == 0 then s.money = s.money + 15 end
        if s.phase == "shop" and s.n_cons < s.cons_limit and rnd(3) == 0 then
            local pool = {"c_strength", "c_death", "c_hermit", "c_jupiter", "c_aura", "c_sigil", "c_ankh", "c_wheel_of_fortune", "c_star", "c_fool"}
            E.I.add_cons(s, D.CONS_ID[pool[rnd(#pool) + 1]])
        end
        FE.state(s, F)
        local n = FE.list_actions(s, AB, F)
        if on_state(s, F, AB, n) == false then break end
        local a
        if n > 0 and (s.phase ~= "play" or rnd(4) == 0) and rnd(3) > 0 then
            a = FE.to_step(AB, rnd(n), st, s)
        else
            a = POL.choose(s)
        end
        if not a or not E.step(s, a) then
            if n == 0 then break end
            E.step(s, FE.to_step(AB, rnd(n), st, s))
        end
    end
    return s
end

do
    local bad, seen, states, msg = 0, {}, 0, ""
    local st = {}
    for seed = 1, 60 do
        drive(seed, 400, function(s, F, AB, n)
            states = states + 1
            for k = 0, n - 1 do
                local t = AB.type[k]
                if t > 2 or (k % 37 == 0) then
                    local c = ST.clone(s)
                    if not E.step(c, FE.to_step(AB, k, st, c)) then
                        bad = bad + 1
                        if msg == "" then msg = FE.TYPES[t] .. " in " .. s.phase end
                    end
                    seen[t] = (seen[t] or 0) + 1
                end
            end
        end)
    end
    local missing = {}
    for t = 3, #FE.TYPES do if not seen[t] then missing[#missing + 1] = FE.TYPES[t] end end
    check(bad == 0 and #missing == 0, string.format("every listed action of every type is legal in the sim (%d states, %d illegal %s, missing %s)",
        states, bad, msg, table.concat(missing, ",")))
end

local function econ_states(want)
    local out = {}
    for seed = 100, 140 do
        drive(seed, 300, function(s, F, AB, n)
            local ph = s.phase
            if want[ph] and n > 1 and not out[ph] then
                local ok = ph ~= "shop" or (s.n_jok >= 2 and s.n_cons > 0)
                if ph == "pack" then ok = s.n_pk > 1 end
                if ok then out[ph] = ST.clone(s) end
            end
        end)
    end
    return out
end

local ES = econ_states({shop = true, pack = true, blind_select = true})
check(ES.shop and ES.pack and ES.blind_select, "found shop, pack and blind select states for the tests")

do
    local net2 = NET.new(WT.random(WT.default_cfg(FE, {E = 16, H = 48, VH = 16}), 21, 2))
    for _, ph in ipairs({"shop", "pack", "blind_select"}) do
        local s = ES[ph]
        if s then
            local before = SNAP.line(s)
            local mc = MC.new(net2, {K = 12, seed = 4})
            mc:search(s, 120, {noise = 0.25})
            check(SNAP.line(s) == before, "search on a " .. ph .. " state leaves the real state untouched")
            local ef, ec = mc:root_edges()
            local tot = 0
            for e = ef, ef + ec - 1 do tot = tot + mc.e_N[e] end
            check(tot == 120 and ec >= 2, ph .. " root visits sum to n_sims (" .. tot .. ")")
            local e = mc:choose(0)
            local rec = REC.encode_record(mc.F_root, mc, e, 120, FE.PHASES[ph])
            local data = REC.decode(REC.file_header() .. REC.encode_run({rec}, 0, 2, 1, 1, 3))
            local r = data.runs[1].recs[1]
            local ok = r.ni == mc.F_root.ni and r.na == ec and r.chosen == e - ef and r.phase == FE.PHASES[ph]
            for k = 0, mc.F_root.ni * FE.IF - 1 do
                if math.abs((r.i[k] or 0) - mc.F_root.i[k]) > 1e-6 then ok = false end
            end
            local ents = 0
            for j, a in ipairs(r.acts) do
                local ed = ef + j - 1
                if a.type ~= mc.e_type[ed] then ok = false end
                if a.ent >= 0 then ents = ents + 1 end
            end
            check(ok and (ph == "blind_select" or ents > 0), ph .. " record roundtrip with items and entities")
            local st = mc:edge_action(e, nil, s)
            check(E.step(ST.clone(s), st), ph .. " chosen edge is a legal sim action")
        end
    end
end

do
    local s = ES.shop
    if s then
        local F1 = FE.state(s, FE.new_state_buf())
        local t = ST.clone(s)
        for i = 1, t.n_deck do
            local j = (i * 13) % t.n_deck + 1
            t.deck[i], t.deck[j] = t.deck[j], t.deck[i]
        end
        for i = 1, #RNG.key_names do t.rng[i] = (i * 0.71) % 1 end
        t.hashed_seed = 0.77
        t.seed = "SOMETHINGELSE"
        t.hcache = RNG.seed_cache("SOMETHINGELSE")
        local F2 = FE.state(t, FE.new_state_buf())
        local same = F1.ni == F2.ni and F1.ni > 0
        for i = 0, FE.GF - 1 do if F1.g[i] ~= F2.g[i] then same = false end end
        for i = 0, F1.ni * FE.IF - 1 do if F1.i[i] ~= F2.i[i] then same = false end end
        check(same, "shop features ignore deck order, rng streams and the seed")
        local mc = MC.new(NET.new(WT.random(WT.default_cfg(FE), 3)), {seed = 9})
        local w = ST.clone(s)
        mc:determinize(w)
        local keep = true
        for _, f in ipairs({"n_sj", "n_sv", "n_sb", "n_jok", "n_cons", "n_tags", "money", "voucher", "boss_choice", "tag_small", "tag_big"}) do
            if w[f] ~= s[f] then keep = false end
        end
        for i = 1, s.n_sj do if w.sj_id[i] ~= s.sj_id[i] or w.sj_kind[i] ~= s.sj_kind[i] then keep = false end end
        for i = 1, s.n_jok do if w.j_id[i] ~= s.j_id[i] then keep = false end end
        check(keep, "determinization keeps everything visible in the shop")
    end
    local net2 = NET.new(WT.random(WT.default_cfg(FE, {E = 16, H = 48, VH = 16}), 6))
    for _, ph in ipairs({"shop", "pack", "blind_select"}) do
        local st = ES[ph]
        if st then
            local function visits(x)
                local mc = MC.new(net2, {K = 8, seed = 42})
                mc:search(x, 150, {})
                local ef, ec = mc:root_edges()
                local out = {}
                for e = ef, ef + ec - 1 do out[#out + 1] = mc.e_N[e] .. "/" .. string.format("%.17g", mc.e_W[e]) end
                return table.concat(out, " ")
            end
            local a, prev = visits(st), nil
            for _ = 1, 5 do
                if a == prev then break end
                prev, a = a, visits(st)
            end
            local t = ST.clone(st)
            t.seed = "OTHERSEED2"
            t.hcache = RNG.seed_cache("OTHERSEED2")
            t.hashed_seed = 0.321
            for i = 1, #RNG.key_names do t.rng[i] = (i * 0.53) % 1 end
            check(a == visits(t), ph .. " search does not depend on the real seed, its hash cache or RNG streams")
        end
    end
end

do
    local s = E.new_run({seed = "VHID", deck = "b_red", stake = 1})
    local F1 = FE.state(s, FE.new_state_buf())
    local t = ST.clone(s)
    t.voucher = t.voucher % #D.VOUCHERS + 1
    local F2 = FE.state(t, FE.new_state_buf())
    local same = true
    for i = 0, FE.GF - 1 do if F1.g[i] ~= F2.g[i] then same = false end end
    check(same and FE.voucher_hidden(s), "the ante's voucher is hidden before the first shop")
    local mc = MC.new(NET.new(WT.random(WT.default_cfg(FE), 3)), {seed = 5})
    local diff = 0
    for _ = 1, 20 do
        local w = ST.clone(s)
        mc:determinize(w)
        if w.voucher ~= s.voucher then diff = diff + 1 end
    end
    check(diff > 0, "determinization resamples a hidden voucher (" .. diff .. "/20)")
end

do
    local s = ES.shop or play_state("NNT9")
    local F = FE.state(s, FE.new_state_buf())
    local AB = FE.new_action_buf(64)
    local n = FE.list_actions(s, AB, F)
    local picks = {}
    for k = 0, math.min(n, 10) - 1 do picks[#picks + 1] = {k = k, visits = k == 0 and 1 or 0, prior = 0.1} end
    local rec = REC.encode_choice(F, AB, picks, {chosen = 1, phase = FE.PHASES[s.phase]})
    local data = REC.decode(REC.file_header() .. REC.encode_run({rec}, 1, 9, 2, 1, 1))
    local r = data.runs[1].recs[1]
    local ok = r.na == #picks and r.chosen == 0 and data.types == table.concat(FE.TYPES, ",")
    for j, p in ipairs(picks) do
        local a = r.acts[j]
        if a.type ~= AB.type[p.k] or a.ent ~= (AB.type[p.k] > 2 and AB.ent[p.k] or -1) then ok = false end
    end
    local found = FE.find_action(AB, FE.to_step(AB, n - 1, {}, s), s)
    check(ok and found == n - 1, "teacher record writer (encode_choice) roundtrip and find_action")
end

do
    local s = play_state("MOVES", {"j_joker", "j_blueprint", "j_cavendish", "j_brainstorm", "j_greedy_joker"})
    local F, AB = FE.new_state_buf(), FE.new_action_buf(64)
    FE.state(s, F)
    local n = FE.list_actions(s, AB, F)
    local T = FE.TYPE_ID
    local got, legal, st = {}, true, {}
    for k = 0, n - 1 do
        if AB.type[k] == T.move_joker then
            local step = FE.to_step(AB, k, st, s)
            local c = ST.clone(s)
            if not E.step(c, step) then legal = false end
            local ids = {}
            for i = 1, c.n_jok do ids[i] = c.j_id[i] end
            got[#got + 1] = table.concat(ids, ",")
        end
    end
    local function order(keys)
        local ids = {}
        for i, key in ipairs(keys) do
            for j, d in ipairs(D.JOKERS) do if d.key == key then ids[i] = j end end
        end
        return table.concat(ids, ",")
    end
    local want = {
        order({"j_joker", "j_blueprint", "j_brainstorm", "j_greedy_joker", "j_cavendish"}),
        order({"j_blueprint", "j_joker", "j_cavendish", "j_brainstorm", "j_greedy_joker"}),
        order({"j_joker", "j_cavendish", "j_brainstorm", "j_blueprint", "j_greedy_joker"}),
        order({"j_cavendish", "j_joker", "j_blueprint", "j_brainstorm", "j_greedy_joker"}),
        order({"j_greedy_joker", "j_joker", "j_blueprint", "j_cavendish", "j_brainstorm"}),
    }
    local have = {}
    for _, g in ipairs(got) do have[g] = true end
    local all = true
    for _, w in ipairs(want) do if not have[w] then all = false end end
    check(legal and all and #got <= 3 * s.n_jok, "mid-blind joker moves: x-mult to the right, Blueprint next to each joker, any joker under Brainstorm, all legal (" .. #got .. " moves)")
    local s2 = play_state("MOVES", {"j_joker", "j_greedy_joker"})
    FE.state(s2, F)
    local n2, moves = FE.list_actions(s2, AB, F), 0
    for k = 0, n2 - 1 do if AB.type[k] == T.move_joker then moves = moves + 1 end end
    check(moves == 0, "no mid-blind joker moves when order cannot matter")
end

do
    local ES = require("botsim.train.evalset")
    local GL = require("botsim.train.gamelog")
    local json = require("bot.sim.json")
    local cells = ES.cells(3)
    check(#cells == 8 and ES.name(3) == "fixed-24" and ES.seed("b_red", 1, 2) == "EV_b_red_1_2", "eval set: 8 deck x stake cells, fixed seeds and name")
    local dk, sk = ES.parse("all", "1,2")
    local wide = ES.cells(4, dk, sk)
    local known = true
    for _, d in ipairs(dk) do known = known and D.DECKS[d] ~= nil end
    check(#wide == 30 and ES.name(4, dk, sk) == "d15-s12-120" and known and select(2, ES.parse("", "3"))[1] == 3,
        "wide eval set: all 15 decks x trained stakes, name says decks, stakes and games")
    local s = E.new_run({seed = "GL1", deck = "b_blue", stake = 2})
    local g = json.decode(json.encode(GL.game(s, {won = 0, ante = 1, deck = "b_blue", stake = 2, seed = "GL1", mpa = {}, dec = 3, sims = 8, dur = 0.5, last_blind = 1})))
    check(g.type == "game" and g.deck == "b_blue" and g.stake == 2 and g.won == 0 and #g.mpa == 0 and #g.jokers == 0 and g.death == "bl_small" and g.dec == 3,
        "game log line encodes the contract fields, empty lists stay arrays")
    check(GL.path("a/g_{seed}.jsonl", 12) == "a/g_12.jsonl", "game log path takes the worker seed")
end

do
    local P = require("botsim.train.plan")
    local s = E.new_run({seed = "PLANTEST", deck = "b_red", stake = 8})
    local c0 = ST.clone(s)
    local v0 = P.eval(s)
    check(v0 > 0, "plan power is positive on a new run")
    check(s.n_hand == c0.n_hand and s.blind == c0.blind and s.money == c0.money, "plan eval leaves the state alone")
    s.h_chips[D.H_FLUSH] = s.h_chips[D.H_FLUSH] + 60
    s.h_mult[D.H_FLUSH] = s.h_mult[D.H_FLUSH] + 8
    local v1, plan = P.eval(s)
    check(v1 > v0, "levelling a hand raises plan power")
    check(plan == D.H_FLUSH, "the levelled hand becomes the plan")
    local before = P.score(s)
    for c = 1, s.n_cards do
        if s.c_suit[c] ~= s.c_suit[1] then s.c_alive[c] = 0 end
    end
    check(P.eval(s) > v1, "a deck of one suit makes the flush plan stronger")
    check(P.score(s) >= before, "plan score follows power")
    check(math.abs(P.tail(52, 4, 12, 3) - 0.0343) < 0.001, "chance of three of a rank in 12 cards")
end

do
    local P = require("botsim.train.plan")
    local s = E.new_run({seed = "PLANETTEST", deck = "b_red", stake = 8})
    s.phase = "shop"
    s.cons[1], s.cons[2] = "c_pluto", "c_fool"
    s.n_cons = 2
    local lv = s.h_level[D.H_HIGH]
    P.use_planets(s, E.step)
    check(s.h_level[D.H_HIGH] == lv + 1, "a held planet is used")
    check(s.n_cons == 1 and s.cons[1] == "c_fool", "other consumables stay")
end

do
    local P = require("botsim.train.plan")
    local s = E.new_run({seed = "ORDERTEST", deck = "b_red", stake = 8})
    s.n_jok = 0
    E.add_joker(s, "j_cavendish")
    E.add_joker(s, "j_joker")
    local o, best, start = P.best_order(s)
    check(o and o[1] == 2 and o[2] == 1, "plus mult goes before times mult")
    check(best > start, "better order scores more")
    check(P.best_order(s) ~= nil and s.n_jok == 2, "best_order leaves the state alone")
    E.reorder(s, o)
    check(P.best_order(s) == nil, "nothing to gain once ordered")
    check(not P.any_flipped(s), "no joker face down")
    s.j_flip[2] = 1
    check(P.any_flipped(s), "a face down joker stops reordering")
end

do
    local P = require("botsim.train.plan")
    local sets = {
        {"j_cavendish", "j_joker"},
        {"j_blueprint", "j_cavendish", "j_joker", "j_duo"},
        {"j_brainstorm", "j_joker", "j_cavendish", "j_baron", "j_trio"},
        {"j_cavendish", "j_photograph", "j_blueprint", "j_joker", "j_hologram"},
        {"j_joker", "j_duo", "j_brainstorm", "j_blueprint", "j_cavendish"},
        {"j_baron", "j_joker"},
    }
    local same, moved = 0, 0
    for i, set in ipairs(sets) do
        for _, deck in ipairs({"b_red", "b_checkered", "b_abandoned"}) do
            local s = E.new_run({seed = "FASTORDER" .. i, deck = deck, stake = 8})
            s.n_jok = 0
            for _, key in ipairs(set) do E.add_joker(s, key) end
            local before = {}
            for k = 1, s.n_jok do before[k] = s.j_uid[k] end
            local o1, b1, s1 = P.best_order_ref(s)
            local o2, b2, s2 = P.best_order(s)
            local ok = (o1 == nil) == (o2 == nil) and b1 == b2 and s1 == s2
            if ok and o1 then
                for k = 1, #o1 do ok = ok and o1[k] == o2[k] end
                moved = moved + 1
            end
            for k = 1, s.n_jok do ok = ok and s.j_uid[k] == before[k] end
            if ok then same = same + 1 end
        end
    end
    check(same == #sets * 3, "fast best_order matches the reference (" .. same .. " of " .. #sets * 3 .. ")")
    check(moved > 0, "the joker sets include ones that get reordered")
end


do
    local T = require("botsim.train.teach")
    local function give(s, key)
        s.n_cons = s.n_cons + 1
        s.cons[s.n_cons], s.cons_ed[s.n_cons], s.cons_ev[s.n_cons] = key, 0, 0
        s.next_uid = s.next_uid + 1
        s.cons_uid[s.n_cons] = s.next_uid
    end
    local s = play_state("TEACH1")
    local t = T.new({})
    give(s, "c_hanged_man")
    local n0 = T.alive_count(s)
    local a, why = t:move(s)
    check(a and a.type == "use" and why == "use_hanged" and #a.targets == 2 and a.targets[1] ~= a.targets[2], "teach: hanged man on two cards")
    check(a and E.step(s, a) and T.alive_count(s) == n0 - 2 and s.n_cons == 0, "teach: hanged man removes two cards")
    local s2 = play_state("TEACH2")
    give(s2, "c_pluto")
    local a2, why2 = T.new({}):move(s2)
    check(a2 and a2.type == "use" and why2 == "use_planet", "teach: uses a held planet")
    local s3 = play_state("TEACH3")
    s3.h_level[D.H_FLUSH] = 30
    local t3 = T.new({})
    t3:update_plan(s3)
    check(t3.plan == D.H_FLUSH, "teach: flush plan when flush is levelled")
    local _, by_suit = T.alive_count(s3)
    local best = 1
    for k = 2, 4 do if by_suit[k] > by_suit[best] then best = k end end
    local key = ({"c_world", "c_sun", "c_moon", "c_star"})[best]
    give(s3, key)
    local a3 = t3:move(s3)
    local off = true
    for _, i in ipairs(a3 and a3.targets or {}) do if s3.c_suit[s3.hand[i]] == best then off = false end end
    check(a3 and a3.type == "use" and off, "teach: suit tarot only on off-suit cards")
    local s4 = play_state("TEACH4")
    give(s4, "c_hanged_man")
    local t4 = T.new({t_deck = 60})
    check(t4:move(s4) == nil, "teach: no thinning under the deck floor")
    local s5 = play_state("TEACH5")
    s5.h_level[D.H_PAIR] = 30
    local t5 = T.new({t_all = 1})
    give(s5, "c_death")
    local a5, why5 = t5:move(s5)
    check(a5 and why5 == "use_death" and #a5.targets == 2 and a5.targets[1] < a5.targets[2], "teach: death copies a plan card onto an off-plan card")
    local src = a5 and s5.hand[a5.targets[2]]
    local dst = a5 and s5.hand[a5.targets[1]]
    check(a5 and E.step(s5, a5) and s5.c_rank[dst] == s5.c_rank[src] and s5.c_suit[dst] == s5.c_suit[src], "teach: death result")
    local s6 = play_state("TEACH6")
    give(s6, "c_empress")
    local a6, why6 = T.new({t_all = 1}):move(s6)
    check(a6 and why6 == "use_enh" and #a6.targets >= 1 and E.step(s6, a6), "teach: empress on plan cards")
    local s7 = play_state("TEACH7")
    s7.money = 12
    give(s7, "c_hermit")
    local a7, why7 = T.new({t_all = 1}):move(s7)
    check(a7 and why7 == "use_free" and E.step(s7, a7) and s7.money == 24, "teach: hermit doubles money")
    local s7b = play_state("TEACH7B")
    give(s7b, "c_empress")
    local tu = T.new({t_all = 1})
    tu:update_plan(s7b)
    local u7 = tu:use_now(s7b)
    check(u7 and u7.type == "use" and E.step(s7b, u7) and s7b.n_cons == 0, "teach: use_now uses a held empress (ro_tarot)")
    local s7c = play_state("TEACH7C")
    give(s7c, "c_pluto")
    tu:update_plan(s7c)
    check(tu:use_now(s7c) == nil, "teach: use_now leaves planets alone")
    local s8 = play_state("TEACH8")
    give(s8, "c_empress")
    check(T.new({}):move(s8) == nil, "teach: t1 holds an empress")
    local PLY = require("bot.seer.play")
    local s9 = play_state("TEACH9")
    s9.blind_chips = 1
    for _ = 1, 20 do
        if s9.phase == "shop" then break end
        if s9.phase == "play" then E.step(s9, PLY.fast_action(s9)) else MC.advance_forced(s9) end
    end
    local cel
    for k = 1, #D.BOOST do if D.BOOST[k].kind_id == 2 and not cel then cel = k end end
    check(s9.phase == "shop" and s9.n_sb >= 1 and cel, "teach: test shop reached")
    if s9.phase == "shop" and cel then
        s9.sb_id[1] = cel
        s9.money = 50
        local a9 = T.new({}):move(s9)
        check(a9 and a9.type == "open" and a9.card == 1, "teach: t1 opens a celestial pack above the reserve")
        local tl = T.new({t_late = 1})
        check(tl:move(s9) == nil, "teach: t_late leaves the shop to the search first")
        local a10, why10 = tl:leave_move(s9)
        check(a10 and a10.type == "open" and why10 == "open_celestial", "teach: t_late opens the pack when the search leaves")
        s9.money = 12
        local a11 = T.new({}):move(s9)
        check(not (a11 and a11.type == "open"), "teach: fixed reserve keeps 25")
        local a12 = T.new({t_res = -1}):move(s9)
        check(a12 and a12.type == "open", "teach: dynamic reserve spends at ante 1")
    end
    local sk = E.new_run({seed = "TSKIP", deck = "b_black", stake = 8})
    check(sk.phase == "blind_select" and not T.skip_safe(sk, 2.5), "teach: no skip into the big blind with no jokers at Gold")
    check(not T.skip_safe(sk, -1), "teach: t_skip=-1 blocks a skip with no joker")
    for _, j in ipairs({"j_joker", "j_cavendish", "j_gros_michel"}) do E.add_joker(sk, j) end
    check(T.skip_safe(sk, 2.5), "teach: skip allowed with a strong build")
    check(T.skip_safe(sk, -1), "teach: t_skip=-1 allows a skip with a joker")
end
print(string.format("nn tests: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
