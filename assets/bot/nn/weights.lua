local BUF = require("bot.nn.buf")

local M = {}

local byte, char, sub = string.byte, string.char, string.sub
local floor, frexp, ldexp, huge = math.floor, math.frexp, math.ldexp, math.huge
local concat = table.concat

M.MAGIC = "BNNW"
M.VERSION = 2

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then ffi = nil end

function M.default_cfg(F, over)
    local cfg = {CF = F.CF, JF = F.JF, IF = F.IF, GF = F.GF, FA = F.FA, E = 32, H = 128, VH = 32, types = table.concat(F.TYPES, ",")}
    for k, v in pairs(over or {}) do cfg[k] = v end
    return cfg
end

local function type_list(cfg)
    local t = {}
    for name in tostring(cfg.types):gmatch("[^,]+") do t[#t + 1] = name end
    return t
end
M.type_list = type_list

function M.shapes(cfg)
    local E, H, VH = cfg.E, cfg.H, cfg.VH
    local s = {
        {"enc.card.w", {cfg.CF, E}}, {"enc.card.b", {E}},
        {"enc.joker.w", {cfg.JF, E}}, {"enc.joker.b", {E}},
        {"enc.item.w", {cfg.IF, E}}, {"enc.item.b", {E}},
        {"trunk.0.w", {cfg.GF + 6 * E, H}}, {"trunk.0.b", {H}},
        {"trunk.1.w", {H, H}}, {"trunk.1.b", {H}},
        {"value.0.w", {H, VH}}, {"value.0.b", {VH}},
        {"value.1.w", {VH, 2}}, {"value.1.b", {2}},
    }
    for _, t in ipairs(type_list(cfg)) do
        s[#s + 1] = {"pol." .. t .. ".w", {H, 2 * E + cfg.FA}}
        s[#s + 1] = {"pol." .. t .. ".b", {2 * E + cfg.FA}}
    end
    return s
end

local function numel(dims)
    local n = 1
    for i = 1, #dims do n = n * dims[i] end
    return n
end
M.numel = numel

function M.count(cfg)
    local n = 0
    for _, sh in ipairs(M.shapes(cfg)) do n = n + numel(sh[2]) end
    return n
end

function M.rng(seed)
    local x = floor(seed or 1) % 2147483646 + 1
    return function()
        x = (x * 48271) % 2147483647
        return x / 2147483647
    end
end

function M.random(cfg, seed, scale)
    local r = M.rng(seed or 1)
    local W = {cfg = cfg, t = {}, order = {}}
    for _, sh in ipairs(M.shapes(cfg)) do
        local name, dims = sh[1], sh[2]
        local n = numel(dims)
        local a = BUF.alloc(n)
        local fan_in = #dims == 2 and dims[1] or 1
        local sc = (scale or 1) * math.sqrt(2 / fan_in)
        if #dims == 1 then sc = (scale or 1) * 0.05 end
        for i = 0, n - 1 do a[i] = (r() * 2 - 1) * sc * 1.7320508 end
        W.t[name] = {dims = dims, data = a, n = n}
        W.order[#W.order + 1] = name
    end
    return W
end

local function u32(v)
    return char(v % 256, floor(v / 256) % 256, floor(v / 65536) % 256, floor(v / 16777216) % 256)
end

local function read_u32(str, pos)
    local a, b, c, d = byte(str, pos, pos + 3)
    return a + b * 256 + c * 65536 + d * 16777216, pos + 4
end

local function f32_bytes(v)
    if v ~= v then return char(0, 0, 192, 127) end
    local sign = 0
    if v < 0 or (v == 0 and 1 / v < 0) then sign = 128; v = -v end
    if v == huge then return char(0, 0, 128, 127 + sign) end
    if v == 0 then return char(0, 0, 0, sign) end
    local m, e = frexp(v)
    local exp = e + 126
    local mant
    if exp <= 0 then
        mant = floor(ldexp(m, 23 + exp) + 0.5)
        exp = 0
    else
        mant = floor((m * 2 - 1) * 8388608 + 0.5)
        if mant >= 8388608 then
            mant = 0
            exp = exp + 1
        end
        if exp >= 255 then return char(0, 0, 128, 127 + sign) end
    end
    return char(mant % 256, floor(mant / 256) % 256, (exp % 2) * 128 + floor(mant / 65536), sign + floor(exp / 2))
end
M.f32_bytes = f32_bytes

local function f32_decode(a, b, c, d)
    local sign = d >= 128 and -1 or 1
    local exp = (d % 128) * 2 + floor(c / 128)
    local mant = (c % 128) * 65536 + b * 256 + a
    if exp == 0 then
        if mant == 0 then return sign * 0 end
        return sign * ldexp(mant, -149)
    elseif exp == 255 then
        if mant == 0 then return sign * huge end
        return 0 / 0
    end
    return sign * ldexp(mant + 8388608, exp - 150)
end
M.f32_decode = f32_decode

function M.pack_floats(arr, off, n)
    off = off or 0
    if ffi and BUF.use_ffi then
        local f = ffi.new("float[?]", n)
        for i = 0, n - 1 do f[i] = arr[off + i] end
        return ffi.string(f, 4 * n)
    end
    local out = {}
    for i = 0, n - 1 do out[i + 1] = f32_bytes(arr[off + i]) end
    return concat(out)
end

function M.unpack_floats(str, pos, n, dst, doff)
    doff = doff or 0
    if ffi and BUF.use_ffi then
        local f = ffi.new("float[?]", n)
        ffi.copy(f, sub(str, pos, pos + 4 * n - 1), 4 * n)
        for i = 0, n - 1 do dst[doff + i] = f[i] end
    else
        for i = 0, n - 1 do
            local p = pos + 4 * i
            dst[doff + i] = f32_decode(byte(str, p, p + 3))
        end
    end
    return pos + 4 * n
end

local function cfg_string(cfg)
    local keys = {}
    for k in pairs(cfg) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(cfg[k]) end
    return concat(parts, ";")
end

local function parse_cfg(str)
    local cfg = {}
    for k, v in str:gmatch("([^=;]+)=([^;]*)") do cfg[k] = tonumber(v) or v end
    return cfg
end

function M.encode(W)
    local cs = cfg_string(W.cfg)
    local out = {M.MAGIC, u32(M.VERSION), u32(#cs), cs, u32(#W.order)}
    for _, name in ipairs(W.order) do
        local t = W.t[name]
        out[#out + 1] = char(#name) .. name .. char(#t.dims)
        for _, d in ipairs(t.dims) do out[#out + 1] = u32(d) end
    end
    for _, name in ipairs(W.order) do
        local t = W.t[name]
        out[#out + 1] = M.pack_floats(t.data, 0, t.n)
    end
    return concat(out)
end

function M.decode(str)
    assert(sub(str, 1, 4) == M.MAGIC, "bad weight magic")
    local pos = 5
    local ver, clen, nt
    ver, pos = read_u32(str, pos)
    assert(ver == M.VERSION, "unsupported weight version " .. ver)
    clen, pos = read_u32(str, pos)
    local cfg = parse_cfg(sub(str, pos, pos + clen - 1))
    pos = pos + clen
    nt, pos = read_u32(str, pos)
    local W = {cfg = cfg, t = {}, order = {}}
    for _ = 1, nt do
        local ln = byte(str, pos)
        local name = sub(str, pos + 1, pos + ln)
        pos = pos + 1 + ln
        local nd = byte(str, pos)
        pos = pos + 1
        local dims = {}
        for d = 1, nd do dims[d], pos = read_u32(str, pos) end
        W.t[name] = {dims = dims, n = numel(dims)}
        W.order[#W.order + 1] = name
    end
    for _, name in ipairs(W.order) do
        local t = W.t[name]
        t.data = BUF.alloc(t.n)
        pos = M.unpack_floats(str, pos, t.n, t.data, 0)
    end
    for _, sh in ipairs(M.shapes(cfg)) do
        local t = W.t[sh[1]]
        assert(t, "missing tensor " .. sh[1])
        assert(t.n == numel(sh[2]), "bad shape for " .. sh[1])
    end
    return W
end

function M.read_file(path)
    local lv = rawget(_G, "love")
    if lv and lv.filesystem and lv.filesystem.read then
        local data = lv.filesystem.read(path)
        if data then return data end
    end
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    return data
end

function M.load(path)
    return M.decode(M.read_file(path))
end

function M.save(path, W)
    local f = assert(io.open(path, "wb"))
    f:write(M.encode(W))
    f:close()
end

M.u32 = u32
M.read_u32 = read_u32

return M
