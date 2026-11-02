local U = require("botsim.book.n_util")
local M = require("botsim.book.n_misc")
local cons = require("botsim.book.n_cons")

local N = {
    jokers = require("botsim.book.n_jokers"),
    consumables = cons,
    vouchers = M.vouchers,
    tags = M.tags,
    blinds = M.blinds,
    decks = M.decks,
    stakes = M.stakes,
    hands = M.hands,
    seals = M.seals,
    editions = M.editions,
    enhancements = M.enhancements,
    boosters = M.boosters,
    booster_sizes = M.booster_sizes,
    stickers = M.stickers,
}

local function rule(what, when, c)
    local combos = {}
    for w in (c or ""):gmatch("[^,]+") do combos[#combos + 1] = w end
    return {what = what, when = when, combos = combos, src = "guess"}
end

N.rules = {
    deck_makeup = rule("A standard deck has 52 cards: 13 ranks in 4 suits, one of each. Rank chips: 2 to 10 are face value, J Q K 10, Ace 11. Ace counts high or low in straights, not around the corner (Q K A 2 3 is not a straight).", "Know the make up before thinning or fattening: Erosion needs fewer than 52, Hologram and Blue Joker like more. Abandoned has 40 cards, Checkered only two suits.", "j_erosion,j_hologram,j_blue_joker,b_abandoned,b_checkered"),
    hand_size = rule("Default hand size is 8 cards drawn each round; you play up to 5 cards per hand. Hand size changes from jokers (Juggler +1, Troubadour +2, Turtle Bean +5, Stuntman -2, Merry Andy -1), vouchers (Paint Brush, Palette), decks (Painted +2) and Ouija or Ectoplasm (-1).", "Bigger hand size makes flushes and straights easier and holds more Steel or Baron cards. Do not drop under 6 without a reason.", "j_juggler,v_paint_brush,v_palette,b_painted"),
    joker_slots = rule("5 joker slots by default. Antimatter and Black Deck add 1 each; Negative jokers add a slot; Painted Deck removes 1.", "Slots are the real limit on power by mid run; sell weak jokers for better ones rather than hold filler. Negative cards are worth about a slot.", "v_antimatter,b_black,e_negative,b_painted"),
    consumable_slots = rule("2 consumable slots by default. Crystal Ball and Negative consumables add 1; Nebula Deck removes 1.", "Free the slot before opening Arcana and Celestial packs. Planet builds that hold planets need extra slots.", "v_crystal_ball,b_nebula,e_negative"),
    shop_slots = rule("The shop shows 2 card slots (jokers, tarot, planet, playing cards), 2 booster pack slots and 1 voucher slot. Overstock adds card slots. Only one voucher is offered per ante.", "Check the voucher each ante; it is the only chance until the next ante.", "v_overstock_norm,v_overstock_plus"),
    reroll_prices = rule("A reroll costs $5 and rises by $1 on each reroll within a shop, then resets next shop. Reroll Surplus and Glut reduce the base by $2 each. Chaos the Clown gives one free reroll per shop.", "Reroll only when a specific piece is worth the cost relative to interest; stop when money would drop below an interest threshold you care about.", "v_reroll_surplus,v_reroll_glut,j_chaos,j_flash"),
    sell_values = rule("A joker or consumable sells for half its cost, rounded down, minimum $1. Egg and Gift Card raise sell value over time.", "Selling can pay for a key buy, and selling a spent scaler or a finished economy joker frees a slot.", "j_egg,j_gift,c_temperance,j_swashbuckler,j_ceremonial"),
    interest = rule("At the end of a round you earn $1 for every $5 held, up to $5 total (cap at $25 held). Seed Money raises the cap to $10 at $50, Money Tree to $20 at $100. To the Moon adds $1 per $5. Green Deck gets no interest.", "Hold $25 where you can early; spending below a $5 multiple loses interest. The bigger the cap the more it matters to bank early.", "v_seed_money,v_money_tree,j_to_the_moon,b_green"),
    hands_discards = rule("Default 4 hands and 3 discards per round. Blue Deck +1 hand, Red Deck +1 discard, Black Deck -1 hand, Blue Stake -1 discard. Grabber and Nacho Tong add hands; Wasteful and Recyclomancy add discards.", "Hands are the damage budget, discards are the dig budget. Unused hands and discards pay on Green Deck and some jokers.", "v_grabber,v_nacho_tong,v_wasteful,v_recyclomancy,b_green"),
    rounds_resource = rule("A run is 8 antes of Small, Big and Boss blinds; winning ante 8 finishes the run. Each round gives a fixed number of hands and discards; skipping a blind skips its shop and reward but gives a tag.", "Rounds are the clock for scaling jokers and perishable or rental jokers. Count rounds when buying Perishable, Rental, Invisible Joker, Popcorn or Ice Cream.", "j_invisible,j_popcorn,j_ice_cream,tag_skip"),
    joker_order = rule("Jokers resolve left to right. Each joker's Chips and Mult adds in that order and xMult multiplies the running total, so +Mult jokers go left of xMult jokers. Blueprint copies the joker on its right, Brainstorm the leftmost joker. Editions apply with the joker: Foil and Holographic add before the joker's own effect, Polychrome after.", "Order matters: +Mult first, then xMult. Put Blueprint directly left of your best xMult or retrigger joker and Brainstorm second with the best joker leftmost.", "j_blueprint,j_brainstorm,e_polychrome"),
    scoring_order = rule("Scoring order: played scoring cards left to right (rank chips, enhancement, edition, joker triggers on each card), then held in hand effects (Steel, Baron, Raised Fist), then jokers left to right including edition. Total is chips times mult.", "Use to place jokers: held effects like Steel apply before joker xMult in the same hand.", "m_steel,j_baron"),
    blind_scaling = rule("Blind score targets rise each ante. Small blind is 1x the base, Big 1.5x, Boss 2x (Wall 4x, Violet Vessel 6x). Stakes raise the base values. Boss reward is $5 and Big $4, Small $3.", "Plan the next boss: it is visible. Keep a spare hand type, Luchador or discard cover for known bad bosses.", "j_luchador,j_chicot,v_directors_cut"),
    skipping = rule("Skipping a Small or Big blind gives its tag but no reward and no shop. The Boss cannot be skipped.", "Skip only for a tag worth more than the reward plus shop; Throwback and Skip Tag reward skipping.", "j_throwback,tag_skip,tag_investment"),
    packs = rule("Booster packs hold a number of cards of which you choose some: Normal $4, Jumbo $6, Mega $8. You may skip a pack, which feeds Red Card.", "Open packs for your plan; skipping is allowed and sometimes better than filling a slot.", "j_red_card,v_telescope"),
    boss_visible = rule("The next boss is shown in advance at the blind select. Boss effects range from debuffing a suit to disabling hands or jokers.", "Prepare for it in the preceding shop.", "j_luchador,j_chicot"),
    probabilities = rule("Listed probabilities (Lucky, Glass, Wheel of Fortune, 8 Ball, Bloodstone, Business Card and so on) are doubled by Oops all 6s.", "Take Oops for probability builds.", "j_oops"),
    legendary = rule("Legendary jokers (Canio, Triboulet, Yorick, Chicot, Perkeo) are only obtained from The Soul.", "Always use The Soul when a slot is free.", "c_soul"),
}

N.stake_levels = {"white", "red", "green", "black", "blue", "purple", "orange", "gold"}

return N
