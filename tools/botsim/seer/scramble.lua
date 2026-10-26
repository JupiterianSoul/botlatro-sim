local ST = require("bot.sim.state")
local rng = require("bot.sim.rng")
local F = require("bot.seer.fair")

local M = {}

function M.variant(s, tag)
    local v = ST.clone(s)
    local seed = "OTHER" .. tag
    v.seed = seed
    v.hashed_seed = rng.pseudohash(seed)
    v.hcache = {}
    for i = 1, v.n_rk do
        local id = v.rng_ids[i]
        v.rng[id] = rng.pseudohash(seed .. "r" .. i)
    end
    local n = v.n_deck
    for i = 1, math.floor(n / 2) do v.deck[i], v.deck[n - i + 1] = v.deck[n - i + 1], v.deck[i] end
    if n >= 3 then v.deck[1], v.deck[2] = v.deck[2], v.deck[1] end
    for i = 1, v.n_hand do
        local cid = v.hand[i]
        if v.c_flip[cid] == 1 and v.n_deck > 0 then
            local d = v.deck[v.n_deck]
            v.deck[v.n_deck] = cid
            v.c_flip[cid] = 0
            v.hand[i] = d
            v.c_flip[d] = 1
        end
    end
    local all = v.n_jok >= 2
    for k = 1, v.n_jok do if v.j_flip[k] ~= 1 then all = false end end
    if all then
        for _, f in ipairs(ST.JOKER_ARRAYS) do
            local a = v[f]
            a[1], a[v.n_jok] = a[v.n_jok], a[1]
        end
    end
    if F.voucher_hidden(v) then v.voucher = (v.voucher % 10) + 1 end
    return v
end

function M.shuffled(s, key)
    local v = M.variant(s, key)
    local n = v.n_deck
    for i = n, 2, -1 do
        local j = math.floor(rng.pseudohash(key .. "#" .. i) * i) + 1
        if j > i then j = i end
        v.deck[i], v.deck[j] = v.deck[j], v.deck[i]
    end
    return v
end

return M
