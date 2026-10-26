local E = require("bot.sim.engine")
local ST = require("bot.sim.state")
local D = require("bot.sim.data")
local PL = require("bot.seer.play")

local S = {}
S.__index = S

local min, max, log = math.min, math.max, math.log
local clone = ST.clone
local K_JOKER, K_CONS, K_CARD = E.K_JOKER, E.K_CONS, E.K_CARD
local ED_NEG = 4

S.DEFAULTS = {
    horizon = 2, tight_horizon = 3, beam = 3, tight_beam = 4, depth = 3, tight_margin = 0.4,
    solve_beam = 6, solve_plays = 3, solve_discards = 6,
    w_clear = 10, w_strength = 2, w_money = 0.04, money_cap = 60, death = -40, win = 1000,
    max_steps = 3000, roll_shop = 0, roll_reserve = 0, roll_swap = 3, skip_cost = 1000, noise = 0, noise_seed = 0,
}

function S.new(opts)
    local self = setmetatable({}, S)
    self.o = {}
    for k, v in pairs(S.DEFAULTS) do self.o[k] = v end
    for k, v in pairs(opts or {}) do self.o[k] = v end
    self.plan, self.plan_i, self.plan_step = nil, 0, -1
    self.rollouts = 0
    self.checkpoints = nil
    return self
end

local A_SELECT, A_CASH, A_LEAVE, A_SKIP = {type = "select"}, {type = "cash_out"}, {type = "leave"}, {type = "skip"}

local function copy(t)
    local r = {}
    for i = 1, #t do r[i] = t[i] end
    return r
end

local function copy_action(a)
    local r = {}
    for k, v in pairs(a) do
        if type(v) == "table" then r[k] = copy(v) else r[k] = v end
    end
    return r
end
S.copy_action = copy_action

local function money_left(s)
    return s.money - s.bankrupt_at
end

local function is_planet(key)
    local c = D.CONS[D.CONS_ID[key]]
    return c and c.hand ~= nil
end

function S:value(c, base, cleared, strength, n_str, margin)
    local o = self.o
    local prog = cleared + (c.skips - base.skips)
    local st = n_str > 0 and strength / n_str or 0
    local v = o.w_clear * prog + o.w_strength * st + o.w_money * min(max(c.money, 0), o.money_cap)
    if c.won == 1 then v = v + o.win end
    if c.phase == "game_over" then v = v + o.death end
    return v, margin
end

local ED_SCORE = {[0] = 0, 1, 2, 4, 5}

local function joker_score(id, ed)
    return D.JOKERS[id].cost + (ED_SCORE[ed] or 0)
end
S.joker_score = joker_score

local function worst_joker(c)
    local wk, ws = 0, math.huge
    for k = 1, c.n_jok do
        if c.j_eternal[k] ~= 1 then
            local sc = joker_score(c.j_id[k], c.j_ed[k])
            if sc < ws then wk, ws = k, sc end
        end
    end
    return wk, ws
end

local function planet_hand(cid)
    local c = D.CONS[cid]
    return c and c.hand
end

function S:roll_shop(c)
    local o = self.o
    for i = c.n_cons, 1, -1 do
        if is_planet(c.cons[i]) then E.step(c, {type = "use", card = i}) end
    end
    if o.roll_shop ~= 1 then return E.step(c, A_LEAVE) end
    local reserve = o.roll_reserve
    for _ = 1, 12 do
        local ml = money_left(c)
        local done = true
        local bi, bs = 0, -1
        for i = 1, c.n_sj do
            if c.sj_kind[i] == K_JOKER then
                local cost = E.shop_joker_cost(c, i)
                local sc = joker_score(c.sj_id[i], c.sj_ed[i])
                if (cost <= 0 or cost <= ml - reserve) and sc > bs then bi, bs = i, sc end
            end
        end
        if bi > 0 then
            if c.n_jok < c.joker_limit or c.sj_ed[bi] == ED_NEG then
                if E.step(c, {type = "buy", card = bi}) then done = false end
            else
                local wk, ws = worst_joker(c)
                if wk > 0 and bs >= ws + o.roll_swap then
                    local cl = clone(c)
                    if E.step(cl, {type = "sell", area = "jokers", card = wk}) and E.step(cl, {type = "buy", card = bi}) then
                        E.step(c, {type = "sell", area = "jokers", card = wk})
                        E.step(c, {type = "buy", card = bi})
                        done = false
                    end
                end
            end
        end
        if done then
            for i = 1, c.n_sj do
                if c.sj_kind[i] == K_CONS and planet_hand(c.sj_id[i]) == c.most_played and E.shop_joker_cost(c, i) <= money_left(c) - reserve then
                    if E.step(c, {type = "buy_and_use", card = i}) then done = false break end
                end
            end
        end
        if done then
            for i = 1, c.n_sb do
                local b = D.BOOST[c.sb_id[i]]
                local want = b.kind == "Celestial" or (b.kind == "Buffoon" and c.n_jok < c.joker_limit)
                if want and E.shop_booster_cost(c, i) <= money_left(c) - reserve then
                    if E.step(c, {type = "open", card = i}) then
                        self:roll_pack(c)
                        done = false
                        break
                    end
                end
            end
        end
        if done or c.phase ~= "shop" then break end
    end
    if c.phase ~= "shop" then return true end
    return E.step(c, A_LEAVE)
end

function S:roll_pack(c)
    for _ = 1, 8 do
        if c.phase ~= "pack" then return true end
        local bi, bs = 0, -1
        for i = 1, c.n_pk do
            local kind = c.pk_kind[i]
            local sc = -1
            if kind == K_JOKER then
                if c.n_jok < c.joker_limit or c.pk_ed[i] == ED_NEG then sc = 100 + joker_score(c.pk_id[i], c.pk_ed[i]) end
            elseif kind == K_CONS then
                local h = planet_hand(c.pk_id[i])
                if h then sc = h == c.most_played and 50 or 10 + (12 - h) end
            end
            if sc > bs then bi, bs = i, sc end
        end
        local ok = false
        if bi > 0 then ok = E.step(c, {type = "pick", card = bi}) end
        if not ok and not E.step(c, A_SKIP) then return false end
    end
    return true
end

function S:rollout(s, H, base)
    self.rollouts = self.rollouts + 1
    base = base or s
    local c = clone(s)
    local cleared, bosses, strength, n_str, margin = 0, 0, 0, 0, 3
    local best_hand = 0
    for _ = 1, self.o.max_steps do
        local ph = c.phase
        if c.won == 1 or ph == "game_over" or ph == "win" then break end
        if ph == "play" then
            local a = PL.fast_action(c, true)
            local before = c.chips
            local boss = c.state_boss == 2
            local need = c.blind_chips
            if not E.step(c, a) then break end
            if a.type == "play" then
                local g = c.chips - before
                if g > best_hand then best_hand = g end
            end
            if c.phase ~= "play" then
                if c.phase ~= "game_over" then
                    cleared = cleared + 1
                    if boss then bosses = bosses + 1 end
                end
                strength = strength + log(max(best_hand, 1))
                n_str = n_str + 1
                local m = PL.margin_log(best_hand, need)
                if m < margin then margin = m end
                best_hand = 0
            end
        elseif ph == "blind_select" then
            if not E.step(c, A_SELECT) then break end
        elseif ph == "round_eval" then
            if not E.step(c, A_CASH) then break end
            if bosses >= H then break end
        elseif ph == "shop" then
            if not self:roll_shop(c) then break end
        elseif ph == "pack" then
            if self.o.roll_shop == 1 then
                if not self:roll_pack(c) then break end
            elseif not E.step(c, A_SKIP) then break end
        else
            break
        end
    end
    local v, st = self:value(c, base, cleared, strength, n_str, margin)
    if self.o.noise > 0 then v = v + self.o.noise * S.jitter(s, self.o.noise_seed) end
    return v, c, st
end

local function mix(h, v)
    return (h * 69069 + v * 2654435 + 12345) % 2147483648
end

function S.jitter(s, seed)
    local h = mix(seed + 1, s.step)
    h = mix(h, s.money + 1000)
    h = mix(h, s.n_cards)
    h = mix(h, s.n_cons)
    h = mix(h, s.reroll_cost)
    for k = 1, s.n_jok do h = mix(h, s.j_uid[k]) end
    for k = 1, s.n_sj do h = mix(h, s.sj_uid[k]) end
    for i = 1, 12 do h = mix(h, s.h_level[i]) end
    return h / 2147483648 - 0.5
end

local function target_sets(s, cid)
    local c = D.CONS[cid]
    local cfg = c.config
    local n = s.n_hand
    local k
    if cfg.max_highlighted then k = min(5, cfg.max_highlighted)
    elseif c.name == "Aura" then k = 1
    else return nil end
    local m = cfg.min_highlighted or 1
    if n < m then return {} end
    k = min(k, n)
    local sets, seen = {}, {}
    local function add(t)
        if #t < m or #t > k then return end
        table.sort(t)
        local key = table.concat(t, ",")
        if not seen[key] then
            seen[key] = true
            sets[#sets + 1] = t
        end
    end
    local hi, lo = {}, {}
    for i = 1, k do hi[i] = i lo[i] = n - k + i end
    add(hi)
    add(lo)
    if k >= 2 then add({1, n}) end
    if k == 1 then
        for i = 2, min(3, n) do add({i}) end
        for i = max(1, n - 2), n - 1 do add({i}) end
    end
    if cfg.suit_conv then
        local suit = D.SUIT_ID and D.SUIT_ID[cfg.suit_conv]
        if suit then
            local t = {}
            for i = 1, n do
                if #t < k and s.c_suit[s.hand[i]] ~= suit then t[#t + 1] = i end
            end
            add(t)
        end
    end
    return sets
end
S.target_sets = target_sets

local function cons_options(s, cid, in_pack, area_cons, act)
    local out = {}
    local sets = target_sets(s, cid)
    if sets then
        for i = 1, #sets do
            if E.can_use_cons(s, cid, #sets[i], in_pack, area_cons) then
                local a = copy_action(act)
                a.targets = sets[i]
                out[#out + 1] = a
            end
        end
    elseif E.can_use_cons(s, cid, 0, in_pack, area_cons) then
        out[#out + 1] = copy_action(act)
    end
    return out
end

function S:shop_cands(s, root)
    local out = {}
    local ml = money_left(s)
    for i = 1, s.n_sj do
        local cost = E.shop_joker_cost(s, i)
        if cost <= 0 or cost <= ml then
            local kind = s.sj_kind[i]
            if kind == K_JOKER then
                if s.n_jok < s.joker_limit or s.sj_ed[i] == ED_NEG then out[#out + 1] = {type = "buy", card = i} end
            elseif kind == K_CONS then
                local cid = s.sj_id[i]
                local cfg = D.CONS[cid].config
                if not cfg.max_highlighted and D.CONS[cid].name ~= "Aura" and E.can_use_cons(s, cid, 0, false, false) then
                    out[#out + 1] = {type = "buy_and_use", card = i}
                end
            elseif kind == K_CARD then
                out[#out + 1] = {type = "buy", card = i}
            end
        end
    end
    for i = 1, s.n_sv do
        if E.shop_voucher_cost(s, i) <= ml then out[#out + 1] = {type = "redeem", card = i} end
    end
    for i = 1, s.n_sb do
        local cost = E.shop_booster_cost(s, i)
        if cost <= 0 or cost <= ml then out[#out + 1] = {type = "open", card = i} end
    end
    if s.reroll_cost == 0 or ml - s.reroll_cost >= 0 then out[#out + 1] = {type = "reroll"} end
    for i = 1, s.n_cons do
        local cid = D.CONS_ID[s.cons[i]]
        local cfg = D.CONS[cid].config
        if not cfg.max_highlighted and D.CONS[cid].name ~= "Aura" and E.can_use_cons(s, cid, 0, false, true) then
            out[#out + 1] = {type = "use", card = i}
        end
    end
    if s.n_jok >= s.joker_limit then
        for i = 1, s.n_sj do
            if s.sj_kind[i] == K_JOKER and s.sj_ed[i] ~= ED_NEG then
                for k = 1, s.n_jok do
                    if s.j_eternal[k] ~= 1 and E.shop_joker_cost(s, i) <= ml + s.j_ev[k] + 30 then
                        out[#out + 1] = {type = "swap", sell = k, buy = i}
                    end
                end
            end
        end
    end
    if root and s.n_jok >= 2 and (E.find_joker(s, E.J.blueprint) or E.find_joker(s, E.J.brainstorm)) then
        for i = 1, s.n_jok - 1 do
            local order = {}
            for q = 1, s.n_jok do if q ~= i then order[#order + 1] = q end end
            order[#order + 1] = i
            out[#out + 1] = {type = "reorder_jokers", order = order}
        end
    end
    return out
end

function S:pack_cands(s)
    local out = {}
    for i = 1, s.n_pk do
        local kind = s.pk_kind[i]
        if kind == K_CONS then
            local opts = cons_options(s, s.pk_id[i], true, false, {type = "pick", card = i})
            for j = 1, #opts do out[#out + 1] = opts[j] end
        elseif kind == K_JOKER then
            if s.pk_ed[i] == ED_NEG or s.n_jok < s.joker_limit then out[#out + 1] = {type = "pick", card = i} end
        else
            out[#out + 1] = {type = "pick", card = i}
        end
    end
    out[#out + 1] = {type = "skip"}
    return out
end

local function state_key(s)
    local t = {s.phase, s.money, s.n_jok, s.n_cons, s.n_sj, s.n_sv, s.n_sb, s.reroll_cost, s.n_cards, s.joker_limit, s.cons_limit, s.n_tags}
    for i = 1, s.n_jok do t[#t + 1] = s.j_uid[i] end
    for i = 1, s.n_cons do t[#t + 1] = s.cons[i] end
    for i = 1, s.n_sj do t[#t + 1] = s.sj_uid[i] end
    for i = 1, s.n_sv do t[#t + 1] = s.sv_id[i] end
    for i = 1, s.n_sb do t[#t + 1] = s.sb_id[i] end
    for i = 1, 12 do t[#t + 1] = s.h_level[i] end
    return table.concat(t, ",")
end
S.state_key = state_key

function S:best_of(s, cands, H, base)
    local bv, bi, bst = -math.huge, 0, 0
    local vals = {}
    for i = 1, #cands do
        local c = clone(s)
        if E.step(c, cands[i]) then
            local v, _, st = self:rollout(c, H, base or s)
            vals[i] = v
            if v > bv then bv, bi, bst = v, i, st end
        else
            vals[i] = nil
        end
    end
    return bi, bv, vals, bst
end

function S:resolve_pack(c, acts, H, base)
    for _ = 1, 16 do
        if c.phase ~= "pack" then return end
        local cands = self:pack_cands(c)
        local bi = self:best_of(c, cands, H, base)
        local a = bi > 0 and cands[bi] or A_SKIP
        if not E.step(c, a) then
            if not E.step(c, A_SKIP) then return end
            a = A_SKIP
        end
        acts[#acts + 1] = copy_action(a)
    end
end

function S:shop_search(s, H, W)
    local o = self.o
    local root = {s = clone(s), acts = {}}
    local rc
    root.v, rc, root.st = self:rollout(root.s, H, s)
    root.dead = rc.phase == "game_over"
    local beam = {root}
    local seen = {[state_key(root.s)] = true}
    for d = 1, o.depth do
        local pool = {}
        for i = 1, #beam do pool[i] = beam[i] end
        local added = false
        for bi = 1, #beam do
            local node = beam[bi]
            local cands = self:shop_cands(node.s, d == 1)
            for ci = 1, #cands do
                local a = cands[ci]
                local c = clone(node.s)
                local stepped
                local acts = copy(node.acts)
                if a.type == "swap" then
                    local sa, ba = {type = "sell", area = "jokers", card = a.sell}, {type = "buy", card = a.buy}
                    stepped = E.step(c, sa) and E.step(c, ba)
                    acts[#acts + 1] = sa
                    acts[#acts + 1] = ba
                else
                    stepped = E.step(c, a)
                    acts[#acts + 1] = copy_action(a)
                end
                if stepped then
                    if c.phase == "pack" then self:resolve_pack(c, acts, H, s) end
                    if c.phase == "shop" then
                        local k = state_key(c)
                        if not seen[k] then
                            seen[k] = true
                            local v, rc, st = self:rollout(c, H, s)
                            pool[#pool + 1] = {s = c, acts = acts, v = v, st = st, dead = rc.phase == "game_over"}
                        end
                    end
                end
            end
        end
        table.sort(pool, function(a, b)
            if a.v ~= b.v then return a.v > b.v end
            return #a.acts < #b.acts
        end)
        local nb = {}
        for i = 1, min(W, #pool) do
            nb[i] = pool[i]
            local fresh = true
            for j = 1, #beam do if beam[j] == pool[i] then fresh = false end end
            if fresh then added = true end
        end
        beam = nb
        if not added then break end
    end
    return beam
end

function S:tight(st_best, dead)
    return dead or st_best < self.o.tight_margin
end

function S:set_plan(s, acts)
    self.plan, self.plan_i, self.plan_step = acts, 1, s.step
end

function S:record(s, kind, ranked)
    if not self.checkpoints then return end
    self.checkpoints[#self.checkpoints + 1] = {state = clone(s), kind = kind, ranked = ranked, step = s.step}
end

function S:decide_shop(s)
    local o = self.o
    local beam = self:shop_search(s, o.horizon, o.tight_beam)
    local best = beam[1]
    if self:tight(best.st or 0, best.dead) then
        for i = 1, #beam do
            beam[i].v = self:rollout(beam[i].s, o.tight_horizon, s)
        end
        table.sort(beam, function(a, b)
            if a.v ~= b.v then return a.v > b.v end
            return #a.acts < #b.acts
        end)
    end
    local ranked = {}
    for i = 1, #beam do
        local acts = copy(beam[i].acts)
        acts[#acts + 1] = copy_action(A_LEAVE)
        ranked[i] = {acts = acts, v = beam[i].v}
    end
    self:record(s, "shop", ranked)
    return ranked[1].acts
end

function S:decide_blind(s)
    local o = self.o
    local cands = {copy_action(A_SELECT)}
    if s.blind_on_deck ~= 3 then cands[#cands + 1] = {type = "skip"} end
    local probe = clone(s)
    if E.step(probe, {type = "reroll_boss"}) then cands[#cands + 1] = {type = "reroll_boss"} end
    if #cands == 1 then return cands end
    local H = o.horizon
    local bi, bv, vals, bst = self:best_of(s, cands, H, s)
    if bst < o.tight_margin then
        bi, bv, vals = self:best_of(s, cands, o.tight_horizon, s)
    end
    local ranked = {}
    for i = 1, #cands do
        if vals[i] then
            local v = vals[i]
            if cands[i].type == "skip" then v = v - o.skip_cost end
            ranked[#ranked + 1] = {acts = {cands[i]}, v = v}
        end
    end
    table.sort(ranked, function(a, b)
        if a.v ~= b.v then return a.v > b.v end
        return a.acts[1].type < b.acts[1].type
    end)
    self:record(s, "blind", ranked)
    return {ranked[1] and ranked[1].acts[1] or cands[1]}
end

function S:decide_pack(s)
    local acts = {}
    local c = clone(s)
    self:resolve_pack(c, acts, self.o.horizon, s)
    if #acts == 0 then acts[1] = copy_action(A_SKIP) end
    return {acts[1]}
end

function S:play_cons(s)
    if s.n_cons == 0 or s.discards_used > 0 or s.round_hands_played > 0 then return nil end
    local cands = {}
    for i = 1, s.n_cons do
        local cid = D.CONS_ID[s.cons[i]]
        if not is_planet(s.cons[i]) then
            local opts = cons_options(s, cid, false, true, {type = "use", card = i})
            for j = 1, #opts do cands[#cands + 1] = opts[j] end
        end
    end
    if #cands == 0 then return nil end
    local v0 = self:rollout(s, self.o.horizon, s)
    local bi, bv = self:best_of(s, cands, self.o.horizon, s)
    if bi > 0 and bv > v0 then return cands[bi] end
    return nil
end

function S:decide_play(s)
    local u = self:play_cons(s)
    if u then return {u} end
    local o = self.o
    local acts = PL.solve(s, {beam = o.solve_beam, plays = o.solve_plays, discards = o.solve_discards})
    return acts
end

function S:choose(s)
    if self.plan and self.plan_i <= #self.plan and s.step == self.plan_step then
        local a = self.plan[self.plan_i]
        self.plan_i = self.plan_i + 1
        self.plan_step = self.plan_step + 1
        return a
    end
    self.plan = nil
    local ph = s.phase
    local acts
    if s.won == 1 or ph == "game_over" or ph == "win" then return nil
    elseif ph == "round_eval" then return copy_action(A_CASH)
    elseif ph == "blind_select" then acts = self:decide_blind(s)
    elseif ph == "shop" then acts = self:decide_shop(s)
    elseif ph == "pack" then acts = self:decide_pack(s)
    elseif ph == "play" then acts = self:decide_play(s)
    else return nil end
    if not acts or #acts == 0 then return nil end
    self:set_plan(s, acts)
    return self:choose(s)
end

function S:play_from(s, line, on_action)
    for _ = 1, self.o.max_steps do
        if s.won == 1 or s.phase == "game_over" then break end
        if self.o.stop_ante and s.ante > self.o.stop_ante then break end
        local a = self:choose(s)
        if not a then break end
        if not E.step(s, a) then
            self.plan = nil
            local fb
            if s.phase == "play" then fb = PL.fast_action(s)
            elseif s.phase == "shop" then fb = A_LEAVE
            elseif s.phase == "pack" then fb = A_SKIP
            elseif s.phase == "blind_select" then fb = A_SELECT end
            if not fb or not E.step(s, fb) then break end
            a = fb
        end
        line[#line + 1] = copy_action(a)
        if on_action then on_action(s, a) end
    end
    return s
end

function S:play(setup, on_action)
    local s = E.new_run(setup)
    local line = {}
    self.plan = nil
    self:play_from(s, line, on_action)
    return line, s
end

local function final_ante(s)
    if s.won == 1 then return s.win_ante end
    return s.ante
end
S.final_ante = final_ante

local function score_line(s)
    return (s.won == 1 and 1000 or 0) + s.ante * 10 + (s.state_small >= 3 and 1 or 0) + (s.state_big >= 3 and 1 or 0)
end

function S.replay(setup, line)
    local s = E.new_run(setup)
    for i = 1, #line do
        if not E.step(s, line[i]) then return s, i end
    end
    return s, nil
end

S.PORTFOLIO = {
    {},
    {horizon = 3, tight_horizon = 4},
    {w_money = 0.1},
    {w_strength = 3, beam = 4},
    {horizon = 1, tight_horizon = 2},
}

S.BOOST = {horizon = 3, tight_horizon = 4, tight_beam = 6, depth = 4, tight_margin = 0.8}

local function merged(a, b)
    local o = {}
    for k, v in pairs(a) do o[k] = v end
    for k, v in pairs(b or {}) do o[k] = v end
    return o
end

function S:solve(setup, opts, progress)
    opts = opts or {}
    local max_lines = opts.max_lines or 8
    local time_limit = opts.time_limit or 0
    local portfolio = opts.portfolio or S.PORTFOLIO
    local n_port = opts.n_portfolio or #portfolio
    local boost = opts.boost or S.BOOST
    local boost_antes = opts.boost_antes or 1
    local clock = os.clock
    local t0 = clock()
    local best
    local open = {}
    local lines = 0
    local function report()
        if progress then
            progress({lines = lines, best_ante = final_ante(best.state), won = best.state.won == 1, time = clock() - t0})
        end
    end
    local function line_score(s)
        return score_line(s) + 0.001 * min(s.chips / max(1, s.blind_chips), 0.999)
    end
    local function finish_line(cps, line, s, base_o, origin)
        lines = lines + 1
        local sc = line_score(s)
        if not best or sc > best.score then best = {line = line, state = s, score = sc, origin = origin} end
        local dead_ante = s.ante
        for _, cp in ipairs(cps) do
            local ranked = cp.ranked
            local near = math.abs(cp.state.ante - (dead_ante - 1))
            if not cp.boosted then
                open[#open + 1] = {deep = true, state = cp.state, gap = 0, prefix = line, plen = cp.step, ante = cp.state.ante,
                    near = near, score = sc, o = base_o}
            end
            for r = 2, #ranked do
                open[#open + 1] = {state = cp.state, acts = ranked[r].acts, gap = ranked[1].v - ranked[r].v,
                    prefix = line, plen = cp.step, ante = cp.state.ante, near = near, score = sc, o = base_o}
            end
        end
        report()
    end
    local function out_of_time()
        return time_limit > 0 and clock() - t0 > time_limit
    end
    local function run_from(st, nl, base_o, boost_until, origin)
        local cps = {}
        if boost_until then
            local bseer = S.new(merged(merged(base_o, boost), {stop_ante = boost_until}))
            bseer.checkpoints = {}
            bseer:play_from(st, nl)
            for _, cp in ipairs(bseer.checkpoints) do
                cp.boosted = true
                cps[#cps + 1] = cp
            end
            self.rollouts = self.rollouts + bseer.rollouts
        end
        if st.won ~= 1 and st.phase ~= "game_over" then
            local seer = S.new(base_o)
            seer.checkpoints = {}
            seer:play_from(st, nl)
            for _, cp in ipairs(seer.checkpoints) do cps[#cps + 1] = cp end
            self.rollouts = self.rollouts + seer.rollouts
        end
        finish_line(cps, nl, st, base_o, origin)
    end
    for i = 1, n_port do
        if lines >= max_lines or out_of_time() or (best and best.state.won == 1) then break end
        local o = merged(self.o, portfolio[i])
        run_from(E.new_run(setup), {}, o, nil, "p" .. i)
    end
    local function branch()
        local bi, bk = 1, math.huge
        local top = best.score
        for i = 1, #open do
            local a = open[i]
            local k = (a.deep and 0.5 or 1 + a.gap) * (1 + a.near) * (1 + 0.5 * max(0, top - a.score))
            if k < bk or (k == bk and a.plen > open[bi].plen) then bi, bk = i, k end
        end
        local alt = table.remove(open, bi)
        local st = clone(alt.state)
        local nl = {}
        for i = 1, alt.plen do nl[i] = alt.prefix[i] end
        if alt.deep then
            run_from(st, nl, alt.o, alt.ante + boost_antes - 1, "d" .. alt.ante)
            return
        end
        for i = 1, #alt.acts do
            if not E.step(st, alt.acts[i]) then return end
            nl[#nl + 1] = copy_action(alt.acts[i])
        end
        run_from(st, nl, alt.o, nil, "a" .. alt.ante)
    end
    local restart_every = opts.restart_every or 2
    local noise = opts.noise or 1.5
    local restarts = 0
    while best.state.won ~= 1 and lines < max_lines and not out_of_time() do
        if restart_every > 0 and (#open == 0 or (lines - n_port) % restart_every == 0) then
            restarts = restarts + 1
            local o = merged(merged(self.o, portfolio[(restarts - 1) % #portfolio + 1]), {noise = noise, noise_seed = restarts})
            run_from(E.new_run(setup), {}, o, nil, "r" .. restarts)
        elseif #open > 0 then
            branch()
        else
            break
        end
    end
    local rs, bad = S.replay(setup, best.line)
    local won = rs.won == 1 and not bad
    local verdict
    if won then
        verdict = string.format("Win found, guaranteed, final ante %d", final_ante(rs))
    else
        verdict = string.format("No win found, best line ante %d", final_ante(best.state))
    end
    return {won = won, verdict = verdict, line = best.line, final_ante = final_ante(best.state), lines = lines,
        time = clock() - t0, replay_ok = bad == nil, origin = best.origin}
end

return S
