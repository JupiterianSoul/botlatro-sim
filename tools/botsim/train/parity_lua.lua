package.path = "assets/?.lua;tools/?.lua;" .. package.path

local FE = require("bot.nn.features")
local WT = require("bot.nn.weights")
local NET = require("bot.nn.net")
local BUF = require("bot.nn.buf")
local REC = require("botsim.train.records")

local wpath, rpath, opath, mode = arg[1], arg[2], arg[3], arg[4] or "ffi"
BUF.set_ffi(mode == "ffi")
local W = WT.load(wpath)
local net = NET.new(W)
local f = assert(io.open(rpath, "rb"))
local data = REC.decode(f:read("*a"))
f:close()
local F = FE.new_state_buf()
local AB = FE.new_action_buf(1024)
local out = assert(io.open(opath, "w"))
local MS = FE.MAXSEL
for _, run in ipairs(data.runs) do
    for _, r in ipairs(run.recs) do
        for i = 0, FE.GF - 1 do F.g[i] = r.g[i] end
        for i = 0, r.nc * FE.CF - 1 do F.c[i] = r.c[i] end
        for i = 0, r.nj * FE.JF - 1 do F.j[i] = r.j[i] end
        for i = 0, r.ni * FE.IF - 1 do F.i[i] = r.i[i] end
        F.nc, F.nj, F.ni = r.nc, r.nj, r.ni
        local _, ante, z = net:forward(F)
        AB.n = #r.acts
        for k, a in ipairs(r.acts) do
            local i0 = k - 1
            AB.type[i0] = a.type
            AB.nc[i0] = a.nc
            AB.ent[i0] = a.ent
            for i = 1, MS do AB.c[i0 * MS + i - 1] = i <= a.nc and a.c[i] or -1 end
            for q = 0, FE.FA - 1 do AB.fa[i0 * FE.FA + q] = a.fa[q] end
        end
        net:policy(AB)
        local parts = {string.format("%.17g", z), string.format("%.17g", ante)}
        for k = 0, AB.n - 1 do parts[#parts + 1] = string.format("%.17g", AB.logit[k]) end
        out:write(table.concat(parts, " "), "\n")
    end
end
out:close()
