package.path = "assets/?.lua;tools/?.lua;" .. package.path

local K = require("botsim.book.check")
local N = require("botsim.book.notes")
local A = require("botsim.book.archetypes")
local json = require("bot.sim.json")
local D = require("bot.sim.data")

local book, counts, errors, cats = K.build()

local hands = book.hand
for i, name in ipairs(D.HAND_NAMES) do
    local h = hands[name]
    if h then
        h.base_chips, h.base_mult = D.HAND_S_CHIPS[i], D.HAND_S_MULT[i]
        h.level_chips, h.level_mult = D.HAND_L_CHIPS[i], D.HAND_L_MULT[i]
    end
end

for _, cat in ipairs(cats) do
    print(string.format("%-14s %d", cat.name, counts[cat.name]))
end

if #errors > 0 then
    for _, e in ipairs(errors) do print("ERROR " .. e) end
    os.exit(1)
end

local out = {categories = book, rules = N.rules, archetypes = A}
local f = assert(io.open("tools/botsim/book/book.json", "w"))
f:write(json.encode(out))
f:close()
print("wrote tools/botsim/book/book.json")
