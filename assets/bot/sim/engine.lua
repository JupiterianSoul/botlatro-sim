local rng = require("bot.sim.rng")
local D = require("bot.sim.data")
local ST = require("bot.sim.state")
local EV = require("bot.sim.eval")

local E = {}

local floor, max, min = math.floor, math.max, math.min
local random_id, element_index_id, shuffle_id, ante_key, key_id = rng.random_id, rng.element_index_id, rng.shuffle_id, rng.ante_key, rng.key_id
local random_int_id = rng.random_int_id

local JOKERS = D.JOKERS
local J = {}
for i, j in ipairs(JOKERS) do J[j.key:sub(3)] = i end
setmetatable(J, {__index = function(_, k) error("unknown joker " .. tostring(k)) end})
E.J = J

local CFG = {}
local EXN = {}
local TYPE_HAND, T_MULT, T_CHIPS, RARITY = {}, {}, {}, {}
for i, j in ipairs(JOKERS) do
    CFG[i] = j.config
    EXN[i] = type(j.config.extra) == "number" and j.config.extra or 0
    TYPE_HAND[i] = j.config.type and D.HAND_ID[j.config.type] or 0
    T_MULT[i] = j.config.t_mult or 0
    T_CHIPS[i] = j.config.t_chips or 0
    RARITY[i] = j.rarity
end

local E_BONUS, E_MULT, E_WILD, E_GLASS, E_STEEL, E_STONE, E_GOLD, E_LUCKY = 1, 2, 3, 4, 5, 6, 7, 8
local ED_FOIL, ED_HOLO, ED_POLY, ED_NEG = 1, 2, 3, 4
local SEAL_GOLD, SEAL_RED, SEAL_BLUE, SEAL_PURPLE = 1, 2, 3, 4
local ENH_BONUS = {[0] = 0, 30, 0, 0, 0, 0, 50, 0, 0}
local ENH_MULT = {[0] = 0, 0, 4, 0, 0, 0, 0, 0, 20}
local NOMINAL = D.RANK_NOMINAL

local B = D.BLIND_ID
local BL_SMALL, BL_BIG = 1, 2
local BL_OX, BL_HOOK, BL_MOUTH, BL_FISH, BL_MANACLE, BL_TOOTH, BL_WALL = B.bl_ox, B.bl_hook, B.bl_mouth, B.bl_fish, B.bl_manacle, B.bl_tooth, B.bl_wall
local BL_HOUSE, BL_MARK, BL_BELL, BL_WHEEL, BL_ARM, BL_PSYCHIC = B.bl_house, B.bl_mark, B.bl_final_bell, B.bl_wheel, B.bl_arm, B.bl_psychic
local BL_WATER, BL_EYE, BL_PLANT, BL_NEEDLE, BL_LEAF, BL_VESSEL = B.bl_water, B.bl_eye, B.bl_plant, B.bl_needle, B.bl_final_leaf, B.bl_final_vessel
local BL_SERPENT, BL_PILLAR, BL_FLINT, BL_ACORN, BL_HEART = B.bl_serpent, B.bl_pillar, B.bl_flint, B.bl_final_acorn, B.bl_final_heart
local BLINDS = D.BLINDS

local K_LUCKY_MULT, K_LUCKY_MONEY, K_GLASS = key_id("lucky_mult"), key_id("lucky_money"), key_id("glass")
local K_8BALL, K_BUSINESS, K_BLOODSTONE, K_PARKING = key_id("8ball"), key_id("business"), key_id("bloodstone"), key_id("parking")
local K_SPACE, K_MISPRINT, K_HOOK, K_WHEEL = key_id("space"), key_id("misprint"), key_id("hook"), key_id("wheel")
local K_BELL, K_HEART, K_MADNESS, K_TODO = key_id("cerulean_bell"), key_id("crimson_heart"), key_id("madness"), key_id("to_do")
local K_GROS, K_CAV, K_SHUFFLE, K_BOSS = key_id("gros_michel"), key_id("cavendish"), key_id("shuffle"), key_id("boss")
local K_ORBITAL = key_id("orbital")
local K_FLIPPED = key_id("flipped_card")
local K_MARB, K_CERT, K_CERTSL, K_AAJK, K_ERRATIC = key_id("marb_fr"), key_id("cert_fr"), key_id("certsl"), key_id("aajk"), key_id("erratic")

local kill_list = {}
local n_kill = 0
local play_buf = {}
local sc_buf = {}
local eff_k = {}
local eff_bp = {}
local tmp = {}
local tmp2 = {}

local function find_joker(s, id)
    local j_id, j_debuff = s.j_id, s.j_debuff
    for k = 1, s.n_jok do
        if j_id[k] == id and j_debuff[k] == 0 then return true end
    end
    return false
end
E.find_joker = find_joker

local function count_joker(s, id)
    local c = 0
    for k = 1, s.n_jok do
        if s.j_id[k] == id and s.j_debuff[k] == 0 then c = c + 1 end
    end
    return c
end

local function get_id(s, cid)
    if s.c_enh[cid] == E_STONE then return -1 end
    return s.c_rank[cid]
end

local function is_face(s, cid, from_boss, pareidolia)
    if s.c_debuff[cid] == 1 and not from_boss then return false end
    if s.c_enh[cid] ~= E_STONE then
        local r = s.c_rank[cid]
        if r == 11 or r == 12 or r == 13 then return true end
    end
    return pareidolia
end

local function is_suit(s, cid, suit, bypass, smeared)
    if s.c_debuff[cid] == 1 and not bypass then return false end
    local e = s.c_enh[cid]
    if e == E_STONE then return false end
    if e == E_WILD then return true end
    local cs = s.c_suit[cid]
    if smeared and ((cs == 2 or cs == 4) == (suit == 2 or suit == 4)) then return true end
    return cs == suit
end

local function joker_cost(s, k)
    local ec = s.inflation + D.ED_EXTRA_COST[s.j_ed[k]]
    local cost = max(1, floor((s.j_bcost[k] + ec + 0.5) * (100 - s.discount) / 100))
    if s.j_rental[k] == 1 then cost = 1 end
    return cost
end

local function joker_sell(s, k)
    return max(1, floor(joker_cost(s, k) / 2)) + s.j_ev[k]
end
E.joker_sell = joker_sell

local function level_up(s, h, amount)
    local lv = max(0, s.h_level[h] + amount)
    s.h_level[h] = lv
    s.h_mult[h] = max(D.HAND_S_MULT[h] + D.HAND_L_MULT[h] * (lv - 1), 1)
    s.h_chips[h] = max(D.HAND_S_CHIPS[h] + D.HAND_L_CHIPS[h] * (lv - 1), 0)
end
E.level_up = level_up

local function joker_effects(s, k, sign, from_debuff)
    local id = s.j_id[k]
    local c = CFG[id]
    if c.h_size and c.h_size ~= 0 then s.hand_size = s.hand_size + sign * c.h_size end
    if c.d_size and c.d_size > 0 then
        s.resets_discards = s.resets_discards + sign * c.d_size
        s.discards_left = s.discards_left + sign * c.d_size
    end
    if id == J.credit_card then s.bankrupt_at = s.bankrupt_at - sign * 20
    elseif id == J.chaos then
        s.free_rerolls = s.free_rerolls + sign
        E.I.calculate_reroll_cost(s, true)
    elseif id == J.turtle_bean then s.hand_size = s.hand_size + sign * s.j_ex[k]
    elseif id == J.oops then
        if sign > 0 then s.prob = s.prob * 2 else s.prob = s.prob / 2 end
    elseif id == J.to_the_moon then s.interest_amount = s.interest_amount + sign
    elseif id == J.troubadour then
        s.hand_size = s.hand_size + sign * 2
        s.resets_hands = s.resets_hands - sign
    elseif id == J.stuntman then s.hand_size = s.hand_size - sign * 2
    end
    if s.j_ed[k] == ED_NEG and not from_debuff then s.joker_limit = s.joker_limit + sign end
end

local function set_joker_debuff(s, k, should)
    if s.j_perish[k] == 0 then
        if s.j_debuff[k] == 0 then
            s.j_debuff[k] = 1
            joker_effects(s, k, -1, true)
        end
        return
    end
    local cur = s.j_debuff[k]
    local want = should and 1 or 0
    if cur ~= want then
        joker_effects(s, k, want == 1 and -1 or 1, true)
        s.j_debuff[k] = want
    end
end

local function hand_pairs_visible(s, exclude, out)
    local n = 0
    local order = D.HAND_PAIRS_ORDER
    for i = 1, 12 do
        local h = order[i]
        if s.h_vis[h] == 1 and h ~= exclude then
            n = n + 1
            out[n] = h
        end
    end
    return n
end

function E.add_joker(s, key, edition, opts)
    local id = type(key) == "number" and key or J[key:sub(3)]
    local j = JOKERS[id]
    local k = s.n_jok + 1
    s.n_jok = k
    s.j_id[k] = id
    if opts and opts.uid then
        s.j_uid[k] = opts.uid
    else
        s.next_uid = s.next_uid + 1
        s.j_uid[k] = s.next_uid
    end
    s.j_ed[k] = edition and (type(edition) == "number" and edition or D.ED_ID[edition] or 0) or 0
    s.j_debuff[k] = 0
    s.j_flip[k] = 0
    s.j_pin[k] = opts and opts.pinned and 1 or 0
    s.j_eternal[k] = opts and opts.eternal and 1 or 0
    s.j_perish[k] = opts and opts.perish or (opts and opts.perishable and 5 or -1)
    s.j_rental[k] = opts and opts.rental and 1 or 0
    s.j_ev[k] = 0
    s.j_bcost[k] = j.cost
    local c = j.config
    s.j_mult[k] = c.mult or 0
    s.j_x[k] = c.Xmult or 1
    local ex = 0
    if type(c.extra) == "number" then ex = c.extra
    elseif type(c.extra) == "table" then
        if id == J.rocket then ex = c.extra.dollars
        elseif id == J.turtle_bean then ex = c.extra.h_size
        elseif c.extra.chips then ex = c.extra.chips
        end
    end
    s.j_ex[k] = ex
    s.j_h[k] = opts and opts.hpc or s.hands_played
    local n = 0
    if id == J.yorick then n = c.extra.discards
    elseif id == J.caino then n = 1
    elseif id == J.loyalty_card then n = c.extra.every
    elseif id == J.todo_list then
        if opts and opts.todo and opts.todo > 0 then n = opts.todo
        else
            local cnt = hand_pairs_visible(s, 0, tmp)
            n = tmp[element_index_id(s, K_TODO, cnt)]
        end
    end
    s.j_n[k] = n
    joker_effects(s, k, 1, false)
    if id == J.chicot and s.blind > 2 and s.blind_disabled == 0 and s.facing_blind == 1 then E.disable_blind(s) end
    return k
end

local function remove_joker_slot(s, k)
    if s.j_debuff[k] == 0 then joker_effects(s, k, -1, false)
    elseif s.j_ed[k] == ED_NEG then s.joker_limit = s.joker_limit - 1 end
    local n = s.n_jok
    for _, f in ipairs(ST.JOKER_ARRAYS) do
        local a = s[f]
        for i = k, n - 1 do a[i] = a[i + 1] end
        a[n] = nil
    end
    s.n_jok = n - 1
end
E.remove_joker_slot = remove_joker_slot

local function queue_kill(s, k)
    n_kill = n_kill + 1
    kill_list[n_kill] = s.j_uid[k]
end

local function flush_kills(s)
    if n_kill == 0 then return end
    for i = 1, n_kill do
        local uid = kill_list[i]
        for k = 1, s.n_jok do
            if s.j_uid[k] == uid then
                remove_joker_slot(s, k)
                break
            end
        end
    end
    n_kill = 0
end

local function is_killed(s, k)
    local uid = s.j_uid[k]
    for i = 1, n_kill do
        if kill_list[i] == uid then return true end
    end
    return false
end

local function new_card(s, rank, suit, enh, ed, seal)
    local cid = s.n_cards + 1
    s.n_cards = cid
    s.next_uid = s.next_uid + 1
    s.c_rank[cid] = rank
    s.c_suit[cid] = suit
    s.c_osuit[cid] = suit
    s.c_enh[cid] = enh or 0
    s.c_ed[cid] = ed or 0
    s.c_seal[cid] = seal or 0
    s.c_bonus[cid] = 0
    s.c_uid[cid] = s.next_uid
    s.c_debuff[cid] = 0
    s.c_flip[cid] = 0
    s.c_pta[cid] = 0
    s.c_forced[cid] = 0
    s.c_alive[cid] = 1
    s.c_times[cid] = 0
    s.c_perma_debuff[cid] = 0
    return cid
end
E.new_card = new_card

local function n_playing(s)
    local n = 0
    local alive = s.c_alive
    for c = 1, s.n_cards do n = n + alive[c] end
    return n
end
E.n_playing = n_playing

local function playing_card_added(s, count)
    for k = 1, s.n_jok do
        if s.j_id[k] == J.hologram and s.j_debuff[k] == 0 then
            s.j_x[k] = s.j_x[k] + count * 0.25
        end
    end
end

local function sort_key(s, cid)
    return EV.nominal_key(s, cid)
end

local function sort_hand(s)
    local h = s.hand
    local n = s.n_hand
    local uid = s.c_uid
    for i = 2, n do
        local c = h[i]
        local kc = sort_key(s, c)
        local j = i - 1
        while j >= 1 do
            local o = h[j]
            local ko = sort_key(s, o)
            if ko > kc or (ko == kc and uid[o] < uid[c]) then break end
            h[j + 1] = o
            j = j - 1
        end
        h[j + 1] = c
    end
end
E.sort_hand = sort_hand

local function blind_debuff_card(s, cid)
    local b = s.blind
    if s.blind_disabled == 0 and b > 0 then
        local bd = BLINDS[b]
        local suit = s.blind_suit
        if suit > 0 and is_suit(s, cid, suit, true, find_joker(s, J.smeared)) then
            s.c_debuff[cid] = 1
            return
        end
        if bd.face and is_face(s, cid, true, find_joker(s, J.pareidolia)) then
            s.c_debuff[cid] = 1
            return
        end
        if b == BL_PILLAR and s.c_pta[cid] == 1 then
            s.c_debuff[cid] = 1
            return
        end
        if b == BL_LEAF then
            s.c_debuff[cid] = 1
            return
        end
    end
    s.c_debuff[cid] = s.c_perma_debuff[cid]
end

local function refresh_debuffs(s)
    for c = 1, s.n_cards do
        if s.c_alive[c] == 1 then blind_debuff_card(s, c) end
    end
end

local function nth_by_uid(s, list, n, r, out_mark)
    local uid = s.c_uid
    local best_i = 0
    for _ = 1, r do
        local cur, cur_i = math.huge, 0
        local prev = best_i > 0 and uid[list[best_i]] or -math.huge
        for i = 1, n do
            local u = uid[list[i]]
            if u > prev and u < cur and not (out_mark and out_mark[i]) then cur, cur_i = u, i end
        end
        best_i = cur_i
    end
    return best_i
end

local function pick_by_uid(s, list, n, key)
    local r = element_index_id(s, key, n)
    return nth_by_uid(s, list, n, r)
end

local function joker_pick_by_uid(s, idxs, n, key)
    local r = element_index_id(s, key, n)
    local juid = s.j_uid
    for i = 2, n do
        local v = idxs[i]
        local j = i - 1
        while j >= 1 and juid[idxs[j]] > juid[v] do
            idxs[j + 1] = idxs[j]
            j = j - 1
        end
        idxs[j + 1] = v
    end
    return idxs[r]
end

local function stay_flipped(s, cid)
    if s.blind_disabled == 1 then return false end
    local b = s.blind
    if b == BL_WHEEL and random_id(s, K_WHEEL) < s.prob / 7 then return true end
    if b == BL_HOUSE and s.round_hands_played == 0 and s.discards_used == 0 then return true end
    if b == BL_MARK and is_face(s, cid, true, find_joker(s, J.pareidolia)) then return true end
    if b == BL_FISH and s.blind_prepped == 1 then return true end
    return false
end

local function draw_n(s, count)
    for _ = 1, count do
        local nd = s.n_deck
        if nd == 0 then break end
        local cid = s.deck[nd]
        s.deck[nd] = nil
        s.n_deck = nd - 1
        local fl = stay_flipped(s, cid)
        if s.flipped_cards > 0 and random_id(s, K_FLIPPED) < 1 / s.flipped_cards then fl = true end
        s.c_flip[cid] = fl and 1 or 0
        local nh = s.n_hand + 1
        s.n_hand = nh
        s.hand[nh] = cid
    end
    sort_hand(s)
end

local function drawn_to_hand(s)
    if s.blind_disabled == 0 then
        if s.blind == BL_BELL then
            local any = false
            for i = 1, s.n_hand do
                if s.c_forced[s.hand[i]] == 1 then any = true end
            end
            if not any and s.n_hand > 0 then
                local i = pick_by_uid(s, s.hand, s.n_hand, K_BELL)
                s.c_forced[s.hand[i]] = 1
            end
        end
        if s.blind == BL_HEART and s.blind_prepped == 1 and s.n_jok > 0 then
            local n = 0
            local nj = s.n_jok
            for k = 1, nj do
                if s.j_debuff[k] == 0 or nj < 2 then
                    n = n + 1
                    tmp[n] = k
                end
                set_joker_debuff(s, k, false)
            end
            if n > 0 then
                local k = joker_pick_by_uid(s, tmp, n, K_HEART)
                set_joker_debuff(s, k, true)
            end
        end
    end
    s.blind_prepped = 0
end

local resolve_blueprints

local function first_hand_drawn(s)
    resolve_blueprints(s)
    for k = 1, s.n_jok do
        local ek = eff_k[k]
        if ek > 0 and s.j_id[ek] == J.certificate then
            local pi = element_index_id(s, K_CERT, 52)
            local pc = D.P_CARDS_ORDER[pi]
            local cid = new_card(s, pc[1], pc[2])
            local roll = random_id(s, K_CERTSL)
            if roll > 0.75 then s.c_seal[cid] = SEAL_RED
            elseif roll > 0.5 then s.c_seal[cid] = SEAL_BLUE
            elseif roll > 0.25 then s.c_seal[cid] = SEAL_GOLD
            else s.c_seal[cid] = SEAL_PURPLE end
            blind_debuff_card(s, cid)
            s.n_hand = s.n_hand + 1
            s.hand[s.n_hand] = cid
            s.deck_limit = s.deck_limit + 1
            sort_hand(s)
            playing_card_added(s, 1)
        end
    end
end

local function lux_sync(s)
    local x = s.lux_x
    if x == 0 then return end
    local f = floor(s.money / x)
    if f ~= s.lux_last then
        local delta = s.lux_last - f
        s.hand_size = s.hand_size + delta
        s.lux_last = f
        if delta > 0 and s.phase == "play" and s.n_hand > 0 then draw_n(s, min(delta, s.n_deck)) end
    end
end
E.lux_sync = lux_sync

local function draw_to_hand(s)
    lux_sync(s)
    if s.hand_size <= 0 and s.n_hand == 0 then
        s.game_over = 1
        s.phase = "game_over"
        return
    end
    local space = min(s.n_deck, s.hand_size - s.n_hand)
    if s.blind == BL_SERPENT and s.blind_disabled == 0 and (s.round_hands_played > 0 or s.discards_used > 0) then
        space = min(s.n_deck, 3)
    end
    if space > 0 then draw_n(s, space) end
    if s.round_hands_played == 0 and s.discards_used == 0 and s.facing_blind == 1 then
        first_hand_drawn(s)
    end
    drawn_to_hand(s)
    if s.n_hand < 1 and s.n_deck < 1 and s.phase == "play" then
        E.end_round(s)
    end
end
E.draw_to_hand = draw_to_hand

resolve_blueprints = function(s)
    local nj = s.n_jok
    local j_id, j_debuff = s.j_id, s.j_debuff
    for k = 1, nj do
        local cur = k
        local bp = 0
        local res = 0
        if j_debuff[k] == 0 then
            res = k
            local hops = 0
            while true do
                local id = j_id[cur]
                local other
                if id == J.blueprint then other = cur + 1
                elseif id == J.brainstorm then other = 1
                else break end
                if other > nj or other == cur then res = 0 break end
                hops = hops + 1
                if hops > nj + 1 then res = 0 break end
                if j_debuff[other] == 1 then res = 0 break end
                cur = other
                bp = 1
                res = cur
            end
        end
        eff_k[k] = res
        eff_bp[k] = bp
    end
end

local function cons_free(s)
    return s.n_cons + s.consumable_buffer < s.cons_limit
end

local function add_pending_cons(s, code)
    local n = s.n_pq + 1
    s.n_pq = n
    s.pq[n] = code
end

local function ease_round_money(s, v)
    s.dollar_buffer = s.dollar_buffer + v
end

local function boss_type(s)
    if s.blind == BL_SMALL then return 1 elseif s.blind == BL_BIG then return 2 elseif s.blind > 0 then return 3 end
    return 0
end

local function disable_blind(s)
    s.blind_disabled = 1
    for k = 1, s.n_jok do s.j_flip[k] = 0 end
    local b = s.blind
    if b == BL_WATER then s.discards_left = s.discards_left + s.blind_discards_sub end
    if b == BL_WHEEL or b == BL_HOUSE or b == BL_MARK or b == BL_FISH then
        for i = 1, s.n_hand do s.c_flip[s.hand[i]] = 0 end
    end
    if b == BL_NEEDLE then s.hands_left = s.hands_left + s.blind_hands_sub end
    if b == BL_WALL then s.blind_chips = s.blind_chips / 2 end
    if b == BL_BELL then
        for c = 1, s.n_cards do s.c_forced[c] = 0 end
    end
    if b == BL_MANACLE then
        s.hand_size = s.hand_size + 1
        if s.phase == "play" then draw_n(s, 1) end
    end
    if b == BL_VESSEL then s.blind_chips = s.blind_chips / 3 end
    refresh_debuffs(s)
    for k = 1, s.n_jok do set_joker_debuff(s, k, false) end
end
E.disable_blind = disable_blind

function E.get_blind_amount(s, ante)
    local k = 0.75
    local amounts
    if s.scaling == 2 then amounts = {300, 900, 2600, 8000, 20000, 36000, 60000, 100000}
    elseif s.scaling == 3 then amounts = {300, 1000, 3200, 9000, 25000, 60000, 110000, 200000}
    else amounts = {300, 800, 2000, 5000, 11000, 20000, 35000, 50000} end
    if ante < 1 then return 100 end
    if ante <= 8 then return amounts[ante] end
    local a, b, c, d = amounts[8], 1.6, ante - 8, 1 + 0.2 * (ante - 8)
    local amount = floor(a * (b + (k * c) ^ d) ^ c)
    amount = amount - amount % (10 ^ floor(math.log10(amount) - 1))
    return amount
end

local function get_new_boss(s)
    local ante = s.ante
    local a1 = max(1, ante)
    local ids = D.BOSS_IDS_SORTED
    local n = 0
    local min_use = 100
    for i = 1, #ids do
        local b = ids[i]
        local bd = BLINDS[b]
        local ok
        if not bd.showdown then
            ok = bd.min <= a1 and (a1 % s.win_ante ~= 0 or ante < 2)
        else
            ok = ante % s.win_ante == 0 and ante >= 2
        end
        if ok and s.ban ~= 0 and s.ban[bd.key] then ok = false end
        if ok then
            n = n + 1
            tmp2[n] = b
            if s.bosses_used[b] <= min_use then min_use = s.bosses_used[b] end
        end
    end
    local m = 0
    for i = 1, n do
        if s.bosses_used[tmp2[i]] <= min_use then
            m = m + 1
            tmp2[m] = tmp2[i]
        end
    end
    local boss = tmp2[element_index_id(s, K_BOSS, m)]
    s.bosses_used[boss] = s.bosses_used[boss] + 1
    return boss
end
E.get_new_boss = get_new_boss

local function get_next_tag(s)
    local ante = s.ante
    local tags = D.TAGS
    local nt = #tags
    local id = ante_key("Tag", ante)
    local it = 1
    while true do
        local r = element_index_id(s, id, nt)
        local t = tags[r]
        if (not t.min_ante or t.min_ante <= ante) and not (s.ban ~= 0 and s.ban[t.key]) then return r end
        it = it + 1
        id = key_id("Tag" .. ante .. "_resample" .. it)
    end
end
E.get_next_tag = get_next_tag

local function get_next_voucher(s)
    local ante = s.ante
    local vs = D.VOUCHERS
    local nv = #vs
    local any = false
    for i = 1, nv do
        local v = vs[i]
        if s.used_v[i] == 0 and (not v.requires_id or s.used_v[v.requires_id] == 1) then any = true end
    end
    if not any then return D.VOUCHER_ID.v_blank end
    local id = ante_key("Voucher", ante)
    local it = 1
    while true do
        local r = element_index_id(s, id, nv)
        local v = vs[r]
        if s.used_v[r] == 0 and (not v.requires_id or s.used_v[v.requires_id] == 1) and not (s.ban ~= 0 and s.ban[v.key]) then return r end
        it = it + 1
        id = key_id("Voucher" .. ante .. "_resample" .. it)
    end
end
E.get_next_voucher = get_next_voucher

local function reset_round_cards(s)
    local ante = s.ante
    local n = 0
    for c = 1, s.n_cards do
        if s.c_alive[c] == 1 and s.c_enh[c] ~= E_STONE then
            n = n + 1
            tmp2[n] = c
        end
    end
    s.idol_rank, s.idol_suit = 14, 1
    if n > 0 then
        local c = tmp2[element_index_id(s, ante_key("idol", ante), n)]
        s.idol_rank, s.idol_suit = s.c_rank[c], s.c_suit[c]
    end
    s.mail_rank = 14
    if n > 0 then
        local c = tmp2[element_index_id(s, ante_key("mail", ante), n)]
        s.mail_rank = s.c_rank[c]
    end
    local m = 0
    for _, su in ipairs({1, 2, 3, 4}) do
        if su ~= s.ancient_suit then
            m = m + 1
            tmp[m] = su
        end
    end
    s.ancient_suit = tmp[element_index_id(s, ante_key("anc", ante), m)]
    s.castle_suit = 1
    if n > 0 then
        local c = tmp2[element_index_id(s, ante_key("cas", ante), n)]
        s.castle_suit = s.c_suit[c]
    end
end

local function shuffle_deck(s, key)
    local d = s.deck
    local n = s.n_deck
    local uid = s.c_uid
    for i = 2, n do
        local v = d[i]
        local j = i - 1
        while j >= 1 and uid[d[j]] > uid[v] do
            d[j + 1] = d[j]
            j = j - 1
        end
        d[j + 1] = v
    end
    shuffle_id(s, key, d, n)
end
E.shuffle_deck = shuffle_deck

local function apply_voucher(s, key)
    local vid = D.VOUCHER_ID[key]
    if vid then s.used_v[vid] = 1 end
    if key == "v_crystal_ball" then s.cons_limit = s.cons_limit + 1
    elseif key == "v_grabber" or key == "v_nacho_tong" then
        s.resets_hands = s.resets_hands + 1
        s.hands_left = s.hands_left + 1
    elseif key == "v_wasteful" or key == "v_recyclomancy" then
        s.resets_discards = s.resets_discards + 1
        s.discards_left = s.discards_left + 1
    elseif key == "v_paint_brush" or key == "v_palette" then s.hand_size = s.hand_size + 1
    elseif key == "v_seed_money" then s.interest_cap = 50
    elseif key == "v_money_tree" then s.interest_cap = 100
    elseif key == "v_clearance_sale" then s.discount = 25
    elseif key == "v_liquidation" then s.discount = 50
    elseif key == "v_antimatter" then s.joker_limit = s.joker_limit + 1
    elseif key == "v_hieroglyph" then
        s.ante = s.ante - 1
        s.resets_hands = s.resets_hands - 1
        s.hands_left = s.hands_left - 1
    elseif key == "v_petroglyph" then
        s.ante = s.ante - 1
        s.resets_discards = s.resets_discards - 1
        s.discards_left = s.discards_left - 1
    elseif vid then
        E.I.apply_voucher_shop(s, vid)
    end
end
E.apply_voucher = apply_voucher

local function ensure_orbital(s)
    local a = s.ante
    if s.orb_a1 == a then s.orb_s, s.orb_b = s.orb_s1, s.orb_b1 return end
    if s.orb_a2 == a then s.orb_s, s.orb_b = s.orb_s2, s.orb_b2 return end
    if s.orb_a3 == a then s.orb_s, s.orb_b = s.orb_s3, s.orb_b3 return end
    local r = {}
    for t = 1, 3 do
        local cnt = hand_pairs_visible(s, 0, tmp)
        r[t] = tmp[element_index_id(s, K_ORBITAL, cnt)]
    end
    s.orb_a3, s.orb_s3, s.orb_b3 = s.orb_a2, s.orb_s2, s.orb_b2
    s.orb_a2, s.orb_s2, s.orb_b2 = s.orb_a1, s.orb_s1, s.orb_b1
    s.orb_a1, s.orb_s1, s.orb_b1 = a, r[1], r[2]
    s.orb_s, s.orb_b = r[1], r[2]
end
E.ensure_orbital = ensure_orbital

local function proto_less(a, b) return a[3] < b[3] end

local function deck_bottom(s, cid)
    local d, n = s.deck, s.n_deck
    for i = n, 1, -1 do d[i + 1] = d[i] end
    d[1] = cid
    s.n_deck = n + 1
end
E.deck_bottom = deck_bottom

function E.new_run(setup)
    local seed = setup.seed
    local s = ST.new(seed)
    local deck_key = setup.deck or "b_red"
    local stake = setup.stake or 1
    local ch = setup.challenge and setup.challenge ~= "" and require("bot.sim.data_challenges")[setup.challenge] or nil
    if ch then deck_key = "b_challenge" end
    local back = D.DECKS[deck_key] or {}
    s.deck_key = deck_key
    s.stake = stake
    s.ante, s.round, s.win_ante = 1, 0, 8
    s.prob = 1
    s.interest_cap, s.interest_amount = 25, 1
    s.scaling = 1
    s.ante_scaling = 1
    s.base_reroll_cost = 5
    s.money_per_hand = 1
    s.joker_max, s.joker_rate, s.tarot_rate, s.planet_rate, s.playing_card_rate, s.edition_rate = 2, 20, 4, 4, 0, 1
    s.temp_reroll = -1
    s.ecto_minus = 1
    s.ban = 0
    s.orb_a1, s.orb_a2, s.orb_a3 = -1000, -1000, -1000
    if stake >= 4 then s.eternals_on = 1 end
    if stake >= 7 then s.perish_on = 1 end
    if stake >= 8 then s.rentals_on = 1 end
    s.blind_on_deck = 1
    s.state_small, s.state_big, s.state_boss = 1, 0, 0
    local dollars, hand_size, discards, hands, joker_slots, cons_slots, reroll = 4, 8, 3, 4, 5, 2, 5
    if stake >= 2 then s.no_reward_small = 1 end
    if stake >= 3 then s.scaling = 2 end
    if stake >= 5 then discards = discards - 1 end
    if stake >= 6 then s.scaling = 3 end
    if back.hands then hands = hands + back.hands end
    if back.dollars then dollars = dollars + back.dollars end
    if back.discards then discards = discards + back.discards end
    if back.joker_slot then joker_slots = joker_slots + back.joker_slot end
    if back.hand_size then hand_size = hand_size + back.hand_size end
    if back.ante_scaling then s.ante_scaling = back.ante_scaling end
    if back.consumable_slot then cons_slots = cons_slots + back.consumable_slot end
    if back.no_interest then s.no_interest = 1 end
    if back.extra_hand_bonus then s.money_per_hand = back.extra_hand_bonus end
    if back.extra_discard_bonus then s.money_per_discard = back.extra_discard_bonus end
    if back.spectral_rate then s.spectral_rate = back.spectral_rate end
    if back.plasma then s.plasma = 1 end
    if back.anaglyph then s.anaglyph = 1 end
    if ch then
        local ban = {}
        local r = ch.restrictions or {}
        for _, list in ipairs({r.banned_cards or {}, r.banned_tags or {}, r.banned_other or {}}) do
            for _, v in ipairs(list) do
                ban[v.id] = true
                for _, x in ipairs(v.ids or {}) do ban[x] = true end
            end
        end
        s.ban = ban
        for _, m in ipairs(ch.rules and ch.rules.modifiers or {}) do
            local v = m.value
            if m.id == "dollars" then dollars = v
            elseif m.id == "discards" then discards = v
            elseif m.id == "hands" then hands = v
            elseif m.id == "hand_size" then hand_size = v
            elseif m.id == "joker_slots" then joker_slots = v
            elseif m.id == "consumable_slots" then cons_slots = v
            elseif m.id == "reroll_cost" then reroll = v end
        end
        for _, c in ipairs(ch.rules and ch.rules.custom or {}) do
            local id = c.id
            if id == "no_reward" then s.no_reward_small, s.no_reward_big, s.no_reward_boss = 1, 1, 1
            elseif id == "no_reward_specific" then
                if c.value == "Small" then s.no_reward_small = 1 elseif c.value == "Big" then s.no_reward_big = 1 else s.no_reward_boss = 1 end
            elseif id == "no_extra_hand_money" then s.no_extra_hand_money = 1
            elseif id == "no_interest" then s.no_interest = 1
            elseif id == "no_shop_jokers" then s.joker_rate = 0
            elseif id == "all_eternal" then s.all_eternal = 1
            elseif id == "inflation" then s.inflation_on = 1
            elseif id == "discard_cost" then s.discard_cost = c.value
            elseif id == "set_eternal_ante" then s.set_eternal_ante = c.value
            elseif id == "set_joker_slots_ante" then s.set_joker_slots_ante = c.value
            elseif id == "flipped_cards" then s.flipped_cards = c.value
            elseif id == "minus_hand_size_per_X_dollar" then s.lux_x = c.value
            elseif id == "debuff_played_cards" then s.debuff_played = 1
            elseif id == "chips_dollar_cap" then s.chips_cap = 1
            end
        end
        for _, v in ipairs(ch.vouchers or {}) do
            local vid = D.VOUCHER_ID[v.id]
            if vid then s.used_v[vid] = 1 end
        end
    end
    s.hand_size, s.joker_limit, s.cons_limit = hand_size, joker_slots, cons_slots
    s.resets_hands, s.resets_discards = hands, discards
    s.money = dollars
    s.reroll_cost, s.base_reroll_cost = reroll, reroll
    if back.voucher then apply_voucher(s, back.voucher) end
    if back.vouchers then
        for _, v in ipairs(back.vouchers) do apply_voucher(s, v) end
    end
    for h = 1, 12 do
        s.h_level[h] = 1
        s.h_chips[h] = D.HAND_S_CHIPS[h]
        s.h_mult[h] = D.HAND_S_MULT[h]
        s.h_played[h] = 0
        s.h_pround[h] = 0
        s.h_vis[h] = D.HAND_VISIBLE[h] and 1 or 0
    end
    s.boss_choice = get_new_boss(s)
    s.voucher = get_next_voucher(s)
    s.tag_small = get_next_tag(s)
    s.tag_big = get_next_tag(s)
    local protos = {}
    local deck_cards = ch and ch.deck and ch.deck.cards
    for _, pc in ipairs(deck_cards and {} or D.P_CARDS_ORDER) do
        local r, su = pc[1], pc[2]
        if back.randomize_rank_suit then
            local p = D.P_CARDS_ORDER[element_index_id(s, K_ERRATIC, 52)]
            r, su = p[1], p[2]
        end
        if not (back.remove_faces and (r == 11 or r == 12 or r == 13)) then
            protos[#protos + 1] = {r, su, D.SUIT_CHARS[su] .. D.RANK_CHARS[r]}
        end
    end
    local rc = {[2] = "2", [3] = "3", [4] = "4", [5] = "5", [6] = "6", [7] = "7", [8] = "8", [9] = "9", [10] = "T", [11] = "J", [12] = "Q", [13] = "K", [14] = "A"}
    local sc = {"S", "H", "C", "D"}
    for _, p in ipairs(protos) do p[3] = sc[p[2]] .. rc[p[1]] end
    if deck_cards then
        for _, c in ipairs(deck_cards) do
            protos[#protos + 1] = {D.RANK_ID[c.r], D.SUIT_ID[c.s], c.s .. c.r .. (c.e or "") .. (c.d or "") .. (c.g or ""),
                c.e and D.ENH_ID[c.e] or 0, c.d and D.ED_ID["e_" .. c.d] or 0, c.g and D.SEAL_NAME_ID[c.g] or 0}
        end
    end
    table.sort(protos, proto_less)
    local np = #protos
    for i, p in ipairs(protos) do
        s.deck[np - i + 1] = new_card(s, p[1], p[2], p[4], p[5], p[6])
    end
    s.n_deck = np
    s.starting_deck_size = s.n_cards
    s.deck_limit = s.n_cards
    s.discards_left = s.resets_discards
    s.hands_left = s.resets_hands
    shuffle_deck(s, K_SHUFFLE)
    s.ancient_suit = 0
    reset_round_cards(s)
    if back.consumables then
        for _, ckey in ipairs(back.consumables) do E.I.add_cons(s, D.CONS_ID[ckey], 0) end
    end
    if ch then
        for _, v in ipairs(ch.jokers or {}) do
            local k = E.add_joker(s, v.id, v.edition and D.ED_ID["e_" .. v.edition] or nil, {hpc = 0, pinned = v.pinned})
            if v.eternal and JOKERS[s.j_id[k]].eternal and s.j_perish[k] < 0 then s.j_eternal[k] = 1 end
        end
        for _, v in ipairs(ch.consumeables or {}) do E.I.add_cons(s, D.CONS_ID[v.id], v.edition and D.ED_ID["e_" .. v.edition] or 0) end
        for _, v in ipairs(ch.vouchers or {}) do apply_voucher(s, v.id) end
    end
    if back.checkered then
        for c = 1, s.n_cards do
            if s.c_suit[c] == 3 then s.c_suit[c] = 1 end
            if s.c_suit[c] == 4 then s.c_suit[c] = 2 end
        end
    end
    s.most_played = 12
    s.phase = "blind_select"
    s.blind = 0
    s.step = 0
    ensure_orbital(s)
    return s
end

local function set_blind(s, b)
    local bd = BLINDS[b]
    s.blind = b
    local dollars = bd.dollars
    local bt = b == BL_SMALL and 1 or b == BL_BIG and 2 or 3
    if (bt == 1 and s.no_reward_small == 1) or (bt == 2 and s.no_reward_big == 1) or (bt == 3 and s.no_reward_boss == 1) then dollars = 0 end
    s.blind_dollars = dollars
    s.blind_disabled = 0
    s.blind_triggered = 0
    s.blind_prepped = 1
    s.blind_suit = bd.suit or 0
    s.blind_hands_sub = 0
    s.blind_discards_sub = 0
    s.blind_chips = E.get_blind_amount(s, s.ante) * bd.mult * s.ante_scaling
    if b == BL_EYE then s.blind_eye = 0 end
    if b == BL_MOUTH then s.blind_mouth = 0 end
    if b == BL_FISH then s.blind_prepped = 0 end
    if b == BL_WATER then
        s.blind_discards_sub = s.discards_left
        s.discards_left = s.discards_left - s.blind_discards_sub
    end
    if b == BL_NEEDLE then
        s.blind_hands_sub = s.resets_hands - 1
        s.hands_left = s.hands_left - s.blind_hands_sub
    end
    if b == BL_MANACLE then s.hand_size = s.hand_size - 1 end
    if b == BL_ACORN then
        for k = 1, s.n_jok do s.j_flip[k] = 1 end
    end
    refresh_debuffs(s)
    if b ~= BL_HEART then
        for k = 1, s.n_jok do set_joker_debuff(s, k, false) end
    end
end

local function shuffle_jokers(s, key)
    local n = s.n_jok
    for i = 1, n do tmp[i] = i end
    local juid = s.j_uid
    for i = 2, n do
        local v = tmp[i]
        local j = i - 1
        while j >= 1 and juid[tmp[j]] > juid[v] do
            tmp[j + 1] = tmp[j]
            j = j - 1
        end
        tmp[j + 1] = v
    end
    shuffle_id(s, key, tmp, n)
    for _, f in ipairs(ST.JOKER_ARRAYS) do
        local a = s[f]
        for i = 1, n do tmp2[i] = a[tmp[i]] end
        for i = 1, n do a[i] = tmp2[i] end
    end
end

local function setting_blind(s)
    local is_boss = s.blind > 2
    resolve_blueprints(s)
    local nj = s.n_jok
    for k = 1, nj do
        local ek = eff_k[k]
        if ek > 0 and not is_killed(s, k) then
            local id = s.j_id[ek]
            local bp = eff_bp[k] == 1
            if id == J.chicot and not bp and is_boss then
                if s.blind_disabled == 0 then disable_blind(s) end
            elseif id == J.madness and not bp and not is_boss then
                s.j_x[ek] = s.j_x[ek] + EXN[id]
                local n = 0
                for o = 1, nj do
                    if o ~= ek and s.j_eternal[o] == 0 and not is_killed(s, o) then
                        n = n + 1
                        tmp[n] = o
                    end
                end
                if n > 0 then
                    local victim = joker_pick_by_uid(s, tmp, n, K_MADNESS)
                    queue_kill(s, victim)
                end
            elseif id == J.burglar then
                s.discards_left = 0
                s.hands_left = s.hands_left + EXN[id]
            elseif id == J.cartomancer then
                if cons_free(s) then
                    s.consumable_buffer = s.consumable_buffer + 1
                    add_pending_cons(s, 6)
                end
            elseif id == J.riff_raff and s.n_jok + s.joker_buffer < s.joker_limit then
                local c = min(2, s.joker_limit - (s.n_jok + s.joker_buffer))
                s.joker_buffer = s.joker_buffer + c
                for _ = 1, c do add_pending_cons(s, 9) end
            elseif id == J.ceremonial and not bp then
                local o = ek + 1
                if o <= nj and s.j_eternal[o] == 0 and not is_killed(s, o) and not is_killed(s, ek) then
                    s.j_mult[ek] = s.j_mult[ek] + joker_sell(s, o) * 2
                    s.joker_buffer = s.joker_buffer - 1
                    queue_kill(s, o)
                end
            elseif id == J.marble then
                local pi = element_index_id(s, K_MARB, 52)
                local pc = D.P_CARDS_ORDER[pi]
                deck_bottom(s, new_card(s, pc[1], pc[2], E_STONE))
                s.deck_limit = s.deck_limit + 1
                playing_card_added(s, 1)
            end
        end
    end
    flush_kills(s)
end

function E.select_blind(s)
    if s.phase ~= "blind_select" then return false end
    local which = s.blind_on_deck
    local b = which == 1 and BL_SMALL or which == 2 and BL_BIG or s.boss_choice
    s.facing_blind = 1
    s.round = s.round + 1
    if which == 1 then s.state_small = 2 elseif which == 2 then s.state_big = 2 else s.state_boss = 2 end
    s.discards_left = max(0, s.resets_discards + s.bonus_discards)
    s.hands_left = max(1, s.resets_hands + s.bonus_hands)
    s.round_hands_played = 0
    s.discards_used = 0
    for h = 1, 12 do s.h_pround[h] = 0 end
    s.reroll_inc = 0
    s.up1, s.up2 = 0, 0
    s.free_rerolls = count_joker(s, J.chaos)
    E.I.calculate_reroll_cost(s, true)
    s.bonus_hands = 0
    s.bonus_discards = 0
    s.chips = 0
    set_blind(s, b)
    setting_blind(s)
    if s.n_pq > 0 then E.flush_pending(s) end
    if b == BL_ACORN and s.n_jok > 1 then
        shuffle_jokers(s, K_AAJK)
        shuffle_jokers(s, K_AAJK)
        shuffle_jokers(s, K_AAJK)
    end
    shuffle_deck(s, ante_key("nr", s.ante))
    s.phase = "play"
    local juggled = false
    for i = 1, s.n_tags do
        if s.tag_trig[i] == 0 and s.tags[i] == D.TAG_ID.tag_juggle then
            s.tag_trig[i] = 1
            s.hand_size = s.hand_size + 3
            s.temp_handsize = s.temp_handsize + 3
            juggled = true
        end
    end
    if juggled then E.I.tag_remove_triggered(s) end
    draw_to_hand(s)
    return true
end

local function skip_tag_immediate(s)
    for i = 1, s.n_tags do
        if s.tag_trig[i] == 0 then
            local t = D.TAGS[s.tags[i]].key
            local used = true
            if t == "tag_economy" then s.money = s.money + min(40, max(0, s.money))
            elseif t == "tag_handy" then s.money = s.money + s.hands_played
            elseif t == "tag_garbage" then s.money = s.money + s.unused_discards
            elseif t == "tag_skip" then s.money = s.money + s.skips * 5
            else used = E.I.immediate_tag(s, s.tags[i], i) end
            if used then s.tag_trig[i] = 1 end
        end
    end
end

function E.skip_blind(s)
    if s.phase ~= "blind_select" or s.blind_on_deck == 3 then return false end
    s.skips = s.skips + 1
    local tag = s.blind_on_deck == 1 and s.tag_small or s.tag_big
    local hand = 0
    if tag == D.TAG_ID.tag_orbital then hand = s.blind_on_deck == 1 and s.orb_s or s.orb_b end
    E.add_tag(s, tag, hand)
    if s.blind_on_deck == 1 then
        s.state_small = 4
        s.state_big = 1
        s.blind_on_deck = 2
    else
        s.state_big = 4
        s.state_boss = 1
        s.blind_on_deck = 3
    end
    skip_tag_immediate(s)
    E.skip_blind_tags(s)
    return true
end

function E.reroll_boss(s)
    if s.phase ~= "blind_select" then return false end
    local ok = s.used_v[D.VOUCHER_ID.v_retcon] == 1 or (s.used_v[D.VOUCHER_ID.v_directors_cut] == 1 and s.boss_rerolled == 0)
    if not ok or (s.money - s.bankrupt_at) - 10 < 0 then return false end
    s.boss_rerolled = 1
    s.money = s.money - 10
    s.boss_choice = get_new_boss(s)
    E.I.new_blind_choice_tags(s)
    return true
end

local function card_chips(s, cid)
    if s.c_debuff[cid] == 1 then return 0 end
    local e = s.c_enh[cid]
    if e == E_STONE then return ENH_BONUS[e] + s.c_bonus[cid] end
    return NOMINAL[s.c_rank[cid]] + ENH_BONUS[e] + s.c_bonus[cid]
end

local function discard_cards(s, cards, n, hook)
    resolve_blueprints(s)
    local nj = s.n_jok
    local j_id = s.j_id
    if not hook then
        for k = 1, nj do
            local ek = eff_k[k]
            if ek > 0 and j_id[ek] == J.burnt and s.discards_used <= 0 then
                local top = EV.evaluate(s, cards, n, find_joker(s, J.four_fingers), find_joker(s, J.shortcut), find_joker(s, J.smeared), false)
                if top > 0 then level_up(s, top, 1) end
            end
        end
    end
    local smeared = find_joker(s, J.smeared)
    local pareidolia = find_joker(s, J.pareidolia)
    local last = cards[n]
    local ndestroyed = 0
    for i = 1, n do
        local cid = cards[i]
        if s.c_debuff[cid] == 0 and s.c_seal[cid] == SEAL_PURPLE and cons_free(s) then
            s.consumable_buffer = s.consumable_buffer + 1
            add_pending_cons(s, 1)
        end
        local removed = false
        for k = 1, nj do
            local ek = eff_k[k]
            if ek > 0 then
                local id = j_id[ek]
                local bp = eff_bp[k] == 1
                if id == J.ramen and not bp then
                    if s.j_x[ek] - 0.01 <= 1 then
                        queue_kill(s, ek)
                    else
                        s.j_x[ek] = s.j_x[ek] - 0.01
                    end
                elseif id == J.yorick and not bp then
                    if s.j_n[ek] <= 1 then
                        s.j_n[ek] = CFG[id].extra.discards
                        s.j_x[ek] = s.j_x[ek] + CFG[id].extra.xmult
                    else
                        s.j_n[ek] = s.j_n[ek] - 1
                    end
                elseif id == J.trading and not bp and s.discards_used <= 0 and n == 1 then
                    ease_round_money(s, 3)
                    removed = true
                elseif id == J.castle and not bp and s.c_debuff[cid] == 0 and is_suit(s, cid, s.castle_suit, false, smeared) then
                    s.j_ex[ek] = s.j_ex[ek] + 3
                elseif id == J.mail and s.c_debuff[cid] == 0 and get_id(s, cid) == s.mail_rank then
                    ease_round_money(s, 5)
                elseif id == J.hit_the_road and not bp and s.c_debuff[cid] == 0 and get_id(s, cid) == 11 then
                    s.j_x[ek] = s.j_x[ek] + 0.5
                elseif id == J.green_joker and not bp and cid == last then
                    s.j_mult[ek] = max(0, s.j_mult[ek] - 1)
                elseif id == J.faceless and cid == last then
                    local faces = 0
                    for q = 1, n do
                        if is_face(s, cards[q], false, pareidolia) then faces = faces + 1 end
                    end
                    if faces >= 3 then ease_round_money(s, 5) end
                end
            end
        end
        if removed then
            s.c_alive[cid] = 0
            ndestroyed = ndestroyed + 1
            tmp2[ndestroyed] = cid
        else
            s.n_disc = s.n_disc + 1
            s.disc[s.n_disc] = cid
        end
    end
    if ndestroyed > 0 then
        for k = 1, nj do
            local id = j_id[k]
            if s.j_debuff[k] == 0 then
                if id == J.caino then
                    local faces = 0
                    for q = 1, ndestroyed do
                        if is_face(s, tmp2[q], false, pareidolia) then faces = faces + 1 end
                    end
                    s.j_n[k] = s.j_n[k] + faces * CFG[id].extra
                elseif id == J.glass then
                    local g = 0
                    for q = 1, ndestroyed do
                        if s.c_enh[tmp2[q]] == E_GLASS then g = g + 1 end
                    end
                    s.j_x[k] = s.j_x[k] + 0.75 * g
                end
            end
        end
    end
    flush_kills(s)
end

local function remove_from_hand(s, cid)
    local h = s.hand
    local n = s.n_hand
    for i = 1, n do
        if h[i] == cid then
            for j = i, n - 1 do h[j] = h[j + 1] end
            h[n] = nil
            s.n_hand = n - 1
            return
        end
    end
end

local function check_positions(s, pos)
    local n = #pos
    if n < 1 or n > 5 then return false end
    for i = 1, n do
        local p = pos[i]
        if type(p) ~= "number" or p < 1 or p > s.n_hand or p ~= floor(p) then return false end
        for j = 1, i - 1 do
            if pos[j] == p then return false end
        end
    end
    for i = 1, s.n_hand do
        if s.c_forced[s.hand[i]] == 1 then
            local found = false
            for j = 1, n do
                if pos[j] == i then found = true end
            end
            if not found then return false end
        end
    end
    return true
end

local function sorted_selection(s, pos, out)
    local n = #pos
    for i = 1, n do tmp[i] = pos[i] end
    for i = 2, n do
        local v = tmp[i]
        local j = i - 1
        while j >= 1 and tmp[j] > v do
            tmp[j + 1] = tmp[j]
            j = j - 1
        end
        tmp[j + 1] = v
    end
    for i = 1, n do out[i] = s.hand[tmp[i]] end
    return n
end

function E.discard(s, pos)
    if s.phase ~= "play" or s.discards_left <= 0 or not check_positions(s, pos) then return false end
    for c = 1, s.n_cards do s.c_forced[c] = 0 end
    local n = sorted_selection(s, pos, play_buf)
    for i = 1, n do remove_from_hand(s, play_buf[i]) end
    s.dollar_buffer = 0
    discard_cards(s, play_buf, n, false)
    s.money = s.money + s.dollar_buffer
    s.dollar_buffer = 0
    s.discards_left = s.discards_left - 1
    s.discards_used = s.discards_used + 1
    if s.discard_cost > 0 then s.money = s.money - s.discard_cost end
    draw_to_hand(s)
    return true
end

local function debuff_hand(s, n, text)
    if s.blind_disabled == 1 then return false end
    local b = s.blind
    s.blind_triggered = 0
    if b == BL_PSYCHIC and n < 5 then
        s.blind_triggered = 1
        return true
    end
    if b == BL_EYE then
        local bit = 2 ^ text
        if floor(s.blind_eye / bit) % 2 == 1 then
            s.blind_triggered = 1
            return true
        end
        s.blind_eye = s.blind_eye + bit
    end
    if b == BL_MOUTH then
        if s.blind_mouth > 0 and s.blind_mouth ~= text then
            s.blind_triggered = 1
            return true
        end
        s.blind_mouth = text
    end
    if b == BL_ARM then
        s.blind_triggered = 0
        if s.h_level[text] > 1 then
            s.blind_triggered = 1
            level_up(s, text, -1)
        end
    end
    if b == BL_OX then
        s.blind_triggered = 0
        if text == s.most_played then
            s.blind_triggered = 1
            s.money = 0
        end
    end
    return false
end

local function joker_individual_play(s, ek, bp, cid, ns, ctx_chips_mult)
    local id = s.j_id[ek]
    local smeared, pareidolia = ctx_chips_mult.smeared, ctx_chips_mult.pareidolia
    local prob = s.prob
    if id == J.hiker then
        s.c_bonus[cid] = s.c_bonus[cid] + 5
        return 0, 0, 0, 0
    elseif id == J.lucky_cat then
        if not bp and ctx_chips_mult.lucky == 1 then s.j_x[ek] = s.j_x[ek] + 0.25 end
        return 0, 0, 0, 0
    elseif id == J.wee then
        if not bp and get_id(s, cid) == 2 then s.j_ex[ek] = s.j_ex[ek] + 8 end
        return 0, 0, 0, 0
    elseif id == J.photograph then
        local first = 0
        for i = 1, ns do
            if is_face(s, sc_buf[i], false, pareidolia) then first = sc_buf[i] break end
        end
        if cid == first then return 0, 0, 2, 0 end
    elseif id == J["8_ball"] then
        if cons_free(s) and get_id(s, cid) == 8 and random_id(s, K_8BALL) < prob / 4 then
            s.consumable_buffer = s.consumable_buffer + 1
            add_pending_cons(s, 1)
        end
    elseif id == J.idol then
        if get_id(s, cid) == s.idol_rank and is_suit(s, cid, s.idol_suit, false, smeared) then return 0, 0, 2, 0 end
    elseif id == J.scary_face then
        if is_face(s, cid, false, pareidolia) then return 30, 0, 0, 0 end
    elseif id == J.smiley then
        if is_face(s, cid, false, pareidolia) then return 0, 5, 0, 0 end
    elseif id == J.ticket then
        if s.c_enh[cid] == E_GOLD then return 0, 0, 0, 4 end
    elseif id == J.scholar then
        if get_id(s, cid) == 14 then return 20, 4, 0, 0 end
    elseif id == J.walkie_talkie then
        local r = get_id(s, cid)
        if r == 10 or r == 4 then return 10, 4, 0, 0 end
    elseif id == J.business then
        if is_face(s, cid, false, pareidolia) and random_id(s, K_BUSINESS) < prob / 2 then return 0, 0, 0, 2 end
    elseif id == J.fibonacci then
        local r = get_id(s, cid)
        if r == 2 or r == 3 or r == 5 or r == 8 or r == 14 then return 0, 8, 0, 0 end
    elseif id == J.even_steven then
        local r = get_id(s, cid)
        if r <= 10 and r >= 0 and r % 2 == 0 then return 0, 4, 0, 0 end
    elseif id == J.odd_todd then
        local r = get_id(s, cid)
        if (r <= 10 and r >= 0 and r % 2 == 1) or r == 14 then return 31, 0, 0, 0 end
    elseif id == J.greedy_joker then
        if is_suit(s, cid, 4, false, smeared) then return 0, 3, 0, 0 end
    elseif id == J.lusty_joker then
        if is_suit(s, cid, 2, false, smeared) then return 0, 3, 0, 0 end
    elseif id == J.wrathful_joker then
        if is_suit(s, cid, 1, false, smeared) then return 0, 3, 0, 0 end
    elseif id == J.gluttenous_joker then
        if is_suit(s, cid, 3, false, smeared) then return 0, 3, 0, 0 end
    elseif id == J.rough_gem then
        if is_suit(s, cid, 4, false, smeared) then return 0, 0, 0, 1 end
    elseif id == J.onyx_agate then
        if is_suit(s, cid, 3, false, smeared) then return 0, 7, 0, 0 end
    elseif id == J.arrowhead then
        if is_suit(s, cid, 1, false, smeared) then return 50, 0, 0, 0 end
    elseif id == J.bloodstone then
        if is_suit(s, cid, 2, false, smeared) and random_id(s, K_BLOODSTONE) < prob / 2 then return 0, 0, 1.5, 0 end
    elseif id == J.ancient then
        if is_suit(s, cid, s.ancient_suit, false, smeared) then return 0, 0, 1.5, 0 end
    elseif id == J.triboulet then
        local r = get_id(s, cid)
        if r == 12 or r == 13 then return 0, 0, 2, 0 end
    end
    return 0, 0, 0, 0
end

local IND_PLAY = {}
for _, key in ipairs({"hiker", "lucky_cat", "wee", "photograph", "8_ball", "idol", "scary_face", "smiley", "ticket", "scholar",
    "walkie_talkie", "business", "fibonacci", "even_steven", "odd_todd", "greedy_joker", "lusty_joker", "wrathful_joker",
    "gluttenous_joker", "rough_gem", "onyx_agate", "arrowhead", "bloodstone", "ancient", "triboulet"}) do
    IND_PLAY[J[key]] = true
end

local REP_PLAY = {}
for _, key in ipairs({"sock_and_buskin", "hanging_chad", "dusk", "selzer", "hack"}) do REP_PLAY[J[key]] = true end

local IND_HAND = {}
for _, key in ipairs({"shoot_the_moon", "baron", "reserved_parking", "raised_fist"}) do IND_HAND[J[key]] = true end

local ctx = {smeared = false, pareidolia = false, lucky = 0}

local function joker_main(s, ek, bp, text, n_full, ns)
    local id = s.j_id[ek]
    local c = CFG[id]
    local present = EV.present
    if id == J.loyalty_card then
        local every = c.extra.every
        local rem = (every - 1 - (s.hands_played - s.j_h[ek])) % (every + 1)
        s.j_n[ek] = rem
        if rem == every then return 0, 0, c.extra.Xmult end
        return 0, 0, 0
    end
    local th = TYPE_HAND[id]
    if id ~= J.seeing_double and s.j_x[ek] > 1 and (th == 0 or present[th]) then
        return 0, 0, s.j_x[ek]
    end
    if T_MULT[id] > 0 and present[th] then return 0, T_MULT[id], 0 end
    if T_CHIPS[id] > 0 and present[th] then return T_CHIPS[id], 0, 0 end
    if id == J.half then
        if n_full <= 3 then return 0, 20, 0 end
    elseif id == J.abstract then
        return 0, s.n_jok * 3, 0
    elseif id == J.acrobat then
        if s.hands_left == 0 then return 0, 0, 3 end
    elseif id == J.mystic_summit then
        if s.discards_left == 0 then return 0, 15, 0 end
    elseif id == J.misprint then
        return 0, random_int_id(s, K_MISPRINT, 0, 23), 0
    elseif id == J.banner then
        if s.discards_left > 0 then return s.discards_left * 30, 0, 0 end
    elseif id == J.stuntman then
        return 250, 0, 0
    elseif id == J.matador then
        if s.blind_triggered == 1 then
            s.dollar_buffer = s.dollar_buffer + 8
        end
    elseif id == J.supernova then
        return 0, s.h_played[text], 0
    elseif id == J.ceremonial then
        if s.j_mult[ek] > 0 then return 0, s.j_mult[ek], 0 end
    elseif id == J.vagabond then
        if cons_free(s) and s.money <= 4 then
            s.consumable_buffer = s.consumable_buffer + 1
            add_pending_cons(s, 2)
        end
    elseif id == J.superposition then
        if cons_free(s) then
            local aces = 0
            for i = 1, ns do
                if get_id(s, sc_buf[i]) == 14 then aces = aces + 1 end
            end
            if aces >= 1 and present[8] then
                s.consumable_buffer = s.consumable_buffer + 1
                add_pending_cons(s, 3)
            end
        end
    elseif id == J.seance then
        if cons_free(s) and present[4] then
            s.consumable_buffer = s.consumable_buffer + 1
            add_pending_cons(s, 4)
        end
    elseif id == J.flower_pot then
        local h, d, sp, cl = 0, 0, 0, 0
        for i = 1, ns do
            local cid = sc_buf[i]
            if s.c_enh[cid] ~= E_WILD then
                if is_suit(s, cid, 2, true, ctx.smeared) and h == 0 then h = 1
                elseif is_suit(s, cid, 4, true, ctx.smeared) and d == 0 then d = 1
                elseif is_suit(s, cid, 1, true, ctx.smeared) and sp == 0 then sp = 1
                elseif is_suit(s, cid, 3, true, ctx.smeared) and cl == 0 then cl = 1 end
            end
        end
        for i = 1, ns do
            local cid = sc_buf[i]
            if s.c_enh[cid] == E_WILD then
                if is_suit(s, cid, 2, false, ctx.smeared) and h == 0 then h = 1
                elseif is_suit(s, cid, 4, false, ctx.smeared) and d == 0 then d = 1
                elseif is_suit(s, cid, 1, false, ctx.smeared) and sp == 0 then sp = 1
                elseif is_suit(s, cid, 3, false, ctx.smeared) and cl == 0 then cl = 1 end
            end
        end
        if h > 0 and d > 0 and sp > 0 and cl > 0 then return 0, 0, 3 end
    elseif id == J.seeing_double then
        local h, d, sp, cl = 0, 0, 0, 0
        for i = 1, ns do
            local cid = sc_buf[i]
            if s.c_enh[cid] ~= E_WILD then
                if is_suit(s, cid, 2, false, ctx.smeared) then h = h + 1 end
                if is_suit(s, cid, 4, false, ctx.smeared) then d = d + 1 end
                if is_suit(s, cid, 1, false, ctx.smeared) then sp = sp + 1 end
                if is_suit(s, cid, 3, false, ctx.smeared) then cl = cl + 1 end
            end
        end
        for i = 1, ns do
            local cid = sc_buf[i]
            if s.c_enh[cid] == E_WILD then
                if is_suit(s, cid, 3, false, ctx.smeared) and cl == 0 then cl = cl + 1
                elseif is_suit(s, cid, 4, false, ctx.smeared) and d == 0 then d = d + 1
                elseif is_suit(s, cid, 1, false, ctx.smeared) and sp == 0 then sp = sp + 1
                elseif is_suit(s, cid, 2, false, ctx.smeared) and h == 0 then h = h + 1 end
            end
        end
        if (h > 0 or d > 0 or sp > 0) and cl > 0 then return 0, 0, 2 end
    elseif id == J.wee or id == J.square or id == J.runner or id == J.ice_cream then
        return s.j_ex[ek], 0, 0
    elseif id == J.castle then
        if s.j_ex[ek] > 0 then return s.j_ex[ek], 0, 0 end
    elseif id == J.blue_joker then
        if s.n_deck > 0 then return 2 * s.n_deck, 0, 0 end
    elseif id == J.erosion then
        local d = s.starting_deck_size - n_playing(s)
        if d > 0 then return 0, 4 * d, 0 end
    elseif id == J.stone then
        local t = s.j_n[ek]
        if t > 0 then return 25 * t, 0, 0 end
    elseif id == J.steel_joker then
        local t = s.j_n[ek]
        if t > 0 then return 0, 0, 1 + 0.2 * t end
    elseif id == J.bull then
        local m = s.money + s.dollar_buffer
        if m > 0 then return 2 * max(0, m), 0, 0 end
    elseif id == J.drivers_license then
        if s.j_n[ek] >= 16 then return 0, 0, 3 end
    elseif id == J.blackboard then
        local black, all = 0, 0
        for i = 1, s.n_hand do
            all = all + 1
            local cid = s.hand[i]
            if EV.is_suit_flush(s, cid, 3, ctx.smeared) or EV.is_suit_flush(s, cid, 1, ctx.smeared) then black = black + 1 end
        end
        if black == all then return 0, 0, 3 end
    elseif id == J.stencil then
        if s.joker_limit - s.n_jok > 0 then return 0, 0, s.j_x[ek] end
    elseif id == J.swashbuckler or id == J.joker or id == J.trousers or id == J.ride_the_bus or id == J.flash
        or id == J.popcorn or id == J.green_joker or id == J.red_card then
        if s.j_mult[ek] > 0 then return 0, s.j_mult[ek], 0 end
    elseif id == J.fortune_teller then
        if s.tarot_used > 0 then return 0, s.tarot_used, 0 end
    elseif id == J.gros_michel then
        return 0, 15, 0
    elseif id == J.cavendish then
        return 0, 0, 3
    elseif id == J.card_sharp then
        if s.h_pround[text] > 1 then return 0, 0, 3 end
    elseif id == J.bootstraps then
        local m = floor((s.money + s.dollar_buffer) / 5)
        if m >= 1 then return 0, 2 * m, 0 end
    elseif id == J.caino then
        if s.j_n[ek] > 1 then return 0, 0, s.j_n[ek] end
    end
    return 0, 0, 0
end

local function update_dynamic(s)
    for k = 1, s.n_jok do
        local id = s.j_id[k]
        if id == J.throwback then
            s.j_x[k] = 1 + s.skips * 0.25
        elseif id == J.stencil then
            local x = s.joker_limit - s.n_jok
            for q = 1, s.n_jok do
                if s.j_id[q] == J.stencil then x = x + 1 end
            end
            s.j_x[k] = x
        elseif id == J.swashbuckler then
            local t = 0
            for q = 1, s.n_jok do
                if q ~= k then t = t + joker_sell(s, q) end
            end
            s.j_mult[k] = t
        elseif id == J.stone or id == J.steel_joker or id == J.drivers_license then
            local want = id == J.stone and E_STONE or id == J.steel_joker and E_STEEL or -1
            local t = 0
            for q = 1, s.n_cards do
                if s.c_alive[q] == 1 then
                    local e = s.c_enh[q]
                    if (want < 0 and e ~= 0) or e == want then t = t + 1 end
                end
            end
            s.j_n[k] = t
        end
    end
end
E.update_dynamic = update_dynamic

local end_round

local function play_eval(s, n)
    local cards = play_buf
    local four = find_joker(s, J.four_fingers)
    local shortcut = find_joker(s, J.shortcut)
    local smeared = find_joker(s, J.smeared)
    local pareidolia = find_joker(s, J.pareidolia)
    local splash = find_joker(s, J.splash)
    ctx.smeared, ctx.pareidolia = smeared, pareidolia
    local text = EV.evaluate(s, cards, n, four, shortcut, smeared, splash)
    local scoring = EV.scoring
    local ns = 0
    for i = 1, n do
        if scoring[i] then
            ns = ns + 1
            sc_buf[ns] = cards[i]
        end
    end
    s.h_played[text] = s.h_played[text] + 1
    s.h_pround[text] = s.h_pround[text] + 1
    s.last_hand = text
    s.h_vis[text] = 1
    update_dynamic(s)
    resolve_blueprints(s)
    local nj = s.n_jok
    local j_id = s.j_id
    local chips, mult = 0, 0
    local prob = s.prob
    if not debuff_hand(s, n, text) then
        local present = EV.present
        for k = 1, nj do
            local ek = eff_k[k]
            if ek > 0 then
                local id = j_id[ek]
                local bp = eff_bp[k] == 1
                if id == J.trousers and not bp then
                    if present[10] or present[6] then s.j_mult[ek] = s.j_mult[ek] + 2 end
                elseif id == J.space then
                    if random_id(s, K_SPACE) < prob / 4 then level_up(s, text, 1) end
                elseif id == J.square and not bp then
                    if n == 4 then s.j_ex[ek] = s.j_ex[ek] + 4 end
                elseif id == J.runner and not bp then
                    if present[8] then s.j_ex[ek] = s.j_ex[ek] + 15 end
                elseif id == J.midas_mask and not bp then
                    for i = 1, ns do
                        local cid = sc_buf[i]
                        if is_face(s, cid, false, pareidolia) then
                            s.c_enh[cid] = E_GOLD
                            s.c_pta[cid] = 0
                            s.c_perma_debuff[cid] = 0
                            blind_debuff_card(s, cid)
                        end
                    end
                elseif id == J.vampire and not bp then
                    local cnt = 0
                    for i = 1, ns do
                        local cid = sc_buf[i]
                        if s.c_enh[cid] ~= 0 and s.c_debuff[cid] == 0 then
                            cnt = cnt + 1
                            s.c_enh[cid] = 0
                            s.c_pta[cid] = 0
                            s.c_perma_debuff[cid] = 0
                            blind_debuff_card(s, cid)
                        end
                    end
                    if cnt > 0 then s.j_x[ek] = s.j_x[ek] + 0.1 * cnt end
                elseif id == J.todo_list then
                    if text == s.j_n[ek] then
                        s.dollar_buffer = s.dollar_buffer + 4
                    end
                elseif id == J.dna then
                    if s.round_hands_played == 0 and n == 1 then
                        local src = cards[1]
                        local cid = new_card(s, s.c_rank[src], s.c_suit[src], s.c_enh[src], s.c_ed[src], s.c_seal[src])
                        s.c_osuit[cid] = s.c_osuit[src]
                        s.c_bonus[cid] = s.c_bonus[src]
                        s.c_pta[cid] = s.c_pta[src]
                        s.c_perma_debuff[cid] = s.c_perma_debuff[src]
                        blind_debuff_card(s, cid)
                        s.deck_limit = s.deck_limit + 1
                        s.n_hand = s.n_hand + 1
                        s.hand[s.n_hand] = cid
                        playing_card_added(s, 1)
                    end
                elseif id == J.ride_the_bus and not bp then
                    local faces = false
                    for i = 1, ns do
                        if is_face(s, sc_buf[i], false, pareidolia) then faces = true end
                    end
                    if faces then s.j_mult[ek] = 0 else s.j_mult[ek] = s.j_mult[ek] + 1 end
                elseif id == J.obelisk and not bp then
                    local reset = true
                    local pm = s.h_played[text]
                    for h = 1, 12 do
                        if h ~= text and s.h_played[h] >= pm and s.h_vis[h] == 1 then reset = false end
                    end
                    if reset then
                        if s.j_x[ek] > 1 then s.j_x[ek] = 1 end
                    else
                        s.j_x[ek] = s.j_x[ek] + 0.2
                    end
                elseif id == J.green_joker and not bp then
                    s.j_mult[ek] = s.j_mult[ek] + 1
                end
            end
        end
        mult = s.h_mult[text]
        chips = s.h_chips[text]
        if s.blind == BL_FLINT and s.blind_disabled == 0 then
            s.blind_triggered = 1
            mult = max(floor(mult * 0.5 + 0.5), 1)
            chips = max(floor(chips * 0.5 + 0.5), 0)
        end
        local c_debuff, c_enh, c_seal, c_ed = s.c_debuff, s.c_enh, s.c_seal, s.c_ed
        for i = 1, ns do
            local cid = sc_buf[i]
            if c_debuff[cid] == 1 then
                s.blind_triggered = 1
            else
                local reps = 1
                if c_seal[cid] == SEAL_RED then reps = reps + 1 end
                for k = 1, nj do
                    local ek = eff_k[k]
                    if ek > 0 then
                        local id = j_id[ek]
                        if REP_PLAY[id] then
                            if id == J.sock_and_buskin then
                                if is_face(s, cid, false, pareidolia) then reps = reps + 1 end
                            elseif id == J.hanging_chad then
                                if cid == sc_buf[1] then reps = reps + 2 end
                            elseif id == J.dusk then
                                if s.hands_left == 0 then reps = reps + 1 end
                            elseif id == J.selzer then
                                reps = reps + 1
                            elseif id == J.hack then
                                local r = get_id(s, cid)
                                if r == 2 or r == 3 or r == 4 or r == 5 then reps = reps + 1 end
                            end
                        end
                    end
                end
                for _ = 1, reps do
                    local e = c_enh[cid]
                    local lucky = 0
                    if c_debuff[cid] == 0 then
                        local cc = card_chips(s, cid)
                        local cm = ENH_MULT[e]
                        if e == E_LUCKY then
                            if random_id(s, K_LUCKY_MULT) < prob / 5 then lucky = 1 else cm = 0 end
                        end
                        local cx = 0
                        if e == E_GLASS then cx = 2 end
                        local pd = 0
                        if c_seal[cid] == SEAL_GOLD then pd = pd + 3 end
                        if e == E_LUCKY then
                            if random_id(s, K_LUCKY_MONEY) < prob / 15 then
                                lucky = 1
                                pd = pd + 20
                            end
                        elseif e == E_GOLD then
                            pd = pd + 0
                        end
                        ctx.lucky = lucky
                        if cc > 0 then chips = chips + cc end
                        if cm > 0 then mult = mult + cm end
                        if pd > 0 then s.dollar_buffer = s.dollar_buffer + pd end
                        if cx > 0 then mult = mult * cx end
                        local ed = c_ed[cid]
                        if ed == ED_FOIL then chips = chips + 50
                        elseif ed == ED_HOLO then mult = mult + 10
                        elseif ed == ED_POLY then mult = mult * 1.5 end
                        for k = 1, nj do
                            local ek = eff_k[k]
                            if ek > 0 and IND_PLAY[j_id[ek]] then
                                local jc, jm, jx, jd = joker_individual_play(s, ek, eff_bp[k] == 1, cid, ns, ctx)
                                if jc ~= 0 then chips = chips + jc end
                                if jm ~= 0 then mult = mult + jm end
                                if jd ~= 0 then s.dollar_buffer = s.dollar_buffer + jd end
                                if jx ~= 0 then mult = mult * jx end
                            end
                        end
                    end
                end
            end
        end
        local hand = s.hand
        local nh = s.n_hand
        for i = 1, nh do
            local cid = hand[i]
            local reps = 1
            local j = 1
            while j <= reps do
                local hx = 0
                if c_debuff[cid] == 0 and c_enh[cid] == E_STEEL then hx = 1.5 end
                local any = hx > 0
                local nfx = 0
                for k = 1, nj do
                    local ek = eff_k[k]
                    if ek > 0 and IND_HAND[j_id[ek]] then
                        local id = j_id[ek]
                        local r = get_id(s, cid)
                        if id == J.shoot_the_moon then
                            if r == 12 then
                                nfx = nfx + 1
                                if c_debuff[cid] == 0 then
                                    tmp[nfx] = 1
                                    tmp2[nfx] = 13
                                else
                                    tmp[nfx] = 0
                                end
                            end
                        elseif id == J.baron then
                            if r == 13 then
                                nfx = nfx + 1
                                if c_debuff[cid] == 0 then
                                    tmp[nfx] = 2
                                    tmp2[nfx] = 1.5
                                else
                                    tmp[nfx] = 0
                                end
                            end
                        elseif id == J.reserved_parking then
                            if is_face(s, cid, false, pareidolia) and random_id(s, K_PARKING) < prob / 2 then
                                nfx = nfx + 1
                                if c_debuff[cid] == 0 then
                                    tmp[nfx] = 3
                                    tmp2[nfx] = 1
                                else
                                    tmp[nfx] = 0
                                end
                            end
                        elseif id == J.raised_fist then
                            local tm, tid, rc = 15, 15, 0
                            for q = 1, nh do
                                local qc = hand[q]
                                if tid >= s.c_rank[qc] and c_enh[qc] ~= E_STONE then
                                    tm = NOMINAL[s.c_rank[qc]]
                                    tid = s.c_rank[qc]
                                    rc = qc
                                end
                            end
                            if rc == cid then
                                nfx = nfx + 1
                                if c_debuff[cid] == 0 then
                                    tmp[nfx] = 1
                                    tmp2[nfx] = 2 * tm
                                else
                                    tmp[nfx] = 0
                                end
                            end
                        end
                    end
                end
                if j == 1 then
                    if any or nfx > 0 then
                        if c_debuff[cid] == 0 and c_seal[cid] == SEAL_RED then reps = reps + 1 end
                        for k = 1, nj do
                            local ek = eff_k[k]
                            if ek > 0 and j_id[ek] == J.mime then reps = reps + 1 end
                        end
                    end
                end
                if hx > 0 then mult = mult * hx end
                for q = 1, nfx do
                    local t = tmp[q]
                    if t == 1 then mult = mult + tmp2[q]
                    elseif t == 2 then mult = mult * tmp2[q]
                    elseif t == 3 then
                        s.dollar_buffer = s.dollar_buffer + tmp2[q]
                    end
                end
                j = j + 1
            end
        end
        for k = 1, nj + s.n_cons do
            if k <= nj then
                local ed = s.j_debuff[k] == 0 and s.j_ed[k] or 0
                if ed == ED_FOIL then chips = chips + 50 elseif ed == ED_HOLO then mult = mult + 10 end
                local ek = eff_k[k]
                if ek > 0 then
                    local jc, jm, jx = joker_main(s, ek, eff_bp[k] == 1, text, n, ns)
                    if jm ~= 0 then mult = mult + jm end
                    if jc ~= 0 then chips = chips + jc end
                    if jx ~= 0 then mult = mult * jx end
                end
                local rar = RARITY[j_id[k]]
                for o = 1, nj do
                    local eo = eff_k[o]
                    if eo > 0 and j_id[eo] == J.baseball and rar == 2 and eo ~= k then mult = mult * 1.5 end
                end
                if ed == ED_POLY then mult = mult * 1.5 end
            else
                local ck = s.cons[k - nj]
                if s.used_v[D.VOUCHER_ID.v_observatory] == 1 and D.PLANET_HAND[ck] == text then mult = mult * 1.5 end
            end
        end
        if s.chips_cap == 1 then chips = min(chips, max(s.money, 0)) end
        if s.plasma == 1 then
            local tot = chips + mult
            chips = floor(tot / 2)
            mult = floor(tot / 2)
        end
        local nd = 0
        for i = 1, ns do
            local cid = sc_buf[i]
            local destroyed = false
            for k = 1, nj do
                local ek = eff_k[k]
                if ek > 0 and eff_bp[k] == 0 and j_id[ek] == J.sixth_sense and n == 1 and get_id(s, cards[1]) == 6 and s.round_hands_played == 0 then
                    if cons_free(s) then
                        s.consumable_buffer = s.consumable_buffer + 1
                        add_pending_cons(s, 5)
                    end
                    destroyed = true
                    break
                end
            end
            if c_enh[cid] == E_GLASS and c_debuff[cid] == 0 and random_id(s, K_GLASS) < prob / 4 then
                destroyed = true
            end
            if destroyed then
                nd = nd + 1
                tmp2[nd] = cid
            end
        end
        if nd > 0 then
            for k = 1, nj do
                if s.j_debuff[k] == 0 then
                    local id = j_id[k]
                    if id == J.caino then
                        local faces = 0
                        for q = 1, nd do
                            if is_face(s, tmp2[q], false, pareidolia) then faces = faces + 1 end
                        end
                        s.j_n[k] = s.j_n[k] + faces
                    elseif id == J.glass then
                        local g = 0
                        for q = 1, nd do
                            if c_enh[tmp2[q]] == E_GLASS then g = g + 1 end
                        end
                        s.j_x[k] = s.j_x[k] + 0.75 * g
                    end
                end
            end
            for q = 1, nd do s.c_alive[tmp2[q]] = 0 end
        end
    else
        chips, mult = 0, 0
        for k = 1, nj do
            local ek = eff_k[k]
            if ek > 0 and j_id[ek] == J.matador and s.blind_triggered == 1 then
                s.dollar_buffer = s.dollar_buffer + 8
            end
        end
    end
    local gained = floor(chips * mult)
    s.chips = s.chips + gained
    for k = 1, nj do
        local ek = eff_k[k]
        if ek > 0 and eff_bp[k] == 0 then
            local id = j_id[ek]
            if id == J.ice_cream then
                if s.j_ex[ek] - 5 <= 0 then queue_kill(s, ek) else s.j_ex[ek] = s.j_ex[ek] - 5 end
            elseif id == J.selzer then
                if s.j_ex[ek] - 1 <= 0 then queue_kill(s, ek) else s.j_ex[ek] = s.j_ex[ek] - 1 end
            end
        end
    end
    if s.debuff_played == 1 then
        for i = 1, ns do
            s.c_perma_debuff[sc_buf[i]] = 1
            s.c_debuff[sc_buf[i]] = 1
        end
    end
    flush_kills(s)
    return gained, text, chips, mult
end

local function play_cards(s, pos)
    for c = 1, s.n_cards do s.c_forced[c] = 0 end
    s.blind_triggered = 0
    local n = sorted_selection(s, pos, play_buf)
    s.hands_left = s.hands_left - 1
    for i = 1, n do
        local cid = play_buf[i]
        remove_from_hand(s, cid)
        s.c_times[cid] = s.c_times[cid] + 1
        s.c_pta[cid] = 1
    end
    s.dollar_buffer = 0
    if s.blind_disabled == 0 then
        local b = s.blind
        if b == BL_HOOK then
            local nh = s.n_hand
            if nh > 0 then
                for i = 1, nh do tmp2[i] = s.hand[i] end
                local m = nh
                local picked = 0
                local hook_buf = {}
                for _ = 1, 2 do
                    if m > 0 and picked < nh then
                        local r = element_index_id(s, K_HOOK, m)
                        local ii = nth_by_uid(s, tmp2, m, r)
                        hook_buf[#hook_buf + 1] = tmp2[ii]
                        table.remove(tmp2, ii)
                        m = m - 1
                        picked = picked + 1
                    end
                end
                local hb = {}
                for i = 1, nh do
                    local cid = s.hand[i]
                    for q = 1, #hook_buf do
                        if hook_buf[q] == cid then hb[#hb + 1] = cid end
                    end
                end
                for q = 1, #hb do remove_from_hand(s, hb[q]) end
                discard_cards(s, hb, #hb, true)
            end
            s.blind_triggered = 1
        elseif b == BL_HEART then
            if s.n_jok > 0 then
                s.blind_triggered = 1
                s.blind_prepped = 1
            end
        elseif b == BL_FISH then
            s.blind_prepped = 1
        elseif b == BL_TOOTH then
            s.money = s.money - n
            s.blind_triggered = 1
        end
    end
    local gained, text = play_eval(s, n)
    s.money = s.money + s.dollar_buffer
    s.dollar_buffer = 0
    for i = 1, n do
        local cid = play_buf[i]
        if s.c_alive[cid] == 1 then
            s.n_disc = s.n_disc + 1
            s.disc[s.n_disc] = cid
        end
    end
    s.hands_played = s.hands_played + 1
    s.round_hands_played = s.round_hands_played + 1
    return gained, text
end

function E.play(s, pos)
    if s.phase ~= "play" or s.hands_left <= 0 or not check_positions(s, pos) then return false end
    local gained, text = play_cards(s, pos)
    if s.chips - s.blind_chips >= 0 or s.hands_left < 1 then
        end_round(s)
    else
        draw_to_hand(s)
    end
    return true, gained, text
end

end_round = function(s)
    if s.phase ~= "play" then return end
    if s.n_pq > 0 then E.flush_pending(s) end
    local game_over = s.chips - s.blind_chips < 0
    local rentals = 0
    resolve_blueprints(s)
    local is_boss = s.blind > 2
    for k = 1, s.n_jok do
        local id = s.j_id[k]
        if s.j_debuff[k] == 0 and not is_killed(s, k) then
            if id == J.campfire and is_boss and s.j_x[k] > 1 then s.j_x[k] = 1
            elseif id == J.rocket and is_boss then s.j_ex[k] = s.j_ex[k] + 2
            elseif id == J.turtle_bean then
                if s.j_ex[k] - 1 <= 0 then queue_kill(s, k)
                else
                    s.j_ex[k] = s.j_ex[k] - 1
                    s.hand_size = s.hand_size - 1
                end
            elseif id == J.invisible then s.j_n[k] = s.j_n[k] + 1
            elseif id == J.popcorn then
                if s.j_mult[k] - 4 <= 0 then queue_kill(s, k) else s.j_mult[k] = s.j_mult[k] - 4 end
            elseif id == J.todo_list then
                local cnt = hand_pairs_visible(s, s.j_n[k], tmp)
                s.j_n[k] = tmp[element_index_id(s, K_TODO, cnt)]
            elseif id == J.egg then
                s.j_ev[k] = s.j_ev[k] + 3
            elseif id == J.gift then
                for q = 1, s.n_jok do s.j_ev[q] = s.j_ev[q] + 1 end
                for q = 1, s.n_cons do s.cons_ev[q] = s.cons_ev[q] + 1 end
            elseif id == J.hit_the_road and s.j_x[k] > 1 then s.j_x[k] = 1
            elseif id == J.gros_michel or id == J.cavendish then
                local key = id == J.cavendish and K_CAV or K_GROS
                local odds = id == J.cavendish and 1000 or 6
                if random_id(s, key) < s.prob / odds then
                    queue_kill(s, k)
                    if id == J.gros_michel then s.gros_extinct = 1 end
                end
            elseif id == J.mr_bones and game_over and s.chips / s.blind_chips >= 0.25 then
                game_over = false
                queue_kill(s, k)
            end
        end
        if s.j_rental[k] == 1 then rentals = rentals + 1 end
        if s.j_perish[k] > 0 then
            if s.j_perish[k] == 1 then
                s.j_perish[k] = 0
                set_joker_debuff(s, k, true)
            else
                s.j_perish[k] = s.j_perish[k] - 1
            end
        end
    end
    if game_over then n_kill = 0 else flush_kills(s) end
    if not game_over then s.money = s.money - 3 * rentals end
    local won = s.ante == s.win_ante and is_boss and s.won == 0
    if won then s.won = 1 end
    if game_over then
        s.game_over = 1
        s.phase = "game_over"
        return
    end
    s.unused_discards = s.unused_discards + s.discards_left
    if is_boss then
        local best, bp = 12, -1
        local order = D.HAND_PAIRS_ORDER
        for i = 1, 12 do
            local h = order[i]
            if s.h_played[h] > bp then
                bp = s.h_played[h]
                best = h
            end
        end
        s.most_played = best
    end
    resolve_blueprints(s)
    local nh = s.n_hand
    for i = 1, nh do
        local cid = s.hand[i]
        local reps = 1
        local j = 1
        while j <= reps do
            local gold = s.c_debuff[cid] == 0 and s.c_enh[cid] == E_GOLD
            local blue = s.c_debuff[cid] == 0 and s.c_seal[cid] == SEAL_BLUE and cons_free(s)
            if blue then
                s.consumable_buffer = s.consumable_buffer + 1
                add_pending_cons(s, 8)
            end
            if j == 1 and (gold or blue) then
                if s.c_seal[cid] == SEAL_RED and s.c_debuff[cid] == 0 then reps = reps + 1 end
                for k = 1, s.n_jok do
                    local ek = eff_k[k]
                    if ek > 0 and s.j_id[ek] == J.mime then reps = reps + 1 end
                end
            end
            if gold then s.money = s.money + 3 end
            j = j + 1
        end
    end
    for i = 1, nh do
        s.n_disc = s.n_disc + 1
        s.disc[s.n_disc] = s.hand[i]
        s.hand[i] = nil
    end
    s.n_hand = 0
    s.consumable_buffer = 0
    if is_boss then
        if s.set_eternal_ante > 0 and s.ante == s.set_eternal_ante then
            for k = 1, s.n_jok do
                if JOKERS[s.j_id[k]].eternal and s.j_perish[k] < 0 then s.j_eternal[k] = 1 end
            end
        end
        if s.set_joker_slots_ante > 0 and s.ante == s.set_joker_slots_ante then s.joker_limit = 0 end
        s.ante = s.ante + 1
    end
    local m, nd = s.n_disc, s.n_deck
    local deck, disc = s.deck, s.disc
    if m > 0 then
        for i = nd, 1, -1 do deck[i + m] = deck[i] end
        for j = 1, m do
            deck[j] = disc[j]
            disc[j] = nil
        end
        s.n_deck = nd + m
    end
    s.n_disc = 0
    if s.blind == BL_SMALL then
        s.state_small = 3
        s.blind_on_deck = 2
        s.state_big = 1
    elseif s.blind == BL_BIG then
        s.state_big = 3
        s.blind_on_deck = 3
        s.state_boss = 1
    else
        s.voucher = get_next_voucher(s)
        s.state_boss = 3
        for c = 1, s.n_cards do s.c_pta[c] = 0 end
    end
    if s.temp_handsize ~= 0 then
        s.hand_size = s.hand_size - s.temp_handsize
        s.temp_handsize = 0
    end
    if s.temp_reroll >= 0 then
        s.temp_reroll = -1
        E.I.calculate_reroll_cost(s, true)
    end
    reset_round_cards(s)
    for c = 1, s.n_cards do s.c_forced[c] = 0 end
    local dollars = 0
    if s.chips - s.blind_chips >= 0 then dollars = dollars + s.blind_dollars end
    if s.anaglyph == 1 and is_boss then E.add_tag(s, D.TAG_ID.tag_double, 0) end
    if s.hands_left > 0 and s.no_extra_hand_money == 0 then dollars = dollars + s.hands_left * s.money_per_hand end
    if s.discards_left > 0 and s.money_per_discard > 0 then dollars = dollars + s.discards_left * s.money_per_discard end
    for k = 1, s.n_jok do
        if s.j_debuff[k] == 0 then
            local id = s.j_id[k]
            if id == J.golden then dollars = dollars + 4
            elseif id == J.cloud_9 then
                local t = 0
                for c = 1, s.n_cards do
                    if s.c_alive[c] == 1 and s.c_enh[c] ~= E_STONE and s.c_rank[c] == 9 then t = t + 1 end
                end
                if t > 0 then dollars = dollars + t end
            elseif id == J.rocket then dollars = dollars + s.j_ex[k]
            elseif id == J.satellite then
                if s.planets_used > 0 then dollars = dollars + s.planets_used end
            elseif id == J.delayed_grat then
                if s.discards_used == 0 and s.discards_left > 0 then dollars = dollars + s.discards_left * 2 end
            end
        end
    end
    local i = 1
    while i <= s.n_tags do
        if D.TAGS[s.tags[i]].key == "tag_investment" and is_boss then
            dollars = dollars + 25
            for q = i, s.n_tags - 1 do s.tags[q] = s.tags[q + 1] s.tag_hand[q] = s.tag_hand[q + 1] s.tag_trig[q] = s.tag_trig[q + 1] end
            s.tags[s.n_tags] = nil
            s.tag_hand[s.n_tags] = nil
            s.tag_trig[s.n_tags] = nil
            s.n_tags = s.n_tags - 1
        else
            i = i + 1
        end
    end
    if s.money >= 5 and s.no_interest == 0 then
        dollars = dollars + s.interest_amount * min(floor(s.money / 5), s.interest_cap / 5)
    end
    s.round_dollars = dollars
    if s.blind == BL_MANACLE and s.blind_disabled == 0 then s.hand_size = s.hand_size + 1 end
    s.blind_disabled = 0
    for k = 1, s.n_jok do s.j_flip[k] = 0 end
    s.blind = 0
    s.blind_chips = 0
    s.blind_suit = 0
    refresh_debuffs(s)
    for k = 1, s.n_jok do set_joker_debuff(s, k, false) end
    s.facing_blind = 0
    s.phase = won and "win" or "round_eval"
end

E.end_round = function(s) return end_round(s) end

function E.cash_out(s)
    if s.phase ~= "round_eval" then return false end
    shuffle_deck(s, ante_key("cashout", s.ante))
    s.discards_left = max(0, s.resets_discards + s.bonus_discards)
    s.hands_left = max(1, s.resets_hands + s.bonus_hands)
    s.money = s.money + s.round_dollars
    s.prev_round_dollars = s.money
    s.round_dollars = 0
    if s.state_boss == 3 then
        s.blind_ante = s.ante
        s.tag_small = get_next_tag(s)
        s.tag_big = get_next_tag(s)
        s.state_small, s.state_big, s.state_boss = 1, 0, 0
        s.blind_on_deck = 1
        s.boss_choice = get_new_boss(s)
        s.boss_rerolled = 0
    end
    s.chips = 0
    s.shop_free, s.shop_d6 = 0, 0
    E.I.enter_shop(s)
    return true
end

function E.step(s, a)
    local t = a.type
    local ok
    if t == "select" then ok = E.select_blind(s)
    elseif t == "skip" then
        if s.phase == "pack" then ok = E.skip_pack(s) else ok = E.skip_blind(s) end
    elseif t == "reroll_boss" then ok = E.reroll_boss(s)
    elseif t == "play" then ok = E.play(s, a.cards)
    elseif t == "discard" then ok = E.discard(s, a.cards)
    elseif t == "cash_out" then ok = E.cash_out(s)
    elseif t == "leave" then ok = E.leave_shop(s)
    elseif t == "buy" then ok = E.buy(s, a.card, false)
    elseif t == "buy_and_use" then ok = E.buy(s, a.card, true)
    elseif t == "sell" then ok = E.sell(s, a.area, a.card)
    elseif t == "use" then ok = E.use(s, a.card, a.targets)
    elseif t == "redeem" then ok = E.redeem(s, a.card)
    elseif t == "open" then ok = E.open(s, a.card)
    elseif t == "reroll" then ok = E.reroll(s)
    elseif t == "pick" then ok = E.pick(s, a.card, a.targets)
    elseif t == "reorder_jokers" then ok = E.reorder(s, a.order)
    elseif t == "endless" then
        ok = s.phase == "win"
        if ok then s.phase = "round_eval" end
    else ok = false end
    if ok then
        if s.n_pq > 0 then E.flush_pending(s) end
        if s.lux_x > 0 then lux_sync(s) end
        if s.phase == "blind_select" then ensure_orbital(s) end
        s.step = s.step + 1
    end
    return ok
end

function E.preview_into(scratch, s, pos)
    ST.copy_into(scratch, s)
    for c = 1, scratch.n_cards do scratch.c_forced[c] = 0 end
    local n = sorted_selection(scratch, pos, play_buf)
    for i = 1, n do remove_from_hand(scratch, play_buf[i]) end
    scratch.hands_left = scratch.hands_left - 1
    scratch.dollar_buffer = 0
    local gained, text = play_eval(scratch, n)
    return gained, text
end

E.play_eval = play_eval
E.play_buf = play_buf

E.I = {
    find_joker = find_joker, count_joker = count_joker, new_card = new_card, level_up = level_up, joker_sell = joker_sell,
    sort_hand = sort_hand, draw_n = draw_n, blind_debuff_card = blind_debuff_card, disable_blind = disable_blind,
    hand_pairs_visible = hand_pairs_visible, remove_joker_slot = remove_joker_slot, joker_pick_by_uid = joker_pick_by_uid,
    nth_by_uid = nth_by_uid, is_face = is_face, resolve_blueprints = function(s) resolve_blueprints(s) end,
    eff_k = eff_k, eff_bp = eff_bp, playing_card_added = playing_card_added,
    SHOP_FIELDS = ST.SHOP_ARRAYS, PACK_FIELDS = ST.PACK_ARRAYS, JOKER_FIELDS = ST.JOKER_ARRAYS,
}
require("bot.sim.econ")(E, E.I)

return E
