local D = require("bot.sim.data")
local rng = require("bot.sim.rng")
local json = require("bot.sim.json")
local E = require("bot.sim.engine")

local M = {}

local format = string.format
local J = E.J

local function card_str(s, cid)
    local out = D.RANK_CHARS[s.c_rank[cid]] .. D.SUIT_CHARS[s.c_suit[cid]]
    local e = s.c_enh[cid]
    if e > 0 then out = out .. ":" .. D.ENH_KEYS[e] end
    local ed = s.c_ed[cid]
    if ed > 0 then out = out .. ":" .. D.ED_KEYS[ed] end
    local sl = s.c_seal[cid]
    if sl > 0 then out = out .. ":" .. D.SEAL_KEYS[sl] end
    local b = s.c_bonus[cid]
    if b > 0 then out = out .. ":+" .. b end
    return out
end
M.card_str = card_str

local AB_FIELDS = {"mult", "h_mult", "h_x_mult", "h_dollars", "p_dollars", "t_mult", "t_chips", "h_size", "d_size"}

local function joker_ab(s, k)
    local id = s.j_id[k]
    local j = D.JOKERS[id]
    local c = j.config
    local ab = json.object()
    for _, f in ipairs(AB_FIELDS) do ab[f] = c[f] or 0 end
    ab.x_mult = s.j_x[k]
    ab.mult = s.j_mult[k]
    ab.extra_value = s.j_ev[k]
    ab.order = j.order
    ab.perma_bonus = 0
    ab.bonus = c.bonus or 0
    ab.hands_played_at_create = s.j_h[k]
    local ex = c.extra
    if type(ex) == "number" then
        ab.extra = s.j_ex[k]
    elseif type(ex) == "table" then
        for kk, v in pairs(ex) do
            if type(v) == "number" then ab["extra." .. kk] = v end
        end
        if id == J.rocket then ab["extra.dollars"] = s.j_ex[k]
        elseif id == J.turtle_bean then ab["extra.h_size"] = s.j_ex[k]
        elseif ex.chips then ab["extra.chips"] = s.j_ex[k] end
    end
    if id == J.invisible then ab.invis_rounds = s.j_n[k] end
    if id == J.yorick then ab.yorick_discards = s.j_n[k] end
    if id == J.caino then ab.caino_xmult = s.j_n[k] end
    if id == J.loyalty_card then
        ab.loyalty_remaining = s.j_n[k]
        ab.burnt_hand = 0
    end
    if s.j_perish[k] >= 0 then ab.perish_tally = s.j_perish[k] end
    if id == J.drivers_license or id == J.steel_joker or id == J.stone or id == J.cloud_9 then
        local t = 0
        for q = 1, s.n_cards do
            if s.c_alive[q] == 1 then
                local e = s.c_enh[q]
                if id == J.drivers_license then if e ~= 0 then t = t + 1 end
                elseif id == J.steel_joker then if e == D.E_STEEL then t = t + 1 end
                elseif id == J.stone then if e == D.E_STONE then t = t + 1 end
                elseif e ~= D.E_STONE and s.c_rank[q] == 9 then t = t + 1 end
            end
        end
        local name = id == J.drivers_license and "driver_tally" or id == J.steel_joker and "steel_tally" or id == J.stone and "stone_tally" or "nine_tally"
        ab[name] = t
    end
    if id == J.swashbuckler then
        local t = 0
        for q = 1, s.n_jok do if q ~= k then t = t + E.joker_sell(s, q) end end
        ab.mult = t
    end
    if id == J.throwback then ab.x_mult = 1 + s.skips * c.extra end
    if id == J.stencil then
        local x = s.joker_limit - s.n_jok
        for q = 1, s.n_jok do if s.j_id[q] == J.stencil then x = x + 1 end end
        ab.x_mult = x
    end
    return ab
end

local function ed_key(ed)
    return ed > 0 and D.ED_KEYS[ed] or json.null
end

local function item_key(s, kind, id, cid)
    if kind == E.K_JOKER then return D.JOKERS[id].key end
    if kind == E.K_CONS then return D.CONS[id].key end
    return card_str(s, cid)
end

local PHASE = {blind_select = "blind_select", play = "play", round_eval = "round_eval", shop = "shop", game_over = "game_over", pack = "pack", win = "win"}

function M.build(s)
    local snap = {}
    snap.step = s.step
    snap.phase = PHASE[s.phase] or s.phase
    snap.ante = s.ante
    snap.round = s.round
    snap.money = s.money
    snap.chips = s.chips
    snap.hands_left = s.hands_left
    snap.discards_left = s.discards_left
    snap.hand_size = s.hand_size
    if s.blind > 0 then
        snap.blind = {key = D.BLINDS[s.blind].key, target = s.blind_chips}
    end
    local hand = json.array()
    for i = 1, s.n_hand do hand[i] = card_str(s, s.hand[i]) end
    snap.hand = hand
    local deck = json.array()
    for i = s.n_deck, 1, -1 do deck[#deck + 1] = card_str(s, s.deck[i]) end
    snap.deck = deck
    snap.discard_count = s.n_disc
    local jokers = json.array()
    for k = 1, s.n_jok do
        jokers[k] = {
            key = D.JOKERS[s.j_id[k]].key,
            ed = s.j_ed[k] > 0 and D.ED_KEYS[s.j_ed[k]] or json.null,
            eternal = s.j_eternal[k] == 1,
            perishable = s.j_perish[k] >= 0,
            rental = s.j_rental[k] == 1,
            sell = E.joker_sell(s, k),
            ab = joker_ab(s, k),
        }
    end
    snap.jokers = jokers
    local cons = json.array()
    for i = 1, s.n_cons do cons[i] = s.cons[i] end
    snap.consumables = cons
    if s.shop_on == 1 then
        local sj, sv, sb = json.array(), json.array(), json.array()
        for i = 1, s.n_sj do
            local kind = s.sj_kind[i]
            sj[i] = {key = item_key(s, kind, s.sj_id[i], s.sj_cid[i]), ed = ed_key(kind == E.K_CARD and s.c_ed[s.sj_cid[i]] or s.sj_ed[i]), cost = E.shop_joker_cost(s, i)}
        end
        for i = 1, s.n_sv do sv[i] = {key = D.VOUCHERS[s.sv_id[i]].key, cost = E.shop_voucher_cost(s, i)} end
        for i = 1, s.n_sb do sb[i] = {key = D.BOOST[s.sb_id[i]].key, cost = E.shop_booster_cost(s, i)} end
        snap.shop = {jokers = sj, vouchers = sv, boosters = sb}
    end
    if s.phase == "pack" then
        local pk = json.array()
        for i = 1, s.n_pk do
            local kind = s.pk_kind[i]
            local k = item_key(s, kind, s.pk_id[i], s.pk_cid[i])
            if kind ~= E.K_CARD and s.pk_ed[i] > 0 then k = k .. ":" .. D.ED_KEYS[s.pk_ed[i]] end
            pk[i] = k
        end
        snap.pack = pk
    end
    local levels = {}
    for h = 1, 12 do
        levels[D.HAND_NAMES[h]] = {level = s.h_level[h], chips = s.h_chips[h], mult = s.h_mult[h], played = s.h_played[h]}
    end
    snap.levels = levels
    local vouchers = json.array()
    for i = 1, #D.VOUCHERS do
        if s.used_v[i] == 1 then vouchers[#vouchers + 1] = D.VOUCHERS[i].key end
    end
    table.sort(vouchers)
    snap.vouchers = vouchers
    local tags = json.array()
    for i = 1, s.n_tags do tags[i] = D.TAGS[s.tags[i]].key end
    snap.tags = tags
    snap.reroll_cost = s.reroll_cost
    local r = json.object()
    local names = rng.key_names
    for i = 1, #names do
        local v = s.rng[i]
        if v and v >= 0 then r[names[i]] = json.raw(format("%.13f", v)) end
    end
    snap.rng = r
    return snap
end

function M.line(s)
    return json.encode(M.build(s))
end

return M
