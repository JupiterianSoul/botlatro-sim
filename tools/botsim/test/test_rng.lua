local T = ...
local rng = require("bot.sim.rng")
local ST = require("bot.sim.state")
local D = require("bot.sim.data")
local E = require("bot.sim.engine")

local function game_env(seed)
    local env = setmetatable({}, {__index = _G})
    env.G = {GAME = {pseudorandom = {seed = seed}}}
    T.load_game_functions("assets/functions/misc_functions.lua",
        {"pseudohash", "pseudoseed", "pseudorandom", "pseudorandom_element", "pseudoshuffle"}, env)
    env.G.GAME.pseudorandom.hashed_seed = env.pseudohash(seed)
    return env
end

local g = game_env("ABCD1234")
local strs = {"", "A", "ABCD1234", "shuffle", "boss", "Tag1", "lucky_mult", "nr3", "cavendishXYZ12345", "\255\001weird"}
for _, str in ipairs(strs) do
    T.eq(rng.pseudohash(str), g.pseudohash(str), "pseudohash " .. str)
end
T.eq(string.format("%.13f", rng.pseudohash("ABCD1234")), "0.0403571890500", "literal pseudohash ABCD1234")
T.eq(string.format("%.13f", rng.pseudohash("shuffleABCD1234")), "0.5092761766808", "literal pseudohash shuffleABCD1234")

math.randomseed(12345)
local mismatch = 0
local total = 0
for _ = 1, 20000 do
    local len = math.random(1, 24)
    local t = {}
    for i = 1, len do t[i] = string.char(math.random(32, 126)) end
    local str = table.concat(t)
    total = total + 1
    if rng.pseudohash(str) ~= g.pseudohash(str) then mismatch = mismatch + 1 end
end
T.eq(mismatch, 0, "pseudohash random strings " .. total)

local seeds = {"ABCD1234", "1Z2Y3X4W", "TUTORIAL", "88888888", "KQ3N1P2M"}
local keys = {"shuffle", "boss", "Tag1", "lucky_mult", "lucky_money", "glass", "misprint", "nr1", "cashout1", "wheel"}
for _, seed in ipairs(seeds) do
    local ge = game_env(seed)
    local s = ST.new(seed)
    local bad = 0
    math.randomseed(99)
    for _ = 1, 3000 do
        local key = keys[math.random(#keys)]
        local a = rng.pseudoseed(s, key)
        local b = ge.pseudoseed(key)
        if a ~= b then bad = bad + 1 end
    end
    T.eq(bad, 0, "pseudoseed stream " .. seed)
    for _, key in ipairs(keys) do
        local id = rng.key_id(key)
        T.eq(string.format("%.13f", s.rng[id]), string.format("%.13f", ge.G.GAME.pseudorandom[key]), "rng table " .. key)
    end
    local a1 = rng.random_int(s, "misprint", 0, 23)
    local b1 = ge.pseudorandom("misprint", 0, 23)
    T.eq(a1, b1, "pseudorandom int " .. seed)
    local list_g, list_s = {}, {}
    for i = 1, 52 do
        list_g[i] = {sort_id = i}
        list_s[i] = i
    end
    ge.pseudoshuffle(list_g, ge.pseudoseed("shuffle"))
    rng.shuffle_id(s, rng.key_id("shuffle"), list_s, 52)
    local same = true
    for i = 1, 52 do
        if list_g[i].sort_id ~= list_s[i] then same = false end
    end
    T.ok(same, "pseudoshuffle " .. seed)
    T.near(rng.predict_seed("Joker4", seed), ge.pseudoseed("Joker4", seed), "predict seed " .. seed)
end

local function deck_order_from_game(seed)
    local ge = game_env(seed)
    local protos = {}
    local rc = {"2", "3", "4", "5", "6", "7", "8", "9", "T", "J", "Q", "K", "A"}
    for _, su in ipairs({"H", "C", "D", "S"}) do
        for _, r in ipairs(rc) do protos[#protos + 1] = su .. r end
    end
    table.sort(protos)
    local cards = {}
    for i, p in ipairs(protos) do table.insert(cards, 1, {sort_id = i, name = p}) end
    ge.pseudoshuffle(cards, ge.pseudoseed("shuffle"))
    local out = {}
    for i = #cards, 1, -1 do out[#out + 1] = cards[i].name:sub(2, 2) .. cards[i].name:sub(1, 1) end
    return table.concat(out, " ")
end

for _, seed in ipairs(seeds) do
    local s = E.new_run({seed = seed, deck = "b_red", stake = 1})
    local out = {}
    for i = s.n_deck, 1, -1 do
        local cid = s.deck[i]
        out[#out + 1] = D.RANK_CHARS[s.c_rank[cid]] .. D.SUIT_CHARS[s.c_suit[cid]]
    end
    T.eq(table.concat(out, " "), deck_order_from_game(seed), "starting deck order " .. seed)
end

local function boss_env(seed)
    local env = game_env(seed)
    T.load_game_functions("assets/functions/common_events.lua", {"get_new_boss"}, env)
    local blinds = {}
    local used = {}
    for _, b in ipairs(D.BLINDS) do
        local e = {name = b.name}
        if b.boss then
            e.boss = {min = b.min, showdown = b.showdown}
            used[b.key] = 0
        end
        blinds[b.key] = e
    end
    env.G.P_BLINDS = blinds
    env.G.FTP_LOCKED = false
    env.G.GAME.bosses_used = used
    env.G.GAME.banned_keys = {}
    env.G.GAME.modifiers = {}
    env.G.GAME.win_ante = 8
    env.G.GAME.round_resets = {ante = 1}
    return env
end

for _, seed in ipairs(seeds) do
    local ge = boss_env(seed)
    local s = ST.new(seed)
    s.win_ante = 8
    for i = 1, #D.BLINDS do s.bosses_used[i] = 0 end
    local ok = true
    for ante = 1, 20 do
        ge.G.GAME.round_resets.ante = ante
        s.ante = ante
        local a = D.BLINDS[E.get_new_boss(s)].key
        local b = ge.get_new_boss()
        if a ~= b then
            ok = false
            print("boss mismatch", seed, ante, a, b)
        end
    end
    T.ok(ok, "boss sequence " .. seed)
end

local function pool_env(seed)
    local env = game_env(seed)
    T.load_game_functions("assets/functions/common_events.lua", {"get_current_pool", "get_next_tag_key", "get_next_voucher_key"}, env)
    env.EMPTY = function(t) if t then for k in pairs(t) do t[k] = nil end return t end return {} end
    env.find_joker = function() return {} end
    local tags, vouchers, centers = {}, {}, {}
    for _, t in ipairs(D.TAGS) do tags[#tags + 1] = {key = t.key, min_ante = t.min_ante} end
    for _, v in ipairs(D.VOUCHERS) do
        vouchers[#vouchers + 1] = {key = v.key, set = "Voucher", requires = v.requires and {v.requires} or nil}
    end
    env.G.P_CENTER_POOLS = {Tag = tags, Voucher = vouchers}
    env.G.P_CENTERS = centers
    env.G.ARGS = {}
    env.G.GAME.round_resets = {ante = 1}
    env.G.GAME.banned_keys = {}
    env.G.GAME.pool_flags = {}
    env.G.GAME.used_jokers = {}
    env.G.GAME.used_vouchers = {}
    return env
end

for _, seed in ipairs(seeds) do
    local ge = pool_env(seed)
    local s = ST.new(seed)
    local ok = true
    for ante = 1, 6 do
        ge.G.GAME.round_resets.ante = ante
        s.ante = ante
        for _ = 1, 3 do
            local a = D.TAGS[E.get_next_tag(s)].key
            local b = ge.get_next_tag_key()
            if a ~= b then ok = false print("tag mismatch", seed, ante, a, b) end
        end
        local va = D.VOUCHERS[E.get_next_voucher(s)].key
        local vb = ge.get_next_voucher_key()
        if va ~= vb then ok = false print("voucher mismatch", seed, ante, va, vb) end
        s.used_v[D.VOUCHER_ID[va]] = 1
        ge.G.GAME.used_vouchers[vb] = true
    end
    T.ok(ok, "tag and voucher sequence " .. seed)
end
