local M = {}

local byte = string.byte
local format = string.format
local tonumber = tonumber
local abs = math.abs
local pi = math.pi
local mrandom = math.random
local mrandomseed = math.randomseed

local ok_ffi, ffi = pcall(require, "ffi")
local use_port = ok_ffi and jit and jit.status and jit.status() and true or false
if use_port then
    local bit = require("bit")
    local band, bor, bxor, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift
    local mfloor = math.floor
    local cv = ffi.new("union { double d; uint64_t u; }")
    local G = ffi.new("uint64_t[4]")
    local M0, M1, M2, M3 = lshift(-1ULL, 1), lshift(-1ULL, 6), lshift(-1ULL, 9), lshift(-1ULL, 17)
    local MANT, ONE = 0x000fffffffffffffULL, 0x3ff0000000000000ULL
    local function step()
        local z = G[0]
        z = bxor(rshift(bxor(lshift(z, 31), z), 45), lshift(band(z, M0), 18))
        local r = z
        G[0] = z
        z = G[1]
        z = bxor(rshift(bxor(lshift(z, 19), z), 30), lshift(band(z, M1), 28))
        r = bxor(r, z)
        G[1] = z
        z = G[2]
        z = bxor(rshift(bxor(lshift(z, 24), z), 48), lshift(band(z, M2), 7))
        r = bxor(r, z)
        G[2] = z
        z = G[3]
        z = bxor(rshift(bxor(lshift(z, 21), z), 39), lshift(band(z, M3), 8))
        r = bxor(r, z)
        G[3] = z
        return bor(band(r, MANT), ONE)
    end
    mrandomseed = function(d)
        d = d * 3.14159265358979323846 + 2.7182818284590452354
        cv.d = d
        local u = cv.u
        if u < 2ULL then u = u + 2ULL end
        G[0] = u
        d = d * 3.14159265358979323846 + 2.7182818284590452354
        cv.d = d
        u = cv.u
        if u < 64ULL then u = u + 64ULL end
        G[1] = u
        d = d * 3.14159265358979323846 + 2.7182818284590452354
        cv.d = d
        u = cv.u
        if u < 512ULL then u = u + 512ULL end
        G[2] = u
        d = d * 3.14159265358979323846 + 2.7182818284590452354
        cv.d = d
        u = cv.u
        if u < 131072ULL then u = u + 131072ULL end
        G[3] = u
        for _ = 1, 10 do step() end
    end
    mrandom = function(m, n)
        cv.u = step()
        local d = cv.d - 1.0
        if not m then return d end
        if not n then return mfloor(d * m) + 1 end
        return mfloor(d * (n - m + 1.0)) + m
    end
end
M.port = use_port
M.seed_raw, M.random_raw = mrandomseed, mrandom

local floor = math.floor

local function round13(x)
    local p = x * 1e13
    local fl = floor(p)
    local f = p - fl
    if f > 0.49 and f < 0.51 then return abs(tonumber(format("%.13f", x))) end
    if f >= 0.5 then fl = fl + 1 end
    return fl / 1e13
end
M.round13 = round13

local function pseudohash(str)
    local num = 1
    for i = #str, 1, -1 do
        num = ((1.1239285023 / num) * byte(str, i) * pi + pi * i) % 1
    end
    return num
end
M.pseudohash = pseudohash

local key_ids = {}
local key_names = {}
M.key_names = key_names

local function key_id(key)
    local id = key_ids[key]
    if not id then
        id = #key_names + 1
        key_names[id] = key
        key_ids[key] = id
    end
    return id
end
M.key_id = key_id

local hash_caches = {}

function M.seed_cache(seed)
    local c = hash_caches[seed]
    if not c then
        c = {}
        hash_caches[seed] = c
    end
    return c
end

local function seed_by_id(s, id)
    local rng = s.rng
    local v = rng[id]
    if v == nil then
        local n = s.n_rk + 1
        s.n_rk = n
        s.rng_ids[n] = id
    end
    if v == nil or v < 0 then
        local hc = s.hcache
        v = hc[id]
        if not v then
            v = pseudohash(key_names[id] .. s.seed)
            hc[id] = v
        end
    end
    v = round13((2.134453429141 + v * 1.72431234) % 1)
    rng[id] = v
    return (v + s.hashed_seed) / 2
end
M.seed_by_id = seed_by_id

function M.pseudoseed(s, key)
    return seed_by_id(s, key_id(key))
end

function M.predict_seed(key, predict_seed)
    local p = pseudohash(key .. predict_seed)
    p = abs(tonumber(format("%.13f", (2.134453429141 + p * 1.72431234) % 1)))
    return (p + pseudohash(predict_seed)) / 2
end

function M.random_id(s, id)
    mrandomseed(seed_by_id(s, id))
    return mrandom()
end

function M.random_int_id(s, id, lo, hi)
    mrandomseed(seed_by_id(s, id))
    return mrandom(lo, hi)
end

function M.random(s, key)
    mrandomseed(seed_by_id(s, key_id(key)))
    return mrandom()
end

function M.random_int(s, key, lo, hi)
    mrandomseed(seed_by_id(s, key_id(key)))
    return mrandom(lo, hi)
end

function M.element_index_id(s, id, n)
    mrandomseed(seed_by_id(s, id))
    return mrandom(n)
end

function M.element_index(s, key, n)
    mrandomseed(seed_by_id(s, key_id(key)))
    return mrandom(n)
end

function M.shuffle_id(s, id, list, n)
    mrandomseed(seed_by_id(s, id))
    for i = n, 2, -1 do
        local j = mrandom(i)
        list[i], list[j] = list[j], list[i]
    end
end

local ante_keys = {}

function M.ante_key(prefix, ante)
    local t = ante_keys[prefix]
    if not t then
        t = {}
        ante_keys[prefix] = t
    end
    local id = t[ante]
    if not id then
        id = key_id(prefix .. ante)
        t[ante] = id
    end
    return id
end

return M
