local BUF = require("bot.nn.buf")
local WT = require("bot.nn.weights")
local FE = require("bot.nn.features")

local M = {}
M.__index = M

local exp = math.exp

local function dense_ref(x, xo, nin, W, b, nout, y, yo, relu)
    for o = 0, nout - 1 do y[yo + o] = b[o] end
    for i = 0, nin - 1 do
        local v = x[xo + i]
        if v ~= 0 then
            local r = i * nout
            for o = 0, nout - 1 do y[yo + o] = y[yo + o] + v * W[r + o] end
        end
    end
    if relu then
        for o = 0, nout - 1 do
            if y[yo + o] < 0 then y[yo + o] = 0 end
        end
    end
end
M.dense_ref = dense_ref

local nz_i, nz_v = BUF.alloc_int(4096), BUF.alloc(4096)

local function accumulate(ii, vv, nz, W, nout, y, yo)
    local k = 0
    while k + 7 < nz do
        local r1, r2, r3, r4 = ii[k], ii[k + 1], ii[k + 2], ii[k + 3]
        local r5, r6, r7, r8 = ii[k + 4], ii[k + 5], ii[k + 6], ii[k + 7]
        local v1, v2, v3, v4 = vv[k], vv[k + 1], vv[k + 2], vv[k + 3]
        local v5, v6, v7, v8 = vv[k + 4], vv[k + 5], vv[k + 6], vv[k + 7]
        for o = 0, nout - 1 do
            y[yo + o] = y[yo + o] + v1 * W[r1 + o] + v2 * W[r2 + o] + v3 * W[r3 + o] + v4 * W[r4 + o]
                + v5 * W[r5 + o] + v6 * W[r6 + o] + v7 * W[r7 + o] + v8 * W[r8 + o]
        end
        k = k + 8
    end
    while k + 3 < nz do
        local r1, r2, r3, r4 = ii[k], ii[k + 1], ii[k + 2], ii[k + 3]
        local v1, v2, v3, v4 = vv[k], vv[k + 1], vv[k + 2], vv[k + 3]
        for o = 0, nout - 1 do
            y[yo + o] = y[yo + o] + v1 * W[r1 + o] + v2 * W[r2 + o] + v3 * W[r3 + o] + v4 * W[r4 + o]
        end
        k = k + 4
    end
    while k < nz do
        local r, v = ii[k], vv[k]
        for o = 0, nout - 1 do y[yo + o] = y[yo + o] + v * W[r + o] end
        k = k + 1
    end
end

local function dense(x, xo, nin, W, b, nout, y, yo, relu)
    local ii, vv = nz_i, nz_v
    local nz = 0
    for i = 0, nin - 1 do
        local v = x[xo + i]
        if v ~= 0 then
            ii[nz] = i * nout
            vv[nz] = v
            nz = nz + 1
        end
    end
    for o = 0, nout - 1 do y[yo + o] = b[o] end
    accumulate(ii, vv, nz, W, nout, y, yo)
    if relu then
        for o = 0, nout - 1 do
            if y[yo + o] < 0 then y[yo + o] = 0 end
        end
    end
end
M.dense = dense

local function encode_set(x, n, nin, W, b, E, emb, x0, sumo, maxo)
    for o = 0, E - 1 do
        x0[sumo + o] = 0
        x0[maxo + o] = 0
    end
    for i = 0, n - 1 do
        local eo = i * E
        dense(x, i * nin, nin, W, b, E, emb, eo, true)
        for o = 0, E - 1 do
            local v = emb[eo + o]
            x0[sumo + o] = x0[sumo + o] + v
            if v > x0[maxo + o] then x0[maxo + o] = v end
        end
    end
end

function M.new(W, opts)
    opts = opts or {}
    local cfg = W.cfg
    local self = setmetatable({}, M)
    self.W = W
    self.cfg = cfg
    self.E, self.H, self.VH = cfg.E, cfg.H, cfg.VH
    self.CF, self.JF, self.IF, self.GF, self.FA = cfg.CF, cfg.JF, cfg.IF, cfg.GF, cfg.FA
    self.types = WT.type_list(cfg)
    for k, name in ipairs(self.types) do
        assert(FE.TYPES[k] == name, "weight action types do not match features: " .. tostring(cfg.types))
    end
    self.ent = {}
    for k = 1, #self.types do self.ent[k] = FE.TYPE_ENT[k] or 0 end
    local maxc, maxj, maxi = opts.maxc or FE.MAXC, opts.maxj or FE.MAXJ, opts.maxi or FE.MAXI
    local t = W.t
    self.cw, self.cb = t["enc.card.w"].data, t["enc.card.b"].data
    self.jw, self.jb = t["enc.joker.w"].data, t["enc.joker.b"].data
    self.iw, self.ib = t["enc.item.w"].data, t["enc.item.b"].data
    self.t0w, self.t0b = t["trunk.0.w"].data, t["trunk.0.b"].data
    self.t1w, self.t1b = t["trunk.1.w"].data, t["trunk.1.b"].data
    self.v0w, self.v0b = t["value.0.w"].data, t["value.0.b"].data
    self.v1w, self.v1b = t["value.1.w"].data, t["value.1.b"].data
    self.pw, self.pb = {}, {}
    for k, name in ipairs(self.types) do
        self.pw[k] = t["pol." .. name .. ".w"].data
        self.pb[k] = t["pol." .. name .. ".b"].data
    end
    local E, H = self.E, self.H
    self.nin0 = self.GF + 6 * E
    self.cemb = BUF.alloc(maxc * E)
    self.jemb = BUF.alloc(maxj * E)
    self.iemb = BUF.alloc(maxi * E)
    self.x0 = BUF.alloc(self.nin0)
    self.h1 = BUF.alloc(H)
    self.base = BUF.alloc(H)
    self.groot = BUF.alloc(self.GF)
    self.q = BUF.alloc(H)
    self.v1 = BUF.alloc(self.VH)
    self.vout = BUF.alloc(2)
    self.u = {}
    self.cs = {}
    self.es = {}
    self.have_u = {}
    local maxe = maxi > maxj and maxi or maxj
    for k = 1, #self.types do
        self.u[k] = BUF.alloc(2 * E + self.FA)
        self.cs[k] = BUF.alloc(maxc)
        self.es[k] = BUF.alloc(maxe)
    end
    return self
end

function M:forward(F)
    local E, GF = self.E, self.GF
    local x0, g = self.x0, F.g
    for i = 0, GF - 1 do x0[i] = g[i] end
    encode_set(F.c, F.nc, self.CF, self.cw, self.cb, E, self.cemb, x0, GF, GF + E)
    encode_set(F.j, F.nj, self.JF, self.jw, self.jb, E, self.jemb, x0, GF + 2 * E, GF + 3 * E)
    encode_set(F.i, F.ni, self.IF, self.iw, self.ib, E, self.iemb, x0, GF + 4 * E, GF + 5 * E)
    dense(x0, 0, self.nin0, self.t0w, self.t0b, self.H, self.h1, 0, true)
    dense(self.h1, 0, self.H, self.t1w, self.t1b, self.H, self.q, 0, true)
    dense(self.q, 0, self.H, self.v0w, self.v0b, self.VH, self.v1, 0, true)
    dense(self.v1, 0, self.VH, self.v1w, self.v1b, 2, self.vout, 0, false)
    self.nc, self.nj, self.ni = F.nc, F.nj, F.ni
    for k = 1, #self.types do self.have_u[k] = false end
    local z = self.vout[0]
    return 1 / (1 + exp(-z)), self.vout[1], z
end

function M:set_base(F)
    local GF, H = self.GF, self.H
    local g, gr = F.g, self.groot
    for i = 0, GF - 1 do gr[i] = g[i] end
    dense(g, 0, GF, self.t0w, self.t0b, H, self.base, 0, false)
end

function M:forward_delta(F)
    local E, GF, H = self.E, self.GF, self.H
    local x0, g, gr = self.x0, F.g, self.groot
    encode_set(F.c, F.nc, self.CF, self.cw, self.cb, E, self.cemb, x0, GF, GF + E)
    encode_set(F.j, F.nj, self.JF, self.jw, self.jb, E, self.jemb, x0, GF + 2 * E, GF + 3 * E)
    encode_set(F.i, F.ni, self.IF, self.iw, self.ib, E, self.iemb, x0, GF + 4 * E, GF + 5 * E)
    local ii, vv = nz_i, nz_v
    local nz = 0
    for i = 0, GF - 1 do
        local v = g[i]
        local d = v - gr[i]
        if d ~= 0 then
            ii[nz] = i * H
            vv[nz] = d
            nz = nz + 1
        end
        x0[i] = v
    end
    for i = GF, self.nin0 - 1 do
        local v = x0[i]
        if v ~= 0 then
            ii[nz] = i * H
            vv[nz] = v
            nz = nz + 1
        end
    end
    local h1, base = self.h1, self.base
    for o = 0, H - 1 do h1[o] = base[o] end
    accumulate(ii, vv, nz, self.t0w, H, h1, 0)
    for o = 0, H - 1 do
        if h1[o] < 0 then h1[o] = 0 end
    end
    dense(h1, 0, H, self.t1w, self.t1b, H, self.q, 0, true)
    dense(self.q, 0, H, self.v0w, self.v0b, self.VH, self.v1, 0, true)
    dense(self.v1, 0, self.VH, self.v1w, self.v1b, 2, self.vout, 0, false)
    self.nc, self.nj, self.ni = F.nc, F.nj, F.ni
    for k = 1, #self.types do self.have_u[k] = false end
    local z = self.vout[0]
    return 1 / (1 + exp(-z)), self.vout[1], z
end

function M:type_query(k)
    if self.have_u[k] then return end
    local E, FA = self.E, self.FA
    local u = self.u[k]
    local ek = self.ent[k]
    local W, b = self.pw[k], self.pb[k]
    local nout = 2 * E + FA
    local q, H = self.q, self.H
    local ii, vv = nz_i, nz_v
    local nz = 0
    for i = 0, H - 1 do
        local v = q[i]
        if v ~= 0 then
            ii[nz] = i * nout
            vv[nz] = v
            nz = nz + 1
        end
    end
    if ek ~= 0 then
        for o = 0, nout - 1 do u[o] = b[o] end
        accumulate(ii, vv, nz, W, nout, u, 0)
    else
        for o = 0, E - 1 do u[o] = b[o] end
        accumulate(ii, vv, nz, W, E, u, 0)
        local c0 = 2 * E
        for o = c0, nout - 1 do u[o] = b[o] end
        for i = 0, nz - 1 do ii[i] = ii[i] + c0 end
        accumulate(ii, vv, nz, W, FA, u, c0)
    end
    local cs, cemb = self.cs[k], self.cemb
    for i = 0, self.nc - 1 do
        local acc, eo = 0, i * E
        for o = 0, E - 1 do acc = acc + u[o] * cemb[eo + o] end
        cs[i] = acc
    end
    if ek ~= 0 then
        local emb, n = self.iemb, self.ni
        if ek == 2 then emb, n = self.jemb, self.nj end
        local es = self.es[k]
        for i = 0, n - 1 do
            local acc, eo = 0, i * E
            for o = 0, E - 1 do acc = acc + u[E + o] * emb[eo + o] end
            es[i] = acc
        end
    end
    self.have_u[k] = true
end

function M:row_logit(ab, k)
    local E2, FA = 2 * self.E, self.FA
    local t = ab.type[k]
    local u, cs = self.u[t], self.cs[t]
    local acc = 0
    local co = k * 5
    local cards = ab.c
    for i = 0, ab.nc[k] - 1 do acc = acc + cs[cards[co + i]] end
    if self.ent[t] ~= 0 then
        local e = ab.ent[k]
        if e >= 0 then acc = acc + self.es[t][e] end
    end
    local fa, fo = ab.fa, k * FA
    for f = 0, FA - 1 do
        local v = fa[fo + f]
        if v ~= 0 then acc = acc + v * u[E2 + f] end
    end
    return acc
end

function M:policy(ab)
    local E2, FA = 2 * self.E, self.FA
    local types, ncs, cards, fa, logit, ents = ab.type, ab.nc, ab.c, ab.fa, ab.logit, ab.ent
    local n = ab.n
    local have = self.have_u
    for k = 0, n - 1 do
        local t = types[k]
        if not have[t] then self:type_query(t) end
    end
    local us, css, ess, ent = self.u, self.cs, self.es, self.ent
    for k = 0, n - 1 do
        local t = types[k]
        local u, cs = us[t], css[t]
        local acc = 0
        local co = k * 5
        for i = 0, ncs[k] - 1 do acc = acc + cs[cards[co + i]] end
        if ent[t] ~= 0 then
            local e = ents[k]
            if e >= 0 then acc = acc + ess[t][e] end
        end
        local fo = k * FA
        for f = 0, FA - 1 do
            local v = fa[fo + f]
            if v ~= 0 then acc = acc + v * u[E2 + f] end
        end
        logit[k] = acc
    end
    return logit
end

function M:policy_compact(ab)
    local E = 2 * self.E
    local A = ab.A
    local types, ncs, cards, logit = ab.type, ab.nc, ab.c, ab.logit
    local tops, xs, xe, xc, xd, xf = ab.top, ab.xs, ab.xe, ab.xc, ab.xd, ab.xf
    local oN, oH = E + A.n - 1, E + A.hand - 1
    local oS, oE, oC, oD, oF, oB = E + A.n_scoring, E + A.est, E + A.clears, E + A.n_debuff, E + A.n_flipped, E + A.bias
    local n = ab.n
    local have = self.have_u
    for k = 0, n - 1 do
        local t = types[k]
        if not have[t] then self:type_query(t) end
    end
    local us, css = self.u, self.cs
    for k = 0, n - 1 do
        local t = types[k]
        if t > 2 then
            logit[k] = self:row_logit(ab, k)
        else
            local u, cs = us[t], css[t]
            local acc = 0
            local co = k * 5
            local nc = ncs[k]
            for i = 0, nc - 1 do acc = acc + cs[cards[co + i]] end
            acc = acc + u[oN + nc]
            local top = tops[k]
            if top > 0 then
                acc = acc + u[oH + top]
                local v = xs[k]
                if v ~= 0 then acc = acc + v * u[oS] end
                v = xe[k]
                if v ~= 0 then acc = acc + v * u[oE] end
                v = xc[k]
                if v ~= 0 then acc = acc + v * u[oC] end
            end
            local v = xd[k]
            if v ~= 0 then acc = acc + v * u[oD] end
            v = xf[k]
            if v ~= 0 then acc = acc + v * u[oF] end
            logit[k] = acc + u[oB]
        end
    end
    return logit
end

function M.softmax(logit, n, out, temp)
    temp = temp or 1
    local m = -math.huge
    for k = 0, n - 1 do
        if logit[k] > m then m = logit[k] end
    end
    local s = 0
    for k = 0, n - 1 do
        local e = exp((logit[k] - m) / temp)
        out[k] = e
        s = s + e
    end
    for k = 0, n - 1 do out[k] = out[k] / s end
    return out
end

return M
