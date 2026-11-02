local T = ...

local K = require("botsim.book.check")

local book, counts, errors = K.build()

for _, e in ipairs(errors) do T.eq(e, "", "book") end
T.eq(#errors, 0, "book errors")

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local expected = {
    joker = 150, tarot = 22, planet = 12, spectral = 18, voucher = 32, tag = 24,
    boss = 28, normal_blind = 2, stake = 8, hand = 12, seal = 4, edition = 4,
    enhancement = 8, sticker = 3, booster_kind = 5, booster_size = 3, booster = 32,
}
for name, n in pairs(expected) do
    T.eq(counts[name], n, "data count " .. name)
    T.eq(count(book[name]), n, "entries " .. name)
end
T.eq(counts.tarot + counts.planet + counts.spectral, 52, "consumables")

local decks = 0
for key in pairs(book.deck) do
    if key ~= "b_challenge" then decks = decks + 1 end
end
T.eq(decks, 15, "decks without challenge")
T.ok(book.deck.b_challenge, "challenge deck entry")

for cname, entries in pairs(book) do
    for key, e in pairs(entries) do
        T.ok(e.what and e.what ~= "", cname .. " " .. key .. " what")
        T.ok(e.when and e.when ~= "", cname .. " " .. key .. " when")
        T.eq(e.src, "guess", cname .. " " .. key .. " src")
        T.eq(type(e.combos), "table", cname .. " " .. key .. " combos")
    end
end

for key, e in pairs(book.joker) do
    T.ok(e.kind, key .. " kind")
    T.eq(type(e.hands), "table", key .. " hands")
    T.eq(type(e.archetypes), "table", key .. " archetypes")
    if e.kind == "scaling" then T.ok(e.scale, key .. " scale") end
end
