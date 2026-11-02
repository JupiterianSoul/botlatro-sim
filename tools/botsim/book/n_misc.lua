local U = require("botsim.book.n_util")
local I = U.item
local B = function(l) return U.build(l, I) end

local M = {}

M.vouchers = B{
{"v_overstock_norm","+1 card slot in the shop.","Cheap and early; fine for hunting, take in ante 1 only if money is spare.",a="economy"},
{"v_overstock_plus","+1 more card slot in the shop. Needs Overstock.","Only when you reroll hunt a lot; low priority.",a="economy"},
{"v_clearance_sale","All cards and packs in the shop cost 25% less.","Good early if you shop heavily; skip when interest matters most.",c="v_liquidation",a="economy"},
{"v_liquidation","All cards and packs in the shop cost 50% less. Needs Clearance Sale.","Strong for a buy heavy run; good with Astronomer-less planet builds.",a="economy"},
{"v_hone","Foil, Holographic and Polychrome appear 2x more often.","Good for edition builds and Poly xMult hunting.",c="v_glow_up",a="xmult_stack"},
{"v_glow_up","Editions appear 4x more often. Needs Hone.","Strong for Polychrome and Negative hunting.",a="xmult_stack"},
{"v_reroll_surplus","Rerolls cost $2 less.","Great for reroll hunting and Flash Card builds; take early if you reroll.",c="j_flash,j_chaos",a="economy"},
{"v_reroll_glut","Rerolls cost $2 less again. Needs Reroll Surplus.","Makes rerolls nearly free; strong with Flash Card.",c="j_flash",a="economy"},
{"v_crystal_ball","+1 consumable slot.","Strong for tarot and planet builds that hold consumables; take early on Magic-less decks.",c="v_omen_globe",a="tarot_scaling,planet_scaling"},
{"v_omen_globe","Spectral cards may appear in Arcana Packs. Needs Crystal Ball.","Good for Spectral hunting, Soul and Black Hole chances.",c="c_soul,c_black_hole",a="tarot_scaling"},
{"v_telescope","Celestial Packs always contain the Planet for your most played hand.","Very strong for planet scaling in a one hand plan.",c="v_observatory,j_constellation",a="planet_scaling"},
{"v_observatory","Planet cards in your consumable area give X1.5 Mult for their hand type. Needs Telescope.","Strong with Perkeo or a held planet for your main hand; requires keeping the planet unused.",c="j_perkeo,v_telescope",a="planet_scaling,xmult_stack"},
{"v_grabber","+1 hand each round.","Always good; take at the first chance. Helps every build.",c="v_nacho_tong",a="survival"},
{"v_nacho_tong","+1 more hand each round. Needs Grabber.","Very strong for hand based plans.",a="survival"},
{"v_wasteful","+1 discard each round.","Good for flush and straight digging; take early.",c="v_recyclomancy,j_banner",a="discard_engine"},
{"v_recyclomancy","+1 more discard each round. Needs Wasteful.","Strong for digging plans, Yorick and Banner.",c="j_yorick,j_banner",a="discard_engine"},
{"v_tarot_merchant","Tarot cards appear 2x more often in the shop.","Good for tarot scaling builds.",c="v_tarot_tycoon,j_fortune_teller",a="tarot_scaling"},
{"v_tarot_tycoon","Tarot cards appear 4x more often. Needs Tarot Merchant.","Good for tarot scaling builds.",a="tarot_scaling"},
{"v_planet_merchant","Planet cards appear 2x more often in the shop.","Good for planet scaling builds.",c="v_planet_tycoon,j_astronomer",a="planet_scaling"},
{"v_planet_tycoon","Planet cards appear 4x more often. Needs Planet Merchant.","Good for planet scaling builds.",a="planet_scaling"},
{"v_seed_money","Raises the interest cap to $10 (hold $50).","Take early in an economy run; pays back over many rounds.",c="v_money_tree,j_to_the_moon",a="economy"},
{"v_money_tree","Raises the interest cap to $20 (hold $100). Needs Seed Money.","Only for a long economy plan; takes time to earn back.",c="j_to_the_moon,j_bootstraps,j_bull",a="economy"},
{"v_blank","Does nothing.","Needed only to unlock Antimatter. Skip unless the price is tiny.",c="v_antimatter",a="economy"},
{"v_antimatter","+1 joker slot. Needs Blank.","Strong at any point; one extra joker slot is a large power gain.",a="xmult_stack"},
{"v_magic_trick","Playing cards can appear in the shop.","Good for deck fattening and Hologram.",c="v_illusion,j_hologram",a="deck_fattening"},
{"v_illusion","Shop playing cards may have an enhancement, edition or seal. Needs Magic Trick.","Strong for deck building with enhanced cards.",c="j_hologram",a="deck_fattening"},
{"v_hieroglyph","-1 Ante, -1 hand each round.","Ante skip is strong early at a hand cost; best with Grabber or Burglar. Good when blind sizes outpace you.",c="v_petroglyph,v_grabber",a="survival"},
{"v_petroglyph","-1 Ante again, -1 discard each round. Needs Hieroglyph.","A second ante skip at a discard cost; good for finishing.",c="v_hieroglyph,v_wasteful",a="survival"},
{"v_directors_cut","Reroll the Boss Blind for $10, once per ante.","Useful when a boss wrecks the build and you have cash.",c="v_retcon",a="survival"},
{"v_retcon","Reroll the Boss Blind as often as you like for $10. Needs Director's Cut.","Strong for guaranteed good boss; costly.",a="survival"},
{"v_paint_brush","+1 hand size.","Strong at any point; more cards to play and hold.",c="v_palette",a="survival"},
{"v_palette","+1 more hand size. Needs Paint Brush.","Strong at any point.",a="survival"},
}

M.tags = B{
{"tag_uncommon","Next shop has a free Uncommon joker.","Worth a skip early, esp. with Baseball Card.",c="j_baseball",a="xmult_stack"},
{"tag_rare","Next shop has a free Rare joker.","Strong skip tag in any ante.",a="xmult_stack"},
{"tag_negative","Next base edition joker in the shop becomes Negative and free.","Strong skip early; a free slot.",a="xmult_stack"},
{"tag_foil","Next base edition joker in the shop becomes Foil and free.","Fine skip tag.",a="mult_stack"},
{"tag_holo","Next base edition joker in the shop becomes Holographic and free.","Good skip tag.",a="mult_stack"},
{"tag_polychrome","Next base edition joker in the shop becomes Polychrome and free.","Strong skip tag; free X1.5 Mult.",a="xmult_stack"},
{"tag_investment","Gives $25 after defeating the next Boss Blind.","Strong economy skip.",a="economy"},
{"tag_voucher","Adds a Voucher to the next shop.","Good skip for a key voucher.",a="economy"},
{"tag_boss","Rerolls the next Boss Blind.","Worth it only to dodge a known bad boss.",a="survival"},
{"tag_standard","Gives a free Mega Standard Pack.","Good for deck building.",a="deck_fattening"},
{"tag_charm","Gives a free Mega Arcana Pack.","Good for tarot builds and steel or glass setups.",a="tarot_scaling"},
{"tag_meteor","Gives a free Mega Celestial Pack.","Good for planet builds.",a="planet_scaling"},
{"tag_buffoon","Gives a free Mega Buffoon Pack.","Good early for jokers.",a="xmult_stack"},
{"tag_handy","Earn $1 per hand played this run when taken.","Good economy mid run if you have played many hands.",a="economy"},
{"tag_garbage","Earn $1 per unused discard this run.","Good economy for stakes with discards unused.",a="economy"},
{"tag_ethereal","Gives a free Spectral Pack.","Good for Soul and Black Hole chances.",a="tarot_scaling"},
{"tag_coupon","Initial cards and packs in the next shop are free.","Strong early; free first purchases.",a="economy"},
{"tag_double","Gives a copy of the next tag you take.","Strong before a great tag; Diet Cola creates one.",c="j_diet_cola",a="economy"},
{"tag_juggle","+3 hand size next round.","Weak skip tag unless tied to a hard blind.",a="survival"},
{"tag_d_six","Rerolls in the next shop start at $0.","Good before a reroll hunt.",c="j_flash",a="economy"},
{"tag_top_up","Creates up to 2 Common jokers if you have room.","Good filler early.",a="economy"},
{"tag_skip","Gives $5 for each blind skipped this run.","Strong the more you have skipped; best late.",c="j_throwback",a="economy"},
{"tag_orbital","Upgrades a shown hand type by 3 levels.","Strong when it matches your plan hand.",a="planet_scaling"},
{"tag_economy","Doubles your money, up to +$40.","Strong when you hold $20 or more.",a="economy"},
}

M.blinds = B{
{"bl_small","Small Blind: base score 1x, reward $3 (none on Red stake and up), can be skipped for a tag.","Skip only for a tag that clearly beats the reward and extra shop; skipping removes a shop visit and interest chance.",a="economy"},
{"bl_big","Big Blind: base score 1.5x, reward $4, can be skipped for a tag.","Skip for a high value tag when your score margin is large.",a="economy"},
{"bl_ox","The Ox: playing your most played hand type sets money to $0.","Avoid the most played hand if you hold cash, or spend before. Be ready with a second hand type.",a="survival"},
{"bl_hook","The Hook: discards 2 random cards from hand after each hand played.","Plan to keep more cards in hand; dangerous for rank dependent jokers.",a="survival"},
{"bl_mouth","The Mouth: only one hand type can be played this round.","Fine for single hand plans; hurts Obelisk and variety plans.",a="survival"},
{"bl_fish","The Fish: cards drawn face down after each hand played.","Play with fewer unknown cards; ok for deterministic plans.",a="survival"},
{"bl_club","The Club: all Clubs are debuffed.","Hurts Club flush plans; use Luchador or Chicot.",a="survival"},
{"bl_manacle","The Manacle: -1 hand size.","Hurts large hand plans; plan a 4 card hand.",a="survival"},
{"bl_tooth","The Tooth: lose $1 per card played.","Play fewer cards; keep money; Matador likes it.",c="j_matador",a="economy"},
{"bl_wall","The Wall: extra large blind (4x base score).","Needs real scoring margin; plan xMult before it.",a="survival"},
{"bl_house","The House: first hand drawn face down.","Minor; avoid planning the first hand blind.",a="survival"},
{"bl_mark","The Mark: all face cards drawn face down.","Hurts face card builds that need to see cards.",a="face_cards"},
{"bl_final_bell","Cerulean Bell: forces one card to always be selected.","Plan hands that include a random card; hurts flush and straight plans.",a="survival"},
{"bl_wheel","The Wheel: 1 in 7 cards drawn face down.","Minor.",a="survival"},
{"bl_arm","The Arm: decreases the level of the played poker hand by 1.","Dangerous for high level hands; vary hand type or use Luchador.",c="j_luchador,j_chicot",a="planet_scaling"},
{"bl_psychic","The Psychic: must play 5 cards.","Hurts High Card and pair plans that use fewer cards; play junk fillers or use Splash.",c="j_splash",a="high_card"},
{"bl_goad","The Goad: all Spades are debuffed.","Hurts Spade flush plans.",a="flush"},
{"bl_water","The Water: start with 0 discards.","Hurts flush and straight plans that dig; discard heavy jokers fail.",a="discard_engine"},
{"bl_eye","The Eye: no repeat hand types this round.","Hurts one hand plans; keep two hand types ready.",a="survival"},
{"bl_plant","The Plant: all face cards are debuffed.","Hurts face card builds; Luchador is good.",a="face_cards"},
{"bl_needle","The Needle: only 1 hand this round.","One hand must kill; needs score margin; use all burst. Strong with xMult and Burglar-less builds.",a="survival"},
{"bl_head","The Head: all Hearts are debuffed.","Hurts Heart flush plans.",a="flush"},
{"bl_final_leaf","Verdant Leaf: all cards are debuffed until a joker is sold.","Sell a spare joker to clear it; keep a junk joker or Luchador ready.",a="survival"},
{"bl_final_vessel","Violet Vessel: 6x base score.","Needs high xMult; the toughest blind size.",a="xmult_stack"},
{"bl_window","The Window: all Diamonds are debuffed.","Hurts Diamond flush plans.",a="flush"},
{"bl_serpent","The Serpent: after play or discard always draw back to 3 cards.","Hurts hand size based plans; the hand shrinks.",a="survival"},
{"bl_pillar","The Pillar: cards played previously this ante are debuffed.","Hurts reusing the same cards; have deep deck variety.",a="deck_thinning"},
{"bl_flint","The Flint: base chips and Mult halved.","Level and xMult matter more; flat jokers still count.",a="planet_scaling"},
{"bl_final_acorn","Amber Acorn: flips and shuffles all jokers.","Joker order is random after; Blueprint and Brainstorm may break.",c="j_blueprint,j_brainstorm",a="copy_chain"},
{"bl_final_heart","Crimson Heart: a random joker is disabled each hand.","Spread power across several jokers; Luchador or Chicot help.",c="j_chicot,j_luchador",a="survival"},
}

M.decks = B{
{"b_red","Red Deck: +1 discard each round.","A balanced starter for flush and straight plans.",a="discard_engine"},
{"b_blue","Blue Deck: +1 hand each round.","A balanced starter for scaling jokers that like hands.",a="scaling_jokers"},
{"b_yellow","Yellow Deck: start with $10 extra.","Early economy; take shop buys at ante 1.",a="economy"},
{"b_green","Green Deck: $2 per remaining hand and $1 per remaining discard at end of round, no interest.","Economy from unused hands and discards; play efficiently and do not rely on interest jokers.",a="economy"},
{"b_black","Black Deck: +1 joker slot, -1 hand each round.","Strong with xMult jokers; the lost hand hurts.",a="xmult_stack"},
{"b_magic","Magic Deck: start with Crystal Ball and 2 copies of The Fool.","Good for consumable builds; the extra slot helps tarot scaling.",a="tarot_scaling"},
{"b_nebula","Nebula Deck: start with Telescope, -1 consumable slot.","Strong planet scaling for one hand plans.",a="planet_scaling"},
{"b_ghost","Ghost Deck: Spectral cards can appear in the shop, start with a Hex.","Spectral cards allow Familiar, Cryptid and Black Hole plans; Hex wipes jokers so use on a single strong joker.",a="deck_fattening"},
{"b_abandoned","Abandoned Deck: no face cards (40 card deck).","Good for Ride the Bus, Erosion and straight plans, bad for face joker plans.",a="deck_thinning,straight"},
{"b_checkered","Checkered Deck: 26 Spades and 26 Hearts only.","Easy flush; use Smeared Joker plans and Blackboard.",a="flush"},
{"b_zodiac","Zodiac Deck: start with Tarot Merchant, Planet Merchant and Overstock.","Good for tarot or planet scaling.",a="tarot_scaling,planet_scaling"},
{"b_painted","Painted Deck: +2 hand size, -1 joker slot.","Big hand size helps flush and straight plans; joker slots are tight so quality over quantity.",a="flush,straight"},
{"b_anaglyph","Anaglyph Deck: gain a Double Tag after defeating each Boss Blind.","Strong economy in skip builds.",a="economy"},
{"b_plasma","Plasma Deck: balances Chips and Mult, blind sizes are 2x.","Reward high chips plus mult together; flat Mult joker lose value, chips rich plans do better.",a="mult_stack"},
{"b_erratic","Erratic Deck: random ranks and suits.","Often many pairs and flush; thin and trim to a build. Favors pair stack and five of a kind chances.",a="pair,five_kind"},
{"b_challenge","Challenge Deck: used by challenge runs only; rules come from the challenge.","Read the challenge rules.",a="survival"},
}

M.stakes = B{
{"white","White Stake: no changes.","Learn builds freely; stickers off.",a="economy"},
{"red","Red Stake: the Small Blind gives no reward.","Less early money; skip Small Blinds more often.",a="economy"},
{"green","Green Stake: faster blind scaling.","More power needed by ante 5; stack xMult earlier.",a="xmult_stack"},
{"black","Black Stake: shop jokers may be Eternal (cannot be sold or destroyed).","Check Eternal status on every offer; do not buy Eternal jokers that block a slot unless strong.",a="survival"},
{"blue","Blue Stake: -1 discard each round.","Digging plans get weaker; prefer hand based plans.",a="discard_engine"},
{"purple","Purple Stake: faster blind scaling again.","Strong xMult needed by ante 6.",a="xmult_stack"},
{"orange","Orange Stake: shop jokers may be Perishable (debuffed after 5 rounds).","Buy perishable jokers only for a short term payoff, and sell before they die.",a="survival"},
{"gold","Gold Stake: shop jokers may be Rental ($3 per round).","Rental jokers cost upkeep; only worth it when a joker wins you a blind soon.",a="economy"},
}

M.hands = B{
{"Flush Five","5 cards of the same rank and suit. Base 160 Chips x 16 Mult. Secret hand; Planet is Eris.","Rarely made without Cryptid or a Death built stack; huge when it works.",a="five_kind,flush"},
{"Flush House","Full House with all five cards of the same suit. Base 140 x 14. Secret hand; Planet is Ceres.","Hard to build; very strong on decks with suit and rank stacks.",a="full_house,flush"},
{"Five of a Kind","5 cards of the same rank. Base 120 x 12. Secret hand; Planet is Planet X.","Needs duplicate ranks from Cryptid, Death or Familiar.",a="five_kind"},
{"Straight Flush","5 sequential cards of one suit. Base 100 x 8. Planet is Neptune.","Plays as both Straight and Flush for jokers; good with Four Fingers and Shortcut.",a="straight,flush"},
{"Four of a Kind","4 cards of the same rank. Base 60 x 7. Planet is Mars.","Needs rank stacks; with The Family a strong build.",a="four_kind"},
{"Full House","Three of a kind plus a pair. Base 40 x 4. Planet is Earth.","Strong with Duo, Trio and Mad jokers; contains both Pair and Three of a Kind.",a="full_house"},
{"Flush","5 cards of the same suit. Base 35 x 4. Planet is Jupiter.","Easy to reach with a suit heavy deck; most reliable early xMult support.",a="flush"},
{"Straight","5 sequential cards. Base 30 x 4. Planet is Saturn.","Aces count high or low; Shortcut and Four Fingers help.",a="straight"},
{"Three of a Kind","3 cards of the same rank. Base 30 x 3. Planet is Venus.","Moderate; contains Pair so Pair jokers also fire.",a="three_kind"},
{"Two Pair","Two different pairs. Base 20 x 2. Planet is Uranus.","Weak base; jokers like Mad and Trousers make it viable.",a="two_pair"},
{"Pair","Two cards of the same rank. Base 10 x 2. Planet is Mercury.","Easiest hand; strong with Duo, Jolly and Splash.",a="pair"},
{"High Card","The best single card. Base 5 x 1. Planet is Pluto.","Only scores one card (without Splash); strong with Stuntman, Half Joker and Scholar.",a="high_card"},
}

M.seals = B{
{"s_gold","Gold Seal: earns $3 when the card is played and scores.","Good on a card you play every hand; early economy. Talisman applies it.",a="economy"},
{"s_red","Red Seal: retriggers the card.","Best on cards that score big, like Steel Kings held with Mime or Glass cards. Deja Vu applies it.",c="j_mime,j_baron",a="retrigger"},
{"s_blue","Blue Seal: creates a Planet card for your last played hand if held in hand at end of round.","Good for planet scaling when held; Trance applies it.",a="planet_scaling"},
{"s_purple","Purple Seal: creates a Tarot card when discarded.","Good in discard heavy plans; Medium applies it.",a="tarot_scaling"},
}

M.editions = B{
{"e_foil","Foil: +50 Chips.","Weak but never wasted; good on a joker early or a card you always score.",a="mult_stack"},
{"e_holo","Holographic: +10 Mult.","Good on any joker or a card you always score; ok before ante 5.",a="mult_stack"},
{"e_polychrome","Polychrome: X1.5 Mult.","Best edition on a scoring card or joker; sits as a multiplier on its own.",a="xmult_stack"},
{"e_negative","Negative: +1 joker slot (jokers) or +1 consumable slot (consumables).","Always good; extra slot. Wins on copy jokers and Perkeo.",c="j_perkeo",a="xmult_stack"},
}

M.enhancements = B{
{"m_bonus","Bonus: +30 Chips when scored.","Low impact; use with Driver's License.",a="tarot_scaling"},
{"m_mult","Mult: +4 Mult when scored.","Steady; fine on cards you always play.",a="mult_stack"},
{"m_wild","Wild: counts as every suit.","Great for flush, Ancient, Flower Pot and Seeing Double. Always scores a flush.",a="flush"},
{"m_glass","Glass: X2 Mult when scored; 1 in 4 chance to shatter.","Fast power; thin with a Hanged Man, strong with Oops, Glass Joker and Caino.",a="glass_cannon"},
{"m_steel","Steel: X1.5 Mult while held in hand.","Core of steel builds; stack on Kings with Baron and Mime.",a="steel_kings"},
{"m_stone","Stone: +50 Chips, no rank or suit, always scores.","Core of stone builds; good with Stone Joker. Hurts flush and straight chances.",a="stone"},
{"m_gold","Gold: $3 if held in hand at end of round.","Economy build; combine with Midas Mask and Ticket.",a="gold_economy"},
{"m_lucky","Lucky: 1 in 5 chance of +20 Mult, 1 in 15 chance of $20.","Needs Oops and Lucky Cat for real power; otherwise average.",a="lucky_cards"},
}

M.boosters = B{
{"arcana","Arcana Pack: Tarot cards.","Take for steel, glass, suit conversion and economy tarots; skip when slots are full and no plan fits.",a="tarot_scaling"},
{"celestial","Celestial Pack: Planet cards.","Take the Planet for your main hand; with Telescope it is guaranteed.",a="planet_scaling"},
{"standard","Standard Pack: playing cards, often with enhancement, edition or seal.","Good for deck building; take cards that fit the plan, skip the rest.",a="deck_fattening"},
{"buffoon","Buffoon Pack: jokers.","Best early source of jokers; take a joker that fits the plan or skip to save slots.",a="xmult_stack"},
{"spectral","Spectral Pack: Spectral cards.","Strong but risky; take Soul, Black Hole, Cryptid, and avoid Ankh and Hex without a plan.",a="tarot_scaling"},
}

M.booster_sizes = B{
{"normal","Normal pack: cheapest ($4), choose 1 from 3 (Arcana, Celestial, Standard) or 2 (Buffoon, Spectral).","Fine value early.",a="economy"},
{"jumbo","Jumbo pack: $6, choose 1 from more cards (5, or 4 for Buffoon and Spectral).","Better when you want options; moderate price.",a="economy"},
{"mega","Mega pack: $8, choose 2 from the larger list.","Strong for hunting; usually worth it when money is spare.",a="economy"},
}

M.stickers = B{
{"eternal","Eternal: the joker cannot be sold or destroyed. Appears from Black Stake.","Do not buy as a temporary joker; blocks a slot forever. Only strong long term keepers are worth it. Safe from Madness, Ankh, Hex.",a="survival"},
{"perishable","Perishable: the joker is debuffed after 5 rounds. Appears from Orange Stake.","Buy only for burst in the next 5 rounds; scaling ones lose value. Sell before it dies if you cannot use it.",a="survival"},
{"rental","Rental: the joker costs $3 each round. Appears at Gold Stake.","Only worth it when the joker pays for itself; a long hold bleeds interest.",a="economy"},
}

return M
