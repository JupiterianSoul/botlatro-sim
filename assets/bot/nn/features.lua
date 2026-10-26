local D = require("bot.sim.data")
local EV = require("bot.sim.eval")
local E = require("bot.sim.engine")
local BUF = require("bot.nn.buf")

local M = {}

local log, min, max = math.log, math.min, math.max

M.VERSION = 2
M.MAXC = 24
M.MAXJ = 16
M.MAXSEL = 5
M.MAXI = 40

local DECK_KEYS = {}
for k in pairs(D.DECKS) do DECK_KEYS[#DECK_KEYS + 1] = k end
table.sort(DECK_KEYS)
local DECK_IDX = {}
for i, k in ipairs(DECK_KEYS) do DECK_IDX[k] = i end
M.DECK_KEYS, M.DECK_IDX = DECK_KEYS, DECK_IDX

local PHASES = {blind_select = 1, play = 2, round_eval = 3, shop = 4, game_over = 5, pack = 6, win = 7}
M.PHASES = PHASES

M.TYPES = {"play", "discard", "select", "skip", "reroll_boss", "buy", "buy_use", "sell_joker", "sell_cons", "use",
    "redeem", "open", "reroll", "leave", "pick", "skip_pack", "move_joker"}
M.TYPE_ID = {}
for i, t in ipairs(M.TYPES) do M.TYPE_ID[t] = i end
local T = M.TYPE_ID
M.ENT_NONE, M.ENT_ITEM, M.ENT_JOKER = 0, 1, 2
M.TYPE_ENT = {[T.buy] = 1, [T.buy_use] = 1, [T.sell_joker] = 2, [T.sell_cons] = 1, [T.use] = 1, [T.redeem] = 1,
    [T.open] = 1, [T.pick] = 1, [T.move_joker] = 2}
for i = 1, #M.TYPES do M.TYPE_ENT[i] = M.TYPE_ENT[i] or 0 end

local NB, NT, NV, NJK = #D.BLINDS, #D.TAGS, #D.VOUCHERS, #D.JOKERS
local NCO, NBO = #D.CONS, #D.BOOST
local MAX_STAKE = 12

local function layout(spec)
    local off, n = {}, 0
    for _, e in ipairs(spec) do
        off[e[1]] = n
        n = n + e[2]
    end
    return off, n
end

local G, GF = layout({
    {"phase", 7}, {"ante", 1}, {"round", 1}, {"ante_oh", 8}, {"blind", NB}, {"boss_choice", NB}, {"on_deck", 3},
    {"blind_chips", 1}, {"chips", 1}, {"ratio", 1}, {"need", 1}, {"hands", 1}, {"discards", 1}, {"last_hand", 1},
    {"hand_size", 1}, {"joker_limit", 1}, {"n_jok", 1}, {"cons_limit", 1}, {"n_cons", 1}, {"money", 1}, {"money_lin", 1},
    {"deck", #DECK_KEYS}, {"stake", MAX_STAKE}, {"levels", 48}, {"pool_rank", 13}, {"pool_suit", 4}, {"pool_enh", 8},
    {"pool_n", 1}, {"n_flipped", 1}, {"n_hand", 1}, {"n_disc", 1}, {"tag_small", NT}, {"tag_big", NT},
    {"voucher", NV}, {"used_v", NV}, {"boss_rerolled", 1}, {"skips", 1}, {"interest_cap", 1}, {"discount", 1},
    {"inflation", 1}, {"prob", 1}, {"win_ante", 1}, {"pending_cons", 1}, {"disabled", 1}, {"no_interest", 1},
    {"pack_kind", 5}, {"pack_choices", 1}, {"reroll_cost", 1}, {"free_rerolls", 1}, {"first_buffoon", 1},
    {"n_tags", 1}, {"shop_left", 1}, {"bias", 1},
})
M.G, M.GF = G, GF

local C, CF = layout({
    {"rank", 13}, {"suit", 4}, {"enh", 8}, {"ed", 4}, {"seal", 4}, {"debuff", 1}, {"flipped", 1}, {"forced", 1},
    {"bonus", 1}, {"nominal", 1}, {"played", 1},
})
M.C, M.CF = C, CF

local JL, JF = layout({
    {"id", NJK}, {"ed", 4}, {"debuff", 1}, {"eternal", 1}, {"perish", 1}, {"rental", 1}, {"sell", 1},
    {"mult", 1}, {"x", 1}, {"ex", 1}, {"n", 1}, {"h", 1}, {"pos", 1}, {"flipped", 1},
})
M.J, M.JF = JL, JF

M.AREAS = {"shop", "voucher", "booster", "pack", "cons", "tag"}
local IL, IF = layout({
    {"area", 6}, {"joker", NJK}, {"cons", NCO}, {"voucher", NV}, {"booster", NBO}, {"tag", NT},
    {"rank", 13}, {"suit", 4}, {"enh", 8}, {"ed", 4}, {"seal", 4}, {"eternal", 1}, {"perish", 1}, {"rental", 1},
    {"cost", 1}, {"afford", 1}, {"sell", 1}, {"usable", 1}, {"targets", 1}, {"pos", 1}, {"tag_hand", 12}, {"bias", 1},
})
M.I, M.IF = IL, IF

local A, FA = layout({
    {"n", 5}, {"hand", 12}, {"n_scoring", 1}, {"est", 1}, {"clears", 1}, {"n_debuff", 1}, {"n_flipped", 1},
    {"bias", 1}, {"cost", 1}, {"after", 1}, {"interest", 1}, {"to", 8}, {"shift", 1},
})
M.A, M.FA = A, FA

local function slog(v)
    if v >= 0 then return log(1 + v) end
    return -log(1 - v)
end

function M.new_state_buf(plain)
    return {
        g = BUF.alloc(GF, plain), c = BUF.alloc(M.MAXC * CF, plain), j = BUF.alloc(M.MAXJ * JF, plain),
        i = BUF.alloc(M.MAXI * IF, plain), nc = 0, nj = 0, ni = 0, plain = plain, i_first = {0, 0, 0, 0, 0, 0},
    }
end

function M.new_action_buf(cap, plain)
    cap = cap or 512
    return {
        cap = cap, n = 0, plain = plain, A = A,
        type = BUF.alloc_int(cap, plain), nc = BUF.alloc_int(cap, plain), c = BUF.alloc_int(cap * M.MAXSEL, plain),
        fa = BUF.alloc(cap * FA, plain), logit = BUF.alloc(cap, plain),
        top = BUF.alloc_int(cap, plain), xs = BUF.alloc(cap, plain), xe = BUF.alloc(cap, plain),
        xc = BUF.alloc(cap, plain), xd = BUF.alloc(cap, plain), xf = BUF.alloc(cap, plain),
        ent = BUF.alloc_int(cap, plain), arg = BUF.alloc_int(cap, plain), arg2 = BUF.alloc_int(cap, plain),
    }
end

local COMPACT = {"type", "nc", "logit", "top", "xs", "xe", "xc", "xd", "xf", "ent", "arg", "arg2"}

local function grow_actions(ab, need)
    if need <= ab.cap then return end
    local cap = ab.cap
    while cap < need do cap = cap * 2 end
    local nb = M.new_action_buf(cap, ab.plain)
    local n = ab.n
    for _, f in ipairs(COMPACT) do
        local src, dst = ab[f], nb[f]
        for i = 0, n - 1 do dst[i] = src[i] end
    end
    for i = 0, n * M.MAXSEL - 1 do nb.c[i] = ab.c[i] end
    for i = 0, n * FA - 1 do nb.fa[i] = ab.fa[i] end
    nb.n = n
    for k, v in pairs(nb) do ab[k] = v end
end

local pool_ids = {}

local function unseen_pool(s)
    local n = 0
    for i = 1, s.n_deck do
        n = n + 1
        pool_ids[n] = s.deck[i]
    end
    for i = 1, s.n_hand do
        local cid = s.hand[i]
        if s.c_flip[cid] == 1 then
            n = n + 1
            pool_ids[n] = cid
        end
    end
    return n
end
M.unseen_pool = unseen_pool
M.pool_ids = pool_ids

function M.voucher_hidden(s)
    local ph = s.phase
    if s.round == 0 then return true end
    if s.round == 1 and (ph == "play" or ph == "round_eval") then return true end
    return ph == "round_eval" and s.state_boss == 3
end

local CONS, CONS_ID = D.CONS, D.CONS_ID
local K_JOKER, K_CONS, K_CARD = E.K_JOKER, E.K_CONS, E.K_CARD

local function cons_targets(cid)
    local c = CONS[cid]
    local mx = c.config.max_highlighted
    if mx then return c.config.min_highlighted or 1, min(5, mx) end
    if c.name == "Aura" then return 1, 1 end
    return 0, 0
end
M.cons_targets = cons_targets

local function item_card(ib, o, s, cid)
    local e = s.c_enh[cid]
    if e ~= 6 then
        ib[o + IL.rank + s.c_rank[cid] - 2] = 1
        ib[o + IL.suit + s.c_suit[cid] - 1] = 1
    end
    if e > 0 then ib[o + IL.enh + e - 1] = 1 end
    local ed = s.c_ed[cid]
    if ed > 0 then ib[o + IL.ed + ed - 1] = 1 end
    local se = s.c_seal[cid]
    if se > 0 then ib[o + IL.seal + se - 1] = 1 end
end

local function item_cost(ib, o, cost, left)
    ib[o + IL.cost] = slog(cost) / 3
    ib[o + IL.afford] = (cost <= 0 or cost <= left) and 1 or 0
end

local function item_thing(ib, o, s, kind, id, ed, et, per, rent, cid)
    if kind == K_JOKER then
        ib[o + IL.joker + id - 1] = 1
    elseif kind == K_CONS then
        ib[o + IL.cons + id - 1] = 1
        local lo, hi = cons_targets(id)
        ib[o + IL.targets] = hi / 5
        if lo == 0 then ib[o + IL.usable] = 1 end
    elseif cid and cid > 0 then
        item_card(ib, o, s, cid)
    end
    if kind ~= K_CARD and ed and ed > 0 then ib[o + IL.ed + ed - 1] = 1 end
    if et == 1 then ib[o + IL.eternal] = 1 end
    if per and per >= 0 then ib[o + IL.perish] = (per + 1) / 6 end
    if rent == 1 then ib[o + IL.rental] = 1 end
end

local function islot(ib, ni, area, pos)
    local o = ni * IF
    for f = 0, IF - 1 do ib[o + f] = 0 end
    ib[o + IL.area + area - 1] = 1
    ib[o + IL.pos] = (pos - 1) / 5
    ib[o + IL.bias] = 1
    return o
end

function M.items(s, F)
    local ib, first = F.i, F.i_first
    local MAXI = M.MAXI
    local left = s.money - s.bankrupt_at
    local ni = 0
    first[1] = ni
    for p = 1, s.n_sj do
        if ni >= MAXI then break end
        local o = islot(ib, ni, 1, p)
        ni = ni + 1
        local kind = s.sj_kind[p]
        item_thing(ib, o, s, kind, s.sj_id[p], s.sj_ed[p], s.sj_et[p], s.sj_per[p], s.sj_rent[p], s.sj_cid[p])
        item_cost(ib, o, E.shop_joker_cost(s, p), left)
    end
    first[2] = ni
    for p = 1, s.n_sv do
        if ni >= MAXI then break end
        local o = islot(ib, ni, 2, p)
        ni = ni + 1
        ib[o + IL.voucher + s.sv_id[p] - 1] = 1
        item_cost(ib, o, E.shop_voucher_cost(s, p), left)
    end
    first[3] = ni
    for p = 1, s.n_sb do
        if ni >= MAXI then break end
        local o = islot(ib, ni, 3, p)
        ni = ni + 1
        ib[o + IL.booster + s.sb_id[p] - 1] = 1
        item_cost(ib, o, E.shop_booster_cost(s, p), left)
    end
    first[4] = ni
    if s.phase == "pack" then
        for p = 1, s.n_pk do
            if ni >= MAXI then break end
            local o = islot(ib, ni, 4, p)
            ni = ni + 1
            item_thing(ib, o, s, s.pk_kind[p], s.pk_id[p], s.pk_ed[p], s.pk_et[p], s.pk_per[p], s.pk_rent[p], s.pk_cid[p])
        end
    end
    first[5] = ni
    for p = 1, s.n_cons do
        if ni >= MAXI then break end
        local o = islot(ib, ni, 5, p)
        ni = ni + 1
        local cid = CONS_ID[s.cons[p]]
        item_thing(ib, o, s, K_CONS, cid, s.cons_ed[p], 0, 0, 0, 0)
        ib[o + IL.sell] = slog(E.cons_sell(s, p)) / 3
    end
    first[6] = ni
    for p = 1, s.n_tags do
        if ni >= MAXI then break end
        local o = islot(ib, ni, 6, p)
        ni = ni + 1
        local t = s.tags[p]
        if t and t > 0 and t <= NT then ib[o + IL.tag + t - 1] = 1 end
        local h = s.tag_hand[p] or 0
        if h > 0 and h <= 12 then ib[o + IL.tag_hand + h - 1] = 1 end
    end
    F.ni = ni
    return ni
end

function M.state(s, F)
    local g = F.g
    BUF.fill(g, GF, 0)
    g[G.phase + (PHASES[s.phase] or 1) - 1] = 1
    local ante = s.ante
    g[G.ante] = ante / 8
    g[G.round] = s.round / 24
    g[G.ante_oh + min(max(ante, 1), 8) - 1] = 1
    if s.blind and s.blind > 0 and s.blind <= NB then g[G.blind + s.blind - 1] = 1 end
    if s.boss_choice and s.boss_choice > 0 and s.boss_choice <= NB then g[G.boss_choice + s.boss_choice - 1] = 1 end
    local od = s.blind_on_deck
    if od and od >= 1 and od <= 3 then g[G.on_deck + od - 1] = 1 end
    local bc, ch = s.blind_chips, s.chips
    g[G.blind_chips] = slog(bc) / 10
    g[G.chips] = slog(ch) / 10
    if bc > 0 then g[G.ratio] = min(ch / bc, 2) end
    g[G.need] = slog(max(bc - ch, 0)) / 10
    g[G.hands] = s.hands_left / 5
    g[G.discards] = s.discards_left / 5
    g[G.last_hand] = s.hands_left == 1 and 1 or 0
    g[G.hand_size] = s.hand_size / 10
    g[G.joker_limit] = s.joker_limit / 5
    g[G.n_jok] = s.n_jok / 5
    g[G.cons_limit] = s.cons_limit / 5
    g[G.n_cons] = s.n_cons / 5
    g[G.money] = slog(s.money) / 5
    g[G.money_lin] = min(max(s.money, -20), 100) / 25
    local di = DECK_IDX[s.deck_key]
    if di then g[G.deck + di - 1] = 1 end
    local st = s.stake
    if st >= 1 and st <= MAX_STAKE then g[G.stake + st - 1] = 1 end
    local lv = G.levels
    for h = 1, 12 do
        local o = lv + (h - 1) * 4
        g[o] = s.h_level[h] / 10
        g[o + 1] = slog(s.h_chips[h]) / 6
        g[o + 2] = slog(s.h_mult[h]) / 4
        g[o + 3] = min(s.h_played[h], 40) / 10
    end
    local n = unseen_pool(s)
    local c_rank, c_suit, c_enh = s.c_rank, s.c_suit, s.c_enh
    local pr, ps, pe = G.pool_rank, G.pool_suit, G.pool_enh
    for i = 1, n do
        local cid = pool_ids[i]
        local e = c_enh[cid]
        if e ~= 6 then
            g[pr + c_rank[cid] - 2] = g[pr + c_rank[cid] - 2] + 0.25
            g[ps + c_suit[cid] - 1] = g[ps + c_suit[cid] - 1] + 1 / 13
        end
        if e > 0 then g[pe + e - 1] = g[pe + e - 1] + 0.25 end
    end
    g[G.pool_n] = n / 52
    g[G.n_flipped] = (n - s.n_deck) / 5
    g[G.n_hand] = s.n_hand / 10
    g[G.n_disc] = s.n_disc / 52
    if s.tag_small and s.tag_small > 0 and s.tag_small <= NT then g[G.tag_small + s.tag_small - 1] = 1 end
    if s.tag_big and s.tag_big > 0 and s.tag_big <= NT then g[G.tag_big + s.tag_big - 1] = 1 end
    if s.voucher and s.voucher > 0 and s.voucher <= NV and not M.voucher_hidden(s) then g[G.voucher + s.voucher - 1] = 1 end
    local uv = s.used_v
    for v = 1, NV do
        if uv[v] ~= 0 then g[G.used_v + v - 1] = 1 end
    end
    g[G.boss_rerolled] = s.boss_rerolled ~= 0 and 1 or 0
    g[G.skips] = min(s.skips, 20) / 10
    g[G.interest_cap] = s.interest_cap / 25
    g[G.discount] = s.discount / 50
    g[G.inflation] = s.inflation / 10
    g[G.prob] = s.prob / 2
    g[G.win_ante] = s.win_ante / 8
    g[G.pending_cons] = s.pending_cons / 2
    g[G.disabled] = s.blind_disabled ~= 0 and 1 or 0
    g[G.no_interest] = s.no_interest ~= 0 and 1 or 0
    local pk = s.pack_kind
    if s.phase == "pack" and pk and pk >= 1 and pk <= 5 then g[G.pack_kind + pk - 1] = 1 end
    g[G.pack_choices] = s.phase == "pack" and s.pack_choices / 2 or 0
    g[G.reroll_cost] = slog(s.reroll_cost) / 3
    g[G.free_rerolls] = min(s.free_rerolls, 5) / 2
    g[G.first_buffoon] = s.first_shop_buffoon ~= 0 and 1 or 0
    g[G.n_tags] = min(s.n_tags, 10) / 3
    g[G.shop_left] = slog(s.money - s.bankrupt_at) / 5
    g[G.bias] = 1

    local nc = min(s.n_hand, M.MAXC)
    local cb = F.c
    BUF.fill(cb, nc * CF, 0)
    local nominal = D.RANK_NOMINAL
    for i = 1, nc do
        local cid = s.hand[i]
        local o = (i - 1) * CF
        if s.c_flip[cid] == 1 then
            cb[o + C.flipped] = 1
        else
            local e = c_enh[cid]
            if e ~= 6 then
                cb[o + C.rank + c_rank[cid] - 2] = 1
                cb[o + C.suit + c_suit[cid] - 1] = 1
                cb[o + C.nominal] = nominal[c_rank[cid]] / 11
            end
            if e > 0 then cb[o + C.enh + e - 1] = 1 end
            local ed = s.c_ed[cid]
            if ed > 0 then cb[o + C.ed + ed - 1] = 1 end
            local se = s.c_seal[cid]
            if se > 0 then cb[o + C.seal + se - 1] = 1 end
            cb[o + C.debuff] = s.c_debuff[cid] ~= 0 and 1 or 0
            cb[o + C.bonus] = s.c_bonus[cid] / 50
            cb[o + C.played] = s.c_pta[cid] ~= 0 and 1 or 0
        end
        cb[o + C.forced] = s.c_forced[cid] ~= 0 and 1 or 0
    end
    F.nc = nc

    local nj = min(s.n_jok, M.MAXJ)
    local jb = F.j
    BUF.fill(jb, nj * JF, 0)
    for k = 1, nj do
        local o = (k - 1) * JF
        jb[o + JL.pos] = (k - 1) / 5
        if s.j_flip[k] == 1 then
            jb[o + JL.flipped] = 1
        else
            jb[o + JL.id + s.j_id[k] - 1] = 1
            local ed = s.j_ed[k]
            if ed > 0 then jb[o + JL.ed + ed - 1] = 1 end
            jb[o + JL.debuff] = s.j_debuff[k] ~= 0 and 1 or 0
            jb[o + JL.eternal] = s.j_eternal[k] ~= 0 and 1 or 0
            local p = s.j_perish[k]
            if p >= 0 then jb[o + JL.perish] = (p + 1) / 6 end
            jb[o + JL.rental] = s.j_rental[k] ~= 0 and 1 or 0
            jb[o + JL.sell] = slog(E.joker_sell(s, k)) / 3
            jb[o + JL.mult] = slog(s.j_mult[k]) / 4
            jb[o + JL.x] = slog(s.j_x[k] - 1) / 2
            jb[o + JL.ex] = slog(s.j_ex[k]) / 4
            jb[o + JL.n] = slog(s.j_n[k]) / 3
            jb[o + JL.h] = slog(max(s.hands_played - s.j_h[k], 0)) / 4
        end
    end
    F.nj = nj
    M.items(s, F)
    return F
end

local sel_ids = {}
local combo = {}
local ENH_CHIPS = {[0] = 0, 30, 0, 0, 0, 0, 50, 0, 0}

local function action_fa(s, ab, k, kind, n, mods, remaining)
    local fa = ab.fa
    local o = k * FA
    for f = 0, FA - 1 do fa[o + f] = 0 end
    fa[o + A.n + n - 1] = 1
    fa[o + A.bias] = 1
    local c_flip, c_debuff, c_enh = s.c_flip, s.c_debuff, s.c_enh
    local nd, nf, m = 0, 0, 0
    for i = 1, n do
        local cid = s.hand[combo[i]]
        if c_flip[cid] == 1 then
            nf = nf + 1
        else
            m = m + 1
            sel_ids[m] = cid
            if c_debuff[cid] ~= 0 then nd = nd + 1 end
        end
    end
    fa[o + A.n_debuff] = nd / 5
    fa[o + A.n_flipped] = nf / 5
    if kind ~= 1 or m == 0 then return end
    local top = EV.evaluate(s, sel_ids, m, mods[1], mods[2], mods[3], mods[4])
    if top == 0 then top = 12 end
    fa[o + A.hand + top - 1] = 1
    local sc = EV.scoring
    local chips, mult, ns = s.h_chips[top], s.h_mult[top], 0
    local nominal = D.RANK_NOMINAL
    for i = 1, m do
        if sc[i] then
            local cid = sel_ids[i]
            ns = ns + 1
            if c_debuff[cid] == 0 then
                local e = c_enh[cid]
                if e ~= 6 then chips = chips + nominal[s.c_rank[cid]] end
                chips = chips + ENH_CHIPS[e] + s.c_bonus[cid]
                if e == 2 then mult = mult + 4 end
            end
        end
    end
    local est = chips * mult
    fa[o + A.n_scoring] = ns / 5
    fa[o + A.est] = min(slog(est) / slog(max(remaining, 1)), 3)
    fa[o + A.clears] = est >= remaining and 1 or 0
end

local J = E.J
local mods = {false, false, false, false}

function M.actions_ref(s, ab)
    ab.n = 0
    if s.phase ~= "play" then return 0 end
    local nh = min(s.n_hand, M.MAXC)
    local forced = 0
    for i = 1, nh do
        if s.c_forced[s.hand[i]] ~= 0 then forced = i end
    end
    mods[1] = E.find_joker(s, J.four_fingers) and true or false
    mods[2] = E.find_joker(s, J.shortcut) and true or false
    mods[3] = E.find_joker(s, J.smeared) and true or false
    mods[4] = E.find_joker(s, J.splash) and true or false
    local remaining = max(s.blind_chips - s.chips, 0)
    local kmax = min(M.MAXSEL, nh)
    for kind = 1, 2 do
        local allowed = (kind == 1 and s.hands_left > 0) or (kind == 2 and s.discards_left > 0)
        if allowed then
            for n = 1, kmax do
                for i = 1, n do combo[i] = i end
                while true do
                    local ok = forced == 0
                    if not ok then
                        for i = 1, n do
                            if combo[i] == forced then ok = true end
                        end
                    end
                    if ok then
                        local k = ab.n
                        grow_actions(ab, k + 1)
                        ab.type[k] = kind
                        ab.nc[k] = n
                        local co = k * M.MAXSEL
                        for i = 1, M.MAXSEL do ab.c[co + i - 1] = i <= n and combo[i] - 1 or -1 end
                        action_fa(s, ab, k, kind, n, mods, remaining)
                        ab.n = k + 1
                    end
                    local i = n
                    while i >= 1 and combo[i] == nh - n + i do i = i - 1 end
                    if i < 1 then break end
                    combo[i] = combo[i] + 1
                    for j = i + 1, n do combo[j] = combo[j - 1] + 1 end
                end
            end
        end
    end
    return ab.n
end

local bit = require("bit")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift

local function straight_mask(rb, need, shortcut)
    local marks, len, skipped, has = 0, 0, false, false
    for j = 1, 14 do
        local r = j == 1 and 14 or j
        if band(rb, lshift(1, r)) ~= 0 then
            len = len + 1
            skipped = false
            marks = bor(marks, lshift(1, r))
        elseif shortcut and not skipped and j ~= 14 then
            skipped = true
        else
            len = 0
            skipped = false
            if not has then marks = 0 end
            if has then break end
        end
        if len >= need then has = true end
    end
    return has and marks or 0
end

local str_tables = {}
local function straight_table(need, shortcut)
    local key = need * 2 + (shortcut and 1 or 0)
    local t = str_tables[key]
    if t then return t end
    t = {}
    for i = 0, 8191 do t[i] = straight_mask(i * 4, need, shortcut) end
    str_tables[key] = t
    return t
end
M.straight_mask = straight_mask

local combo_cache = {}
local function combos(nh)
    local cc = combo_cache[nh]
    if cc then return cc end
    local sz, cs, n = {}, {}, 0
    local cb = {}
    for k = 1, min(M.MAXSEL, nh) do
        for i = 1, k do cb[i] = i end
        while true do
            n = n + 1
            sz[n] = k
            for i = 1, M.MAXSEL do cs[(n - 1) * M.MAXSEL + i] = i <= k and cb[i] or 0 end
            local i = k
            while i >= 1 and cb[i] == nh - k + i do i = i - 1 end
            if i < 1 then break end
            cb[i] = cb[i] + 1
            for j = i + 1, k do cb[j] = cb[j - 1] + 1 end
        end
    end
    cc = {n = n, sz = sz, cs = cs}
    combo_cache[nh] = cc
    return cc
end

local P_flip, P_deb, P_r, P_rbit, P_sm, P_pk, P_nom, P_eb, P_bon, P_mul, P_key, P_uid, P_stone = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
local SUITBIT = {1, 2, 4, 8}
local SUITPK = {1, 8, 64, 512}
local sel, grp = {}, {}
for i = 1, 8 do sel[i], grp[i] = 0, 0 end

function M.actions_compact(s, ab)
    ab.n = 0
    if s.phase ~= "play" then return 0 end
    local play_ok, disc_ok = s.hands_left > 0, s.discards_left > 0
    if not play_ok and not disc_ok then return 0 end
    local nh = min(s.n_hand, M.MAXC)
    local hand = s.hand
    local c_forced, c_flip, c_debuff, c_enh, c_rank, c_bonus, c_uid = s.c_forced, s.c_flip, s.c_debuff, s.c_enh, s.c_rank, s.c_bonus, s.c_uid
    local forced = 0
    for i = 1, nh do
        if c_forced[hand[i]] ~= 0 then forced = i end
    end
    local ff = E.find_joker(s, J.four_fingers)
    local shortcut = E.find_joker(s, J.shortcut)
    local smeared = E.find_joker(s, J.smeared)
    local splash = E.find_joker(s, J.splash)
    local need = ff and 4 or 5
    local STR = straight_table(need, shortcut)
    local nominal = D.RANK_NOMINAL
    local is_suit_flush, nominal_key = EV.is_suit_flush, EV.nominal_key
    for i = 1, nh do
        local cid = hand[i]
        if c_flip[cid] == 1 then
            P_flip[i] = true
        else
            P_flip[i] = false
            P_deb[i] = c_debuff[cid] ~= 0
            local e = c_enh[cid]
            local stone = e == 6
            P_stone[i] = stone
            local r = stone and 0 or c_rank[cid]
            P_r[i] = r
            P_rbit[i] = stone and 0 or lshift(1, r)
            local sm, pk = 0, 0
            for suit = 1, 4 do
                if is_suit_flush(s, cid, suit, smeared) then
                    sm = sm + SUITBIT[suit]
                    pk = pk + SUITPK[suit]
                end
            end
            P_sm[i], P_pk[i] = sm, pk
            P_nom[i] = stone and -1 or nominal[c_rank[cid]]
            P_eb[i] = ENH_CHIPS[e]
            P_bon[i] = c_bonus[cid]
            P_mul[i] = e == 2
            P_key[i] = nominal_key(s, cid)
            P_uid[i] = c_uid[cid]
        end
    end
    local remaining = max(s.blind_chips - s.chips, 0)
    local lrem = slog(max(remaining, 1))
    local h_chips, h_mult = s.h_chips, s.h_mult
    local cc = combos(nh)
    local nco, csz, ccs = cc.n, cc.sz, cc.cs
    local MSL = M.MAXSEL
    local np = 0
    if forced == 0 then
        np = nco
    else
        for q = 1, nco do
            local o = (q - 1) * MSL
            for i = 1, csz[q] do
                if ccs[o + i] == forced then np = np + 1 break end
            end
        end
    end
    local total = (play_ok and np or 0) + (disc_ok and np or 0)
    grow_actions(ab, total)
    local a_type, a_nc, a_c, a_top, a_xs, a_xe, a_xc, a_xd, a_xf = ab.type, ab.nc, ab.c, ab.top, ab.xs, ab.xe, ab.xc, ab.xd, ab.xf
    local doff = play_ok and np or 0
    local k = 0
    for q = 1, nco do
        local n = csz[q]
        local o = (q - 1) * MSL
        local ok = forced == 0
        if not ok then
            for i = 1, n do
                if ccs[o + i] == forced then ok = true end
            end
        end
        if ok then
            local m, nd, nf = 0, 0, 0
            for i = 1, n do
                local p = ccs[o + i]
                if P_flip[p] then
                    nf = nf + 1
                else
                    m = m + 1
                    sel[m] = p
                    if P_deb[p] then nd = nd + 1 end
                end
            end
            local xd, xf = nd / 5, nf / 5
            if disc_ok then
                local kd = doff + k
                a_type[kd] = 2
                a_nc[kd] = n
                local co = kd * MSL
                for i = 1, MSL do a_c[co + i - 1] = ccs[o + i] - 1 end
                a_top[kd], a_xs[kd], a_xe[kd], a_xc[kd], a_xd[kd], a_xf[kd] = 0, 0, 0, 0, xd, xf
            end
            if play_ok then
                a_type[k] = 1
                a_nc[k] = n
                local co = k * MSL
                for i = 1, MSL do a_c[co + i - 1] = ccs[o + i] - 1 end
                a_xd[k], a_xf[k] = xd, xf
                if m == 0 then
                    a_top[k], a_xs[k], a_xe[k], a_xc[k] = 0, 0, 0, 0
                else
                    local pairs_n, rb, pk = 0, 0, 0
                    for j = 1, m do grp[j] = 0 end
                    for j = 1, m do
                        local pj = sel[j]
                        local rj = P_r[pj]
                        if rj > 0 then
                            rb = bor(rb, P_rbit[pj])
                            for j2 = j + 1, m do
                                if P_r[sel[j2]] == rj then
                                    grp[j] = grp[j] + 1
                                    grp[j2] = grp[j2] + 1
                                    pairs_n = pairs_n + 1
                                end
                            end
                        end
                        pk = pk + P_pk[pj]
                    end
                    local fbit, stm = 0, 0
                    if m >= need then
                        for suit = 1, 4 do
                            if band(rshift(pk, 3 * (suit - 1)), 7) >= need then
                                fbit = SUITBIT[suit]
                                break
                            end
                        end
                        stm = STR[rshift(rb, 2)]
                    end
                    local flush, straight = fbit ~= 0, stm ~= 0
                    local top, mode
                    if pairs_n == 10 and flush then top, mode = 1, 1
                    elseif pairs_n == 4 and flush then top, mode = 2, 1
                    elseif pairs_n == 10 then top, mode = 3, 1
                    elseif flush and straight then top, mode = 4, 4
                    elseif pairs_n == 6 then top, mode = 5, 1
                    elseif pairs_n == 4 then top, mode = 6, 1
                    elseif flush then top, mode = 7, 7
                    elseif straight then top, mode = 8, 8
                    elseif pairs_n == 3 then top, mode = 9, 1
                    elseif pairs_n == 2 then top, mode = 10, 1
                    elseif pairs_n == 1 then top, mode = 11, 1
                    else top, mode = 12, 12 end
                    local best = 0
                    if mode == 12 then
                        best = 1
                        for j = 2, m do
                            local pj, pb = sel[j], sel[best]
                            local ka, kb = P_key[pj], P_key[pb]
                            if ka > kb or (ka == kb and P_uid[pj] < P_uid[pb]) then best = j end
                        end
                    end
                    local chips, mult, ns = h_chips[top], h_mult[top], 0
                    for j = 1, m do
                        local pj = sel[j]
                        local sc
                        if splash or P_stone[pj] then sc = true
                        elseif mode == 1 then sc = grp[j] > 0
                        elseif mode == 12 then sc = j == best
                        else
                            local f = band(P_sm[pj], fbit) ~= 0
                            local st = band(stm, P_rbit[pj]) ~= 0
                            if mode == 4 then sc = f or st elseif mode == 7 then sc = f else sc = st end
                        end
                        if sc then
                            ns = ns + 1
                            if not P_deb[pj] then
                                local nom = P_nom[pj]
                                if nom >= 0 then chips = chips + nom end
                                chips = chips + P_eb[pj] + P_bon[pj]
                                if P_mul[pj] then mult = mult + 4 end
                            end
                        end
                    end
                    local est = chips * mult
                    a_top[k] = top
                    a_xs[k] = ns / 5
                    a_xe[k] = min(slog(est) / lrem, 3)
                    a_xc[k] = est >= remaining and 1 or 0
                end
            end
            k = k + 1
        end
    end
    ab.n = total
    return total
end

function M.fill_fa(ab, k, dst, off)
    if ab.type[k] > 2 then
        local fa, o = ab.fa, k * FA
        for f = 0, FA - 1 do dst[off + f] = fa[o + f] end
        return
    end
    for f = 0, FA - 1 do dst[off + f] = 0 end
    dst[off + A.n + ab.nc[k] - 1] = 1
    local top = ab.top[k]
    if top > 0 then
        dst[off + A.hand + top - 1] = 1
        dst[off + A.n_scoring] = ab.xs[k]
        dst[off + A.est] = ab.xe[k]
        dst[off + A.clears] = ab.xc[k]
    end
    dst[off + A.n_debuff] = ab.xd[k]
    dst[off + A.n_flipped] = ab.xf[k]
    dst[off + A.bias] = 1
end

function M.actions(s, ab)
    local n = M.actions_compact(s, ab)
    local fa = ab.fa
    for k = 0, n - 1 do M.fill_fa(ab, k, fa, k * FA) end
    return n
end

local SIM_TYPE = {"play", "discard", "select", "skip", "reroll_boss", "buy", "buy_and_use", "sell", "sell", "use",
    "redeem", "open", "reroll", "leave", "pick", "skip", "reorder_jokers"}
M.SIM_TYPE = SIM_TYPE

function M.finish_step(out, t, nc, arg, arg2, n_jok)
    out.type = SIM_TYPE[t]
    out.card = arg
    out.area = t == T.sell_cons and "consumables" or "jokers"
    out.targets = nc > 0 and out.cards or nil
    if t == T.move_joker then
        local o = out.order or {}
        for i = #o, 1, -1 do o[i] = nil end
        local m = 0
        for q = 1, n_jok do
            if q ~= arg then
                m = m + 1
                o[m] = q
            end
        end
        table.insert(o, arg2, arg)
        out.order = o
    end
    return out
end

function M.to_step(ab, k, out, s)
    out = out or {}
    local t = ab.type[k]
    local cards = out.cards or {}
    for i = #cards, 1, -1 do cards[i] = nil end
    local co = k * M.MAXSEL
    local nc = ab.nc[k]
    for i = 1, nc do cards[i] = ab.c[co + i - 1] + 1 end
    out.cards = cards
    if t <= 2 then
        out.type = SIM_TYPE[t]
        return out
    end
    return M.finish_step(out, t, nc, ab.arg[k], ab.arg2[k], s and s.n_jok or 0)
end

local floor = math.floor

local function interest(m, cap)
    if m <= 0 then return 0 end
    local v = floor(m / 5)
    if v > cap then v = cap end
    return v
end

local function econ_row(ab, k, t, ent, arg, arg2)
    if k + 1 > ab.cap then
        ab.n = k
        grow_actions(ab, k + 1)
    end
    ab.type[k] = t
    ab.nc[k] = 0
    local co = k * M.MAXSEL
    local c = ab.c
    for i = 0, M.MAXSEL - 1 do c[co + i] = -1 end
    ab.ent[k], ab.arg[k], ab.arg2[k] = ent, arg, arg2
    ab.top[k] = 0
    local fa, o = ab.fa, k * FA
    for f = 0, FA - 1 do fa[o + f] = 0 end
    fa[o + A.bias] = 1
    return o
end

local function money_fa(ab, o, s, cost)
    local fa = ab.fa
    local after = s.money - cost
    fa[o + A.cost] = slog(cost) / 3
    fa[o + A.after] = slog(after) / 5
    local cap = floor(s.interest_cap / 5)
    fa[o + A.interest] = (interest(after, cap) - interest(s.money, cap)) / 5
end

local function item_ent(F, area, pos)
    local i = F.i_first[area] + pos - 1
    local lim = area < 6 and F.i_first[area + 1] or F.ni
    if i < lim then return i end
    return -1
end

local AREA_OF = {[T.buy] = 1, [T.buy_use] = 1, [T.redeem] = 2, [T.open] = 3, [T.pick] = 4, [T.use] = 5, [T.sell_cons] = 5}

function M.edge_ent(F, t, arg)
    local ek = M.TYPE_ENT[t]
    if ek == 2 then return arg >= 1 and arg <= F.nj and arg - 1 or -1 end
    if ek == 1 then return item_ent(F, AREA_OF[t], arg) end
    return -1
end

local tsel = {}

local function target_rows(s, ab, k, t, ent, arg, cid, in_pack, area_cons)
    local lo, hi = cons_targets(cid)
    local nh = min(s.n_hand, M.MAXC)
    if hi > nh then hi = nh end
    local MSL = M.MAXSEL
    for n = lo, hi do
        if E.can_use_cons(s, cid, n, in_pack, area_cons) then
            if n == 0 then
                econ_row(ab, k, t, ent, arg, 0)
                k = k + 1
            else
                for i = 1, n do tsel[i] = i end
                while true do
                    local o = econ_row(ab, k, t, ent, arg, 0)
                    ab.nc[k] = n
                    local fa = ab.fa
                    fa[o + A.n + n - 1] = 1
                    local nd, nf = 0, 0
                    for i = 1, n do
                        ab.c[k * MSL + i - 1] = tsel[i] - 1
                        local cid2 = s.hand[tsel[i]]
                        if s.c_flip[cid2] == 1 then nf = nf + 1 elseif s.c_debuff[cid2] ~= 0 then nd = nd + 1 end
                    end
                    fa[o + A.n_debuff] = nd / 5
                    fa[o + A.n_flipped] = nf / 5
                    k = k + 1
                    local i = n
                    while i >= 1 and tsel[i] == nh - n + i do i = i - 1 end
                    if i < 1 then break end
                    tsel[i] = tsel[i] + 1
                    for j = i + 1, n do tsel[j] = tsel[j - 1] + 1 end
                end
            end
        end
    end
    return k
end

local XMULT_KEYS = {"loyalty_card", "cavendish", "card_sharp", "ramen", "acrobat", "photograph", "baron", "ancient",
    "triboulet", "yorick", "caino", "hologram", "constellation", "campfire", "glass", "steel_joker", "madness", "vampire",
    "obelisk", "lucky_cat", "throwback", "hit_the_road", "duo", "trio", "family", "order", "tribe", "drivers_license",
    "bloodstone", "flower_pot", "seeing_double", "idol", "blackboard", "stencil"}
local XMULT, J_BLUEPRINT, J_BRAINSTORM = {}, nil, nil
for i, j in ipairs(D.JOKERS) do
    if j.key == "j_blueprint" then J_BLUEPRINT = i end
    if j.key == "j_brainstorm" then J_BRAINSTORM = i end
end
for _, key in ipairs(XMULT_KEYS) do
    for i, j in ipairs(D.JOKERS) do
        if j.key == "j_" .. key then XMULT[i] = true end
    end
end

local function move_row(ab, F, k, i, j)
    local o = econ_row(ab, k, T.move_joker, i <= F.nj and i - 1 or -1, i, j)
    ab.fa[o + A.to + min(j, 8) - 1] = 1
    ab.fa[o + A.shift] = (j - i) / 5
    return k + 1
end

local function play_moves(s, ab, F, k)
    local nj = s.n_jok
    local has_bs = false
    for i = 1, nj do
        local id = s.j_id[i]
        if (XMULT[id] or s.j_ed[i] == D.ED_POLY) and i < nj then k = move_row(ab, F, k, i, nj) end
        if id == J_BLUEPRINT then
            for q = 1, nj do
                if q ~= i and q ~= i + 1 then k = move_row(ab, F, k, i, q < i and q or q - 1) end
            end
        end
        if id == J_BRAINSTORM then has_bs = true end
    end
    if has_bs then
        for q = 2, nj do
            if s.j_id[q] ~= J_BRAINSTORM then k = move_row(ab, F, k, q, 1) end
        end
    end
    return k
end

local function owned_rows(s, ab, F, k, shop)
    for p = 1, s.n_jok do
        if s.j_eternal[p] ~= 1 then
            local o = econ_row(ab, k, T.sell_joker, p <= F.nj and p - 1 or -1, p, 0)
            money_fa(ab, o, s, -E.joker_sell(s, p))
            k = k + 1
        end
    end
    for p = 1, s.n_cons do
        local ent = item_ent(F, 5, p)
        local o = econ_row(ab, k, T.sell_cons, ent, p, 0)
        money_fa(ab, o, s, -E.cons_sell(s, p))
        k = k + 1
        local cid = CONS_ID[s.cons[p]]
        if not (CONS[cid].name == "Ankh" and s.n_jok >= s.joker_limit) then
            k = target_rows(s, ab, k, T.use, ent, p, cid, false, true)
        end
    end
    if shop and s.n_jok >= 2 then
        local nj = s.n_jok
        for i = 1, nj do
            for j = 1, nj do
                if j ~= i and j ~= i - 1 then
                    local o = econ_row(ab, k, T.move_joker, i <= F.nj and i - 1 or -1, i, j)
                    ab.fa[o + A.to + min(j, 8) - 1] = 1
                    ab.fa[o + A.shift] = (j - i) / 5
                    k = k + 1
                end
            end
        end
    elseif not shop and s.n_jok >= 2 then
        k = play_moves(s, ab, F, k)
    end
    return k
end

local function slot_ok(s, kind, ed)
    if kind == K_JOKER then return s.n_jok < s.joker_limit + (ed == 4 and 1 or 0) end
    if kind == K_CONS then return s.n_cons < s.cons_limit + (ed == 4 and 1 or 0) end
    return true
end

function M.econ_actions(s, ab, F, k)
    local ph = s.phase
    local left = s.money - s.bankrupt_at
    if ph == "play" then
        k = owned_rows(s, ab, F, k, false)
    elseif ph == "blind_select" then
        econ_row(ab, k, T.select, -1, 0, 0)
        k = k + 1
        if s.blind_on_deck ~= 3 then
            econ_row(ab, k, T.skip, -1, 0, 0)
            k = k + 1
        end
        local rv = s.used_v[D.VOUCHER_ID.v_retcon] == 1 or (s.used_v[D.VOUCHER_ID.v_directors_cut] == 1 and s.boss_rerolled == 0)
        if rv and left - 10 >= 0 then
            local o = econ_row(ab, k, T.reroll_boss, -1, 0, 0)
            money_fa(ab, o, s, 10)
            k = k + 1
        end
    elseif ph == "shop" then
        for p = 1, s.n_sj do
            local cost = E.shop_joker_cost(s, p)
            if cost <= 0 or cost <= left then
                local kind, id = s.sj_kind[p], s.sj_id[p]
                local ent = item_ent(F, 1, p)
                if slot_ok(s, kind, s.sj_ed[p]) then
                    local o = econ_row(ab, k, T.buy, ent, p, 0)
                    money_fa(ab, o, s, cost)
                    k = k + 1
                end
                if kind == K_CONS and not CONS[id].config.max_highlighted and E.can_use_cons(s, id, 0, false, false) then
                    local o = econ_row(ab, k, T.buy_use, ent, p, 0)
                    money_fa(ab, o, s, cost)
                    k = k + 1
                end
            end
        end
        for p = 1, s.n_sv do
            local cost = E.shop_voucher_cost(s, p)
            if cost <= left then
                local o = econ_row(ab, k, T.redeem, item_ent(F, 2, p), p, 0)
                money_fa(ab, o, s, cost)
                k = k + 1
            end
        end
        for p = 1, s.n_sb do
            local cost = E.shop_booster_cost(s, p)
            if cost <= 0 or cost <= left then
                local o = econ_row(ab, k, T.open, item_ent(F, 3, p), p, 0)
                money_fa(ab, o, s, cost)
                k = k + 1
            end
        end
        local rc = s.reroll_cost
        if rc == 0 or left - rc >= 0 then
            local o = econ_row(ab, k, T.reroll, -1, 0, 0)
            money_fa(ab, o, s, rc)
            k = k + 1
        end
        econ_row(ab, k, T.leave, -1, 0, 0)
        k = k + 1
        k = owned_rows(s, ab, F, k, true)
    elseif ph == "pack" then
        for p = 1, s.n_pk do
            local kind, id = s.pk_kind[p], s.pk_id[p]
            local ent = item_ent(F, 4, p)
            if kind == K_CONS then
                if not (CONS[id].name == "Ankh" and s.n_jok >= s.joker_limit) then
                    k = target_rows(s, ab, k, T.pick, ent, p, id, true, false)
                end
            elseif kind ~= K_JOKER or s.pk_ed[p] == 4 or s.n_jok < s.joker_limit then
                econ_row(ab, k, T.pick, ent, p, 0)
                k = k + 1
            end
        end
        econ_row(ab, k, T.skip_pack, -1, 0, 0)
        k = k + 1
    end
    ab.n = k
    return k
end

function M.list_actions(s, ab, F)
    local n = M.actions_compact(s, ab)
    local fa = ab.fa
    for k = 0, n - 1 do
        ab.ent[k], ab.arg[k], ab.arg2[k] = -1, 0, 0
        M.fill_fa(ab, k, fa, k * FA)
    end
    return M.econ_actions(s, ab, F, n)
end

local function same_step(a, b)
    if a.type ~= b.type then return false end
    local t = a.type
    if t == "play" or t == "discard" or t == "use" or t == "pick" then
        local hand = t == "play" or t == "discard"
        local ca = (hand and a.cards or a.targets) or {}
        local cb = (hand and b.cards or b.targets) or {}
        if #ca ~= #cb then return false end
        local seen = {}
        for i = 1, #ca do seen[ca[i]] = true end
        for i = 1, #cb do if not seen[cb[i]] then return false end end
        return hand or a.card == b.card
    end
    if t == "buy" or t == "buy_and_use" or t == "redeem" or t == "open" then return a.card == b.card end
    if t == "sell" then return a.card == b.card and (a.area == "consumables") == (b.area == "consumables") end
    if t == "reorder_jokers" then
        if #a.order ~= #b.order then return false end
        for i = 1, #a.order do if a.order[i] ~= b.order[i] then return false end end
    end
    return true
end
M.same_step = same_step

function M.find_action(ab, step, s)
    local tmp = {}
    for k = 0, ab.n - 1 do
        if same_step(M.to_step(ab, k, tmp, s), step) then return k end
    end
    return -1
end

M.slog = slog

return M
