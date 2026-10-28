local rng = require("bot.sim.rng")
local D = require("bot.sim.data")

local M = {}

local ok_tnew, tnew = pcall(require, "table.new")
if not ok_tnew then tnew = function() return {} end end

local SCALARS = {
    "seed", "hashed_seed", "hcache", "deck_key", "stake", "phase", "step",
    "ante", "round", "money", "chips", "hands_left", "discards_left", "hand_size", "joker_limit", "cons_limit",
    "hands_played", "round_hands_played", "discards_used", "unused_discards", "skips",
    "blind", "blind_chips", "blind_dollars", "blind_disabled", "blind_triggered", "blind_prepped",
    "blind_eye", "blind_mouth", "blind_hands_sub", "blind_discards_sub", "blind_suit", "facing_blind",
    "blind_on_deck", "boss_choice", "tag_small", "tag_big", "boss_rerolled", "blind_ante",
    "state_small", "state_big", "state_boss", "voucher",
    "resets_hands", "resets_discards", "bonus_hands", "bonus_discards", "temp_handsize",
    "prob", "interest_cap", "interest_amount", "bankrupt_at", "discount", "inflation",
    "no_interest", "money_per_hand", "money_per_discard", "no_extra_hand_money", "ante_scaling", "scaling",
    "no_reward_small", "no_reward_big", "no_reward_boss", "win_ante", "won", "plasma", "anaglyph",
    "starting_deck_size", "deck_limit", "idol_rank", "idol_suit", "mail_rank", "ancient_suit", "castle_suit",
    "most_played", "last_hand", "next_uid", "n_cards", "n_deck", "n_hand", "n_disc", "n_jok", "n_cons", "n_tags",
    "dollar_buffer", "round_dollars", "prev_round_dollars", "tarot_used", "planets_used", "gros_extinct",
    "free_rerolls", "reroll_cost", "base_reroll_cost", "game_over", "consumable_buffer", "spectral_rate",
    "first_shop_buffoon", "pending_cons",
    "n_sj", "n_sv", "n_sb", "n_pk", "n_pq", "pack_choices", "pack_kind", "pack_ret", "shop_on", "joker_max",
    "joker_rate", "tarot_rate", "planet_rate", "playing_card_rate", "edition_rate", "up1", "up2", "reroll_inc",
    "temp_reroll", "shop_free", "shop_d6", "last_tp", "joker_buffer", "ecto_minus", "planet_mask", "ban",
    "eternals_on", "perish_on", "rentals_on", "all_eternal", "inflation_on", "booster_ante_scaling", "vouchers_off",
    "n_rk", "lux_x", "lux_last", "debuff_played", "chips_cap", "discard_cost", "set_eternal_ante", "set_joker_slots_ante", "flipped_cards",
    "orb_s", "orb_b", "orb_a1", "orb_s1", "orb_b1", "orb_a2", "orb_s2", "orb_b2", "orb_a3", "orb_s3", "orb_b3",
}
M.SCALARS = SCALARS

local CARD_ARRAYS = {
    "c_rank", "c_suit", "c_osuit", "c_enh", "c_ed", "c_seal", "c_bonus", "c_uid", "c_debuff", "c_flip",
    "c_pta", "c_forced", "c_alive", "c_times", "c_perma_debuff",
}
M.CARD_ARRAYS = CARD_ARRAYS

local JOKER_ARRAYS = {
    "j_id", "j_ed", "j_uid", "j_debuff", "j_eternal", "j_perish", "j_rental", "j_ev", "j_bcost",
    "j_mult", "j_x", "j_ex", "j_n", "j_h", "j_flip", "j_pin",
}
M.JOKER_ARRAYS = JOKER_ARRAYS

local SHOP_ARRAYS = {"sj_kind", "sj_id", "sj_ed", "sj_et", "sj_per", "sj_rent", "sj_cid", "sj_hpc", "sj_n", "sj_coup", "sj_uid"}
local PACK_ARRAYS = {"pk_kind", "pk_id", "pk_ed", "pk_et", "pk_per", "pk_rent", "pk_cid", "pk_hpc", "pk_n", "pk_uid"}
M.SHOP_ARRAYS, M.PACK_ARRAYS = SHOP_ARRAYS, PACK_ARRAYS
local VAR_ARRAYS = {{"sv_id", "n_sv"}, {"sv_main", "n_sv"}, {"sb_id", "n_sb"}, {"sb_coup", "n_sb"}, {"sb_pos", "n_sb"},
    {"cons_ed", "n_cons"}, {"cons_ev", "n_cons"}, {"cons_uid", "n_cons"}, {"tag_hand", "n_tags"}, {"tag_trig", "n_tags"}, {"pq", "n_pq"}}
for _, f in ipairs(SHOP_ARRAYS) do VAR_ARRAYS[#VAR_ARRAYS + 1] = {f, "n_sj"} end
for _, f in ipairs(PACK_ARRAYS) do VAR_ARRAYS[#VAR_ARRAYS + 1] = {f, "n_pk"} end
M.VAR_ARRAYS = VAR_ARRAYS

local FIXED_ARRAYS = {
    {"h_level", 12}, {"h_chips", 12}, {"h_mult", 12}, {"h_played", 12}, {"h_pround", 12}, {"h_vis", 12},
    {"bosses_used", #D.BLINDS}, {"used_v", #D.VOUCHERS},
}
M.FIXED_ARRAYS = FIXED_ARRAYS

local function new_arrays(s, nc, nj, nd, nr)
    nc, nj, nd, nr = nc or 0, nj or 0, nd or 0, nr or 0
    for i = 1, #CARD_ARRAYS do s[CARD_ARRAYS[i]] = tnew(nc, 0) end
    for i = 1, #JOKER_ARRAYS do s[JOKER_ARRAYS[i]] = tnew(nj, 0) end
    for i = 1, #FIXED_ARRAYS do
        local f = FIXED_ARRAYS[i]
        local t = tnew(f[2], 0)
        for j = 1, f[2] do t[j] = 0 end
        s[f[1]] = t
    end
    s.deck, s.hand, s.disc, s.cons, s.tags, s.rng = tnew(nd, 0), tnew(16, 0), tnew(16, 0), {}, {}, tnew(nr, 0)
    for i = 1, #VAR_ARRAYS do s[VAR_ARRAYS[i][1]] = {} end
    s.rng_ids = {}
end

function M.new(seed)
    local s = tnew(0, 160)
    for _, k in ipairs(SCALARS) do s[k] = 0 end
    new_arrays(s)
    s.seed = seed
    s.hcache = rng.seed_cache(seed)
    s.hashed_seed = rng.pseudohash(seed)
    s.deck_key = "b_red"
    s.phase = "blind_select"
    s.blind_on_deck = 1
    s.pending_cons = 0
    return s
end

local function build_copier(proxy_rng, hand_cards)
    local src = {"return function(d, s)",
        "    local od, oh, odi, ork = d.n_deck or 0, d.n_hand or 0, d.n_disc or 0, d.n_rk or 0"}
    for i = 1, #SCALARS do
        src[#src + 1] = string.format("    d.%s = s.%s", SCALARS[i], SCALARS[i])
    end
    local function group(count, names, guard)
        src[#src + 1] = "    do"
        src[#src + 1] = "        local n = " .. count
        if guard then src[#src + 1] = "        if n > 0 then" end
        for c = 1, #names, 4 do
            local loads, body = {}, {}
            for i = c, math.min(c + 3, #names) do
                local f = names[i]
                loads[#loads + 1] = string.format("local d%d, s%d = d.%s, s.%s", i, i, f, f)
                body[#body + 1] = string.format("d%d[i] = s%d[i]", i, i)
            end
            src[#src + 1] = "        do " .. table.concat(loads, " ")
            src[#src + 1] = "        for i = 1, n do " .. table.concat(body, " ") .. " end end"
        end
        if guard then src[#src + 1] = "        end" end
        src[#src + 1] = "    end"
    end
    if hand_cards then
        src[#src + 1] = "    do"
        src[#src + 1] = "        local hand, nh = s.hand, s.n_hand"
        for c = 1, #CARD_ARRAYS, 4 do
            local loads, body = {}, {}
            for i = c, math.min(c + 3, #CARD_ARRAYS) do
                local f = CARD_ARRAYS[i]
                loads[#loads + 1] = string.format("local d%d, s%d = d.%s, s.%s", i, i, f, f)
                body[#body + 1] = string.format("d%d[i] = s%d[i]", i, i)
            end
            src[#src + 1] = "        do " .. table.concat(loads, " ")
            src[#src + 1] = "        for j = 1, nh do local i = hand[j] " .. table.concat(body, " ") .. " end end"
        end
        src[#src + 1] = "    end"
    else
        group("s.n_cards", CARD_ARRAYS, false)
    end
    group("s.n_jok", JOKER_ARRAYS, true)
    for i = 1, #FIXED_ARRAYS do
        local f = FIXED_ARRAYS[i]
        group(tostring(f[2]), {f[1]}, false)
    end
    local by_count, order = {}, {}
    for i = 1, #VAR_ARRAYS do
        local f = VAR_ARRAYS[i]
        if not by_count[f[2]] then by_count[f[2]] = {} order[#order + 1] = f[2] end
        table.insert(by_count[f[2]], f[1])
    end
    for _, c in ipairs(order) do group("s." .. c, by_count[c], true) end
    group("s.n_deck", {"deck"}, false)
    group("s.n_hand", {"hand"}, false)
    group("s.n_disc", {"disc"}, false)
    group("s.n_tags", {"tags"}, true)
    if proxy_rng then
        src[#src + 1] = [==[
    local dc, sc = d.cons, s.cons
    for i = 1, s.n_cons do dc[i] = sc[i] end
    for i = s.n_cons + 1, #dc do dc[i] = nil end
    local dd, dh, ddi = d.deck, d.hand, d.disc
    for i = s.n_deck + 1, od do dd[i] = nil end
    for i = s.n_hand + 1, oh do dh[i] = nil end
    for i = s.n_disc + 1, odi do ddi[i] = nil end
    local p = d.rng_proxy
    for k in pairs(p) do p[k] = nil end
    d.rng_mt.__index = s.rng
    d.rng = p
    return d
end]==]
    else
        src[#src + 1] = [==[
    local dc, sc = d.cons, s.cons
    for i = 1, s.n_cons do dc[i] = sc[i] end
    for i = s.n_cons + 1, #dc do dc[i] = nil end
    local dd, dh, ddi = d.deck, d.hand, d.disc
    for i = s.n_deck + 1, od do dd[i] = nil end
    for i = s.n_hand + 1, oh do dh[i] = nil end
    for i = s.n_disc + 1, odi do ddi[i] = nil end
    local dr, sr, di, si = d.rng, s.rng, d.rng_ids, s.rng_ids
    for i = 1, ork do dr[di[i]] = nil end
    local nk = s.n_rk
    for i = 1, nk do
        local id = si[i]
        di[i] = id
        dr[id] = sr[id]
    end
    for i = nk + 1, ork do di[i] = nil end
    return d
end]==]
    end
    local chunk = assert(loadstring(table.concat(src, "\n"), proxy_rng and "=preview_copier" or "=state_copier"))
    return chunk()
end

M.copy_into = build_copier()

function M.clone(s)
    local d = tnew(0, 160)
    new_arrays(d, s.n_cards, s.n_jok, s.n_deck, 0)
    return M.copy_into(d, s)
end

local copy_preview = build_copier(true)
local copy_preview_hand = build_copier(true, true)

function M.scratch()
    local d = tnew(0, 160)
    for _, k in ipairs(SCALARS) do d[k] = 0 end
    new_arrays(d)
    d.rng_mt = {}
    d.rng_proxy = setmetatable({}, d.rng_mt)
    return d
end

M.PREVIEW_PROXY = true
M.PREVIEW_AGAIN = true

function M.copy_preview(d, s)
    if M.PREVIEW_PROXY then return copy_preview(d, s) end
    if d.rng == d.rng_proxy then
        d.rng, d.rng_ids, d.n_rk = {}, {}, 0
    end
    return M.copy_into(d, s)
end

function M.copy_preview_again(d, s)
    if M.PREVIEW_PROXY and M.PREVIEW_AGAIN then return copy_preview_hand(d, s) end
    return M.copy_preview(d, s)
end

return M
