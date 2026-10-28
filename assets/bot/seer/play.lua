local E = require("bot.sim.engine")
local ST = require("bot.sim.state")
local EV = require("bot.sim.eval")

local PL = {}
PL.FAST_TOP = 0
PL.REUSE_SCAN = true

local min, max, log = math.min, math.max, math.log

local combo_cache = {}

local function combos(n)
    local c = combo_cache[n]
    if c then return c end
    c = {}
    local cur = {}
    local function rec(start, depth)
        if depth > 0 then
            local t = {}
            for i = 1, depth do t[i] = cur[i] end
            c[#c + 1] = t
        end
        if depth == 5 then return end
        for i = start, n do
            cur[depth + 1] = i
            rec(i + 1, depth + 1)
        end
    end
    rec(1, 0)
    combo_cache[n] = c
    return c
end
PL.combos = combos

local scratch = ST.scratch()

local function forced_pos(s)
    for i = 1, s.n_hand do
        if s.c_forced[s.hand[i]] == 1 then return i end
    end
    return 0
end
PL.forced_pos = forced_pos

local function has(t, v)
    for i = 1, #t do if t[i] == v then return true end end
    return false
end

local BID = require("bot.sim.data").BLIND_ID
local SMALL_OK = {[BID.bl_eye] = true, [BID.bl_mouth] = true, [BID.bl_psychic] = true}

local function wants_small(s)
    if s.n_hand < 5 or SMALL_OK[s.blind] then return true end
    return E.find_joker(s, E.J.half) or E.find_joker(s, E.J.square) or false
end

local cbuf, nom_v, nom_c, nom_i = {}, {}, {}, {}
local J = E.J

local function nominal(s, cs, four, shortcut, smeared, splash)
    local n = #cs
    for i = 1, n do cbuf[i] = s.hand[cs[i]] end
    local text = EV.evaluate(s, cbuf, n, four, shortcut, smeared, splash)
    local chips = s.h_chips[text]
    local sc = EV.scoring
    for i = 1, n do
        if sc[i] then chips = chips + E.card_chips(s, cbuf[i]) end
    end
    return chips * s.h_mult[text]
end

local function nom_greater(a, b)
    if nom_v[a] ~= nom_v[b] then return nom_v[a] > nom_v[b] end
    return a < b
end

function PL.scan(s, out_v, out_c, fast, top)
    local list = combos(s.n_hand)
    local fp = forced_pos(s)
    local five = fast and not wants_small(s)
    local n = 0
    for i = 1, #list do
        local cs = list[i]
        if (fp == 0 or has(cs, fp)) and (not five or #cs == 5) then
            n = n + 1
            out_c[n] = cs
        end
    end
    top = top or PL.FAST_TOP
    if five and top > 0 and n > top then
        local fj = E.find_joker
        local four, shortcut = fj(s, J.four_fingers), fj(s, J.shortcut)
        local smeared, splash = fj(s, J.smeared), fj(s, J.splash)
        for i = 1, n do
            nom_c[i] = out_c[i]
            nom_v[i] = nominal(s, out_c[i], four, shortcut, smeared, splash)
            nom_i[i] = i
        end
        for i = n + 1, #nom_i do nom_i[i] = nil end
        table.sort(nom_i, nom_greater)
        for i = 1, top do out_c[i] = nom_c[nom_i[i]] end
        n = top
    end
    for i = 1, n do out_v[i] = E.preview_into(scratch, s, out_c[i], i > 1) end
    for i = n + 1, #out_v do out_v[i], out_c[i] = nil, nil end
    return n
end

local sv, sc = {}, {}
local scan_v, scan_c = sv, sc

function PL.best_play(s, fast)
    local n = PL.scan(s, sv, sc, fast)
    local bv, bi = -1, 0
    for i = 1, n do
        local v = sv[i]
        if v > bv or (v == bv and #sc[i] > #sc[bi]) then bv, bi = v, i end
    end
    return sc[bi], bv
end

local function discard_rest(s, keep)
    local d = {}
    for i = s.n_hand, 1, -1 do
        if not has(keep, i) and #d < 5 and s.c_forced[s.hand[i]] ~= 1 then d[#d + 1] = i end
    end
    table.sort(d)
    return d
end
PL.discard_rest = discard_rest

function PL.fast_action(s, fast)
    local cards, v = PL.best_play(s, fast)
    local need = s.blind_chips - s.chips
    if v < need and s.discards_left > 0 and s.hands_left > 1 and v * s.hands_left < need then
        local d = discard_rest(s, cards or {})
        if #d > 0 then return {type = "discard", cards = d} end
    end
    if not cards then
        local d = {}
        for i = 1, min(5, s.n_hand) do d[i] = i end
        local fp = forced_pos(s)
        if fp > 5 then d[5] = fp end
        return {type = "play", cards = d}
    end
    local c = {}
    for i = 1, #cards do c[i] = cards[i] end
    return {type = "play", cards = c}
end

local function cleared(s)
    return s.won == 1 or s.phase == "round_eval" or s.phase == "win"
end
PL.cleared = cleared

local function copy_acts(a)
    local t = {}
    for i = 1, #a do t[i] = a[i] end
    return t
end

local function key_of(cs)
    local k = 0
    for i = 1, #cs do k = k * 32 + cs[i] end
    return k
end

local function node_best(k, top)
    if top > 0 then
        local n = PL.scan(k.s, sv, sc, true, top)
        local bv = -1
        for i = 1, n do if sv[i] > bv then bv = sv[i] end end
        return bv, n
    end
    local n = PL.scan(k.s, sv, sc)
    local bv = -1
    local kv, kc = {}, {}
    for i = 1, n do
        local v = sv[i]
        kv[i], kc[i] = v, sc[i]
        if v > bv then bv = v end
    end
    k.sv, k.sc, k.n = kv, kc, n
    return bv, n
end

local function better(a, b)
    if not b then return true end
    if a.hands ~= b.hands then return a.hands < b.hands end
    if a.discs ~= b.discs then return a.discs < b.discs end
    return a.margin > b.margin
end

function PL.solve(s0, opts)
    opts = opts or {}
    local B = opts.beam or 6
    local NP = opts.plays or 3
    local ND = opts.discards or 6
    local KT = PL.KID_TOP or opts.kid_top or 0
    local start_h, start_d = s0.hands_left, s0.discards_left
    local best
    local beam = {{s = ST.clone(s0), acts = {}, h = 0}}
    local fallback, fb_chips = nil, -1
    local evals = 0
    for _ = 1, start_h + start_d + 1 do
        local kids = {}
        local seen = {}
        for bi = 1, #beam do
            local node = beam[bi]
            local s = node.s
            local n, sv, sc = node.n, node.sv, node.sc
            if not n or not PL.REUSE_SCAN then
                sv, sc = scan_v, scan_c
                n = PL.scan(s, sv, sc)
                evals = evals + n
            end
            local need = s.blind_chips - s.chips
            local order = {}
            for i = 1, n do order[i] = i end
            table.sort(order, function(a, b)
                if sv[a] ~= sv[b] then return sv[a] > sv[b] end
                if #sc[a] ~= #sc[b] then return #sc[a] > #sc[b] end
                return key_of(sc[a]) < key_of(sc[b])
            end)
            local vals, cards = {}, {}
            for i = 1, n do vals[i], cards[i] = sv[order[i]], sc[order[i]] end
            local used_h = start_h - s.hands_left + 1
            local used_d = start_d - s.discards_left
            if s.hands_left > 0 and (not best or used_h <= best.hands) then
                local tried = 0
                for i = 1, n do
                    if vals[i] < need then break end
                    if tried >= 3 then break end
                    tried = tried + 1
                    local c = ST.clone(s)
                    local a = {type = "play", cards = copy_acts(cards[i])}
                    if E.step(c, a) and cleared(c) then
                        local acts = copy_acts(node.acts)
                        acts[#acts + 1] = a
                        local cand = {acts = acts, hands = used_h, discs = used_d, margin = c.chips / max(1, c.blind_chips)}
                        if better(cand, best) then best = cand end
                        break
                    end
                end
                local np = 0
                for i = 1, n do
                    if np >= NP then break end
                    if vals[i] < need then
                        local c = ST.clone(s)
                        local a = {type = "play", cards = copy_acts(cards[i])}
                        if E.step(c, a) then
                            np = np + 1
                            if c.phase == "play" then
                                local acts = copy_acts(node.acts)
                                acts[#acts + 1] = a
                                kids[#kids + 1] = {s = c, acts = acts}
                            elseif cleared(c) then
                                local acts = copy_acts(node.acts)
                                acts[#acts + 1] = a
                                local cand = {acts = acts, hands = used_h, discs = used_d, margin = c.chips / max(1, c.blind_chips)}
                                if better(cand, best) then best = cand end
                            elseif c.chips > fb_chips then
                                local acts = copy_acts(node.acts)
                                acts[#acts + 1] = a
                                fallback, fb_chips = acts, c.chips
                            end
                        end
                    end
                end
            end
            if s.discards_left > 0 and (not best or used_h - 1 < best.hands) then
                local nd = 0
                local dseen = {}
                for i = 1, n do
                    if nd >= ND then break end
                    local d = discard_rest(s, cards[i])
                    if #d > 0 then
                        local k = key_of(d)
                        if not dseen[k] then
                            dseen[k] = true
                            nd = nd + 1
                            local c = ST.clone(s)
                            local a = {type = "discard", cards = d}
                            if E.step(c, a) and c.phase == "play" then
                                local acts = copy_acts(node.acts)
                                acts[#acts + 1] = a
                                kids[#kids + 1] = {s = c, acts = acts}
                            end
                        end
                    end
                end
            end
        end
        if #kids == 0 then break end
        for i = 1, #kids do
            local k = kids[i]
            local bv, n = node_best(k, KT)
            evals = evals + n
            k.h = k.s.chips + bv * (1 + 0.15 * (k.s.hands_left - 1)) + k.s.hands_left * 1e-3 + k.s.discards_left * 1e-6
            k.key = k.s.chips .. ":" .. k.s.hands_left .. ":" .. k.s.discards_left .. ":" .. table.concat(k.s.hand, ",", 1, k.s.n_hand)
        end
        table.sort(kids, function(a, b)
            if a.h ~= b.h then return a.h > b.h end
            return #a.acts < #b.acts
        end)
        beam = {}
        for i = 1, #kids do
            local k = kids[i]
            if not seen[k.key] then
                seen[k.key] = true
                beam[#beam + 1] = k
                if #beam >= B then break end
            end
        end
        if best and best.hands <= 1 then break end
    end
    PL.last_evals = evals
    if best then return best.acts, true end
    if fallback then return fallback, false end
    return {PL.fast_action(s0)}, false
end

function PL.margin_log(gained, need)
    if need <= 0 then return 0 end
    return max(-3, min(3, log(max(gained, 1) / need)))
end

return PL
