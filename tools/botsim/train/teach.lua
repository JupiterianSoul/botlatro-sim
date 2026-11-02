local E = require("bot.sim.engine")
local D = require("bot.sim.data")
local PLAN = require("botsim.train.plan")
local FAIR = require("bot.seer.fair")

local M = {}
M.__index = M

local SET_TAROT, SET_PLANET, SET_SPECTRAL = 1, 2, 3
local K_CONS = E.K_CONS or 2
local OBS = D.VOUCHER_ID and D.VOUCHER_ID.v_observatory
local C = D.CONS_ID
local HANGED = C.c_hanged_man
local BLACK_HOLE = C.c_black_hole
local SUIT_TAROT = {[C.c_star] = 4, [C.c_moon] = 3, [C.c_sun] = 2, [C.c_world] = 1}
local FLUSHY = {[D.H_FLUSH] = true, [D.H_SFLUSH] = true, [D.H_FLUSH_HOUSE] = true, [D.H_FLUSH_FIVE] = true}
local RANKY = {[D.H_PAIR] = true, [D.H_TWO_PAIR] = true, [D.H_THREE] = true, [D.H_FOUR] = true, [D.H_FULL] = true, [D.H_FIVE] = true, [D.H_HIGH] = true}
local CELESTIAL, ARCANA = 2, 1

function M.new(opt)
    opt = opt or {}
    return setmetatable({
        reserve = tonumber(opt.t_res) or 25,
        planet_res = tonumber(opt.t_pres) or 5,
        min_deck = tonumber(opt.t_deck) or 30,
        switch = tonumber(opt.t_switch) or 1.25,
        all = (tonumber(opt.t_all) or 0) > 0,
        late = (tonumber(opt.t_late) or 0) > 0,
        dyn = (tonumber(opt.t_res) or 25) < 0,
        plan = nil, plan_ante = -1, n = {}, fb = {},
    }, M)
end

local function bump(t, k) t[k] = (t[k] or 0) + 1 end

local function alive_count(s)
    local n, by_suit, by_rank = 0, {0, 0, 0, 0}, {}
    for id = 1, s.n_cards do
        if s.c_alive[id] == 1 then
            n = n + 1
            local su = s.c_suit[id]
            if by_suit[su] then by_suit[su] = by_suit[su] + 1 end
            by_rank[s.c_rank[id]] = (by_rank[s.c_rank[id]] or 0) + 1
        end
    end
    return n, by_suit, by_rank
end
M.alive_count = alive_count

local function best_suit(by_suit)
    local b = 1
    for k = 2, 4 do if by_suit[k] > by_suit[b] then b = k end end
    return b
end

function M:update_plan(s)
    if self.plan_ante == s.ante and self.plan then return self.plan end
    local w = FAIR.world(FAIR.sanitize(s), "TPLAN_" .. s.ante)
    PLAN.eval(w)
    local rows = PLAN.last_rows or {}
    local best, cur = nil, nil
    for _, r in ipairs(rows) do
        local v = r.v * r.reach
        if not best or v > best.v then best = {h = r.h, v = v} end
        if r.h == self.plan then cur = v end
    end
    if best then
        if not self.plan then
            self.plan = best.h
        elseif best.h ~= self.plan and (not cur or best.v > self.switch * cur) then
            self.plan = best.h
            bump(self.n, "switch")
        end
    end
    self.plan_ante = s.ante
    return self.plan
end

local function plain(s, id)
    return s.c_enh[id] == 0 and s.c_ed[id] == 0 and s.c_seal[id] == 0
end

local function off_plan(self, s, max_n, suit)
    local _, by_suit, by_rank = alive_count(s)
    local plan = self.plan
    local flushy = plan and FLUSHY[plan]
    local want = suit or (flushy and best_suit(by_suit)) or nil
    local list = {}
    for i = 1, s.n_hand do
        local id = s.hand[i]
        if plain(s, id) and s.c_debuff[id] == 0 then
            local bad
            if want then
                if s.c_suit[id] ~= want then bad = 100 - s.c_rank[id] end
            elseif plan and RANKY[plan] then
                bad = 50 - 3 * (by_rank[s.c_rank[id]] or 0) - s.c_rank[id]
            end
            if bad then list[#list + 1] = {i = i, b = bad} end
        end
    end
    table.sort(list, function(a, b)
        if a.b ~= b.b then return a.b > b.b end
        return a.i < b.i
    end)
    local out = {}
    for k = 1, math.min(max_n, #list) do out[k] = list[k].i end
    table.sort(out)
    return out
end

local function cons_of_key(key)
    local id = C[key]
    return id, id and D.CONS[id]
end

local function good_list(self, s, need_suit)
    local _, by_suit, by_rank = alive_count(s)
    local plan = self.plan
    local su = plan and FLUSHY[plan] and best_suit(by_suit) or nil
    local list = {}
    for i = 1, s.n_hand do
        local id = s.hand[i]
        if s.c_debuff[id] == 0 and s.c_enh[id] ~= D.ENH_ID.m_stone and (not su or s.c_suit[id] == su or not need_suit) then
            local g = s.c_rank[id]
            if plan and RANKY[plan] and plan ~= D.H_HIGH then g = g + 3 * (by_rank[s.c_rank[id]] or 0) end
            if su and s.c_suit[id] == su then g = g + 20 end
            list[#list + 1] = {i = i, g = g, id = id}
        end
    end
    table.sort(list, function(a, b)
        if a.g ~= b.g then return a.g > b.g end
        return a.i < b.i
    end)
    return list
end

local function pick_good(self, s, n, field)
    local out = {}
    for _, e in ipairs(good_list(self, s, true)) do
        if #out >= n then break end
        if s[field][e.id] == 0 then out[#out + 1] = e.i end
    end
    table.sort(out)
    return #out > 0 and out or nil
end

local ENH_GOOD = {c_empress = 2, c_hierophant = 2, c_magician = 2, c_justice = 1}
local SEAL_GOOD = {c_deja_vu = true, c_aura = true}
local SEAL_BAD = {c_talisman = true, c_trance = true, c_medium = true}
local FREE = {c_hermit = true, c_temperance = true, c_judgement = true, c_wheel_of_fortune = true, c_emperor = true, c_high_priestess = true, c_fool = true, c_soul = true, c_wraith = true}

function M:all_targets(s, cid)
    local key = D.CONS[cid].key
    if FREE[key] then
        if key == "c_hermit" and s.money < 8 then return nil end
        if key == "c_wraith" and s.money > 4 then return nil end
        if (key == "c_judgement" or key == "c_soul" or key == "c_wraith") and s.n_jok >= s.joker_limit then return nil end
        if E.can_use_cons and not E.can_use_cons(s, cid, 0, s.phase == "pack", s.phase ~= "pack") then return nil end
        return {}, "free"
    end
    if s.phase ~= "play" and s.phase ~= "pack" then return nil end
    if s.n_hand == 0 then return nil end
    if ENH_GOOD[key] then
        local t = pick_good(self, s, ENH_GOOD[key], "c_enh")
        if t then return t, "enh" end
    elseif key == "c_chariot" then
        local t = pick_good(self, s, 1, "c_enh")
        if t then return t, "steel" end
    elseif key == "c_lovers" and self.plan and FLUSHY[self.plan] then
        local t = off_plan(self, s, 1)
        if #t > 0 and s.c_enh[s.hand[t[1]]] == 0 then return t, "wild" end
    elseif key == "c_devil" then
        local t = off_plan(self, s, 1)
        if #t > 0 then return t, "gold" end
    elseif SEAL_GOOD[key] then
        local t = pick_good(self, s, 1, key == "c_aura" and "c_ed" or "c_seal")
        if t then return t, key == "c_aura" and "aura" or "seal" end
    elseif SEAL_BAD[key] then
        local t = off_plan(self, s, 1)
        if #t > 0 then return t, "seal" end
    elseif key == "c_cryptid" and self.plan and self.plan ~= D.H_STRAIGHT then
        local g = good_list(self, s, true)
        if g[1] then return {g[1].i}, "cryptid" end
    elseif key == "c_death" then
        local bad = off_plan(self, s, 8)
        local g = good_list(self, s, true)
        local isbad = {}
        for _, i in ipairs(bad) do isbad[i] = true end
        for _, e in ipairs(g) do
            if not isbad[e.i] then
                for k = #bad, 1, -1 do
                    if bad[k] < e.i then return {bad[k], e.i}, "death" end
                end
            end
        end
    end
    return nil
end

local PICK_V = {c_soul = 5, c_cryptid = 2.5, c_death = 2.2, c_hanged_man = 2, c_deja_vu = 1.8, c_aura = 1.8, c_judgement = 1.5}

function M:tarot_targets(s, cid)
    if self.all and cid ~= HANGED and not SUIT_TAROT[cid] then return self:all_targets(s, cid) end
    if cid == HANGED then
        local n = alive_count(s)
        if n <= self.min_deck then return nil end
        local t = off_plan(self, s, math.min(2, n - self.min_deck))
        if #t > 0 then return t, "hanged" end
    elseif SUIT_TAROT[cid] and self.plan and FLUSHY[self.plan] then
        local _, by_suit = alive_count(s)
        local su = SUIT_TAROT[cid]
        if su ~= best_suit(by_suit) then return nil end
        local t = off_plan(self, s, 3, su)
        if #t > 0 then return t, "suit" end
    end
    return nil
end

local function planet_ok(s)
    return not (OBS and s.used_v[OBS] and s.used_v[OBS] ~= 0)
end

function M:move(s)
    local ph = s.phase
    if ph ~= "shop" and ph ~= "pack" and ph ~= "play" then return nil end
    self:update_plan(s)
    if ph == "shop" or ph == "play" then
        for k = s.n_cons, 1, -1 do
            local cid, c = cons_of_key(s.cons[k])
            if c then
                if (c.set == SET_PLANET and planet_ok(s)) or cid == BLACK_HOLE then
                    return {type = "use", card = k}, "use_planet"
                end
                if (ph == "play" and c.set == SET_TAROT) or (self.all and (c.set == SET_TAROT or c.set == SET_SPECTRAL)) then
                    local t, why = self:tarot_targets(s, cid)
                    if t then return {type = "use", card = k, targets = #t > 0 and t or nil}, "use_" .. why end
                end
            end
        end
    end
    if ph == "shop" then
        if self.late and not self.leaving then return nil end
        local money = s.money
        local reserve = self.dyn and self:dyn_reserve(s) or self.reserve
        if planet_ok(s) and s.n_cons < s.cons_limit then
            for i = 1, s.n_sj do
                if s.sj_kind[i] == K_CONS then
                    local c = D.CONS[s.sj_id[i]]
                    if c and c.set == SET_PLANET and c.hand == self.plan and money - E.shop_joker_cost(s, i) >= self.planet_res then
                        return {type = "buy", card = i}, "buy_planet"
                    end
                end
            end
        end
        for i = 1, s.n_sb do
            local b = D.BOOST[s.sb_id[i]]
            local kind = b and b.kind_id
            if (kind == CELESTIAL and planet_ok(s)) or (kind == ARCANA and alive_count(s) > self.min_deck) then
                if money - E.shop_booster_cost(s, i) >= reserve then
                    return {type = "open", card = i}, kind == CELESTIAL and "open_celestial" or "open_arcana"
                end
            end
        end
        return nil
    end
    if ph == "pack" then
        local best, bv, why = nil, 0, nil
        for i = 1, s.n_pk do
            if s.pk_kind[i] == K_CONS then
                local cid = s.pk_id[i]
                local c = D.CONS[cid]
                if cid == BLACK_HOLE then
                    if bv < 3 then best, bv, why = {type = "pick", card = i}, 3, "pick_black_hole" end
                elseif c.set == SET_PLANET and c.hand == self.plan and planet_ok(s) then
                    if bv < 2 then best, bv, why = {type = "pick", card = i}, 2, "pick_planet" end
                elseif (c.set == SET_TAROT or (self.all and c.set == SET_SPECTRAL)) then
                    local v = self.all and (PICK_V[c.key] or 1) or 1
                    if bv < v then
                        local t, w = self:tarot_targets(s, cid)
                        if t then best, bv, why = {type = "pick", card = i, targets = #t > 0 and t or nil}, v, "pick_" .. w end
                    end
                end
            end
        end
        return best, why
    end
    return nil
end

function M:dyn_reserve(s)
    if s.no_interest == 1 then return 0 end
    local m = PLAN.score(FAIR.world(FAIR.sanitize(s), "TRES_" .. s.ante))
    local r = m < 0 and 0 or m < 1 and 10 or 25
    if s.ante <= 2 then r = math.min(r, 5) end
    return r
end

function M.skip_safe(s, margin)
    if s.phase ~= "blind_select" or s.blind_on_deck == 3 then return true end
    if margin < 0 then return s.n_jok > 0 end
    local b = s.blind_on_deck == 1 and 2 or s.boss_choice
    local bd = D.BLINDS[b]
    local need = E.get_blind_amount(s, s.ante) * (bd and bd.mult or 2) * s.ante_scaling
    local v = PLAN.eval(FAIR.world(FAIR.sanitize(s), "TSKIP_" .. s.ante .. "_" .. s.blind_on_deck))
    return v * math.max(1, s.resets_hands + s.bonus_hands) >= margin * need
end

function M:leave_move(s)
    self.leaving = true
    local a, why = self:move(s)
    self.leaving = false
    if a and (a.type == "open" or a.type == "buy") then return a, why end
    return nil
end

function M:note(ph, why, ok)
    if why and ok then bump(self.n, why)
    elseif why then bump(self.n, "fail_" .. why)
    else bump(self.fb, ph) end
end

function M:report()
    return {n = self.n, fb = self.fb}
end

function M.build_row(s, uses)
    local n = alive_count(s)
    local top = 0
    for h = 1, D.NUM_HANDS do if s.h_level[h] > top then top = s.h_level[h] end end
    return string.format("%d:%d:%d:%d:%d", s.ante, n, top, s.money, uses)
end

return M
