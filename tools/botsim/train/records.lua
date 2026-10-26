local FE = require("bot.nn.features")
local WT = require("bot.nn.weights")
local BUF = require("bot.nn.buf")

local M = {}

local char, byte, sub, floor = string.char, string.byte, string.sub, math.floor
local concat = table.concat
local u32, read_u32 = WT.u32, WT.read_u32

M.MAGIC = "BSPR"
M.VERSION = 2

local function u16(v)
    return char(v % 256, floor(v / 256) % 256)
end

local function read_u16(str, pos)
    local a, b = byte(str, pos, pos + 1)
    return a + b * 256, pos + 2
end

local tmpv = BUF.alloc(4096)

local function sparse(arr, off, n, out)
    local idx, nnz = {}, 0
    for i = 0, n - 1 do
        local v = arr[off + i]
        if v ~= 0 then
            idx[nnz + 1] = u16(i)
            tmpv[nnz] = v
            nnz = nnz + 1
        end
    end
    out[#out + 1] = u16(nnz)
    out[#out + 1] = concat(idx)
    if nnz > 0 then out[#out + 1] = WT.pack_floats(tmpv, 0, nnz) end
end
M.sparse = sparse

function M.file_header()
    local types = concat(FE.TYPES, ",")
    return concat({M.MAGIC, u32(M.VERSION), u32(FE.GF), u32(FE.CF), u32(FE.JF), u32(FE.IF), u32(FE.FA), u32(FE.MAXSEL),
        u16(#types), types})
end

local function state_part(F, na, chosen, root_q, net_v, n_sims, phase, out)
    out[#out + 1] = char(F.nc, F.nj, F.ni, phase or 0)
    out[#out + 1] = u16(na) .. u16(chosen)
    out[#out + 1] = WT.pack_floats({[0] = root_q or 0, net_v or 0}, 0, 2)
    out[#out + 1] = u32(n_sims or 0)
    sparse(F.g, 0, FE.GF, out)
    for i = 0, F.nc - 1 do sparse(F.c, i * FE.CF, FE.CF, out) end
    for k = 0, F.nj - 1 do sparse(F.j, k * FE.JF, FE.JF, out) end
    for k = 0, F.ni - 1 do sparse(F.i, k * FE.IF, FE.IF, out) end
end

local function action_part(t, nc, c, co, ent, visits, prior, fa, fo, out)
    local cs = {}
    for i = 0, FE.MAXSEL - 1 do
        local v = i < nc and c[co + i] or -1
        cs[i + 1] = v >= 0 and v or 255
    end
    out[#out + 1] = char(t, nc, cs[1], cs[2], cs[3], cs[4], cs[5], ent >= 0 and ent or 255)
    out[#out + 1] = u32(visits)
    out[#out + 1] = WT.pack_floats({[0] = prior}, 0, 1)
    sparse(fa, fo, FE.FA, out)
end

function M.encode_record(F, mc, chosen, n_sims, phase)
    local out = {}
    local ef, ec = mc:root_edges()
    state_part(F, ec, chosen - ef, mc:root_q(), mc.n_val[mc.root], n_sims, phase, out)
    for j = 0, ec - 1 do
        local e = ef + j
        local t = mc.e_type[e]
        action_part(t, mc.e_nc[e], mc.e_c, e * FE.MAXSEL, t > 2 and FE.edge_ent(F, t, mc.e_arg[e]) or -1,
            mc.e_N[e], mc.e_prior[e], mc.root_fa, j * FE.FA, out)
    end
    return concat(out)
end

function M.encode_choice(F, AB, picks, opts)
    opts = opts or {}
    local out = {}
    local chosen = opts.chosen or 1
    state_part(F, #picks, chosen - 1, opts.root_q, opts.net_v, opts.n_sims, opts.phase, out)
    local row = BUF.alloc(FE.FA)
    for _, p in ipairs(picks) do
        local k = p.k
        FE.fill_fa(AB, k, row, 0)
        local t = AB.type[k]
        action_part(t, AB.nc[k], AB.c, k * FE.MAXSEL, t > 2 and AB.ent[k] or -1, p.visits or 0, p.prior or 0, row, 0, out)
    end
    return concat(out)
end

function M.encode_run(recs, won, final_ante, deck_idx, stake, run_index)
    return concat({"RUN2", u32(#recs), char(won, final_ante, deck_idx, stake), u32(run_index), concat(recs)})
end

local function read_sparse(str, pos, dst, off, n)
    for i = 0, n - 1 do dst[off + i] = 0 end
    local nnz
    nnz, pos = read_u16(str, pos)
    local idx = {}
    for i = 1, nnz do idx[i], pos = read_u16(str, pos) end
    for i = 1, nnz do
        dst[off + idx[i]] = WT.f32_decode(byte(str, pos, pos + 3))
        pos = pos + 4
    end
    return pos
end

function M.decode(str)
    assert(sub(str, 1, 4) == M.MAGIC, "bad record magic")
    local pos = 5
    local hdr = {}
    for i = 1, 7 do hdr[i], pos = read_u32(str, pos) end
    assert(hdr[1] == M.VERSION, "unsupported record version " .. hdr[1])
    local GF, CF, JF, IF, FA, MS = hdr[2], hdr[3], hdr[4], hdr[5], hdr[6], hdr[7]
    local tl
    tl, pos = read_u16(str, pos)
    local types = sub(str, pos, pos + tl - 1)
    pos = pos + tl
    local runs = {}
    while pos <= #str do
        assert(sub(str, pos, pos + 3) == "RUN2", "bad run magic")
        pos = pos + 4
        local run = {recs = {}}
        local nrec
        nrec, pos = read_u32(str, pos)
        run.won, run.final_ante, run.deck_idx, run.stake = byte(str, pos, pos + 3)
        pos = pos + 4
        run.index, pos = read_u32(str, pos)
        for _ = 1, nrec do
            local r = {}
            r.nc, r.nj, r.ni, r.phase = byte(str, pos, pos + 3)
            pos = pos + 4
            r.na, pos = read_u16(str, pos)
            r.chosen, pos = read_u16(str, pos)
            r.root_q = WT.f32_decode(byte(str, pos, pos + 3))
            r.net_v = WT.f32_decode(byte(str, pos + 4, pos + 7))
            pos = pos + 8
            r.n_sims, pos = read_u32(str, pos)
            r.g = {}
            pos = read_sparse(str, pos, r.g, 0, GF)
            r.c = {}
            for i = 0, r.nc - 1 do pos = read_sparse(str, pos, r.c, i * CF, CF) end
            r.j = {}
            for k = 0, r.nj - 1 do pos = read_sparse(str, pos, r.j, k * JF, JF) end
            r.i = {}
            for k = 0, r.ni - 1 do pos = read_sparse(str, pos, r.i, k * IF, IF) end
            r.acts = {}
            for _ = 1, r.na do
                local a = {}
                a.type, a.nc = byte(str, pos, pos + 1)
                a.c = {byte(str, pos + 2, pos + 1 + MS)}
                a.ent = byte(str, pos + 2 + MS)
                if a.ent == 255 then a.ent = -1 end
                pos = pos + 8
                a.visits, pos = read_u32(str, pos)
                a.prior = WT.f32_decode(byte(str, pos, pos + 3))
                pos = pos + 4
                a.fa = {}
                pos = read_sparse(str, pos, a.fa, 0, FA)
                r.acts[#r.acts + 1] = a
            end
            run.recs[#run.recs + 1] = r
        end
        runs[#runs + 1] = run
    end
    return {GF = GF, CF = CF, JF = JF, IF = IF, FA = FA, MS = MS, types = types, runs = runs}
end

return M
