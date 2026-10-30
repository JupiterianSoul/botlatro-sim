local E = require("bot.sim.engine")
local ST = require("bot.sim.state")
local RNG = require("bot.sim.rng")
local BUF = require("bot.nn.buf")
local FE = require("bot.nn.features")
local NET = require("bot.nn.net")
local D = require("bot.sim.data")

local M = {}
M.__index = M

local sqrt, log, cos, min, floor, exp, max = math.sqrt, math.log, math.cos, math.min, math.floor, math.exp, math.max
local MS = FE.MAXSEL

local STEP_SELECT, STEP_CASH, STEP_LEAVE = {type = "select"}, {type = "cash_out"}, {type = "leave"}

function M.advance(s)
    for _ = 1, 64 do
        local ph = s.phase
        if s.won == 1 or ph == "game_over" or ph == "play" then return end
        local a
        if ph == "blind_select" then a = STEP_SELECT
        elseif ph == "round_eval" then a = STEP_CASH
        elseif ph == "shop" then a = STEP_LEAVE
        else return end
        if not E.step(s, a) then return end
    end
end

function M.advance_forced(s)
    for _ = 1, 8 do
        if s.phase ~= "round_eval" or s.won == 1 then return end
        if not E.step(s, STEP_CASH) then return end
    end
end

function M.terminal(s)
    return s.won == 1 or s.phase == "game_over"
end

function M.new_rng(seed)
    local x = floor(seed or 12345) % 2147483646 + 1
    return function()
        x = (x * 48271) % 2147483647
        return x / 2147483647
    end
end

local function gamma(rnd, a)
    if a < 1 then
        return gamma(rnd, a + 1) * rnd() ^ (1 / a)
    end
    local d = a - 1 / 3
    local c = 1 / sqrt(9 * d)
    while true do
        local x = sqrt(-2 * log(rnd())) * cos(6.283185307179586 * rnd())
        local v = 1 + c * x
        if v > 0 then
            v = v * v * v
            local u = rnd()
            if log(u) < 0.5 * x * x + d - d * v + d * log(v) then return d * v end
        end
    end
end
M.gamma = gamma

function M.new(net, opts)
    opts = opts or {}
    local self = setmetatable({}, M)
    self.net = net
    self.K = opts.K or 24
    self.c_puct = opts.c_puct or 1.5
    self.alpha = opts.alpha or 0.5
    self.mix = opts.mix
    self.leaf_money = opts.leaf_money or 0
    self.leaf_rent = opts.leaf_rent or 0
    self.leaf_dead = opts.leaf_dead or 0
    self.rent_prior = opts.rent_prior or 1
    self.rent_from = opts.rent_from or 0
    self.score_prior = opts.score_prior or 0
    self.score_top = opts.score_top or 6
    self.score_temp = opts.score_temp or 4
    self.type_mass = (opts.type_mass or 0) > 0
    self.tm_at = (opts.type_mass or 0) < 1 and opts.type_mass or 0.5
    self.tm_plays = opts.tm_plays or 0
    self.quick_clear = (opts.quick_clear or 0) > 0
    self.pace = opts.pace or 0
    self.pace_net = (opts.pace_net or 0) > 0
    self.cleared = 0
    self.paced = 0
    self.tm_top = {}
    self.tm = BUF.alloc(1024)
    self.tm_cap = 1024
    self.skip_pen = opts.skip_pen or 1
    self.skip_ante = opts.skip_ante or 1
    self.pw_c = opts.pw_c or 0
    self.pw_a = opts.pw_a or 0.5
    self.pw_min = opts.pw_min or 2
    self.full = opts.full ~= false
    self.rnd = M.new_rng(opts.seed or 1)
    self.F = FE.new_state_buf()
    self.F_root = FE.new_state_buf()
    self.AB = FE.new_action_buf(1024)
    self.prob = BUF.alloc(1024)
    self.prob_cap = 1024
    self.root_fa = BUF.alloc(self.K * FE.FA)
    self.ws = ST.scratch()
    self.pv = ST.scratch()
    self.pos = {}
    self.key = BUF.alloc(1024)
    self.sq = BUF.alloc(1024)
    self.key_cap = 1024
    self.act = {type = "play", cards = {}}
    self.path = {}
    self.topk = {}
    self.cap_nodes = 0
    self:reserve(opts.nodes or 1024)
    return self
end

function M:reserve(nodes)
    if nodes <= self.cap_nodes then return false end
    local ne = nodes * self.K
    self.cap_nodes = nodes
    self.n_N, self.n_val, self.n_ef, self.n_ec = BUF.alloc(nodes + 1), BUF.alloc(nodes + 1), BUF.alloc_int(nodes + 1), BUF.alloc_int(nodes + 1)
    self.n_key, self.n_next, self.n_term = BUF.alloc(nodes + 1), BUF.alloc_int(nodes + 1), BUF.alloc_int(nodes + 1)
    self.e_type, self.e_nc, self.e_c = BUF.alloc_int(ne + 1), BUF.alloc_int(ne + 1), BUF.alloc_int((ne + 1) * MS)
    self.e_prior, self.e_N, self.e_W, self.e_child = BUF.alloc(ne + 1), BUF.alloc(ne + 1), BUF.alloc(ne + 1), BUF.alloc_int(ne + 1)
    self.e_src = BUF.alloc_int(ne + 1)
    self.e_arg, self.e_arg2 = BUF.alloc_int(ne + 1), BUF.alloc_int(ne + 1)
    self.n_exp = BUF.alloc_int(nodes + 1)
    self.remap = BUF.alloc_int(nodes + 1)
    self.e_mark = BUF.alloc_int(ne + 1)
    self.stack = BUF.alloc_int(nodes + 1)
    self.nn, self.ne, self.root = 0, 0, nil
    return true
end

local T_BUY = 0
for i, name in ipairs(FE.TYPES) do
    if name == "buy" then T_BUY = i end
end

function M:leaf_econ(s)
    local v = 0
    if self.leaf_money ~= 0 then
        local m = s.money
        if m < 0 then m = 0 elseif m > 25 then m = 25 end
        v = v + self.leaf_money * m / 25
    end
    if self.leaf_rent ~= 0 or self.leaf_dead ~= 0 then
        for k = 1, s.n_jok do
            if s.j_rental[k] == 1 then v = v - self.leaf_rent end
            if s.j_perish[k] == 0 then v = v - self.leaf_dead end
        end
    end
    return v
end

function M:value_of(s, p, ante_hat)
    local wa = s.win_ante > 0 and s.win_ante or 8
    if s.won == 1 then return 1 end
    if s.phase ~= "game_over" and (self.leaf_money ~= 0 or self.leaf_rent ~= 0 or self.leaf_dead ~= 0) then
        return self:value_base(s, p, ante_hat, wa) + self:leaf_econ(s)
    end
    return self:value_base(s, p, ante_hat, wa)
end

function M:value_base(s, p, ante_hat, wa)
    local m = self.mix
    if m then
        if s.phase == "game_over" then return m * (min(s.ante, wa) - 1) / wa end
        local a = (ante_hat * 8 - 1) / wa
        if a < 0 then a = 0 elseif a > 1 then a = 1 end
        return (1 - m) * p + m * a
    end
    if s.phase == "game_over" then return self.alpha * min(s.ante, wa) / (wa + 1) end
    local a = ante_hat * 8 / (wa + 1)
    if a < 0 then a = 0 elseif a > 1 then a = 1 end
    return (1 - self.alpha) * p + self.alpha * a
end

local CONS_ID = D.CONS_ID

local function obs_key(s, full)
    local h = 7
    local P = 4294967291
    h = (h * 1000003 + (FE.PHASES[s.phase] or 0)) % P
    h = (h * 1000003 + s.ante * 64 + s.round) % P
    h = (h * 1000003 + s.hands_left * 32 + s.discards_left) % P
    h = (h * 1000003 + floor(s.chips) % 1000003) % P
    h = (h * 1000003 + floor(s.money) % 1000) % P
    local hand, flip = s.hand, s.c_flip
    for i = 1, s.n_hand do
        local cid = hand[i]
        h = (h * 1000003 + (flip[cid] == 1 and 1 or cid * 2)) % P
    end
    if not full then return h end
    for i = 1, s.n_hand do
        local cid = hand[i]
        if flip[cid] ~= 1 then
            h = (h * 1000003 + ((s.c_rank[cid] * 8 + s.c_suit[cid]) * 16 + s.c_enh[cid]) * 64 + s.c_ed[cid] * 8 + s.c_seal[cid]) % P
        end
    end
    h = (h * 1000003 + s.blind_on_deck * 64 + s.pack_choices * 8 + s.n_tags) % P
    h = (h * 1000003 + s.boss_choice * 256 + s.reroll_cost) % P
    for i = 1, s.n_jok do h = (h * 1000003 + (s.j_id[i] * 8 + s.j_ed[i]) * 4096 + s.j_uid[i] % 4096) % P end
    for i = 1, s.n_cons do h = (h * 1000003 + (CONS_ID[s.cons[i]] or 0) * 8 + s.cons_ed[i]) % P end
    for i = 1, s.n_sj do h = (h * 1000003 + (s.sj_kind[i] * 256 + s.sj_id[i]) * 8 + s.sj_ed[i]) % P end
    for i = 1, s.n_sv do h = (h * 1000003 + s.sv_id[i] + 512) % P end
    for i = 1, s.n_sb do h = (h * 1000003 + s.sb_id[i] + 1024) % P end
    for i = 1, s.n_pk do
        local cid = s.pk_cid[i]
        local x = (s.pk_kind[i] * 256 + s.pk_id[i]) * 8 + s.pk_ed[i]
        if cid and cid > 0 then x = x * 4096 + (s.c_rank[cid] * 8 + s.c_suit[cid]) * 16 + s.c_enh[cid] end
        h = (h * 1000003 + x) % P
    end
    local lv = 0
    for i = 1, 12 do lv = lv + s.h_level[i] * i end
    h = (h * 1000003 + lv) % P
    return h
end
M.obs_key = obs_key

function M:new_node(key)
    local id = self.nn + 1
    if id > self.cap_nodes then return 0 end
    self.nn = id
    self.n_N[id], self.n_val[id], self.n_ef[id], self.n_ec[id] = 0, 0, 0, 0
    self.n_key[id], self.n_next[id], self.n_term[id], self.n_exp[id] = key, 0, 0, 0
    return id
end

function M:expand(id, s, keep_src, value_only)
    if M.terminal(s) then
        self.n_term[id] = 1
        local v = self:value_of(s, 0, 0)
        self.n_val[id] = v
        return v
    end
    local net, AB = self.net, self.AB
    local F = keep_src and self.F_root or self.F
    FE.state(s, F)
    local p, ante_hat
    if keep_src then
        p, ante_hat = net:forward(F)
        net:set_base(F)
    else
        p, ante_hat = net:forward_delta(F)
    end
    local v = self:value_of(s, p, ante_hat)
    self.n_val[id] = v
    if value_only then return v end
    self.n_exp[id] = 1
    local na = FE.actions_compact(s, AB)
    if self.full then na = FE.econ_actions(s, AB, F, na) end
    if na == 0 then
        self.n_term[id] = 1
        return v
    end
    net:policy_compact(AB)
    if self.prob_cap < na then
        self.prob_cap = AB.cap
        self.prob = BUF.alloc(AB.cap)
    end
    local prob = NET.softmax(AB.logit, na, self.prob)
    if self.rent_prior ~= 1 and s.phase == "shop" and s.n_jok >= self.rent_from then
        for k = 0, na - 1 do
            if AB.type[k] == T_BUY and s.sj_rent[AB.arg[k]] == 1 then prob[k] = prob[k] * self.rent_prior end
        end
    end
    local key = prob
    if s.phase == "play" then key = self:play_priors(s, AB, na, prob, keep_src)
    elseif s.phase == "blind_select" then self:skip_prior(s, AB, na, prob) end
    if self.type_mass and s.phase == "play" then key = self:mass_key(AB, na, prob, key) end
    if self.quick_clear and keep_src and s.phase == "play" then key = self:clear_key(s, AB, na, key) end
    local K = min(self.K, na)
    local top = self.topk
    local nt = 0
    for k = 0, na - 1 do
        local pk = key[k]
        if nt < K or pk > key[top[nt]] then
            local j = nt < K and nt + 1 or nt
            while j > 1 and key[top[j - 1]] < pk do
                top[j] = top[j - 1]
                j = j - 1
            end
            top[j] = k
            if nt < K then nt = nt + 1 end
        end
    end
    local ef = self.ne + 1
    local tot = 0
    for j = 1, nt do tot = tot + prob[top[j]] end
    for j = 1, nt do
        local k = top[j]
        local e = ef + j - 1
        local t = AB.type[k]
        self.e_type[e] = t
        self.e_nc[e] = AB.nc[k]
        if t > 2 then
            self.e_arg[e], self.e_arg2[e] = AB.arg[k], AB.arg2[k]
        else
            self.e_arg[e], self.e_arg2[e] = 0, 0
        end
        for i = 0, MS - 1 do self.e_c[e * MS + i] = AB.c[k * MS + i] end
        self.e_prior[e] = prob[k] / tot
        self.e_N[e], self.e_W[e], self.e_child[e] = 0, 0, 0
        self.e_src[e] = keep_src and k or -1
        if keep_src then FE.fill_fa(AB, k, self.root_fa, (j - 1) * FE.FA) end
    end
    self.ne = ef + nt - 1
    self.n_ef[id], self.n_ec[id] = ef, nt
    return v
end

function M:clear_key(s, AB, na, key)
    local FAIR, PL = require("bot.seer.fair"), require("bot.seer.play")
    local cs, v = PL.best_play(FAIR.sanitize(s))
    if not cs then return key end
    local need = s.blind_chips - s.chips
    if v < need then
        if self.pace <= 0 or s.discards_left <= 0 or v * s.hands_left < need * self.pace then return key end
        self.paced = self.paced + 1
        if self.pace_net then
            if key ~= self.tm then
                if self.tm_cap < na then
                    self.tm_cap = AB.cap
                    self.tm = BUF.alloc(AB.cap)
                end
                for j = 0, na - 1 do self.tm[j] = key[j] end
                key = self.tm
            end
            for k = 0, na - 1 do
                if AB.type[k] == 2 then key[k] = key[k] - 64 end
            end
            return key
        end
    end
    local band, lshift = bit.band, bit.lshift
    local want = 0
    for i = 1, #cs do want = want + lshift(1, cs[i]) end
    for k = 0, na - 1 do
        if AB.type[k] == 1 and AB.nc[k] == #cs then
            local m = 0
            for i = 0, AB.nc[k] - 1 do m = m + lshift(1, AB.c[k * MS + i] + 1) end
            if band(m, want) == want then
                if key ~= self.tm then
                    if self.tm_cap < na then
                        self.tm_cap = AB.cap
                        self.tm = BUF.alloc(AB.cap)
                    end
                    for j = 0, na - 1 do self.tm[j] = key[j] end
                    key = self.tm
                end
                key[k] = key[k] + 32
                self.cleared = self.cleared + 1
                return key
            end
        end
    end
    return key
end

function M:mass_key(AB, na, prob, key)
    local ty = AB.type
    local mp, md, bk = 0, 0, 0
    local N, xe, bt, nb = self.tm_plays, AB.xe, self.tm_top, 0
    for k = 0, na - 1 do
        local t = ty[k]
        if t == 1 then
            if N > 0 then
                local x = xe[k]
                if nb < N or x > xe[bt[nb]] then
                    local j = nb < N and nb + 1 or nb
                    while j > 1 and xe[bt[j - 1]] < x do
                        bt[j] = bt[j - 1]
                        j = j - 1
                    end
                    bt[j] = k
                    if nb < N then nb = nb + 1 end
                end
            else
                mp = mp + prob[k]
            end
        elseif t == 2 then md = md + prob[k] end
        if key[k] > key[bk] then bk = k end
    end
    for j = 1, nb do mp = mp + prob[bt[j]] end
    local win = md > self.tm_at * (mp + md) and 2 or 1
    if ty[bk] > 2 or ty[bk] == win then return key end
    if self.tm_cap < na then
        self.tm_cap = AB.cap
        self.tm = BUF.alloc(AB.cap)
    end
    local tm = self.tm
    for k = 0, na - 1 do tm[k] = ty[k] == win and key[k] + 8 or key[k] end
    return tm
end

function M:play_priors(s, AB, na, prob, exact)
    local w = self.score_prior
    if w <= 0 then return prob end
    if self.key_cap < na then
        self.key_cap = AB.cap
        self.key = BUF.alloc(AB.cap)
        self.sq = BUF.alloc(AB.cap)
    end
    local key, sq, xe, ty = self.key, self.sq, AB.xe, AB.type
    local remaining = max(s.blind_chips - s.chips, 1)
    local lrem = log(remaining + 1)
    local nb = 0
    if exact and self.score_top > 0 then
        local bt = self.topk
        for k = 0, na - 1 do
            if ty[k] == 1 then
                local x = xe[k]
                if nb < self.score_top or x > xe[bt[nb]] then
                    local j = nb < self.score_top and nb + 1 or nb
                    while j > 1 and xe[bt[j - 1]] < x do
                        bt[j] = bt[j - 1]
                        j = j - 1
                    end
                    bt[j] = k
                    if nb < self.score_top then nb = nb + 1 end
                end
            end
        end
        for k = 0, na - 1 do sq[k] = ty[k] == 1 and min(xe[k], 3) or 0 end
        local pos = self.pos
        for j = 1, nb do
            local k = bt[j]
            local n = AB.nc[k]
            for i = 1, MS do pos[i] = nil end
            local hidden = false
            for i = 1, n do
                pos[i] = AB.c[k * MS + i - 1] + 1
                if s.c_flip[s.hand[pos[i]]] == 1 then hidden = true end
            end
            if not hidden then
                local g = tonumber((E.preview_into(self.pv, s, pos))) or 0
                sq[k] = min(log(max(g, 0) + 1) / lrem, 3) + 10
            end
        end
    else
        for k = 0, na - 1 do sq[k] = ty[k] == 1 and min(xe[k], 3) or 0 end
    end
    local mx, tot = -1e9, 0
    for k = 0, na - 1 do
        if ty[k] == 1 then
            local x = sq[k] >= 10 and sq[k] - 10 or sq[k]
            if x > mx then mx = x end
        end
    end
    local temp = self.score_temp
    for k = 0, na - 1 do
        if ty[k] == 1 then
            local x = sq[k] >= 10 and sq[k] - 10 or sq[k]
            key[k] = exp(temp * (min(x, 1.5) - min(mx, 1.5)))
            tot = tot + key[k]
        else
            key[k] = 0
        end
    end
    for k = 0, na - 1 do
        local q = tot > 0 and key[k] / tot or 0
        prob[k] = (1 - w) * prob[k] + w * q
        key[k] = prob[k]
        if sq[k] >= 10 then key[k] = key[k] + 2 end
    end
    return key
end

function M:skip_prior(s, AB, na, prob)
    if self.skip_pen >= 1 or s.ante > self.skip_ante then return end
    local tot = 0
    for k = 0, na - 1 do
        if AB.type[k] == 4 then prob[k] = prob[k] * self.skip_pen end
        tot = tot + prob[k]
    end
    if tot > 0 then
        for k = 0, na - 1 do prob[k] = prob[k] / tot end
    end
end

function M:add_noise(id, dir_alpha, frac)
    local ef, ec = self.n_ef[id], self.n_ec[id]
    if ec < 2 then return end
    local g, tot = {}, 0
    for j = 1, ec do
        g[j] = gamma(self.rnd, dir_alpha)
        tot = tot + g[j]
    end
    for j = 1, ec do
        local e = ef + j - 1
        self.e_prior[e] = (1 - frac) * self.e_prior[e] + frac * g[j] / tot
    end
end

local FAKE_SEEDS = {}
M.FAKE_SEEDS = FAKE_SEEDS
for i = 1, 64 do FAKE_SEEDS[i] = "ISMCTS" .. i end

function M:determinize(s)
    local n = FE.unseen_pool(s)
    local ids = FE.pool_ids
    local rnd = self.rnd
    for i = n, 2, -1 do
        local j = floor(rnd() * i) + 1
        ids[i], ids[j] = ids[j], ids[i]
    end
    local nd = s.n_deck
    local deck = s.deck
    for i = 1, nd do deck[i] = ids[i] end
    local k = nd
    local hand, flip = s.hand, s.c_flip
    for i = 1, s.n_hand do
        if flip[hand[i]] == 1 then
            k = k + 1
            hand[i] = ids[k]
            flip[ids[k]] = 1
        end
    end
    local r, ids2 = s.rng, s.rng_ids
    local x = floor(rnd() * 2147483645) + 1
    for i = 1, s.n_rk do
        x = (x * 48271) % 2147483647
        r[ids2[i]] = x / 2147483647
    end
    s.hashed_seed = rnd()
    local f = floor(rnd() * #FAKE_SEEDS) + 1
    s.seed = FAKE_SEEDS[f]
    s.hcache = RNG.seed_cache(FAKE_SEEDS[f])
    if self.full and s.voucher > 0 and FE.voucher_hidden(s) then s.voucher = E.get_next_voucher(s) end
end

function M:select(id)
    local ef, ec = self.n_ef[id], self.n_ec[id]
    local nv = self.n_N[id]
    local sq = self.c_puct * sqrt(nv + 1)
    if self.pw_c > 0 then
        local w = floor(self.pw_c * (nv + 1) ^ self.pw_a)
        if w < self.pw_min then w = self.pw_min end
        if w < ec then ec = w end
    end
    local fpu = self.n_val[id]
    local best, bv = ef, -math.huge
    local eN, eW, eP = self.e_N, self.e_W, self.e_prior
    for e = ef, ef + ec - 1 do
        local n = eN[e]
        local q = n > 0 and eW[e] / n or fpu
        local u = q + eP[e] * sq / (1 + n)
        if u > bv then
            bv = u
            best = e
        end
    end
    return best
end

function M:swap_edges(a, b, ja, jb)
    self.e_type[a], self.e_type[b] = self.e_type[b], self.e_type[a]
    self.e_nc[a], self.e_nc[b] = self.e_nc[b], self.e_nc[a]
    self.e_prior[a], self.e_prior[b] = self.e_prior[b], self.e_prior[a]
    self.e_N[a], self.e_N[b] = self.e_N[b], self.e_N[a]
    self.e_W[a], self.e_W[b] = self.e_W[b], self.e_W[a]
    self.e_child[a], self.e_child[b] = self.e_child[b], self.e_child[a]
    self.e_src[a], self.e_src[b] = self.e_src[b], self.e_src[a]
    self.e_arg[a], self.e_arg[b] = self.e_arg[b], self.e_arg[a]
    self.e_arg2[a], self.e_arg2[b] = self.e_arg2[b], self.e_arg2[a]
    local c = self.e_c
    for i = 0, MS - 1 do c[a * MS + i], c[b * MS + i] = c[b * MS + i], c[a * MS + i] end
    local rf, FA = self.root_fa, FE.FA
    for f = 0, FA - 1 do rf[ja * FA + f], rf[jb * FA + f] = rf[jb * FA + f], rf[ja * FA + f] end
end

function M:sort_root(rid)
    local ef, ec = self.n_ef[rid], self.n_ec[rid]
    local P = self.e_prior
    for j = 1, ec - 1 do
        local i = j
        while i > 0 and P[ef + i] > P[ef + i - 1] do
            self:swap_edges(ef + i, ef + i - 1, i, i - 1)
            i = i - 1
        end
    end
end

function M:edge_action(e, out, s)
    out = out or self.act
    local t = self.e_type[e]
    local cards = out.cards
    for i = #cards, 1, -1 do cards[i] = nil end
    local nc = self.e_nc[e]
    for i = 0, nc - 1 do cards[i + 1] = self.e_c[e * MS + i] + 1 end
    if t <= 2 then
        out.type = FE.SIM_TYPE[t]
        return out
    end
    return FE.finish_step(out, t, nc, self.e_arg[e], self.e_arg2[e], s and s.n_jok or 0)
end

function M:commit(e)
    self.commit_edge = e
end

function M:keep_subtree(c)
    local map, stack = self.remap, self.stack
    local n_ef, n_ec, n_next, e_child = self.n_ef, self.n_ec, self.n_next, self.e_child
    local old_nn, old_ne = self.nn, self.ne
    map[c] = 1
    local sp = 1
    stack[1] = c
    while sp > 0 do
        local x = stack[sp]
        sp = sp - 1
        local ef = n_ef[x]
        for e = ef, ef + n_ec[x] - 1 do
            local ch = e_child[e]
            while ch ~= 0 do
                map[ch] = 1
                sp = sp + 1
                stack[sp] = ch
                ch = n_next[ch]
            end
        end
    end
    local n_N, n_val, n_key, n_term, n_exp = self.n_N, self.n_val, self.n_key, self.n_term, self.n_exp
    local mark = self.e_mark
    local nid = 0
    for old = 1, old_nn do
        if map[old] ~= 0 then
            nid = nid + 1
            map[old] = nid
            n_N[nid], n_val[nid], n_key[nid], n_term[nid], n_exp[nid] = n_N[old], n_val[old], n_key[old], n_term[old], n_exp[old]
            n_next[nid] = n_next[old]
            local ec = n_ec[old]
            if ec > 0 then mark[n_ef[old]] = nid end
            n_ef[nid], n_ec[nid] = 0, ec
        end
    end
    local e_type, e_nc, e_cc, e_prior, e_N, e_W, e_src = self.e_type, self.e_nc, self.e_c, self.e_prior, self.e_N, self.e_W, self.e_src
    local e_arg, e_arg2 = self.e_arg, self.e_arg2
    local ne = 0
    for e = 1, old_ne do
        local nd = mark[e]
        if nd ~= 0 then
            mark[e] = 0
            local ec = n_ec[nd]
            local nef = ne + 1
            for j = 0, ec - 1 do
                local src, dst = e + j, nef + j
                e_type[dst], e_nc[dst], e_prior[dst], e_N[dst], e_W[dst] = e_type[src], e_nc[src], e_prior[src], e_N[src], e_W[src]
                e_child[dst], e_src[dst] = e_child[src], -1
                e_arg[dst], e_arg2[dst] = e_arg[src], e_arg2[src]
                for i = 0, MS - 1 do e_cc[dst * MS + i] = e_cc[src * MS + i] end
            end
            n_ef[nd] = nef
            ne = ne + ec
        end
    end
    for x = 1, nid do
        local nx = n_next[x]
        n_next[x] = nx ~= 0 and map[nx] or 0
    end
    n_next[1] = 0
    for e = 1, ne do
        local ch = e_child[e]
        if ch ~= 0 then e_child[e] = map[ch] end
    end
    for old = 1, old_nn do map[old] = 0 end
    self.nn, self.ne = nid, ne
    return 1
end

function M:reuse_root(ce, root)
    if ce > self.ne then return 0 end
    local key = obs_key(root, self.full)
    local c = self.e_child[ce]
    while c ~= 0 and self.n_key[c] ~= key do c = self.n_next[c] end
    if c == 0 or self.n_term[c] == 1 then return 0 end
    local rid = self:keep_subtree(c)
    if self.n_exp[rid] == 0 then
        self:expand(rid, root, true)
        return rid
    end
    FE.state(root, self.F_root)
    self.net:set_base(self.F_root)
    local ef, ec = self.n_ef[rid], self.n_ec[rid]
    if ec == 0 then return rid end
    local AB = self.AB
    local na = FE.actions_compact(root, AB)
    if self.full then na = FE.econ_actions(root, AB, self.F_root, na) end
    local at, anc, ac = AB.type, AB.nc, AB.c
    for j = 0, ec - 1 do
        local e = ef + j
        local t, nc = self.e_type[e], self.e_nc[e]
        for k = 0, na - 1 do
            if at[k] == t and anc[k] == nc and (t <= 2 or (AB.arg[k] == self.e_arg[e] and AB.arg2[k] == self.e_arg2[e])) then
                local same = true
                for i = 0, nc - 1 do
                    if ac[k * MS + i] ~= self.e_c[e * MS + i] then
                        same = false
                        break
                    end
                end
                if same then
                    self.e_src[e] = k
                    FE.fill_fa(AB, k, self.root_fa, j * FE.FA)
                    break
                end
            end
        end
    end
    return rid
end

function M:search(root, n_sims, opts)
    opts = opts or {}
    local grown = self:reserve(2 * n_sims + 2)
    local ce = self.commit_edge
    self.commit_edge = nil
    local rid = 0
    if ce and not grown and self.root and opts.reuse ~= false then rid = self:reuse_root(ce, root) end
    self.reused = rid ~= 0
    if rid == 0 then
        self.nn, self.ne = 0, 0
        rid = self:new_node(0)
        self.root = rid
        self:expand(rid, root, true)
    end
    self.root = rid
    local top_prior = self.n_ec[rid] > 0 and self.e_prior[self.n_ef[rid]] or 1
    self.top_prior = top_prior
    if opts.noise and opts.noise > 0 then
        self:add_noise(rid, opts.dir_alpha or 0.3, opts.noise)
        if self.pw_c > 0 then self:sort_root(rid) end
    end
    self.sims_done = 0
    if self.n_term[rid] == 1 then return self end
    local adaptive = opts.adaptive
    local ref, rec = self.n_ef[rid], self.n_ec[rid]
    if rec == 1 then
        if self.e_N[ref] < 1 then self.e_N[ref] = 1 end
        return self
    end
    local ws, path = self.ws, self.path
    local full = self.full
    local eN, eW, nN = self.e_N, self.e_W, self.n_N
    local have = 0
    if self.reused then
        local ef, ec = self.n_ef[rid], self.n_ec[rid]
        for e = ef, ef + ec - 1 do have = have + eN[e] end
    end
    local todo = n_sims
    if adaptive and opts.conf_prior and top_prior >= opts.conf_prior then
        todo = math.ceil(todo * (opts.conf_frac or 0.25))
    end
    todo = todo - have
    if todo < 0 then todo = 0 end
    local extend = adaptive and opts.extend or 1
    local close = opts.close or 0.25
    local limit = floor(todo * extend)
    local done = 0
    for it = 1, limit do
        if it > todo then
            local b1, b2 = 0, 0
            for e = ref, ref + rec - 1 do
                local n = eN[e]
                if n > b1 then b2, b1 = b1, n elseif n > b2 then b2 = n end
            end
            if b1 - b2 > close * b1 then break end
        end
        local wd = ws.deck
        local top = #wd
        ST.copy_into(ws, root)
        for i = root.n_deck + 1, top do wd[i] = nil end
        self:determinize(ws)
        local node, depth, v = rid, 0, nil
        while true do
            if self.n_term[node] == 1 then
                v = self.n_val[node]
                break
            end
            if self.n_exp[node] == 0 then
                self:expand(node, ws, false)
                if self.n_term[node] == 1 then
                    v = self.n_val[node]
                    break
                end
            end
            local e = self:select(node)
            depth = depth + 1
            path[depth] = e
            if not E.step(ws, self:edge_action(e, nil, ws)) then
                v = self.n_val[node]
                break
            end
            if full then M.advance_forced(ws) else M.advance(ws) end
            local key = obs_key(ws, full)
            local c = self.e_child[e]
            while c ~= 0 and self.n_key[c] ~= key do c = self.n_next[c] end
            if c == 0 then
                c = self:new_node(key)
                if c == 0 then
                    v = self.n_val[node]
                    break
                end
                self.n_next[c] = self.e_child[e]
                self.e_child[e] = c
                v = self:expand(c, ws, false, true)
                nN[c] = 1
                break
            end
            nN[c] = nN[c] + 1
            node = c
        end
        nN[rid] = nN[rid] + 1
        for d = 1, depth do
            local e = path[d]
            eN[e] = eN[e] + 1
            eW[e] = eW[e] + v
        end
        done = it
        if adaptive and it < todo and it % 4 == 0 then
            local b1, b2 = 0, 0
            for e = ref, ref + rec - 1 do
                local n = eN[e]
                if n > b1 then b2, b1 = b1, n elseif n > b2 then b2 = n end
            end
            if b1 - b2 > todo - it then break end
        end
    end
    self.sims_done = done
    return self
end

function M:root_edges()
    local rid = self.root
    return self.n_ef[rid], self.n_ec[rid]
end

function M:choose(temp)
    local ef, ec = self:root_edges()
    if ec == 0 then return nil end
    local best, bn = ef, -1
    if temp and temp > 0 then
        local tot = 0
        for e = ef, ef + ec - 1 do tot = tot + self.e_N[e] ^ (1 / temp) end
        if tot > 0 then
            local r = self.rnd() * tot
            for e = ef, ef + ec - 1 do
                r = r - self.e_N[e] ^ (1 / temp)
                if r <= 0 then return e end
            end
        end
    end
    for e = ef, ef + ec - 1 do
        if self.e_N[e] > bn then
            bn = self.e_N[e]
            best = e
        end
    end
    return best
end

function M:root_q()
    local ef, ec = self:root_edges()
    local n, w = 0, 0
    for e = ef, ef + ec - 1 do
        n = n + self.e_N[e]
        w = w + self.e_W[e]
    end
    if n == 0 then return self.n_val[self.root] end
    return w / n
end

return M
