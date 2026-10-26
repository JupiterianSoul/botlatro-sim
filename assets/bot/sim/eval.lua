local M = {}

local E_WILD, E_STONE = 3, 6

local present = {}
local scoring = {}
local cnt = {}
local ranks = {}
local fl = {}
local st = {}
local flush_ok = {}
for i = 1, 12 do present[i] = false end
for i = 1, 16 do scoring[i] = false; ranks[i] = 0; fl[i] = false; st[i] = false; flush_ok[i] = false end
for r = 0, 15 do cnt[r] = 0 end
M.present = present
M.scoring = scoring

local function is_suit_flush(s, cid, suit, smeared)
    if s.c_enh[cid] == E_STONE then return false end
    if s.c_enh[cid] == E_WILD and s.c_debuff[cid] == 0 then return true end
    local cs = s.c_suit[cid]
    if smeared and ((cs == 2 or cs == 4) == (suit == 2 or suit == 4)) then return true end
    return cs == suit
end
M.is_suit_flush = is_suit_flush

local SN = {0.04, 0.03, 0.02, 0.01}
local SO = {0.004, 0.003, 0.002, 0.001}

local function nominal_key(s, cid)
    local r = s.c_rank[cid]
    local m = 1
    if s.c_enh[cid] == E_STONE then m = -1000 end
    local sn = SN[s.c_suit[cid]]
    local so = SO[s.c_osuit[cid]]
    local nom = r == 14 and 11 or (r > 10 and 10 or r)
    local face = r == 11 and 0.1 or r == 12 and 0.2 or r == 13 and 0.3 or r == 14 and 0.4 or 0
    return nom + sn * m + so * 0.0001 * m + face
end
M.nominal_key = nominal_key

local function nominal_greater(s, a, b)
    local ka, kb = nominal_key(s, a), nominal_key(s, b)
    if ka ~= kb then return ka > kb end
    return s.c_uid[a] < s.c_uid[b]
end
M.nominal_greater = nominal_greater

function M.evaluate(s, cards, n, four_fingers, shortcut, smeared, splash)
    for i = 1, 12 do present[i] = false end
    for r = 2, 14 do cnt[r] = 0 end
    local c_enh, c_rank = s.c_enh, s.c_rank
    for i = 1, n do
        local cid = cards[i]
        scoring[i] = false
        fl[i] = false
        st[i] = false
        if c_enh[cid] == E_STONE then
            ranks[i] = 0
        else
            local r = c_rank[cid]
            ranks[i] = r
            cnt[r] = cnt[r] + 1
        end
    end
    local r5, r4, r3, r2a, r2b, n2 = 0, 0, 0, 0, 0, 0
    for r = 14, 2, -1 do
        local c = cnt[r]
        if c == 5 then r5 = r
        elseif c == 4 then if r4 == 0 then r4 = r end
        elseif c == 3 then if r3 == 0 then r3 = r end
        elseif c == 2 then
            n2 = n2 + 1
            if r2a == 0 then r2a = r elseif r2b == 0 then r2b = r end
        end
    end
    local need = four_fingers and 4 or 5
    local has_flush = false
    if n <= 5 and n >= need then
        for suit = 1, 4 do
            local fc = 0
            for i = 1, n do
                local ok = is_suit_flush(s, cards[i], suit, smeared)
                flush_ok[i] = ok
                if ok then fc = fc + 1 end
            end
            if fc >= need then
                has_flush = true
                for i = 1, n do fl[i] = flush_ok[i] end
                break
            end
        end
    end
    local has_straight = false
    if n <= 5 and n >= need then
        local len, skipped = 0, false
        for j = 1, 14 do
            local r = j == 1 and 14 or j
            if cnt[r] > 0 then
                len = len + 1
                skipped = false
                for i = 1, n do
                    if ranks[i] == r then st[i] = true end
                end
            elseif shortcut and not skipped and j ~= 14 then
                skipped = true
            else
                len = 0
                skipped = false
                if not has_straight then
                    for i = 1, n do st[i] = false end
                end
                if has_straight then break end
            end
            if len >= need then has_straight = true end
        end
        if not has_straight then
            for i = 1, n do st[i] = false end
        end
    end
    local p5, p4, p3, p2 = r5 > 0, r4 > 0, r3 > 0, n2 > 0
    if p5 and has_flush then present[1] = true end
    if p3 and p2 and has_flush then present[2] = true end
    if p5 then present[3] = true end
    if has_flush and has_straight then present[4] = true end
    if p4 or p5 then present[5] = true end
    if p3 and p2 then present[6] = true end
    if has_flush then present[7] = true end
    if has_straight then present[8] = true end
    if p3 or present[5] then present[9] = true end
    if n2 == 2 or (r3 > 0 and n2 == 1) then present[10] = true end
    if p2 or present[9] then present[11] = true end
    if n > 0 then present[12] = true end
    local top
    if present[1] then
        top = 1
        for i = 1, n do scoring[i] = ranks[i] == r5 end
    elseif present[2] then
        top = 2
        for i = 1, n do scoring[i] = ranks[i] == r3 or ranks[i] == r2a end
    elseif p5 then
        top = 3
        for i = 1, n do scoring[i] = ranks[i] == r5 end
    elseif present[4] then
        top = 4
        for i = 1, n do scoring[i] = fl[i] or st[i] end
    elseif p4 then
        top = 5
        for i = 1, n do scoring[i] = ranks[i] == r4 end
    elseif present[6] then
        top = 6
        for i = 1, n do scoring[i] = ranks[i] == r3 or ranks[i] == r2a end
    elseif has_flush then
        top = 7
        for i = 1, n do scoring[i] = fl[i] end
    elseif has_straight then
        top = 8
        for i = 1, n do scoring[i] = st[i] end
    elseif p3 then
        top = 9
        for i = 1, n do scoring[i] = ranks[i] == r3 end
    elseif present[10] then
        top = 10
        local rb = r2b > 0 and r2b or r3
        for i = 1, n do scoring[i] = ranks[i] == r2a or ranks[i] == rb end
    elseif p2 then
        top = 11
        for i = 1, n do scoring[i] = ranks[i] == r2a end
    elseif n > 0 then
        top = 12
        local best = 1
        for i = 2, n do
            if nominal_greater(s, cards[i], cards[best]) then best = i end
        end
        scoring[best] = true
    else
        return 0
    end
    if splash then
        for i = 1, n do scoring[i] = true end
    else
        for i = 1, n do
            if c_enh[cards[i]] == E_STONE then scoring[i] = true end
        end
    end
    return top
end

return M
