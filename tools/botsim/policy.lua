local E = require("bot.sim.engine")
local ST = require("bot.sim.state")
local D = require("bot.sim.data")

local P = {}

local scratch = ST.scratch()
local combo = {}
local best = {}
local nbest = 0

local function search(s, start, depth, maxd)
    local bestv = -1
    if depth > 0 then
        local pos = {}
        for i = 1, depth do pos[i] = combo[i] end
        local g = E.preview_into(scratch, s, pos)
        bestv = g
        if g > P.best_value then
            P.best_value = g
            nbest = depth
            for i = 1, depth do best[i] = combo[i] end
        end
    end
    if depth == maxd then return bestv end
    for i = start, s.n_hand do
        combo[depth + 1] = i
        search(s, i + 1, depth + 1, maxd)
    end
    return bestv
end

function P.best_play(s)
    P.best_value = -1
    nbest = 0
    search(s, 1, 0, math.min(5, s.n_hand))
    local out = {}
    for i = 1, nbest do out[i] = best[i] end
    return out, P.best_value
end

function P.choose(s)
    local ph = s.phase
    if ph == "blind_select" then return {type = "select"} end
    if ph == "round_eval" then return {type = "cash_out"} end
    if ph == "win" then return {type = "endless"} end
    if ph == "shop" then
        if not P.shop then return {type = "leave"} end
        local left = s.money - s.bankrupt_at
        for i = 1, s.n_sj do
            if s.sj_kind[i] == E.K_JOKER and s.n_jok < s.joker_limit and E.shop_joker_cost(s, i) <= left then
                return {type = "buy", card = i}
            end
        end
        for i = 1, s.n_sb do
            local b = D.BOOST[s.sb_id[i]]
            if (b.kind == "Buffoon" or b.kind == "Celestial") and E.shop_booster_cost(s, i) + 5 <= left then
                return {type = "open", card = i}
            end
        end
        return {type = "leave"}
    end
    if ph == "pack" then
        for i = 1, s.n_pk do
            if s.pk_kind[i] == E.K_CONS or (s.pk_kind[i] == E.K_JOKER and s.n_jok < s.joker_limit) then
                return {type = "pick", card = i}
            end
        end
        return {type = "skip"}
    end
    if ph == "play" then
        local cards, v = P.best_play(s)
        local need = s.blind_chips - s.chips
        if v < need and s.discards_left > 0 and s.hands_left > 1 and v * s.hands_left < need then
            local keep = {}
            for _, p in ipairs(cards) do keep[p] = true end
            local d = {}
            for i = s.n_hand, 1, -1 do
                if not keep[i] and #d < 5 then d[#d + 1] = i end
            end
            if #d > 0 then return {type = "discard", cards = d} end
        end
        return {type = "play", cards = cards}
    end
    return nil
end

return P
