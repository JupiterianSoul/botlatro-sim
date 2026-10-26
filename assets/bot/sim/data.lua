local D = {}

D.HAND_NAMES = {
    "Flush Five", "Flush House", "Five of a Kind", "Straight Flush", "Four of a Kind", "Full House",
    "Flush", "Straight", "Three of a Kind", "Two Pair", "Pair", "High Card",
}
D.H_FLUSH_FIVE, D.H_FLUSH_HOUSE, D.H_FIVE, D.H_SFLUSH, D.H_FOUR, D.H_FULL = 1, 2, 3, 4, 5, 6
D.H_FLUSH, D.H_STRAIGHT, D.H_THREE, D.H_TWO_PAIR, D.H_PAIR, D.H_HIGH = 7, 8, 9, 10, 11, 12
D.NUM_HANDS = 12
D.HAND_ID = {}
for i, n in ipairs(D.HAND_NAMES) do D.HAND_ID[n] = i end
D.HAND_S_CHIPS = {160, 140, 120, 100, 60, 40, 35, 30, 30, 20, 10, 5}
D.HAND_S_MULT = {16, 14, 12, 8, 7, 4, 4, 4, 3, 2, 2, 1}
D.HAND_L_CHIPS = {50, 40, 35, 40, 30, 25, 15, 30, 20, 20, 15, 10}
D.HAND_L_MULT = {3, 4, 3, 4, 3, 2, 2, 3, 2, 1, 1, 1}
D.HAND_VISIBLE = {false, false, false, true, true, true, true, true, true, true, true, true}

D.HAND_PAIRS_ORDER = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}

D.SUIT_CHARS = {"S", "H", "C", "D"}
D.SUIT_NAMES = {"Spades", "Hearts", "Clubs", "Diamonds"}
D.S_SPADES, D.S_HEARTS, D.S_CLUBS, D.S_DIAMONDS = 1, 2, 3, 4
D.SUIT_NOMINAL = {0.04, 0.03, 0.02, 0.01}
D.SUIT_NOMINAL_ORIG = {0.004, 0.003, 0.002, 0.001}
D.SUIT_ID = {S = 1, H = 2, C = 3, D = 4, Spades = 1, Hearts = 2, Clubs = 3, Diamonds = 4}

D.RANK_CHARS = {}
D.RANK_ID = {}
do
    local chars = {[2] = "2", [3] = "3", [4] = "4", [5] = "5", [6] = "6", [7] = "7", [8] = "8", [9] = "9",
        [10] = "T", [11] = "J", [12] = "Q", [13] = "K", [14] = "A"}
    for r = 2, 14 do
        D.RANK_CHARS[r] = chars[r]
        D.RANK_ID[chars[r]] = r
    end
end
D.RANK_NOMINAL = {[2] = 2, [3] = 3, [4] = 4, [5] = 5, [6] = 6, [7] = 7, [8] = 8, [9] = 9, [10] = 10, [11] = 10, [12] = 10, [13] = 10, [14] = 11}
D.RANK_FACE_NOMINAL = {[2] = 0, [3] = 0, [4] = 0, [5] = 0, [6] = 0, [7] = 0, [8] = 0, [9] = 0, [10] = 0, [11] = 0.1, [12] = 0.2, [13] = 0.3, [14] = 0.4}

D.P_CARDS_ORDER = {}
do
    local rank_order = {2, 3, 4, 5, 6, 7, 8, 9, 14, 11, 13, 12, 10}
    local suit_order = {3, 4, 2, 1}
    for _, su in ipairs(suit_order) do
        for _, r in ipairs(rank_order) do
            D.P_CARDS_ORDER[#D.P_CARDS_ORDER + 1] = {r, su}
        end
    end
end

D.E_NONE, D.E_BONUS, D.E_MULT, D.E_WILD, D.E_GLASS, D.E_STEEL, D.E_STONE, D.E_GOLD, D.E_LUCKY = 0, 1, 2, 3, 4, 5, 6, 7, 8
D.ENH_KEYS = {"m_bonus", "m_mult", "m_wild", "m_glass", "m_steel", "m_stone", "m_gold", "m_lucky"}
D.ENH_ID = {}
for i, k in ipairs(D.ENH_KEYS) do D.ENH_ID[k] = i end

D.ED_NONE, D.ED_FOIL, D.ED_HOLO, D.ED_POLY, D.ED_NEG = 0, 1, 2, 3, 4
D.ED_KEYS = {"e_foil", "e_holo", "e_polychrome", "e_negative"}
D.ED_ID = {}
for i, k in ipairs(D.ED_KEYS) do D.ED_ID[k] = i end
D.ED_EXTRA_COST = {[0] = 0, 2, 3, 5, 5}

D.SEAL_NONE, D.SEAL_GOLD, D.SEAL_RED, D.SEAL_BLUE, D.SEAL_PURPLE = 0, 1, 2, 3, 4
D.SEAL_KEYS = {"s_gold", "s_red", "s_blue", "s_purple"}
D.SEAL_NAME_ID = {Gold = 1, Red = 2, Blue = 3, Purple = 4}

D.JOKERS = require("bot.sim.data_jokers")
D.JOKER_ID = {}
D.JOKER_NAME_ID = {}
for i, j in ipairs(D.JOKERS) do
    D.JOKER_ID[j.key] = i
    D.JOKER_NAME_ID[j.name] = i
end
D.NUM_JOKERS = #D.JOKERS

D.BLINDS = {
    {key = "bl_small", name = "Small Blind", dollars = 3, mult = 1},
    {key = "bl_big", name = "Big Blind", dollars = 4, mult = 1.5},
    {key = "bl_ox", name = "The Ox", dollars = 5, mult = 2, min = 6},
    {key = "bl_hook", name = "The Hook", dollars = 5, mult = 2, min = 1},
    {key = "bl_mouth", name = "The Mouth", dollars = 5, mult = 2, min = 2},
    {key = "bl_fish", name = "The Fish", dollars = 5, mult = 2, min = 2},
    {key = "bl_club", name = "The Club", dollars = 5, mult = 2, min = 1, suit = 3},
    {key = "bl_manacle", name = "The Manacle", dollars = 5, mult = 2, min = 1},
    {key = "bl_tooth", name = "The Tooth", dollars = 5, mult = 2, min = 3},
    {key = "bl_wall", name = "The Wall", dollars = 5, mult = 4, min = 2},
    {key = "bl_house", name = "The House", dollars = 5, mult = 2, min = 2},
    {key = "bl_mark", name = "The Mark", dollars = 5, mult = 2, min = 2},
    {key = "bl_final_bell", name = "Cerulean Bell", dollars = 8, mult = 2, min = 10, showdown = true},
    {key = "bl_wheel", name = "The Wheel", dollars = 5, mult = 2, min = 2},
    {key = "bl_arm", name = "The Arm", dollars = 5, mult = 2, min = 2},
    {key = "bl_psychic", name = "The Psychic", dollars = 5, mult = 2, min = 1, h_size_ge = 5},
    {key = "bl_goad", name = "The Goad", dollars = 5, mult = 2, min = 1, suit = 1},
    {key = "bl_water", name = "The Water", dollars = 5, mult = 2, min = 2},
    {key = "bl_eye", name = "The Eye", dollars = 5, mult = 2, min = 3},
    {key = "bl_plant", name = "The Plant", dollars = 5, mult = 2, min = 4, face = true},
    {key = "bl_needle", name = "The Needle", dollars = 5, mult = 1, min = 2},
    {key = "bl_head", name = "The Head", dollars = 5, mult = 2, min = 1, suit = 2},
    {key = "bl_final_leaf", name = "Verdant Leaf", dollars = 8, mult = 2, min = 10, showdown = true},
    {key = "bl_final_vessel", name = "Violet Vessel", dollars = 8, mult = 6, min = 10, showdown = true},
    {key = "bl_window", name = "The Window", dollars = 5, mult = 2, min = 1, suit = 4},
    {key = "bl_serpent", name = "The Serpent", dollars = 5, mult = 2, min = 5},
    {key = "bl_pillar", name = "The Pillar", dollars = 5, mult = 2, min = 1},
    {key = "bl_flint", name = "The Flint", dollars = 5, mult = 2, min = 2},
    {key = "bl_final_acorn", name = "Amber Acorn", dollars = 8, mult = 2, min = 10, showdown = true},
    {key = "bl_final_heart", name = "Crimson Heart", dollars = 8, mult = 2, min = 10, showdown = true},
}
D.BLIND_ID = {}
for i, b in ipairs(D.BLINDS) do
    D.BLIND_ID[b.key] = i
    b.boss = i > 2
end
D.BOSS_KEYS_SORTED = {}
for i = 3, #D.BLINDS do D.BOSS_KEYS_SORTED[#D.BOSS_KEYS_SORTED + 1] = D.BLINDS[i].key end
table.sort(D.BOSS_KEYS_SORTED)
D.BOSS_IDS_SORTED = {}
for i, k in ipairs(D.BOSS_KEYS_SORTED) do D.BOSS_IDS_SORTED[i] = D.BLIND_ID[k] end

D.TAGS = {
    {key = "tag_uncommon"}, {key = "tag_rare"}, {key = "tag_negative", min_ante = 2}, {key = "tag_foil"},
    {key = "tag_holo"}, {key = "tag_polychrome"}, {key = "tag_investment"}, {key = "tag_voucher"},
    {key = "tag_boss"}, {key = "tag_standard", min_ante = 2}, {key = "tag_charm"}, {key = "tag_meteor", min_ante = 2},
    {key = "tag_buffoon", min_ante = 2}, {key = "tag_handy", min_ante = 2}, {key = "tag_garbage", min_ante = 2},
    {key = "tag_ethereal", min_ante = 2}, {key = "tag_coupon"}, {key = "tag_double"}, {key = "tag_juggle"},
    {key = "tag_d_six"}, {key = "tag_top_up", min_ante = 2}, {key = "tag_skip"}, {key = "tag_orbital", min_ante = 2},
    {key = "tag_economy"},
}
D.TAG_ID = {}
for i, t in ipairs(D.TAGS) do D.TAG_ID[t.key] = i end

D.VOUCHERS = {}
do
    local list = {
        {"v_overstock_norm"}, {"v_overstock_plus", "v_overstock_norm"}, {"v_clearance_sale"}, {"v_liquidation", "v_clearance_sale"},
        {"v_hone"}, {"v_glow_up", "v_hone"}, {"v_reroll_surplus"}, {"v_reroll_glut", "v_reroll_surplus"},
        {"v_crystal_ball"}, {"v_omen_globe", "v_crystal_ball"}, {"v_telescope"}, {"v_observatory", "v_telescope"},
        {"v_grabber"}, {"v_nacho_tong", "v_grabber"}, {"v_wasteful"}, {"v_recyclomancy", "v_wasteful"},
        {"v_tarot_merchant"}, {"v_tarot_tycoon", "v_tarot_merchant"}, {"v_planet_merchant"}, {"v_planet_tycoon", "v_planet_merchant"},
        {"v_seed_money"}, {"v_money_tree", "v_seed_money"}, {"v_blank"}, {"v_antimatter", "v_blank"},
        {"v_magic_trick"}, {"v_illusion", "v_magic_trick"}, {"v_hieroglyph"}, {"v_petroglyph", "v_hieroglyph"},
        {"v_directors_cut"}, {"v_retcon", "v_directors_cut"}, {"v_paint_brush"}, {"v_palette", "v_paint_brush"},
    }
    for i, v in ipairs(list) do D.VOUCHERS[i] = {key = v[1], requires = v[2]} end
end
D.VOUCHER_ID = {}
for i, v in ipairs(D.VOUCHERS) do D.VOUCHER_ID[v.key] = i end
for _, v in ipairs(D.VOUCHERS) do
    if v.requires then v.requires_id = D.VOUCHER_ID[v.requires] end
end

D.DECKS = {
    b_red = {discards = 1},
    b_blue = {hands = 1},
    b_yellow = {dollars = 10},
    b_green = {extra_hand_bonus = 2, extra_discard_bonus = 1, no_interest = true},
    b_black = {hands = -1, joker_slot = 1},
    b_magic = {voucher = "v_crystal_ball", consumables = {"c_fool", "c_fool"}},
    b_nebula = {voucher = "v_telescope", consumable_slot = -1},
    b_ghost = {spectral_rate = 2, consumables = {"c_hex"}},
    b_abandoned = {remove_faces = true},
    b_checkered = {checkered = true},
    b_zodiac = {vouchers = {"v_tarot_merchant", "v_planet_merchant", "v_overstock_norm"}},
    b_painted = {hand_size = 2, joker_slot = -1},
    b_anaglyph = {anaglyph = true},
    b_plasma = {ante_scaling = 2, plasma = true},
    b_erratic = {randomize_rank_suit = true},
    b_challenge = {},
}

D.PLANET_HAND = {
    c_mercury = 11, c_venus = 9, c_earth = 6, c_mars = 5, c_jupiter = 7, c_saturn = 8,
    c_uranus = 10, c_neptune = 4, c_pluto = 12, c_planet_x = 3, c_ceres = 2, c_eris = 1,
}

return D
