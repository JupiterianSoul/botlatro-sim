package.path = "assets/?.lua;tools/?.lua;" .. package.path
local CS = require("botsim.cscan")
local E = require("bot.sim.engine")
local D = require("bot.sim.data")
local rng = require("bot.sim.rng")

local opt = {n = 1000, seed = 1, every = 0}
for _, a in ipairs(arg or {}) do
    local k, v = a:match("^%-*([%w_]+)=(.*)$")
    if k then opt[k] = tonumber(v) or v end
end

if not CS.on then
    print("fuzz_scan: C library not found, build tools/botsim/c first")
    os.exit(1)
end
CS.enable(false)

local J = E.J
local HOT = {}
for n in ("four_fingers shortcut smeared pareidolia splash blueprint brainstorm hiker lucky_cat wee photograph 8_ball idol "
    .. "scary_face smiley ticket scholar walkie_talkie business fibonacci even_steven odd_todd greedy_joker lusty_joker "
    .. "wrathful_joker gluttenous_joker rough_gem onyx_agate arrowhead bloodstone ancient triboulet sock_and_buskin "
    .. "hanging_chad dusk selzer hack shoot_the_moon baron reserved_parking raised_fist mime loyalty_card seeing_double "
    .. "half abstract acrobat mystic_summit misprint banner stuntman matador supernova ceremonial vagabond superposition "
    .. "seance flower_pot square runner ice_cream castle blue_joker erosion stone steel_joker bull drivers_license "
    .. "blackboard stencil swashbuckler joker trousers ride_the_bus flash popcorn green_joker red_card fortune_teller "
    .. "gros_michel cavendish card_sharp bootstraps caino space midas_mask vampire todo_list dna obelisk baseball "
    .. "hologram throwback sixth_sense glass"):gmatch("%S+") do HOT[#HOT + 1] = J[n] end
local BOSS = {}
for i in ipairs(D.BLINDS) do BOSS[#BOSS + 1] = i end
local PLANETS = {}
for k in pairs(D.PLANET_HAND) do PLANETS[#PLANETS + 1] = k end
table.sort(PLANETS)
local KEYS = {"lucky_mult", "lucky_money", "8ball", "business", "bloodstone", "parking", "space", "misprint"}
local decks = {"b_red", "b_blue", "b_yellow", "b_green", "b_black", "b_magic", "b_nebula", "b_ghost", "b_abandoned",
    "b_checkered", "b_zodiac", "b_painted", "b_anaglyph", "b_plasma", "b_erratic"}

local r = opt.seed * 7919 + 17
local function rnd(n)
    r = (r * 16807) % 2147483647
    return r % n + 1
end
local function pick(t) return t[rnd(#t)] end
local function chance(n) return rnd(n) == 1 end
local function frac() return (rnd(1000000) - 1) / 1000000 end

local function make_state(i)
    local s = E.new_run({seed = string.format("FS%d_%07d", opt.seed, i), deck = pick(decks), stake = rnd(8)})
    E.step(s, {type = "select"})
    if s.phase ~= "play" then return nil end
    for _ = 1, rnd(9) - 1 do
        local id = chance(4) and rnd(D.NUM_JOKERS) or pick(HOT)
        E.add_joker(s, id, chance(5) and D.ED_KEYS[rnd(4)] or nil)
    end
    for k = 1, s.n_jok do
        if chance(3) then s.j_x[k] = pick({1, 1.25, 1.5, 2, 3.75, 0.5}) end
        if chance(3) then s.j_mult[k] = rnd(30) - 5 end
        if chance(3) then s.j_ex[k] = rnd(120) - 10 end
        if chance(3) then s.j_n[k] = rnd(20) - 1 end
        if chance(4) then s.j_h[k] = rnd(10) - 1 end
        if chance(10) then s.j_debuff[k] = 1 end
        if chance(6) then s.j_ed[k] = rnd(4) end
        if chance(8) then s.j_rental[k] = 1 end
        if chance(5) then s.j_ev[k] = rnd(6) end
    end
    local want = chance(4) and rnd(14) or s.n_hand
    if want < s.n_hand then
        s.n_hand = want
        for q = want + 1, #s.hand do s.hand[q] = nil end
    else
        while s.n_hand < want do
            local cid = E.new_card(s, rnd(13) + 1, rnd(4))
            s.n_hand = s.n_hand + 1
            s.hand[s.n_hand] = cid
        end
    end
    local suits = {rnd(4), rnd(4)}
    for q = 1, s.n_hand do
        local c = s.hand[q]
        if chance(3) then s.c_rank[c] = pick({2, 3, 4, 5, 6, 8, 10, 11, 12, 13, 14, rnd(13) + 1}) end
        if chance(3) then s.c_suit[c] = pick(suits) end
        if chance(4) then s.c_osuit[c] = rnd(4) end
        if chance(3) then s.c_enh[c] = rnd(9) - 1 end
        if chance(5) then s.c_seal[c] = rnd(5) - 1 end
        if chance(6) then s.c_ed[c] = rnd(4) - 1 end
        if chance(6) then s.c_bonus[c] = pick({5, 10, 30}) end
        if chance(8) then s.c_debuff[c] = 1 end
        if chance(8) then s.c_pta[c] = 1 end
        if chance(10) then s.c_perma_debuff[c] = 1 end
        if chance(15) then s.c_uid[c] = s.c_uid[s.hand[rnd(s.n_hand)]] end
    end
    for c = 1, s.n_cards do
        if chance(6) then s.c_enh[c] = pick({5, 6, 1, 2}) end
        if chance(30) then s.c_alive[c] = 0 end
    end
    for c = 1, s.n_cards do s.c_forced[c] = 0 end
    if s.n_hand > 0 and chance(8) then s.c_forced[s.hand[rnd(s.n_hand)]] = 1 end
    if chance(2) then
        s.blind = pick(BOSS)
        s.blind_suit = D.BLINDS[s.blind].suit or 0
        if chance(5) then s.blind_suit = rnd(5) - 1 end
    end
    s.blind_disabled = chance(6) and 1 or 0
    s.blind_triggered = chance(4) and 1 or 0
    s.blind_eye = chance(2) and rnd(8192) - 1 or 0
    s.blind_mouth = chance(2) and rnd(13) - 1 or 0
    s.most_played = rnd(12)
    for h = 1, 12 do
        if chance(3) then E.level_up(s, h, rnd(5) - 1) end
        if chance(3) then s.h_played[h] = rnd(6) - 1 end
        if chance(3) then s.h_pround[h] = rnd(3) - 1 end
        if chance(3) then s.h_vis[h] = 1 - s.h_vis[h] end
    end
    s.money = rnd(80) - 10
    s.hands_left = rnd(5)
    s.discards_left = rnd(5) - 1
    s.hands_played = rnd(20) - 1
    s.round_hands_played = chance(2) and 0 or rnd(3)
    s.prob = pick({1, 1, 2, 4})
    s.consumable_buffer = chance(4) and 1 or 0
    s.cons_limit = rnd(3)
    s.n_cons = 0
    for q = 1, rnd(4) - 1 do
        s.n_cons = q
        s.cons[q] = chance(4) and "c_fool" or pick(PLANETS)
    end
    s.used_v[D.VOUCHER_ID.v_observatory] = chance(3) and 1 or 0
    s.chips_cap = chance(10) and 1 or 0
    s.plasma = chance(10) and 1 or 0
    s.tarot_used = rnd(6) - 1
    s.skips = rnd(5) - 1
    s.joker_limit = rnd(4) + 3
    s.idol_rank, s.idol_suit, s.ancient_suit = rnd(13) + 1, rnd(4), rnd(4)
    s.dollar_buffer = rnd(5) - 1
    for _, kn in ipairs(KEYS) do
        local id = rng.key_id(kn)
        local u = rnd(4)
        if u == 1 then s.rng[id] = frac() elseif u == 2 then s.rng[id] = -1 end
    end
    return s
end

local function same(a, b)
    return a == b or (a ~= a and b ~= b)
end

local lv, lc, cv, cc = {}, {}, {}, {}
local MODES = {{false, nil}, {true, 0}, {true, 8}, {true, 3}}
local states, scans, previews, errors, skipped, bad = 0, 0, 0, 0, 0, 0
local t0 = os.clock()
local tl, tc = 0, 0
for i = 1, opt.n do
    local ok, s = pcall(make_state, i)
    if not ok then
        errors = errors + 1
        if errors <= 5 then print("make error", i, s) end
    elseif s then
        states = states + 1
        for _, md in ipairs(MODES) do
            local a = os.clock()
            local okl, nl = pcall(CS.lua_scan, s, lv, lc, md[1], md[2])
            local b = os.clock()
            if not okl then
                skipped = skipped + 1
                if skipped <= 3 then print("lua error", i, nl) end
                break
            end
            local okc, nc = pcall(CS.c_scan, s, cv, cc, md[1], md[2])
            tl, tc = tl + (b - a), tc + (os.clock() - b)
            scans = scans + 1
            previews = previews + (okl and nl or 0)
            local diff
            if not okc then diff = "c error " .. tostring(nc)
            elseif nl ~= nc then diff = string.format("count %d vs %d", nl, nc)
            else
                for q = 1, nl do
                    if lc[q] ~= cc[q] then diff = "combo " .. q break end
                    if not same(lv[q], cv[q]) then
                        diff = string.format("value %d %s: lua %.17g c %.17g", q, table.concat(lc[q], ","), lv[q], cv[q])
                        break
                    end
                end
            end
            if diff then
                bad = bad + 1
                if bad <= 10 then
                    local js = {}
                    for k = 1, s.n_jok do js[k] = D.JOKERS[s.j_id[k]].key .. (s.j_debuff[k] == 1 and "(d)" or "") end
                    print(string.format("DIFF state %d mode %s/%s: %s | blind %s dis %d | jokers %s", i, tostring(md[1]), tostring(md[2]),
                        diff, D.BLINDS[s.blind] and D.BLINDS[s.blind].key or s.blind, s.blind_disabled, table.concat(js, " ")))
                end
                break
            end
        end
    end
    if opt.every > 0 and i % opt.every == 0 then
        print(string.format("  %d states, %d scans, %d previews, %d bad, %.0f s", states, scans, previews, bad, os.clock() - t0))
        io.stdout:flush()
    end
end
print(string.format("fuzz_scan: %d states, %d scans, %d previews, %d differ, %d make errors, %d lua errors, lua %.2f s, c %.2f s",
    states, scans, previews, bad, errors, skipped, tl, tc))
os.exit((bad == 0 and errors == 0) and 0 or 1)
