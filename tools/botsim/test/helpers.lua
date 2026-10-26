local D = require("bot.sim.data")
local E = require("bot.sim.engine")
local ST = require("bot.sim.state")

local H = {}

function H.parse_card(s, str)
    local r = D.RANK_ID[str:sub(1, 1)]
    local su = D.SUIT_ID[str:sub(2, 2)]
    local enh, ed, seal = 0, 0, 0
    for tag in str:gmatch(":([%w_]+)") do
        if D.ENH_ID[tag] then enh = D.ENH_ID[tag]
        elseif D.ED_ID[tag] then ed = D.ED_ID[tag]
        else
            for i, k in ipairs(D.SEAL_KEYS) do
                if k == tag then seal = i end
            end
        end
    end
    return E.new_card(s, r, su, enh, ed, seal)
end

function H.cards(s, list)
    local out = {}
    for w in list:gmatch("%S+") do out[#out + 1] = H.parse_card(s, w) end
    return out
end

function H.blank(seed)
    local s = E.new_run({seed = seed or "TESTSEED", deck = "b_red", stake = 1})
    return s
end

function H.round_with(seed, hand_str, jokers, opts)
    local s = H.blank(seed)
    opts = opts or {}
    for _, j in ipairs(jokers or {}) do
        if type(j) == "table" then E.add_joker(s, j[1], j[2]) else E.add_joker(s, j) end
    end
    E.select_blind(s)
    for i = 1, s.n_hand do
        s.n_deck = s.n_deck + 1
        s.deck[s.n_deck] = s.hand[i]
        s.hand[i] = nil
    end
    s.n_hand = 0
    local cs = H.cards(s, hand_str)
    for i, cid in ipairs(cs) do
        s.hand[i] = cid
    end
    s.n_hand = #cs
    if opts.blind_chips then s.blind_chips = opts.blind_chips else s.blind_chips = 1e12 end
    return s
end

H.ST = ST
return H
