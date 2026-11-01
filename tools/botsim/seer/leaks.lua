local ST = require("bot.sim.state")

local M = {}

local function copy_rng(w, real)
    w.rng, w.rng_ids = {}, {}
    w.n_rk = real.n_rk
    for i = 1, real.n_rk do
        local id = real.rng_ids[i]
        w.rng_ids[i] = id
        w.rng[id] = real.rng[id]
    end
end

local function place_true(w, real, slot_hand)
    local cid = real.hand[slot_hand]
    local cur = w.hand[slot_hand]
    if cur == cid then return end
    for i = 1, w.n_deck do
        if w.deck[i] == cid then
            w.deck[i] = cur
            w.c_flip[cur] = 0
            w.hand[slot_hand] = cid
            w.c_flip[cid] = 1
            return
        end
    end
    for i = 1, w.n_hand do
        if w.hand[i] == cid then
            w.hand[i] = cur
            w.hand[slot_hand] = cid
            return
        end
    end
end

M.world = {
    deck = function(w, real)
        if w.n_deck ~= real.n_deck then return end
        for i = 1, real.n_hand do
            if real.c_flip[real.hand[i]] == 1 then place_true(w, real, i) end
        end
        for i = 1, real.n_deck do w.deck[i] = real.deck[i] end
    end,
    flip = function(w, real)
        for i = 1, real.n_hand do
            if real.c_flip[real.hand[i]] == 1 then place_true(w, real, i) end
        end
    end,
    true_future = function(w, real)
        w.seed, w.hashed_seed, w.hcache = real.seed, real.hashed_seed, real.hcache
        copy_rng(w, real)
    end,
    seed = function(w, real) w.seed = real.seed end,
    hashed = function(w, real) w.hashed_seed = real.hashed_seed end,
    rng = function(w, real) copy_rng(w, real) end,
    hcache = function(w, real) w.hcache = real.hcache end,
    voucher = function(w, real, base)
        if base.fair_voucher_hidden == 1 then w.voucher = real.voucher end
    end,
    jokers = function(w, real)
        for _, f in ipairs(ST.JOKER_ARRAYS) do
            for k = 1, real.n_jok do w[f][k] = real[f][k] end
        end
    end,
}

M.sanitize = {
    deck = function(b, real)
        for i = 1, real.n_deck do b.deck[i] = real.deck[i] end
        for i = 1, real.n_hand do b.hand[i] = real.hand[i] end
    end,
    seed = function(b, real) b.seed = real.seed end,
    hashed = function(b, real) b.hashed_seed = real.hashed_seed end,
    rng = function(b, real) copy_rng(b, real) end,
    hcache = function(b, real) b.hcache = real.hcache end,
    voucher = function(b, real) b.voucher = real.voucher end,
    jokers = function(b, real)
        for _, f in ipairs(ST.JOKER_ARRAYS) do
            for k = 1, real.n_jok do b[f][k] = real[f][k] end
        end
    end,
}

return M
