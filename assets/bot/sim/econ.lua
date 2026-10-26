local rng = require("bot.sim.rng")
local D = require("bot.sim.data")
local DC = require("bot.sim.data_centers")

local floor, max, min = math.floor, math.max, math.min
local key_id, random_id, element_index_id, shuffle_id = rng.key_id, rng.random_id, rng.element_index_id, rng.shuffle_id
local random_int_id = rng.random_int_id
local key_names = rng.key_names

local CONS, CONS_ID = {}, {}
local SET_TAROT, SET_PLANET, SET_SPECTRAL = 1, 2, 3
local POOL = {{}, {}, {}}
for set_i, name in ipairs({"Tarot", "Planet", "Spectral"}) do
    for _, c in ipairs(DC[name]) do
        local e = {key = c.key, name = c.name, set = set_i, cost = c.cost, config = c.config, order = c.order}
        if c.config.hand_type then e.hand = D.HAND_ID[c.config.hand_type] end
        CONS[#CONS + 1] = e
        CONS_ID[c.key] = #CONS
        POOL[set_i][#POOL[set_i] + 1] = #CONS
    end
end
D.CONS, D.CONS_ID = CONS, CONS_ID
local PLANET_OF_HAND = {}
for i, c in ipairs(CONS) do if c.hand then PLANET_OF_HAND[c.hand] = i end end
local C_SOUL, C_BH, C_FOOL = CONS_ID.c_soul, CONS_ID.c_black_hole, CONS_ID.c_fool
local C_STRENGTH, C_PLUTO, C_INCANT = CONS_ID.c_strength, CONS_ID.c_pluto, CONS_ID.c_incantation

local BOOST, BOOST_ID = DC.Booster, {}
local KIND_ID = {Arcana = 1, Celestial = 2, Spectral = 3, Standard = 4, Buffoon = 5}
for i, b in ipairs(BOOST) do
    BOOST_ID[b.key] = i
    b.kind_id = KIND_ID[b.kind]
end
D.BOOST, D.BOOST_ID = BOOST, BOOST_ID
local VEXTRA, VCOST = {}, {}
for i, v in ipairs(DC.Voucher) do
    assert(D.VOUCHERS[i].key == v.key)
    VEXTRA[i] = v.config.extra
    VCOST[i] = v.cost
end
local V = D.VOUCHER_ID

local JOKERS = D.JOKERS
local JPOOL = {{}, {}, {}, {}}
for i, j in ipairs(JOKERS) do JPOOL[j.rarity][#JPOOL[j.rarity] + 1] = i end
local GATE = {}
local TAG = D.TAG_ID
local TAGS = DC.Tag

local T_JOKER, T_TAROT, T_PLANET, T_SPECTRAL, T_BASE, T_ENH, T_TP = 1, 2, 3, 4, 5, 6, 7
local TNAME = {"Joker", "Tarot", "Planet", "Spectral", "Base", "Enhanced", "Tarot_Planet"}
local A_SHOP, A_PACK, A_JOK, A_CONS = 1, 2, 3, 4
local K_JOKER, K_CONS, K_CARD = 1, 2, 3
local ED_FOIL, ED_HOLO, ED_POLY, ED_NEG = 1, 2, 3, 4

local kc = {}
local function k3(a, ante, b)
    local t = kc[a]
    if not t then t = {} kc[a] = t end
    local u = t[b]
    if not u then u = {} t[b] = u end
    local id = u[ante]
    if not id then
        id = key_id(a .. ante .. b)
        u[ante] = id
    end
    return id
end

local kpc = {}
local function kp(a, b, ante)
    local t = kpc[a]
    if not t then t = {} kpc[a] = t end
    local u = t[b]
    if not u then u = {} t[b] = u end
    local id = u[ante]
    if not id then
        id = key_id(a .. b .. ante)
        u[ante] = id
    end
    return id
end

local kplain = {}
local function k1(a)
    local id = kplain[a]
    if not id then id = key_id(a) kplain[a] = id end
    return id
end

return function(E, I)
    local J = E.J
    local find_joker, count_joker, new_card = I.find_joker, I.count_joker, I.new_card
    local level_up, joker_sell = I.level_up, I.joker_sell
    local sort_hand, draw_n = I.sort_hand, I.draw_n
    local blind_debuff_card, disable_blind = I.blind_debuff_card, I.disable_blind
    local hand_pairs_visible, remove_joker_slot = I.hand_pairs_visible, I.remove_joker_slot
    local joker_pick_by_uid, nth_by_uid = I.joker_pick_by_uid, I.nth_by_uid
    local is_face, resolve_blueprints = I.is_face, I.resolve_blueprints
    local eff_k, eff_bp = I.eff_k, I.eff_bp
    local tmp, tmp2 = {}, {}

    GATE[J.steel_joker] = D.E_STEEL
    GATE[J.stone] = D.E_STONE
    GATE[J.lucky_cat] = D.E_LUCKY
    GATE[J.ticket] = D.E_GOLD
    GATE[J.glass] = D.E_GLASS
    local K_TODO = key_id("to_do")

    local mark_j, mark_c, mark_v, gen = {}, {}, {}, 0
    local cur_use = 0

    local function build_marks(s, want_j, want_c)
        gen = gen + 1
        local g = gen
        if want_j then
            for k = 1, s.n_jok do mark_j[s.j_id[k]] = g end
            for i = 1, s.n_sj do if s.sj_kind[i] == K_JOKER then mark_j[s.sj_id[i]] = g end end
            for i = 1, s.n_pk do if s.pk_kind[i] == K_JOKER then mark_j[s.pk_id[i]] = g end end
        end
        if want_c then
            for i = 1, s.n_cons do mark_c[CONS_ID[s.cons[i]]] = g end
            for i = 1, s.n_sj do if s.sj_kind[i] == K_CONS then mark_c[s.sj_id[i]] = g end end
            for i = 1, s.n_pk do if s.pk_kind[i] == K_CONS then mark_c[s.pk_id[i]] = g end end
            if cur_use > 0 then mark_c[cur_use] = g end
        end
        for i = 1, s.n_sv do mark_v[s.sv_id[i]] = g end
    end

    local function banned(s, key)
        local b = s.ban
        return b ~= 0 and b[key] == true
    end

    local function has_enh(s, e)
        for c = 1, s.n_cards do
            if s.c_alive[c] == 1 and s.c_enh[c] == e then return true end
        end
        return false
    end

    local pool_buf = {}

    local GROS, CAV = J.gros_michel, J.cavendish
    local function joker_pool(s, r, showman)
        local list = JPOOL[r]
        local n, sz = #list, 0
        local ban = s.ban
        for i = 1, n do
            local id = list[i]
            local ok = not (mark_j[id] == gen and not showman)
            if ok and GATE[id] then ok = has_enh(s, GATE[id]) end
            if ok and id == GROS and s.gros_extinct == 1 then ok = false end
            if ok and id == CAV and s.gros_extinct ~= 1 then ok = false end
            if ok and ban ~= 0 and ban[JOKERS[id].key] then ok = false end
            if ok then pool_buf[i] = id sz = sz + 1 else pool_buf[i] = 0 end
        end
        if sz == 0 then pool_buf[1] = J.joker return 1 end
        return n
    end

    local function cons_pool(s, set, showman)
        local list = POOL[set]
        local n, sz = #list, 0
        for i = 1, n do
            local id = list[i]
            local c = CONS[id]
            local ok = not (mark_c[id] == gen and not showman)
            if ok and c.config.softlock and s.h_played[c.hand] <= 0 then ok = false end
            if id == C_SOUL or id == C_BH then ok = false end
            if ok and banned(s, c.key) then ok = false end
            if ok then pool_buf[i] = id sz = sz + 1 else pool_buf[i] = 0 end
        end
        if sz == 0 then
            pool_buf[1] = set == SET_TAROT and C_STRENGTH or set == SET_PLANET and C_PLUTO or C_INCANT
            return 1
        end
        return n
    end

    local function pick_pool(s, n, kid)
        local v = pool_buf[element_index_id(s, kid, n)]
        local it = 1
        while v == 0 do
            it = it + 1
            v = pool_buf[element_index_id(s, key_id(key_names[kid] .. "_resample" .. it), n)]
        end
        return v
    end

    local function poll_edition(s, kid, mod, no_neg, guaranteed)
        local p = random_id(s, kid)
        if guaranteed then
            if p > 1 - 0.003 * 25 and not no_neg then return ED_NEG
            elseif p > 1 - 0.006 * 25 then return ED_POLY
            elseif p > 1 - 0.02 * 25 then return ED_HOLO
            elseif p > 1 - 0.04 * 25 then return ED_FOIL end
        else
            local rate = s.edition_rate
            if p > 1 - 0.003 * mod and not no_neg then return ED_NEG
            elseif p > 1 - 0.006 * rate * mod then return ED_POLY
            elseif p > 1 - 0.02 * rate * mod then return ED_HOLO
            elseif p > 1 - 0.04 * rate * mod then return ED_FOIL end
        end
        return 0
    end
    I.poll_edition = poll_edition

    local function roll_todo(s, old)
        local cnt = hand_pairs_visible(s, old, tmp)
        return tmp[element_index_id(s, K_TODO, cnt)]
    end
    I.roll_todo = roll_todo

    local JR = {"Joker1", "Joker2", "Joker3", "Joker4"}

    local R = {kind = 0, id = 0, ed = 0, et = 0, per = -1, rent = 0, cid = 0, n = 0, uid = 0}

    local function create_card(s, typ, area, legendary, rarity, soulable, forced, app)
        local ante = s.ante
        local is_c = typ == T_TAROT or typ == T_PLANET or typ == T_SPECTRAL or typ == T_TP
        if typ == T_JOKER or is_c then build_marks(s, typ == T_JOKER, is_c) end
        local showman = (typ == T_JOKER or is_c) and find_joker(s, J.ring_master)
        R.ed, R.et, R.per, R.rent, R.cid, R.n = 0, 0, -1, 0, 0, 0
        s.next_uid = s.next_uid + 1
        R.uid = s.next_uid
        if not forced and soulable and not banned(s, "c_soul") then
            if typ == T_TAROT or typ == T_SPECTRAL or typ == T_TP then
                if not (mark_c[C_SOUL] == gen and not showman) then
                    if random_id(s, kp("soul_", TNAME[typ], ante)) > 0.997 then forced = C_SOUL end
                end
            end
            if typ == T_PLANET or typ == T_SPECTRAL then
                if not (mark_c[C_BH] == gen and not showman) then
                    if random_id(s, kp("soul_", TNAME[typ], ante)) > 0.997 then forced = C_BH end
                end
            end
        end
        if forced and banned(s, CONS[forced].key) then forced = nil end
        if typ == T_BASE then
            R.kind = K_CARD
        elseif forced then
            R.kind = K_CONS
            R.id = forced
        elseif typ == T_JOKER then
            local r = rarity or random_id(s, k3("rarity", ante, app))
            r = (legendary and 4) or (r > 0.95 and 3) or (r > 0.7 and 2) or 1
            local n = joker_pool(s, r, showman)
            local kid = legendary and k1("Joker4") or kp(JR[r], app, ante)
            R.kind = K_JOKER
            R.id = pick_pool(s, n, kid)
        elseif typ == T_ENH then
            local n = 8
            local sz = 0
            for i = 1, 8 do
                if banned(s, D.ENH_KEYS[i]) then pool_buf[i] = 0 else pool_buf[i] = i sz = sz + 1 end
            end
            if sz == 0 then pool_buf[1] = 0 n = 1 end
            R.kind = K_CARD
            R.id = pick_pool(s, n, kp("Enhanced", app, ante))
        else
            local set = typ == T_TAROT and SET_TAROT or typ == T_PLANET and SET_PLANET or SET_SPECTRAL
            local n = cons_pool(s, set, showman)
            R.kind = K_CONS
            R.id = pick_pool(s, n, kp(TNAME[typ], app, ante))
        end
        if R.kind == K_CARD then
            local pi = element_index_id(s, kp("front", app, ante), 52)
            local pc = D.P_CARDS_ORDER[pi]
            local cid = new_card(s, pc[1], pc[2], typ == T_ENH and R.id or 0)
            s.c_alive[cid] = 0
            R.cid = cid
            R.id = 0
            return R
        end
        if R.kind == K_JOKER then
            local id = R.id
            local j = JOKERS[id]
            if id == J.todo_list then R.n = roll_todo(s, 0) end
            if s.all_eternal == 1 and j.eternal then R.et = 1 end
            if area == A_SHOP or area == A_PACK then
                local poll = random_id(s, k3(area == A_PACK and "packetper" or "etperpoll", ante, ""))
                if s.eternals_on == 1 and poll > 0.7 then
                    if j.eternal and R.per < 0 then R.et = 1 end
                elseif s.perish_on == 1 and poll > 0.4 and poll <= 0.7 then
                    if j.perishable and R.et == 0 then R.per = 5 end
                end
                if s.rentals_on == 1 and random_id(s, k3(area == A_PACK and "packssjr" or "ssjr", ante, "")) > 0.7 then R.rent = 1 end
            end
            R.ed = poll_edition(s, kp("edi", app, ante), 1, false, false)
        end
        return R
    end
    I.create_card = create_card

    local function astronomer(s)
        return find_joker(s, J.astronomer)
    end

    local function calc_cost(s, base, ed, planetish, booster, rental, coupon)
        local extra = s.inflation + D.ED_EXTRA_COST[ed]
        local cost = max(1, floor((base + extra + 0.5) * (100 - s.discount) / 100))
        if booster and s.booster_ante_scaling == 1 then cost = cost + s.ante - 1 end
        if planetish and astronomer(s) then cost = 0 end
        if rental then cost = 1 end
        if coupon then cost = 0 end
        return cost
    end

    local function item_base(kind, id, cid)
        if kind == K_JOKER then return JOKERS[id].cost end
        if kind == K_CONS then return CONS[id].cost end
        return 1
    end

    local function sj_cost(s, i)
        local kind, id = s.sj_kind[i], s.sj_id[i]
        return calc_cost(s, item_base(kind, id), kind == K_CARD and s.c_ed[s.sj_cid[i]] or s.sj_ed[i],
            kind == K_CONS and CONS[id].set == SET_PLANET, false, s.sj_rent[i] == 1, s.sj_coup[i] == 1)
    end
    E.shop_joker_cost = sj_cost

    local function sv_cost(s, i)
        return calc_cost(s, VCOST[s.sv_id[i]], 0, false, false, false, false)
    end
    E.shop_voucher_cost = sv_cost

    local function sb_cost(s, i)
        local b = BOOST[s.sb_id[i]]
        return calc_cost(s, b.cost, 0, b.kind_id == 2, true, false, s.sb_coup[i] == 1)
    end
    E.shop_booster_cost = sb_cost

    local function cons_cost(s, i)
        local id = CONS_ID[s.cons[i]]
        return calc_cost(s, CONS[id].cost, s.cons_ed[i], CONS[id].set == SET_PLANET, false, false, false)
    end

    local function cons_sell(s, i)
        return max(1, floor(cons_cost(s, i) / 2)) + s.cons_ev[i]
    end
    E.cons_sell = cons_sell

    local function money_left(s)
        return s.money - s.bankrupt_at
    end

    local function tag_remove_triggered(s)
        local n = 0
        for i = 1, s.n_tags do
            if s.tag_trig[i] == 0 then
                n = n + 1
                s.tags[n] = s.tags[i]
                s.tag_hand[n] = s.tag_hand[i]
                s.tag_trig[n] = 0
            end
        end
        for i = n + 1, s.n_tags do s.tags[i] = nil s.tag_hand[i] = nil s.tag_trig[i] = nil end
        s.n_tags = n
    end
    I.tag_remove_triggered = tag_remove_triggered

    local add_tag

    local function push_tag(s, t, hand)
        local n = s.n_tags + 1
        s.n_tags = n
        s.tags[n] = t
        s.tag_hand[n] = hand or 0
        s.tag_trig[n] = 0
    end

    add_tag = function(s, t, hand)
        local nt = s.n_tags
        for i = 1, nt do
            if s.tag_trig[i] == 0 and s.tags[i] == TAG.tag_double and t ~= TAG.tag_double then
                s.tag_trig[i] = 1
                tmp2[#tmp2 + 1] = t
                tmp2[#tmp2 + 1] = hand or 0
            end
        end
        push_tag(s, t, hand)
    end

    local function add_tag_full(s, t, hand)
        for i = #tmp2, 1, -1 do tmp2[i] = nil end
        add_tag(s, t, hand)
        local q = 1
        while q <= #tmp2 do
            local qt, qh = tmp2[q], tmp2[q + 1]
            q = q + 2
            push_tag(s, qt, qh)
            for i = 1, s.n_tags - 1 do
                if s.tag_trig[i] == 0 and s.tags[i] == TAG.tag_double and qt ~= TAG.tag_double then
                    s.tag_trig[i] = 1
                    tmp2[#tmp2 + 1] = qt
                    tmp2[#tmp2 + 1] = qh
                end
            end
        end
        for i = #tmp2, 1, -1 do tmp2[i] = nil end
    end
    E.add_tag = add_tag_full

    local function store_joker_modify(s, i)
        if s.sj_kind[i] ~= K_JOKER or s.sj_ed[i] ~= 0 then return end
        for t = 1, s.n_tags do
            local tg = s.tags[t]
            if s.tag_trig[t] == 0 and (tg == TAG.tag_foil or tg == TAG.tag_holo or tg == TAG.tag_polychrome or tg == TAG.tag_negative) then
                s.sj_ed[i] = tg == TAG.tag_foil and ED_FOIL or tg == TAG.tag_holo and ED_HOLO or tg == TAG.tag_polychrome and ED_POLY or ED_NEG
                s.sj_coup[i] = 1
                s.tag_trig[t] = 1
                return
            end
        end
    end

    local function put_shop_item(s, r, coupon)
        local i = s.n_sj + 1
        s.n_sj = i
        s.sj_kind[i] = r.kind
        s.sj_id[i] = r.id
        s.sj_ed[i] = r.ed
        s.sj_et[i] = r.et
        s.sj_per[i] = r.per
        s.sj_rent[i] = r.rent
        s.sj_cid[i] = r.cid
        s.sj_hpc[i] = s.hands_played
        s.sj_n[i] = r.n
        s.sj_coup[i] = coupon and 1 or 0
        s.sj_uid[i] = r.uid
        return i
    end

    local function create_card_for_shop(s)
        for t = 1, s.n_tags do
            local tg = s.tags[t]
            if s.tag_trig[t] == 0 and (tg == TAG.tag_uncommon or tg == TAG.tag_rare) then
                local made = false
                if tg == TAG.tag_rare then
                    local cnt = 0
                    for k = 1, s.n_jok do
                        local id = s.j_id[k]
                        if JOKERS[id].rarity == 3 then
                            local dup = false
                            for q = 1, k - 1 do if s.j_id[q] == id then dup = true end end
                            if not dup then cnt = cnt + 1 end
                        end
                    end
                    if #JPOOL[3] > cnt then
                        create_card(s, T_JOKER, A_SHOP, nil, 1, nil, nil, "rta")
                        made = true
                    end
                else
                    create_card(s, T_JOKER, A_SHOP, nil, 0.9, nil, nil, "uta")
                    made = true
                end
                s.tag_trig[t] = 1
                if made then
                    local i = put_shop_item(s, R, true)
                    store_joker_modify(s, i)
                    return
                end
            end
        end
        local jr = s.joker_rate
        local tr, pr, sr, cr = s.tarot_rate, s.planet_rate, s.spectral_rate, s.playing_card_rate
        if jr + tr + pr + cr + sr <= 0 then cr = 1 end
        local total = jr + tr + pr + cr + sr
        local polled = random_id(s, k3("cdt", s.ante, "")) * total
        local card_type = T_BASE
        if s.used_v[V.v_illusion] == 1 and random_id(s, k1("illusion")) > 0.6 then card_type = T_ENH end
        local typ
        local check = 0
        if polled > check and polled <= check + jr then typ = T_JOKER end
        check = check + jr
        if not typ and polled > check and polled <= check + tr then typ = T_TAROT end
        check = check + tr
        if not typ and polled > check and polled <= check + pr then typ = T_PLANET end
        check = check + pr
        if not typ and polled > check and polled <= check + cr then typ = card_type end
        check = check + cr
        if not typ and polled > check and polled <= check + sr then typ = T_SPECTRAL end
        if not typ then return end
        create_card(s, typ, A_SHOP, nil, nil, nil, nil, "sho")
        local i = put_shop_item(s, R, false)
        store_joker_modify(s, i)
        if (typ == T_BASE or typ == T_ENH) and s.used_v[V.v_illusion] == 1 and random_id(s, k1("illusion")) > 0.8 then
            local p = random_id(s, k1("illusion"))
            local ed
            if p > 1 - 0.15 then ed = ED_POLY elseif p > 0.5 then ed = ED_HOLO else ed = ED_FOIL end
            s.c_ed[s.sj_cid[i]] = ed
        end
    end

    local function calculate_reroll_cost(s, skip_increment)
        if s.free_rerolls < 0 then s.free_rerolls = 0 end
        if s.free_rerolls > 0 then s.reroll_cost = 0 return end
        if not skip_increment then s.reroll_inc = s.reroll_inc + 1 end
        s.reroll_cost = (s.temp_reroll >= 0 and s.temp_reroll or s.base_reroll_cost) + s.reroll_inc
    end
    I.calculate_reroll_cost = calculate_reroll_cost

    local function get_pack(s)
        if s.first_shop_buffoon == 0 and not banned(s, "p_buffoon_normal_1") then
            s.first_shop_buffoon = 1
            return BOOST_ID["p_buffoon_normal_" .. random_int_id(s, k1("first_buffoon"), 1, 2)]
        end
        local cume = 0
        for i = 1, #BOOST do
            if not banned(s, BOOST[i].key) then cume = cume + BOOST[i].weight end
        end
        local poll = random_id(s, k3("shop_pack", s.ante, "")) * cume
        local it = 0
        for i = 1, #BOOST do
            local b = BOOST[i]
            if not banned(s, b.key) then
                it = it + b.weight
                if it >= poll and it - b.weight <= poll then return i end
            end
        end
        return 0
    end

    local function voucher_from_tag(s)
        build_marks(s, false, false)
        local vs = D.VOUCHERS
        local nv = #vs
        local sz = 0
        for i = 1, nv do
            local v = vs[i]
            local ok = s.used_v[i] == 0 and mark_v[i] ~= gen and (not v.requires_id or s.used_v[v.requires_id] == 1) and not banned(s, v.key)
            if ok then pool_buf[i] = i sz = sz + 1 else pool_buf[i] = 0 end
        end
        if sz == 0 then pool_buf[1] = V.v_blank return pick_pool(s, 1, k1("Voucher_fromtag")) end
        return pick_pool(s, nv, k1("Voucher_fromtag"))
    end

    local function add_shop_voucher(s, vid)
        local i = s.n_sv + 1
        s.n_sv = i
        s.sv_id[i] = vid
        s.sv_main[i] = 0
    end

    local function enter_shop(s)
        s.shop_on = 1
        s.phase = "shop"
        for t = 1, s.n_tags do
            if s.tag_trig[t] == 0 and s.tags[t] == TAG.tag_d_six and s.shop_d6 == 0 then
                s.shop_d6 = 1
                s.temp_reroll = 0
                calculate_reroll_cost(s, true)
                s.tag_trig[t] = 1
            end
        end
        for _ = 1, s.joker_max - s.n_sj do create_card_for_shop(s) end
        if s.voucher > 0 and s.vouchers_off == 0 then
            add_shop_voucher(s, s.voucher)
            s.sv_main[s.n_sv] = 1
        end
        for i = 1, 2 do
            local up = i == 1 and s.up1 or s.up2
            if up == 0 then
                up = get_pack(s)
                if i == 1 then s.up1 = up else s.up2 = up end
            end
            if up > 0 then
                local n = s.n_sb + 1
                s.n_sb = n
                s.sb_id[n] = up
                s.sb_coup[n] = 0
                s.sb_pos[n] = i
            end
        end
        for t = 1, s.n_tags do
            if s.tag_trig[t] == 0 and s.tags[t] == TAG.tag_voucher then
                add_shop_voucher(s, voucher_from_tag(s))
                s.tag_trig[t] = 1
            end
        end
        for t = 1, s.n_tags do
            if s.tag_trig[t] == 0 and s.tags[t] == TAG.tag_coupon and s.shop_free == 0 then
                s.shop_free = 1
                for i = 1, s.n_sj do s.sj_coup[i] = 1 end
                for i = 1, s.n_sb do s.sb_coup[i] = 1 end
                s.tag_trig[t] = 1
            end
        end
        tag_remove_triggered(s)
    end
    I.enter_shop = enter_shop

    local function remove_shop_item(s, i)
        local n = s.n_sj
        for _, f in ipairs(I.SHOP_FIELDS) do
            local a = s[f]
            for q = i, n - 1 do a[q] = a[q + 1] end
            a[n] = nil
        end
        s.n_sj = n - 1
    end

    local function remove_pack_item(s, i)
        local n = s.n_pk
        for _, f in ipairs(I.PACK_FIELDS) do
            local a = s[f]
            for q = i, n - 1 do a[q] = a[q + 1] end
            a[n] = nil
        end
        s.n_pk = n - 1
    end

    local function clear_shop(s)
        for i = s.n_sj, 1, -1 do remove_shop_item(s, i) end
        for i = s.n_sv, 1, -1 do s.sv_id[i] = nil s.sv_main[i] = nil end
        for i = s.n_sb, 1, -1 do s.sb_id[i] = nil s.sb_coup[i] = nil s.sb_pos[i] = nil end
        s.n_sv, s.n_sb = 0, 0
        s.shop_on = 0
    end
    I.clear_shop = clear_shop

    local function add_cons(s, cid, ed, uid)
        local n = s.n_cons + 1
        s.n_cons = n
        s.cons[n] = CONS[cid].key
        s.cons_ed[n] = ed or 0
        s.cons_ev[n] = 0
        if not uid then
            s.next_uid = s.next_uid + 1
            uid = s.next_uid
        end
        s.cons_uid[n] = uid
        if ed == ED_NEG then s.cons_limit = s.cons_limit + 1 end
    end
    I.add_cons = add_cons

    local function remove_cons(s, i)
        if s.cons_ed[i] == ED_NEG then s.cons_limit = s.cons_limit - 1 end
        local n = s.n_cons
        for q = i, n - 1 do
            s.cons[q] = s.cons[q + 1]
            s.cons_ed[q] = s.cons_ed[q + 1]
            s.cons_ev[q] = s.cons_ev[q + 1]
            s.cons_uid[q] = s.cons_uid[q + 1]
        end
        s.cons[n], s.cons_ed[n], s.cons_ev[n], s.cons_uid[n] = nil, nil, nil, nil
        s.n_cons = n - 1
    end

    local function joker_from_r(s, r, area_opts)
        local k = E.add_joker(s, r.id, r.ed, {eternal = r.et == 1, perish = r.per, rental = r.rent == 1, todo = r.n, hpc = area_opts, uid = r.uid})
        return k
    end

    local function create_into(s, typ, legendary, rarity, forced, app)
        local area = typ == T_JOKER and A_JOK or A_CONS
        create_card(s, typ, area, legendary, rarity, nil, forced, app)
        if R.kind == K_JOKER then
            joker_from_r(s, R, nil)
        elseif R.kind == K_CONS then
            add_cons(s, R.id, 0, R.uid)
        end
    end
    I.create_into = create_into

    local PQ_T = {T_TAROT, T_TAROT, T_TAROT, T_SPECTRAL, T_SPECTRAL, T_TAROT, T_TAROT, T_PLANET, T_JOKER}
    local PQ_A = {"8ba", "vag", "sup", "sea", "sixth", "car", "hal", "blusl", "rif"}
    E.PQ = {ba8 = 1, vag = 2, sup = 3, sea = 4, sixth = 5, car = 6, hal = 7, blusl = 8, rif = 9}

    local function flush_pending(s)
        local n = s.n_pq
        if n == 0 then return end
        for i = 1, n do
            local code = s.pq[i]
            if code == 9 then
                create_into(s, T_JOKER, nil, 0, nil, "rif")
            elseif code == 8 then
                if s.last_hand > 0 then create_into(s, T_PLANET, nil, nil, PLANET_OF_HAND[s.last_hand], "blusl") end
            else
                create_into(s, PQ_T[code], nil, nil, nil, PQ_A[code])
            end
            s.pq[i] = nil
        end
        s.n_pq = 0
        s.consumable_buffer = 0
        s.joker_buffer = 0
    end
    E.flush_pending = flush_pending

    local function draw_hand_for_pack(s)
        local space = min(s.n_deck, max(0, s.hand_size) - s.n_hand)
        if space > 0 then draw_n(s, space) end
    end

    local function open_pack(s, bid, cost, from_shop)
        local b = BOOST[bid]
        local kind = b.kind_id
        local ante = s.ante
        s.pack_kind = kind
        s.pack_choices = b.config.choose or 1
        if cost > 0 then s.money = s.money - cost end
        local size = b.config.extra
        for i = 1, size do
            if kind == 1 then
                if s.used_v[V.v_omen_globe] == 1 and random_id(s, k1("omen_globe")) > 0.8 then
                    create_card(s, T_SPECTRAL, A_PACK, nil, nil, true, nil, "ar2")
                else
                    create_card(s, T_TAROT, A_PACK, nil, nil, true, nil, "ar1")
                end
            elseif kind == 2 then
                local forced
                if s.used_v[V.v_telescope] == 1 and i == 1 then
                    local best, tally = 0, 0
                    for h = 1, 12 do
                        if s.h_vis[h] == 1 and s.h_played[h] > tally then best, tally = h, s.h_played[h] end
                    end
                    if best > 0 then forced = PLANET_OF_HAND[best] end
                end
                create_card(s, T_PLANET, A_PACK, nil, nil, true, forced, "pl1")
            elseif kind == 3 then
                create_card(s, T_SPECTRAL, A_PACK, nil, nil, true, nil, "spe")
            elseif kind == 4 then
                local typ = random_id(s, k3("stdset", ante, "")) > 0.6 and T_ENH or T_BASE
                create_card(s, typ, A_PACK, nil, nil, true, nil, "sta")
                local cid = R.cid
                s.c_ed[cid] = poll_edition(s, k3("standard_edition", ante, ""), 2, true, false)
                if random_id(s, k3("stdseal", ante, "")) > 1 - 0.02 * 10 then
                    local st = random_id(s, k3("stdsealtype", ante, ""))
                    if st > 0.75 then s.c_seal[cid] = D.SEAL_RED
                    elseif st > 0.5 then s.c_seal[cid] = D.SEAL_BLUE
                    elseif st > 0.25 then s.c_seal[cid] = D.SEAL_GOLD
                    else s.c_seal[cid] = D.SEAL_PURPLE end
                end
            else
                create_card(s, T_JOKER, A_PACK, nil, nil, true, nil, "buf")
            end
            local n = s.n_pk + 1
            s.n_pk = n
            s.pk_kind[n] = R.kind
            s.pk_id[n] = R.id
            s.pk_ed[n] = R.ed
            s.pk_et[n] = R.et
            s.pk_per[n] = R.per
            s.pk_rent[n] = R.rent
            s.pk_cid[n] = R.cid
            s.pk_hpc[n] = s.hands_played
            s.pk_n[n] = R.n
            s.pk_uid[n] = R.uid
        end
        resolve_blueprints(s)
        for k = 1, s.n_jok do
            local ek = eff_k[k]
            if ek > 0 and s.j_id[ek] == J.hallucination and s.n_cons + s.consumable_buffer < s.cons_limit then
                if random_id(s, k3("halu", ante, "")) < s.prob / 2 then
                    s.consumable_buffer = s.consumable_buffer + 1
                    s.n_pq = s.n_pq + 1
                    s.pq[s.n_pq] = 7
                end
            end
        end
        if s.inflation_on == 1 then s.inflation = s.inflation + 1 end
        s.pack_ret = from_shop and 1 or 0
        s.phase = "pack"
        if kind == 1 or kind == 3 then draw_hand_for_pack(s) end
    end

    local open_tag_pack

    local new_blind_choice_tags
    new_blind_choice_tags = function(s)
        for t = 1, s.n_tags do
            if s.tag_trig[t] == 0 then
                local tg = s.tags[t]
                local key
                if tg == TAG.tag_charm then key = "p_arcana_mega_" .. random_int_id(s, k1("charm_tag"), 1, 2)
                elseif tg == TAG.tag_meteor then key = "p_celestial_mega_" .. random_int_id(s, k1("meteor_tag"), 1, 2)
                elseif tg == TAG.tag_ethereal then key = "p_spectral_normal_1"
                elseif tg == TAG.tag_standard then key = "p_standard_mega_1"
                elseif tg == TAG.tag_buffoon then key = "p_buffoon_mega_1"
                elseif tg == TAG.tag_boss then
                    s.tag_trig[t] = 1
                    s.boss_rerolled = 1
                    s.boss_choice = E.get_new_boss(s)
                    tag_remove_triggered(s)
                    new_blind_choice_tags(s)
                    return true
                end
                if key then
                    s.tag_trig[t] = 1
                    tag_remove_triggered(s)
                    open_tag_pack(s, BOOST_ID[key])
                    return true
                end
            end
        end
        return false
    end
    I.new_blind_choice_tags = new_blind_choice_tags

    open_tag_pack = function(s, bid)
        open_pack(s, bid, 0, s.shop_on == 1)
    end

    local function end_pack(s)
        local h, d = s.hand, s.deck
        local m, nd = s.n_hand, s.n_deck
        if m > 0 then
            for i = nd, 1, -1 do d[i + m] = d[i] end
            for j = 1, m do
                d[j] = h[m - j + 1]
            end
            for j = 1, m do h[j] = nil end
            s.n_deck = nd + m
        end
        s.n_hand = 0
        for i = s.n_pk, 1, -1 do remove_pack_item(s, i) end
        s.pack_kind = 0
        s.pack_choices = 0
        s.phase = s.pack_ret == 1 and "shop" or "blind_select"
        new_blind_choice_tags(s)
    end

    local function hologram(s, count)
        I.playing_card_added(s, count)
    end

    local function set_joker_edition(s, k, ed)
        local old = s.j_ed[k]
        if old == ED_NEG then return end
        s.j_ed[k] = ed
        if ed == ED_NEG then s.joker_limit = s.joker_limit + 1 end
    end

    local function destroy_jokers_except(s, keep_uid)
        local k = 1
        while k <= s.n_jok do
            if s.j_uid[k] ~= keep_uid and s.j_eternal[k] == 0 then
                remove_joker_slot(s, k)
            else
                k = k + 1
            end
        end
    end

    local function copy_joker(s, k, strip_neg)
        local ed = s.j_ed[k]
        if strip_neg and ed == ED_NEG then ed = 0 end
        local id = s.j_id[k]
        local todo = 0
        if id == J.todo_list then roll_todo(s, 0) todo = s.j_n[k] end
        local nk = E.add_joker(s, id, ed, {eternal = s.j_eternal[k] == 1, perish = s.j_perish[k], rental = s.j_rental[k] == 1,
            todo = id == J.todo_list and todo or nil, hpc = s.j_h[k]})
        s.j_mult[nk] = s.j_mult[k]
        s.j_x[nk] = s.j_x[k]
        s.j_ex[nk] = s.j_ex[k]
        s.j_n[nk] = s.j_n[k]
        s.j_ev[nk] = s.j_ev[k]
        s.j_bcost[nk] = s.j_bcost[k]
        return nk
    end
    I.copy_joker = copy_joker

    local function editionless(s, out)
        local n = 0
        for k = 1, s.n_jok do
            if s.j_ed[k] == 0 then n = n + 1 out[n] = k end
        end
        return n
    end

    local function destroy_card(s, cid)
        s.c_alive[cid] = 0
        local h = s.hand
        for i = 1, s.n_hand do
            if h[i] == cid then
                for q = i, s.n_hand - 1 do h[q] = h[q + 1] end
                h[s.n_hand] = nil
                s.n_hand = s.n_hand - 1
                break
            end
        end
    end

    local function removed_cards_effects(s, list, n)
        local faces = 0
        local pareidolia = find_joker(s, J.pareidolia)
        for i = 1, n do
            if is_face(s, list[i], false, pareidolia) then faces = faces + 1 end
        end
        for k = 1, s.n_jok do
            if s.j_debuff[k] == 0 and s.j_id[k] == J.caino and faces > 0 then
                s.j_n[k] = s.j_n[k] + faces * JOKERS[J.caino].config.extra
            end
        end
    end

    local function add_card_to_hand(s, rank, suit, enh)
        local cid = new_card(s, rank, suit, enh)
        s.n_hand = s.n_hand + 1
        s.hand[s.n_hand] = cid
        s.deck_limit = s.deck_limit + 1
        return cid
    end

    local SUITS4 = {1, 2, 4, 3}
    local RANK13 = {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14}
    local SHDC = {"S", "H", "D", "C"}
    local function suit_pick(s, kid)
        return D.SUIT_ID[SHDC[element_index_id(s, kid, 4)]]
    end

    local function can_use(s, cid, n_targets, in_pack, area_cons)
        local c = CONS[cid]
        local name = c.name
        local cfg = c.config
        if name == "The Hermit" or c.hand or name == "Temperance" or name == "Black Hole" then return true end
        if name == "The Wheel of Fortune" then return editionless(s, tmp) > 0 end
        if name == "Ankh" then return s.n_jok > 0 and s.joker_limit > 1 end
        if name == "Aura" then return n_targets == 1 end
        if name == "Ectoplasm" or name == "Hex" then return editionless(s, tmp) > 0 end
        if name == "The Emperor" or name == "The High Priestess" then return s.n_cons < s.cons_limit or area_cons end
        if name == "The Fool" then return (s.n_cons < s.cons_limit or area_cons) and s.last_tp > 0 and s.last_tp ~= C_FOOL end
        if name == "Judgement" or name == "The Soul" or name == "Wraith" then return s.n_jok < s.joker_limit end
        if s.phase == "play" or (in_pack and (s.pack_kind == 1 or s.pack_kind == 3 or s.pack_kind == 2)) then
            if cfg.max_highlighted then
                local mx = min(5, cfg.max_highlighted)
                if mx >= n_targets and n_targets >= (cfg.min_highlighted or 1) then return true end
            end
            if (name == "Familiar" or name == "Grim" or name == "Incantation" or name == "Immolate" or name == "Sigil" or name == "Ouija") and s.n_hand > 1 then
                return true
            end
        end
        return false
    end
    E.can_use_cons = can_use

    local tsel = {}

    local function use_cons(s, cid, targets, in_pack, area_cons)
        local c = CONS[cid]
        local name = c.name
        local cfg = c.config
        local nt = targets and #targets or 0
        for i = 1, nt do tsel[i] = s.hand[targets[i]] end
        for i = nt + 1, #tsel do tsel[i] = nil end
        if c.set == SET_TAROT then s.tarot_used = s.tarot_used + 1
        elseif c.set == SET_PLANET then
            local bit = 2 ^ (c.order - 1)
            if floor(s.planet_mask / bit) % 2 == 0 then
                s.planet_mask = s.planet_mask + bit
                s.planets_used = s.planets_used + 1
            end
        end
        cur_use = cid
        if cfg.mod_conv or cfg.suit_conv then
            if name == "Death" then
                local right = 1
                for i = 2, nt do if targets[i] > targets[right] then right = i end end
                local src = tsel[right]
                for i = 1, nt do
                    local d = tsel[i]
                    if d ~= src then
                        s.c_rank[d], s.c_suit[d], s.c_enh[d], s.c_ed[d], s.c_seal[d], s.c_bonus[d] =
                            s.c_rank[src], s.c_suit[src], s.c_enh[src], s.c_ed[src], s.c_seal[src], s.c_bonus[src]
                        s.c_debuff[d] = s.c_debuff[src]
                        s.c_perma_debuff[d] = s.c_perma_debuff[src]
                        s.c_pta[d] = s.c_pta[src]
                    end
                end
            elseif name == "Strength" then
                for i = 1, nt do
                    local d = tsel[i]
                    local r = s.c_rank[d]
                    s.c_rank[d] = r == 14 and 2 or min(r + 1, 14)
                end
            elseif cfg.suit_conv then
                local su = D.SUIT_ID[cfg.suit_conv]
                for i = 1, nt do
                    s.c_suit[tsel[i]] = su
                    blind_debuff_card(s, tsel[i])
                end
            else
                local e = D.ENH_ID[cfg.mod_conv]
                for i = 1, nt do
                    local d = tsel[i]
                    s.c_enh[d] = e
                    s.c_pta[d] = 0
                    s.c_perma_debuff[d] = 0
                    blind_debuff_card(s, d)
                end
            end
        end
        if name == "Black Hole" then
            for h = 1, 12 do level_up(s, h, 1) end
        end
        if name == "Talisman" or name == "Deja Vu" or name == "Trance" or name == "Medium" then
            s.c_seal[tsel[1]] = D.SEAL_NAME_ID[cfg.extra]
        end
        if name == "Aura" then
            s.c_ed[tsel[1]] = poll_edition(s, k1("aura"), 1, true, true)
        end
        if name == "Cryptid" then
            local src = tsel[1]
            for _ = 1, cfg.extra do
                local d = add_card_to_hand(s, s.c_rank[src], s.c_suit[src], s.c_enh[src])
                s.c_ed[d], s.c_seal[d], s.c_bonus[d], s.c_osuit[d] = s.c_ed[src], s.c_seal[src], s.c_bonus[src], s.c_osuit[src]
                s.c_debuff[d] = s.c_debuff[src]
                s.c_perma_debuff[d] = s.c_perma_debuff[src]
                s.c_pta[d] = s.c_pta[src]
            end
            hologram(s, cfg.extra)
        end
        if name == "Sigil" or name == "Ouija" then
            if name == "Sigil" then
                local su = suit_pick(s, k1("sigil"))
                for i = 1, s.n_hand do s.c_suit[s.hand[i]] = su end
            else
                local r = RANK13[element_index_id(s, k1("ouija"), 13)]
                for i = 1, s.n_hand do s.c_rank[s.hand[i]] = r end
                s.hand_size = s.hand_size - 1
            end
            for i = 1, s.n_hand do blind_debuff_card(s, s.hand[i]) end
        end
        if c.hand then level_up(s, c.hand, 1) end
        if cfg.remove_card then
            local nd = 0
            if name == "The Hanged Man" then
                for i = nt, 1, -1 do nd = nd + 1 tmp2[nd] = tsel[i] end
            elseif name == "Familiar" or name == "Grim" or name == "Incantation" then
                local i = nth_by_uid(s, s.hand, s.n_hand, element_index_id(s, k1("random_destroy"), s.n_hand))
                nd = 1
                tmp2[1] = s.hand[i]
            elseif name == "Immolate" then
                local n = s.n_hand
                for i = 1, n do tmp[i] = s.hand[i] end
                local uid = s.c_uid
                for i = 2, n do
                    local v = tmp[i]
                    local j = i - 1
                    while j >= 1 and uid[tmp[j]] > uid[v] do tmp[j + 1] = tmp[j] j = j - 1 end
                    tmp[j + 1] = v
                end
                shuffle_id(s, k1("immolate"), tmp, n)
                for i = 1, min(cfg.extra.destroy, n) do nd = nd + 1 tmp2[nd] = tmp[i] end
                s.money = s.money + cfg.extra.dollars
            end
            local destroyed = {}
            for i = 1, nd do destroyed[i] = tmp2[i] end
            for i = 1, nd do destroy_card(s, destroyed[i]) end
            if name == "Familiar" or name == "Grim" or name == "Incantation" then
                for i = 1, cfg.extra do
                    local rank, suit
                    if name == "Familiar" then
                        rank = 10 + element_index_id(s, k1("familiar_create"), 3)
                        suit = suit_pick(s, k1("familiar_create"))
                    elseif name == "Grim" then
                        rank = 14
                        suit = suit_pick(s, k1("grim_create"))
                    else
                        rank = 1 + element_index_id(s, k1("incantation_create"), 9)
                        suit = suit_pick(s, k1("incantation_create"))
                    end
                    local e = element_index_id(s, k1("spe_card"), 7)
                    if e >= D.E_STONE then e = e + 1 end
                    add_card_to_hand(s, rank, suit, e)
                end
                hologram(s, cfg.extra)
            end
            removed_cards_effects(s, destroyed, nd)
        end
        if name == "The Fool" then
            if s.cons_limit > s.n_cons then create_into(s, T_TP, nil, nil, s.last_tp, "fool") end
        end
        if name == "The Hermit" then s.money = s.money + max(0, min(s.money, cfg.extra)) end
        if name == "Temperance" then
            local m = 0
            for k = 1, s.n_jok do m = m + joker_sell(s, k) end
            s.money = s.money + min(m, cfg.extra)
        end
        if name == "The Emperor" or name == "The High Priestess" then
            local nmax = min(cfg.tarots or cfg.planets, s.cons_limit - s.n_cons)
            for _ = 1, nmax do
                if s.cons_limit > s.n_cons then
                    create_into(s, name == "The Emperor" and T_TAROT or T_PLANET, nil, nil, nil, name == "The Emperor" and "emp" or "pri")
                end
            end
        end
        if name == "Judgement" or name == "The Soul" then
            create_into(s, T_JOKER, name == "The Soul", nil, nil, name == "Judgement" and "jud" or "sou")
        end
        if name == "Ankh" then
            local n = s.n_jok
            for k = 1, n do tmp[k] = k end
            local chosen = joker_pick_by_uid(s, tmp, n, k1("ankh_choice"))
            local cuid = s.j_uid[chosen]
            local nk = copy_joker(s, chosen, true)
            local nuid = s.j_uid[nk]
            local k = 1
            while k <= s.n_jok do
                local u = s.j_uid[k]
                if u ~= cuid and u ~= nuid and s.j_eternal[k] == 0 then remove_joker_slot(s, k) else k = k + 1 end
            end
        end
        if name == "Wraith" then
            create_into(s, T_JOKER, nil, 0.99, nil, "wra")
            if s.money ~= 0 then s.money = 0 end
        end
        if name == "The Wheel of Fortune" or name == "Ectoplasm" or name == "Hex" then
            local go = name ~= "The Wheel of Fortune" or random_id(s, k1("wheel_of_fortune")) < s.prob / cfg.extra
            if go then
                local n = editionless(s, tmp)
                local kid = k1(name == "The Wheel of Fortune" and "wheel_of_fortune" or name == "Ectoplasm" and "ectoplasm" or "hex")
                local k = joker_pick_by_uid(s, tmp, n, kid)
                local ed
                if name == "Ectoplasm" then ed = ED_NEG elseif name == "Hex" then ed = ED_POLY
                else ed = poll_edition(s, kid, 1, true, true) end
                set_joker_edition(s, k, ed)
                if name == "Hex" then destroy_jokers_except(s, s.j_uid[k]) end
                if name == "Ectoplasm" then
                    s.hand_size = s.hand_size - s.ecto_minus
                    s.ecto_minus = s.ecto_minus + 1
                end
            end
        end
        cur_use = 0
        for k = 1, s.n_jok do
            if s.j_debuff[k] == 0 then
                local id = s.j_id[k]
                if id == J.glass and name == "The Hanged Man" then
                    local g = 0
                    for i = 1, nt do if s.c_enh[tsel[i]] == D.E_GLASS then g = g + 1 end end
                    if g > 0 then s.j_x[k] = s.j_x[k] + 0.75 * g end
                elseif id == J.constellation and c.set == SET_PLANET then
                    s.j_x[k] = s.j_x[k] + JOKERS[id].config.extra
                end
            end
        end
        if c.set == SET_TAROT or c.set == SET_PLANET then s.last_tp = cid end
    end
    I.use_cons = use_cons

    local function target_ok(s, targets)
        if not targets then return true end
        for i = 1, #targets do
            local p = targets[i]
            if type(p) ~= "number" or p < 1 or p > s.n_hand then return false end
            for q = 1, i - 1 do if targets[q] == p then return false end end
        end
        return true
    end

    function E.use(s, pos, targets)
        if s.phase ~= "play" and s.phase ~= "shop" then return false end
        if type(pos) ~= "number" or pos < 1 or pos > s.n_cons then return false end
        if not target_ok(s, targets) then return false end
        local cid = CONS_ID[s.cons[pos]]
        if not can_use(s, cid, targets and #targets or 0, false, true) then return false end
        if CONS[cid].name == "Ankh" and s.n_jok >= s.joker_limit then return false end
        local ed = s.cons_ed[pos]
        remove_cons(s, pos)
        if ed == ED_NEG then s.cons_limit = s.cons_limit + 1 end
        use_cons(s, cid, targets, false, true)
        if ed == ED_NEG then s.cons_limit = s.cons_limit - 1 end
        return true
    end

    function E.sell(s, area, pos)
        if s.phase ~= "play" and s.phase ~= "shop" then return false end
        if area == "consumables" then
            if type(pos) ~= "number" or pos < 1 or pos > s.n_cons then return false end
            local v = cons_sell(s, pos)
            remove_cons(s, pos)
            s.money = s.money + v
        else
            if type(pos) ~= "number" or pos < 1 or pos > s.n_jok then return false end
            if s.j_eternal[pos] == 1 then return false end
            local k = pos
            local id = s.j_id[k]
            if s.j_debuff[k] == 0 then
                if id == J.luchador and s.blind > 2 and s.blind_disabled == 0 then disable_blind(s) end
                if id == J.diet_cola then add_tag_full(s, TAG.tag_double) end
                if id == J.invisible and s.j_n[k] >= JOKERS[id].config.extra then
                    local n = 0
                    for q = 1, s.n_jok do if q ~= k then n = n + 1 tmp[n] = q end end
                    if n > 0 and s.n_jok <= s.joker_limit then
                        local ch = joker_pick_by_uid(s, tmp, n, k1("invisible"))
                        local nk = copy_joker(s, ch, true)
                        if s.j_id[nk] == J.invisible then s.j_n[nk] = 0 end
                    end
                end
            end
            local v = joker_sell(s, k)
            s.money = s.money + v
            if s.blind == D.BLIND_ID.bl_final_leaf and s.blind_disabled == 0 then disable_blind(s) end
            local uid = s.j_uid[k]
            for q = 1, s.n_jok do
                if s.j_uid[q] ~= uid and s.j_debuff[q] == 0 and s.j_id[q] == J.campfire then
                    s.j_x[q] = s.j_x[q] + JOKERS[J.campfire].config.extra
                end
            end
            for q = 1, s.n_jok do
                if s.j_uid[q] == uid then remove_joker_slot(s, q) break end
            end
            return true
        end
        for q = 1, s.n_jok do
            if s.j_debuff[q] == 0 and s.j_id[q] == J.campfire then
                s.j_x[q] = s.j_x[q] + JOKERS[J.campfire].config.extra
            end
        end
        return true
    end

    local pin_state
    local function pin_less(a, b)
        local s = pin_state
        local pa, pb = s.j_pin[a] == 1, s.j_pin[b] == 1
        if pa ~= pb then return pa end
        if pa then return s.j_uid[a] > s.j_uid[b] end
        return a < b
    end

    function E.reorder(s, order)
        local n = s.n_jok
        if type(order) ~= "table" or #order ~= n then return false end
        for i = 1, n do
            local p = order[i]
            if type(p) ~= "number" or p < 1 or p > n then return false end
            for q = 1, i - 1 do if order[q] == p then return false end end
        end
        for _, f in ipairs(I.JOKER_FIELDS) do
            local a = s[f]
            for i = 1, n do tmp[i] = a[order[i]] end
            for i = 1, n do a[i] = tmp[i] end
        end
        local npin = 0
        for k = 1, n do if s.j_pin[k] == 1 then npin = npin + 1 end end
        if npin > 0 then
            for k = 1, n do tmp2[k] = k end
            pin_state = s
            table.sort(tmp2, pin_less)
            for _, f in ipairs(I.JOKER_FIELDS) do
                local a = s[f]
                for i = 1, n do tmp[i] = a[tmp2[i]] end
                for i = 1, n do a[i] = tmp[i] end
            end
            for i = #tmp2, 1, -1 do tmp2[i] = nil end
        end
        return true
    end

    local function joker_slot_ok(s, kind, ed)
        if kind == K_JOKER then return s.n_jok < s.joker_limit + (ed == ED_NEG and 1 or 0) end
        if kind == K_CONS then return s.n_cons < s.cons_limit + (ed == ED_NEG and 1 or 0) end
        return true
    end

    local function add_playing_card_to_deck(s, cid)
        s.c_alive[cid] = 1
        E.deck_bottom(s, cid)
        s.deck_limit = s.deck_limit + 1
        hologram(s, 1)
    end

    local function item_to_owned(s, kind, id, ed, et, per, rent, cid, hpc, n, uid)
        if kind == K_JOKER then
            E.add_joker(s, id, ed, {eternal = et == 1, perish = per, rental = rent == 1, todo = n, hpc = hpc, uid = uid})
        elseif kind == K_CONS then
            add_cons(s, id, ed, uid)
        else
            add_playing_card_to_deck(s, cid)
        end
    end

    function E.buy(s, pos, and_use)
        if s.phase ~= "shop" then return false end
        if type(pos) ~= "number" or pos < 1 or pos > s.n_sj then return false end
        local cost = sj_cost(s, pos)
        if cost > money_left(s) and cost > 0 then return false end
        local kind, id, ed = s.sj_kind[pos], s.sj_id[pos], s.sj_ed[pos]
        if and_use then
            if kind ~= K_CONS then return false end
            if CONS[id].config.max_highlighted then return false end
            if not can_use(s, id, 0, false, false) then return false end
        elseif not joker_slot_ok(s, kind, ed) then
            return false
        end
        local et, per, rent, cid, hpc, n = s.sj_et[pos], s.sj_per[pos], s.sj_rent[pos], s.sj_cid[pos], s.sj_hpc[pos], s.sj_n[pos]
        local uid = s.sj_uid[pos]
        remove_shop_item(s, pos)
        if and_use then
            cur_use = id
        else
            item_to_owned(s, kind, id, ed, et, per, rent, cid, hpc, n, uid)
        end
        if s.inflation_on == 1 then s.inflation = s.inflation + 1 end
        if cost ~= 0 then s.money = s.money - cost end
        if and_use then use_cons(s, id, nil, false, false) end
        return true
    end

    local function apply_voucher_shop(s, vid)
        local key = D.VOUCHERS[vid].key
        if key == "v_overstock_norm" or key == "v_overstock_plus" then
            s.joker_max = s.joker_max + 1
            if s.shop_on == 1 then
                for _ = 1, s.joker_max - s.n_sj do create_card_for_shop(s) end
            end
            return true
        elseif key == "v_tarot_merchant" or key == "v_tarot_tycoon" then s.tarot_rate = 4 * VEXTRA[vid] return true
        elseif key == "v_planet_merchant" or key == "v_planet_tycoon" then s.planet_rate = 4 * VEXTRA[vid] return true
        elseif key == "v_hone" or key == "v_glow_up" then s.edition_rate = VEXTRA[vid] return true
        elseif key == "v_magic_trick" or key == "v_illusion" then s.playing_card_rate = VEXTRA[vid] return true
        elseif key == "v_reroll_surplus" or key == "v_reroll_glut" then
            s.base_reroll_cost = s.base_reroll_cost - VEXTRA[vid]
            s.reroll_cost = max(0, s.reroll_cost - VEXTRA[vid])
            return true
        end
        return false
    end
    I.apply_voucher_shop = apply_voucher_shop

    function E.redeem(s, pos)
        if s.phase ~= "shop" then return false end
        if type(pos) ~= "number" or pos < 1 or pos > s.n_sv then return false end
        local cost = sv_cost(s, pos)
        if cost > money_left(s) then return false end
        local vid = s.sv_id[pos]
        if s.sv_main[pos] == 1 then s.voucher = 0 end
        s.voucher = 0
        for q = pos, s.n_sv - 1 do s.sv_id[q] = s.sv_id[q + 1] s.sv_main[q] = s.sv_main[q + 1] end
        s.sv_id[s.n_sv], s.sv_main[s.n_sv] = nil, nil
        s.n_sv = s.n_sv - 1
        s.money = s.money - cost
        E.apply_voucher(s, D.VOUCHERS[vid].key)
        if s.inflation_on == 1 then s.inflation = s.inflation + 1 end
        return true
    end

    function E.open(s, pos)
        if s.phase ~= "shop" then return false end
        if type(pos) ~= "number" or pos < 1 or pos > s.n_sb then return false end
        local cost = sb_cost(s, pos)
        if cost > 0 and cost > money_left(s) then return false end
        local bid = s.sb_id[pos]
        if s.sb_pos[pos] == 1 then s.up1 = -1 elseif s.sb_pos[pos] == 2 then s.up2 = -1 end
        for q = pos, s.n_sb - 1 do
            s.sb_id[q], s.sb_coup[q], s.sb_pos[q] = s.sb_id[q + 1], s.sb_coup[q + 1], s.sb_pos[q + 1]
        end
        s.sb_id[s.n_sb], s.sb_coup[s.n_sb], s.sb_pos[s.n_sb] = nil, nil, nil
        s.n_sb = s.n_sb - 1
        open_pack(s, bid, cost, true)
        return true
    end

    function E.reroll(s)
        if s.phase ~= "shop" then return false end
        local rc = s.reroll_cost
        if not (rc == 0 or money_left(s) - rc >= 0) then return false end
        if rc > 0 then s.money = s.money - rc end
        local final_free = s.free_rerolls > 0
        s.free_rerolls = max(s.free_rerolls - 1, 0)
        calculate_reroll_cost(s, final_free)
        for i = s.n_sj, 1, -1 do remove_shop_item(s, i) end
        for _ = 1, s.joker_max - s.n_sj do create_card_for_shop(s) end
        tag_remove_triggered(s)
        for k = 1, s.n_jok do
            if s.j_debuff[k] == 0 and s.j_id[k] == J.flash then s.j_mult[k] = s.j_mult[k] + JOKERS[J.flash].config.extra end
        end
        return true
    end

    function E.pick(s, pos, targets)
        if s.phase ~= "pack" then return false end
        if type(pos) ~= "number" or pos < 1 or pos > s.n_pk then return false end
        if not target_ok(s, targets) then return false end
        local kind, id, ed = s.pk_kind[pos], s.pk_id[pos], s.pk_ed[pos]
        if kind == K_CONS then
            if not can_use(s, id, targets and #targets or 0, true, false) then return false end
            if CONS[id].name == "Ankh" and s.n_jok >= s.joker_limit then return false end
            remove_pack_item(s, pos)
            use_cons(s, id, targets, true, false)
        elseif kind == K_JOKER then
            if not (ed == ED_NEG or s.n_jok < s.joker_limit) then return false end
            local et, per, rent, hpc, n = s.pk_et[pos], s.pk_per[pos], s.pk_rent[pos], s.pk_hpc[pos], s.pk_n[pos]
            local uid = s.pk_uid[pos]
            remove_pack_item(s, pos)
            item_to_owned(s, kind, id, ed, et, per, rent, 0, hpc, n, uid)
        else
            local cid = s.pk_cid[pos]
            remove_pack_item(s, pos)
            add_playing_card_to_deck(s, cid)
        end
        if s.pack_choices > 1 then
            s.pack_choices = s.pack_choices - 1
        else
            end_pack(s)
        end
        return true
    end

    function E.skip_pack(s)
        if s.phase ~= "pack" then return false end
        for k = 1, s.n_jok do
            if s.j_debuff[k] == 0 and s.j_id[k] == J.red_card then s.j_mult[k] = s.j_mult[k] + JOKERS[J.red_card].config.extra end
        end
        end_pack(s)
        return true
    end

    function E.leave_shop(s)
        if s.phase ~= "shop" then return false end
        resolve_blueprints(s)
        local nperk = 0
        for k = 1, s.n_jok do
            local ek = eff_k[k]
            if ek > 0 and s.j_id[ek] == J.perkeo then nperk = nperk + 1 end
        end
        for _ = 1, nperk do
            local n = s.n_cons
            if n > 0 then
                local r = element_index_id(s, k1("perkeo"), n)
                local best, bi = 0, 0
                for _ = 1, r do
                    local cur, ci = math.huge, 0
                    for i = 1, n do
                        local u = s.cons_uid[i]
                        if u > best and u < cur then cur, ci = u, i end
                    end
                    best, bi = cur, ci
                end
                add_cons(s, CONS_ID[s.cons[bi]], ED_NEG)
            end
        end
        clear_shop(s)
        s.phase = "blind_select"
        return true
    end

    function E.skip_blind_tags(s)
        tag_remove_triggered(s)
        if not new_blind_choice_tags(s) then return end
    end

    I.immediate_tag = function(s, t, i)
        local key = TAGS[t].key
        if key == "tag_top_up" then
            for _ = 1, TAGS[t].config.spawn_jokers do
                if s.n_jok < s.joker_limit then create_into(s, T_JOKER, nil, 0, nil, "top") end
            end
            return true
        elseif key == "tag_orbital" then
            local h = s.tag_hand[i]
            if h > 0 then level_up(s, h, TAGS[t].config.levels) end
            return true
        end
        return false
    end

    E.K_JOKER, E.K_CONS, E.K_CARD = K_JOKER, K_CONS, K_CARD

    local APPS = {"sho", "buf", "ar1", "ar2", "pl1", "spe", "sta", "jud", "sou", "wra", "rif", "top", "uta", "rta", "emp", "pri",
        "fool", "8ba", "vag", "sup", "sea", "sixth", "car", "hal", "blusl"}
    for ante = 1, 16 do
        for _, p in ipairs({"Tag", "Voucher", "idol", "mail", "anc", "cas", "nr", "cashout"}) do rng.ante_key(p, ante) end
        for _, p in ipairs({"cdt", "shop_pack", "etperpoll", "packetper", "ssjr", "packssjr", "stdset", "standard_edition",
            "stdseal", "stdsealtype", "halu"}) do k3(p, ante, "") end
        for _, t in ipairs(TNAME) do kp("soul_", t, ante) end
        for _, app in ipairs(APPS) do
            k3("rarity", ante, app)
            kp("edi", app, ante)
            kp("front", app, ante)
            kp("Enhanced", app, ante)
            for r = 1, 3 do kp(JR[r], app, ante) end
            for t = 2, 4 do kp(TNAME[t], app, ante) end
        end
    end
end
