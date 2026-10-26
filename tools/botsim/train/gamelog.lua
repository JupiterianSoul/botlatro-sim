local D = require("bot.sim.data")
local json = require("bot.sim.json")

local M = {}

function M.path(p, seed)
    return (p:gsub("{seed}", tostring(seed)))
end

function M.append(path, v)
    local f = assert(io.open(path, "ab"))
    f:write(json.encode(v) .. "\n")
    f:close()
end

local function joker_keys(s)
    local out = {}
    for i = 1, s.n_jok do
        local j = D.JOKERS[s.j_id[i]]
        if j then out[#out + 1] = j.key end
    end
    return json.array(out)
end

local function hand_cards(s)
    local out = {}
    for i = 1, s.n_hand do
        local c = s.hand[i]
        out[i] = (D.RANK_CHARS[s.c_rank[c]] or "?") .. (D.SUIT_CHARS[s.c_suit[c]] or "?")
    end
    return json.array(out)
end

function M.blind_key(s, last)
    local b = D.BLINDS[s.blind > 0 and s.blind or last or 0]
    return b and b.key or nil
end

function M.game(s, info)
    local g = {type = "game", deck = info.deck, stake = info.stake, seed = info.seed, won = info.won, ante = info.ante,
        round = s.round, money = s.money, jokers = joker_keys(s), mpa = json.array(info.mpa), hands = s.hands_played,
        discards = s.discards_used, dec = info.dec, sims = info.sims, dur = info.dur}
    if info.won == 0 then g.death = M.blind_key(s, info.last_blind) end
    return g
end

function M.move(s, mc, step, e, tn, n, ph)
    local FE = require("bot.nn.features")
    local m = {phase = ph, ante = s.ante, blind = M.blind_key(s), need = s.blind_chips, score = s.chips, money = s.money,
        hands = s.hands_left, discards = s.discards_left, deck = s.n_deck, hand = hand_cards(s), jokers = joker_keys(s),
        act = tn, v = mc:root_q(), sims = n}
    if tn == "play" or tn == "discard" then
        local cards = {}
        for i = 1, mc.e_nc[e] do cards[i] = (step.cards[i] or 1) - 1 end
        m.cards = json.array(cards)
        m.act = (tn == "play" and "Play " or "Discard ") .. #cards
    end
    local rid = mc.root
    local ef, ec = mc.n_ef[rid], mc.n_ec[rid]
    local total = 0
    local ids = {}
    for x = ef, ef + ec - 1 do
        total = total + mc.e_N[x]
        ids[#ids + 1] = x
    end
    table.sort(ids, function(a, b) return mc.e_N[a] > mc.e_N[b] end)
    local top = {}
    local tmp = {type = "play", cards = {}}
    for i = 1, math.min(3, #ids) do
        local x = ids[i]
        mc:edge_action(x, tmp, s)
        local t = {a = FE.TYPES[mc.e_type[x]], visits = total > 0 and mc.e_N[x] / total or 0, prior = mc.e_prior[x]}
        if mc.e_N[x] > 0 then t.q = mc.e_W[x] / mc.e_N[x] end
        if mc.e_nc[x] > 0 then
            local cs = {}
            for k = 1, mc.e_nc[x] do cs[k] = (tmp.cards[k] or 1) - 1 end
            t.cards = json.array(cs)
        end
        top[i] = t
    end
    m.top = json.array(top)
    return m
end

return M
