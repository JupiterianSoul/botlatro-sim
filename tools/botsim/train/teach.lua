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

function M:tarot_targets(s, cid)
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
                if ph == "play" and c.set == SET_TAROT then
                    local t, why = self:tarot_targets(s, cid)
                    if t then return {type = "use", card = k, targets = t}, "use_" .. why end
                end
            end
        end
    end
    if ph == "shop" then
        local money = s.money
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
                if money - E.shop_booster_cost(s, i) >= self.reserve then
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
                elseif c.set == SET_TAROT and bv < 1 then
                    local t, w = self:tarot_targets(s, cid)
                    if t then best, bv, why = {type = "pick", card = i, targets = t}, 1, "pick_" .. w end
                end
            end
        end
        return best, why
    end
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
