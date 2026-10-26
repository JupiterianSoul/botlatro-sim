local T = ...
local E = require("bot.sim.engine")
local D = require("bot.sim.data")
local H = dofile("tools/botsim/test/helpers.lua")

local function run(name, hand, pos, jokers, want, setup, after)
    local s = H.round_with("SCORETST", hand, jokers)
    if setup then setup(s) end
    local ok, gained = E.play(s, pos)
    T.ok(ok, name .. " legal")
    T.eq(gained, want, name)
    if after then after(s) end
    return s
end

local AA = "AS AH 9D 4C 2S"
run("plain pair", AA, {1, 2}, {}, 64)
run("joker", AA, {1, 2}, {"j_joker"}, 192)
run("greedy", "KD KS 9C 4C 2S", {1, 2}, {"j_greedy_joker"}, 150)
run("jolly", AA, {1, 2}, {"j_jolly"}, 320)
run("sly", AA, {1, 2}, {"j_sly"}, 164)
run("duo", AA, {1, 2}, {"j_duo"}, 128)
run("scary face", "KD KS 9C 4C 2S", {1, 2}, {"j_scary_face"}, 180)
run("fibonacci", "8D 8S 9C 4C 2S", {1, 2}, {"j_fibonacci"}, 468)
run("scholar", AA, {1, 2}, {"j_scholar"}, 720)
run("hanging chad", AA, {1, 2}, {"j_hanging_chad"}, 108)
run("sock and buskin", "KD KS 9C 4C 2S", {1, 2}, {"j_sock_and_buskin"}, 100)
run("red seal", "AS:s_red AH 9D 4C 2S", {1, 2}, {}, 86)
run("glass card", "AS:m_glass AH 9D 4C 2S", {1, 2}, {}, 128)
run("steel held", "AS AH KS:m_steel 4C 2S", {1, 2}, {}, 96)
run("baron one king", "AS AH KS 4C 2S", {1, 2}, {"j_baron"}, 96)
run("baron two kings", "AS AH KS KD 2S", {1, 2}, {"j_baron"}, 144)
run("mime steel", "AS AH KS:m_steel 4C 2S", {1, 2}, {"j_mime"}, 144)
run("mime red seal steel", "AS AH KS:m_steel:s_red 4C 2S", {1, 2}, {"j_mime"}, 216)
run("poly joker", AA, {1, 2}, {{"j_joker", "e_polychrome"}}, 288)
run("foil joker", AA, {1, 2}, {{"j_joker", "e_foil"}}, 492)
run("holo joker", AA, {1, 2}, {{"j_joker", "e_holo"}}, 512)
run("blueprint joker", AA, {1, 2}, {"j_blueprint", "j_joker"}, 320)
run("brainstorm duo", AA, {1, 2}, {"j_duo", "j_brainstorm"}, 256)
run("raised fist", AA, {1, 2}, {"j_raised_fist"}, 192)
run("half joker", AA, {1, 2}, {"j_half"}, 704)
run("abstract", AA, {1, 2}, {"j_joker", "j_abstract"}, 384)
run("ride the bus", AA, {1, 2}, {"j_ride_the_bus"}, 96)
run("green joker", AA, {1, 2}, {"j_green_joker"}, 96)
run("supernova", AA, {1, 2}, {"j_supernova"}, 96)
run("flower pot", "AS AH AD AC 2S", {1, 2, 3, 4}, {"j_flower_pot"}, 2184)
run("blackboard", "AH AD 9S 4C 2S", {1, 2}, {"j_blackboard"}, 192)
run("stuntman", AA, {1, 2}, {"j_stuntman"}, 564)
run("bull", AA, {1, 2}, {"j_bull"}, 80)
run("arrowhead", AA, {1, 2}, {"j_arrowhead"}, 164)
run("odd todd", AA, {1, 2}, {"j_odd_todd"}, 188)
run("even steven", "8D 8S 9C 4C 2S", {1, 2}, {"j_even_steven"}, 260)
run("walkie talkie", "4D 4S 9C 7C 2S", {1, 2}, {"j_walkie_talkie"}, 380)
run("shoot the moon", "AS AH QH 4C 2S", {1, 2}, {"j_shoot_the_moon"}, 480)
run("triboulet", "KD KS 9C 4C 2S", {1, 2}, {"j_triboulet"}, 240)
run("photograph", "KD KS 9C 4C 2S", {1, 2}, {"j_photograph"}, 120)
run("acrobat", AA, {1, 2}, {"j_acrobat"}, 192, function(s) s.hands_left = 1 end)
run("dusk", AA, {1, 2}, {"j_dusk"}, 108, function(s) s.hands_left = 1 end)
run("mystic summit", AA, {1, 2}, {"j_mystic_summit"}, 544, function(s) s.discards_left = 0 end)
run("banner", AA, {1, 2}, {"j_banner"}, 304)
run("hiker", AA, {1, 2}, {"j_hiker"}, 64, nil, function(s)
    local n = 0
    for c = 1, s.n_cards do if s.c_bonus[c] == 5 then n = n + 1 end end
    T.eq(n, 2, "hiker perma bonus")
end)
run("ice cream", AA, {1, 2}, {"j_ice_cream"}, 264, nil, function(s) T.eq(s.j_ex[1], 95, "ice cream melts") end)
run("seltzer", AA, {1, 2}, {"j_selzer"}, 108, nil, function(s) T.eq(s.j_ex[1], 9, "seltzer count") end)
run("cavendish", AA, {1, 2}, {"j_cavendish"}, 192)
run("gros michel", AA, {1, 2}, {"j_gros_michel"}, 544)
run("hack", "3D 3S 9C 7C 2S", {1, 2}, {"j_hack"}, 44)
run("ancient", AA, {1, 2}, {"j_ancient"}, 96, function(s) s.ancient_suit = 1 end)
run("baseball mime", AA, {1, 2}, {"j_mime", "j_baseball"}, 96)
run("splash", AA, {1, 2, 3, 4, 5}, {"j_splash"}, 94)
run("vampire", "AS:m_bonus AH 9D 4C 2S", {1, 2}, {"j_vampire"}, 70)
run("midas", "KD KS 9C 4C 2S", {1, 2}, {"j_midas_mask"}, 60, nil, function(s)
    local g = 0
    for c = 1, s.n_cards do if s.c_enh[c] == D.E_GOLD then g = g + 1 end end
    T.eq(g, 2, "midas gold cards")
end)
run("bonus mult cards", "AS:m_bonus AH:m_mult 9D 4C 2S", {1, 2}, {}, 372)
run("stone card", "AS AH 9D 4C 2S:m_stone", {1, 2, 5}, {}, 164)
run("foil holo poly cards", "AS:e_foil AH:e_holo 9D 4C 2S", {1, 2}, {}, 984)
run("poly card", "AS:e_polychrome AH 9D 4C 2S", {1, 2}, {}, 96)
run("steel joker", AA, {1, 2}, {"j_steel_joker"}, 89, function(s)
    s.c_enh[s.deck[1]] = D.E_STEEL
    s.c_enh[s.deck[2]] = D.E_STEEL
end)
run("stencil", AA, {1, 2}, {"j_stencil"}, 320)
run("loyalty no trigger", AA, {1, 2}, {"j_loyalty_card"}, 64, nil, function(s) T.eq(s.j_n[1], 4, "loyalty remaining") end)
run("loyalty trigger", AA, {1, 2}, {"j_loyalty_card"}, 256, function(s) s.hands_played = 5 end)
run("swashbuckler", AA, {1, 2}, {"j_joker", "j_swashbuckler"}, 224)
run("card sharp first", AA, {1, 2}, {"j_card_sharp"}, 64)
run("erosion", AA, {1, 2}, {"j_erosion"}, 64)
run("blue joker", AA, {1, 2}, {"j_blue_joker"}, 64 + 2 * 2 * 52, function(s) s.n_deck = 52 end)
run("square four cards", "AS AH 9D 9C 2S", {1, 2, 3, 4}, {"j_square"}, (20 + 22 + 18 + 4) * 2)
run("runner straight", "AS 2H 3D 4C 5S", {1, 2, 3, 4, 5}, {"j_runner"}, (30 + 25 + 15) * 4)
run("devious crazy straight", "AS 2H 3D 4C 5S", {1, 2, 3, 4, 5}, {"j_devious", "j_crazy"}, (30 + 25 + 100) * 16)
run("order", "AS 2H 3D 4C 5S", {1, 2, 3, 4, 5}, {"j_order"}, 55 * 4 * 3)
run("tribe flush", "AS 9S 7S 4S 2S", {1, 2, 3, 4, 5}, {"j_tribe"}, (35 + 33) * 4 * 2)
run("droll crafty", "AS 9S 7S 4S 2S", {1, 2, 3, 4, 5}, {"j_droll", "j_crafty"}, (35 + 33 + 80) * 14)
run("family", "AS AH AD AC 2S", {1, 2, 3, 4}, {"j_family"}, 104 * 7 * 4)
run("trio", "AS AH AD 9C 2S", {1, 2, 3}, {"j_trio"}, 63 * 3 * 3)
run("zany wily", "AS AH AD 9C 2S", {1, 2, 3}, {"j_zany", "j_wily"}, 163 * 15)
run("mad clever two pair", "AS AH 9D 9C 2S", {1, 2, 3, 4}, {"j_mad", "j_clever"}, (20 + 40 + 80) * 12)
run("spare trousers", "AS AH 9D 9C 2S", {1, 2, 3, 4}, {"j_trousers"}, 60 * 4)
run("four fingers flush", "AS 9S 7S 4S 2H", {1, 2, 3, 4, 5}, {"j_four_fingers"}, (35 + 11 + 9 + 7 + 4) * 4)
run("shortcut straight", "2S 4H 6D 8C TS", {1, 2, 3, 4, 5}, {"j_shortcut"}, (30 + 30) * 4)
run("smeared flush", "AH 9D 7H 4D 2H", {1, 2, 3, 4, 5}, {"j_smeared"}, (35 + 33) * 4)
run("pareidolia scary", AA, {1, 2}, {"j_pareidolia", "j_scary_face"}, (32 + 60) * 2)
run("onyx clubs", "AC AH 9D 4C 2S", {1, 2}, {"j_onyx_agate"}, 32 * 9)
run("plasma", AA, {1, 2}, {}, 289, function(s) s.plasma = 1 end)

local function boss_run(name, boss, hand, pos, jokers, want, setup)
    local s = H.round_with("BOSSTEST", hand, jokers)
    s.blind = D.BLIND_ID[boss]
    s.blind_suit = D.BLINDS[s.blind].suit or 0
    s.blind_disabled = 0
    if setup then setup(s) end
    local ok, gained = E.play(s, pos)
    T.ok(ok, name .. " legal")
    T.eq(gained, want, name)
    return s
end

boss_run("flint", "bl_flint", AA, {1, 2}, {}, 27)
boss_run("psychic", "bl_psychic", AA, {1, 2}, {}, 0)
boss_run("psychic matador", "bl_psychic", AA, {1, 2}, {"j_matador"}, 0, function(s) s.money = 10 end)
do
    local s = boss_run("psychic matador money", "bl_psychic", AA, {1, 2}, {"j_matador"}, 0)
    T.eq(s.money, 4 + 8, "matador pays on debuffed hand")
end
do
    local s = H.round_with("BOSSTEST", "AS AH 9D 4C 2S", {})
    s.blind = D.BLIND_ID.bl_goad
    s.blind_suit = 1
    for c = 1, s.n_cards do s.c_debuff[c] = 0 end
    s.c_debuff[s.hand[1]] = 1
    s.c_debuff[s.hand[5]] = 1
    local _, gained = E.play(s, {1, 2})
    T.eq(gained, 42, "goad debuffed spade")
end
do
    local s = boss_run("arm", "bl_arm", AA, {1, 2}, {}, (10 + 22) * 2, function(s) E.level_up(s, 11, 1) end)
    T.eq(s.h_level[11], 1, "arm levels down")
end
do
    local s = boss_run("ox", "bl_ox", AA, {1, 2}, {}, 64, function(s) s.most_played = 11 s.money = 20 end)
    T.eq(s.money, 0, "ox takes money")
end
do
    local s = boss_run("tooth", "bl_tooth", AA, {1, 2}, {}, 64, function(s) s.money = 20 end)
    T.eq(s.money, 18, "tooth costs per card")
end
do
    local s = boss_run("eye first", "bl_eye", AA, {1, 2}, {}, 64)
    s.blind_chips = 1e12
    local hand = s.hand
    local p = {}
    local ranks = {}
    for i = 1, s.n_hand do
        local r = s.c_rank[hand[i]]
        if ranks[r] and #p == 0 then p = {ranks[r], i} end
        ranks[r] = ranks[r] or i
    end
    if #p == 2 then
        local _, g2 = E.play(s, p)
        T.eq(g2, 0, "eye blocks repeat hand")
    end
end
do
    local s = H.round_with("ROUNDEND", AA, {"j_golden"})
    s.blind_chips = 50
    s.money = 12
    E.play(s, {1, 2})
    T.eq(s.phase, "round_eval", "round ends when blind beaten")
    T.eq(s.round_dollars, 3 + 3 + 4 + 2, "round dollars: blind, hands left, golden joker, interest")
end
do
    local s = H.blank("CERT0001")
    E.add_joker(s, "j_blueprint")
    E.add_joker(s, "j_certificate")
    E.add_joker(s, "j_hologram")
    E.step(s, {type = "select"})
    T.eq(s.n_hand, 10, "certificate and blueprint copy add two cards to the first hand")
    T.eq(s.j_x[3], 1.5, "hologram counts both cards")
end
