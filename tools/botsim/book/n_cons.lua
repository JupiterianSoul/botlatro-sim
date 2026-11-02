local U = require("botsim.book.n_util")
local I = U.item

local tarots = {
{"c_fool","Creates the last Tarot or Planet card used this run (not The Fool).","Use when you have a great last card to copy such as a Planet for your main hand or Hermit. Keep one for a repeat of a key tarot; low priority otherwise.",c="c_hermit,c_black_hole",a="tarot_scaling"},
{"c_magician","Enhances up to 2 selected cards into Lucky cards.","Take in Lucky card builds with Oops all 6s and Lucky Cat. Otherwise Lucky cards are volatile; skip in steel or glass plans.",c="j_oops,j_lucky_cat",a="lucky_cards"},
{"c_high_priestess","Creates up to 2 random Planet cards.","Strong in planet scaling; use immediately when you have free consumable slots. Good for a level boost on your main hand.",c="j_constellation,j_satellite",a="planet_scaling"},
{"c_empress","Enhances up to 2 selected cards into Mult cards.","Fine for +4 Mult on scoring cards; best on cards you play every hand. Also feeds Vampire and Driver's License.",c="j_vampire,j_drivers_license",a="tarot_scaling"},
{"c_emperor","Creates up to 2 random Tarot cards.","Use early to fuel tarot builds when you have empty slots. Weak late.",c="j_fortune_teller,j_hallucination",a="tarot_scaling"},
{"c_heirophant","Enhances up to 2 selected cards into Bonus cards.","+30 Chips on the card; low priority. Good for Driver's License or Vampire fodder.",c="j_drivers_license,j_vampire",a="tarot_scaling"},
{"c_lovers","Enhances 1 selected card into a Wild card.","Wild cards count as every suit, so great for flush, Ancient Joker and Flower Pot plans. Put on scoring cards.",c="j_flower_pot,j_ancient,j_seeing_double,j_smeared",a="flush"},
{"c_chariot","Enhances 1 selected card into a Steel card.","Core of steel builds: X1.5 Mult while held. Put it on Kings for Baron. Use on high ranks you will hold.",c="j_steel_joker,j_baron,j_mime,j_shoot_the_moon",a="steel_kings"},
{"c_justice","Enhances 1 selected card into a Glass card.","Glass cannon builds: X2 Mult per glass card scored, with a 1 in 4 shatter chance. Pair with Oops, Glass Joker and Caino.",c="j_glass,j_caino,j_oops,j_hanging_chad",a="glass_cannon"},
{"c_hermit","Doubles your money, up to $20 extra.","Use when holding $10 or more, ideal at $20. Excellent economy tarot; do not use at low money.",c="c_fool,j_to_the_moon",a="economy"},
{"c_wheel_of_fortune","1 in 4 chance to add Foil, Holographic or Polychrome to a random joker.","Use with Oops all 6s for 1 in 2. Fine to use any time you have a spare slot; consumes without effect on failure. Never use if jokers already have editions you want.",c="j_oops,j_perkeo",a="tarot_scaling"},
{"c_strength","Increases the rank of up to 2 selected cards by 1.","Use to make pairs, straights or Kings and Queens; turns 10s into Jacks. Excellent to build rank stacks and to change a rank for Triboulet or Baron.",c="j_triboulet,j_baron,j_wee",a="deck_thinning,pair"},
{"c_hanged_man","Destroys up to 2 selected cards.","Core thinning tool; use on weak cards, or to destroy steel-less duplicates. Key for Erosion, Caino, Ride the Bus and deck thinning.",c="j_erosion,j_caino,j_ride_the_bus,j_trading,j_glass",a="deck_thinning"},
{"c_death","Converts the left selected card into a copy of the right selected card.","Use to duplicate your best enhanced, edition or seal card, and to build rank stacks (pairs, five of a kind). Strong for flush color changes.",c="j_hologram,j_dna",a="deck_fattening,pair"},
{"c_temperance","Gives the total sell value of all jokers, up to $50.","Strong with Egg, Gift Card and expensive jokers; use before selling. Good late economy.",c="j_egg,j_gift",a="economy"},
{"c_devil","Enhances 1 selected card into a Gold card.","Gold cards give $3 held at end of round. Pair with Midas Mask and Ticket.",c="j_midas_mask,j_ticket",a="gold_economy"},
{"c_tower","Enhances 1 selected card into a Stone card.","Stone cards give +50 Chips with no rank or suit. Core of stone builds with Stone Joker.",c="j_stone,j_marble",a="stone"},
{"c_star","Converts up to 3 selected cards to Diamonds.","Use to change suits toward a flush plan; Diamonds with Rough Gem and Greedy.",c="j_rough_gem,j_greedy_joker,j_smeared",a="flush"},
{"c_moon","Converts up to 3 selected cards to Clubs.","Use to change suits toward a Club flush plan.",c="j_onyx_agate,j_gluttenous_joker",a="flush"},
{"c_sun","Converts up to 3 selected cards to Hearts.","Use to change suits toward a Heart flush plan.",c="j_bloodstone,j_lusty_joker",a="flush"},
{"c_judgement","Creates a random joker.","Use when you have an open joker slot, ideally early for a free Rare chance. Skip if slots are full.",c="j_ring_master",a="tarot_scaling"},
{"c_world","Converts up to 3 selected cards to Spades.","Use to change suits toward a Spade flush plan.",c="j_arrowhead,j_wrathful_joker,j_blackboard",a="flush"},
}

local planets = {
{"c_mercury","Levels up Pair.","Take if you run a pair plan; each level gives +1 Mult and +15 Chips.",a="pair,planet_scaling"},
{"c_venus","Levels up Three of a Kind.","Take for trips and full house plans; +2 Mult +20 Chips per level.",a="three_kind,planet_scaling"},
{"c_earth","Levels up Full House.","Take for full house plans; +2 Mult +25 Chips per level.",a="full_house,planet_scaling"},
{"c_mars","Levels up Four of a Kind.","Take for four of a kind plans; +3 Mult +30 Chips per level.",a="four_kind,planet_scaling"},
{"c_jupiter","Levels up Flush.","Take for flush plans; +2 Mult +15 Chips per level. Telescope often points here.",a="flush,planet_scaling"},
{"c_saturn","Levels up Straight.","Take for straight plans; +3 Mult +30 Chips per level.",a="straight,planet_scaling"},
{"c_uranus","Levels up Two Pair.","Take for two pair plans; +1 Mult +20 Chips per level.",a="two_pair,planet_scaling"},
{"c_neptune","Levels up Straight Flush.","Take for straight flush plans; +4 Mult +40 Chips per level. Also boosts royal flush combos.",a="straight,flush,planet_scaling"},
{"c_pluto","Levels up High Card.","Take for high card plans; +1 Mult +10 Chips per level.",a="high_card,planet_scaling"},
{"c_planet_x","Levels up Five of a Kind. Appears only after that hand has been played.","Take if you are on a five of a kind plan after you have made one.",a="five_kind,planet_scaling"},
{"c_ceres","Levels up Flush House. Appears only after that hand has been played.","Take if you are on a flush house plan after you have made one.",a="full_house,flush,planet_scaling"},
{"c_eris","Levels up Flush Five. Appears only after that hand has been played.","Take if you are on a flush five plan after you have made one.",a="five_kind,flush,planet_scaling"},
}

local spectrals = {
{"c_familiar","Destroys 1 random card in hand and adds 3 random Enhanced face cards.","Good for face decks and Hologram; thins junk and adds enhancements. Take in Pareidolia or Triboulet plans.",c="j_hologram,j_pareidolia,j_triboulet",a="deck_fattening,face_cards"},
{"c_grim","Destroys 1 random card in hand and adds 2 random Enhanced Aces.","Good for Ace stacks and Scholar; adds Aces.",c="j_hologram,j_scholar",a="deck_fattening,high_card"},
{"c_incantation","Destroys 1 random card in hand and adds 4 random Enhanced numbered cards.","Good for numbered rank decks, Hologram and Fibonacci.",c="j_hologram,j_fibonacci,j_even_steven",a="deck_fattening"},
{"c_talisman","Adds a Gold Seal to 1 selected card.","Put a Gold Seal on a card you play every hand, ideally retriggered or a Steel king. Early economy.",c="j_hanging_chad,j_dusk",a="economy"},
{"c_aura","Adds Foil, Holographic or Polychrome to 1 selected card.","Edition on a card you play every hand; Polychrome is X1.5 Mult. Best on retrigger cards.",c="j_hanging_chad",a="retrigger"},
{"c_wraith","Creates a random Rare joker and sets money to $0.","Use only if you have a joker slot and no need for the money; a free rare is strong. Avoid with a large bank.",c="j_riff_raff",a="economy"},
{"c_sigil","Converts all cards in hand to a single random suit.","Strong for flush plans; convert the whole hand. Pair with Ouija for a rank stack too.",c="c_ouija,j_smeared",a="flush"},
{"c_ouija","Converts all cards in hand to a single random rank, -1 hand size.","Strong for pair and five of a kind plans; the hand size hit is permanent, so offset with Juggler or Paint Brush.",c="c_sigil,j_juggler,v_paint_brush",a="pair,five_kind"},
{"c_ectoplasm","Adds Negative to a random joker, -1 hand size.","An extra joker slot; take the hand size hit when jokers matter more than hand size. Prefer to have Juggler to offset.",c="j_juggler,v_paint_brush",a="economy"},
{"c_immolate","Destroys 5 random cards in hand and gives $20.","Big money and thinning; use when your deck has junk and you are poor.",c="j_erosion,c_hanged_man",a="deck_thinning,economy"},
{"c_ankh","Creates a copy of a random joker and destroys the others.","Gamble; use only if you have one great joker and everything else is junk. Never with Blueprint-reliant boards.",c="j_blueprint",a="copy_chain"},
{"c_deja_vu","Adds a Red Seal to 1 selected card.","Red Seal retriggers the card; best on steel kings or a face card with Photograph.",c="j_baron,j_mime,j_photograph",a="retrigger,steel_kings"},
{"c_hex","Adds Polychrome to a random joker and destroys the others.","Use only with a single dominant joker (legendary or xMult); also a way to clear slots.",c="j_blueprint",a="xmult_stack"},
{"c_trance","Adds a Blue Seal to 1 selected card.","Blue Seal gives a Planet card if held in hand at end of round; good for planet scaling when held.",c="j_baron",a="planet_scaling"},
{"c_medium","Adds a Purple Seal to 1 selected card.","Purple Seal makes a Tarot when discarded; good for tarot scaling with discards.",c="j_trading,j_mail",a="tarot_scaling"},
{"c_cryptid","Creates 2 copies of 1 selected card in hand.","Strong: duplicate your best enhanced, edition and sealed card; builds five of a kind and Hologram, Idol and Steel stacks.",c="j_hologram,j_idol,j_dna",a="deck_fattening,five_kind"},
{"c_soul","Creates a Legendary joker.","Always take and use if you have a slot. Appears in Arcana and Spectral packs rarely.",c="j_caino,j_triboulet,j_yorick,j_chicot,j_perkeo",a="xmult_stack"},
{"c_black_hole","Upgrades every poker hand by 1 level.","Always strong; use right away or hold with Perkeo. Best when all hand types matter.",c="j_perkeo,j_constellation,c_fool",a="planet_scaling"},
}

local out = {}
for _, group in ipairs{tarots, planets, spectrals} do
    for k, v in pairs(U.build(group, I)) do
        assert(not out[k], k)
        out[k] = v
    end
end
return out
