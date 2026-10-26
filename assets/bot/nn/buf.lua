local M = {}

local ok_ffi, ffi = pcall(require, "ffi")
M.has_ffi = ok_ffi and ffi ~= nil
M.use_ffi = M.has_ffi

local function alloc_table(n)
    local t = {}
    for i = 0, n - 1 do t[i] = 0 end
    return t
end

function M.alloc(n, plain)
    if n < 1 then n = 1 end
    if M.use_ffi and not plain then return ffi.new("double[?]", n) end
    return alloc_table(n)
end

function M.alloc_int(n, plain)
    if n < 1 then n = 1 end
    if M.use_ffi and not plain then return ffi.new("int32_t[?]", n) end
    return alloc_table(n)
end

function M.fill(a, n, v)
    v = v or 0
    for i = 0, n - 1 do a[i] = v end
end

function M.set_ffi(on)
    M.use_ffi = on and M.has_ffi or false
end

return M
