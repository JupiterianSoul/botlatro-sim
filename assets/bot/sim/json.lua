local M = {}

local format, byte, sub, char = string.format, string.byte, string.sub, string.char
local concat = table.concat

local ARRAY_MT = {__jsontype = "array"}
local OBJECT_MT = {__jsontype = "object"}

function M.array(t) return setmetatable(t or {}, ARRAY_MT) end
function M.object(t) return setmetatable(t or {}, OBJECT_MT) end
M.null = setmetatable({}, {__jsontype = "null"})

local escapes = {['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t"}

local function enc_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return escapes[c] or format("\\u%04x", byte(c))
    end) .. '"'
end

local function enc_number(n)
    if n ~= n or n == math.huge or n == -math.huge then return "null" end
    if n == math.floor(n) and math.abs(n) < 1e15 then return format("%d", n) end
    return format("%.17g", n)
end

local encode

local function is_array(t)
    local mt = getmetatable(t)
    if mt == ARRAY_MT then return true end
    if mt == OBJECT_MT then return false end
    local n = #t
    if n == 0 then return next(t) == nil end
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then return false end
    end
    return true
end

encode = function(v, out)
    local t = type(v)
    if v == nil or v == M.null then out[#out + 1] = "null"
    elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
    elseif t == "number" then out[#out + 1] = enc_number(v)
    elseif t == "string" then out[#out + 1] = enc_string(v)
    elseif t == "table" then
        if v.__raw then
            out[#out + 1] = v.__raw
        elseif is_array(v) then
            out[#out + 1] = "["
            for i = 1, #v do
                if i > 1 then out[#out + 1] = "," end
                encode(v[i], out)
            end
            out[#out + 1] = "]"
        else
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            out[#out + 1] = "{"
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                out[#out + 1] = enc_string(k)
                out[#out + 1] = ":"
                local val = v[k]
                if val == nil then val = v[tonumber(k)] end
                encode(val, out)
            end
            out[#out + 1] = "}"
        end
    else
        error("cannot encode " .. t)
    end
end

function M.encode(v)
    local out = {}
    encode(v, out)
    return concat(out)
end

function M.raw(s) return {__raw = s} end

local function skip(str, i)
    while true do
        local c = byte(str, i)
        if c == 32 or c == 9 or c == 10 or c == 13 then i = i + 1 else return i end
    end
end

local decode_value

local function decode_string(str, i)
    local out = {}
    i = i + 1
    while true do
        local c = sub(str, i, i)
        if c == "" then error("unterminated string") end
        if c == '"' then return concat(out), i + 1 end
        if c == "\\" then
            local e = sub(str, i + 1, i + 1)
            if e == "u" then
                local cp = tonumber(sub(str, i + 2, i + 5), 16)
                if cp < 128 then out[#out + 1] = char(cp)
                elseif cp < 2048 then out[#out + 1] = char(192 + math.floor(cp / 64), 128 + cp % 64)
                else out[#out + 1] = char(224 + math.floor(cp / 4096), 128 + math.floor(cp / 64) % 64, 128 + cp % 64) end
                i = i + 6
            else
                local map = {b = "\b", f = "\f", n = "\n", r = "\r", t = "\t"}
                out[#out + 1] = map[e] or e
                i = i + 2
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
end

decode_value = function(str, i)
    i = skip(str, i)
    local c = sub(str, i, i)
    if c == "{" then
        local obj = {}
        i = skip(str, i + 1)
        if sub(str, i, i) == "}" then return obj, i + 1 end
        while true do
            local k
            k, i = decode_string(str, skip(str, i))
            i = skip(str, i)
            if sub(str, i, i) ~= ":" then error("expected : at " .. i) end
            local v
            v, i = decode_value(str, i + 1)
            obj[k] = v
            i = skip(str, i)
            local d = sub(str, i, i)
            if d == "}" then return obj, i + 1 end
            if d ~= "," then error("expected , at " .. i) end
            i = i + 1
        end
    elseif c == "[" then
        local arr = {}
        i = skip(str, i + 1)
        if sub(str, i, i) == "]" then return M.array(arr), i + 1 end
        while true do
            local v
            v, i = decode_value(str, i)
            arr[#arr + 1] = v
            i = skip(str, i)
            local d = sub(str, i, i)
            if d == "]" then return M.array(arr), i + 1 end
            if d ~= "," then error("expected , at " .. i) end
            i = i + 1
        end
    elseif c == '"' then
        return decode_string(str, i)
    elseif sub(str, i, i + 3) == "true" then return true, i + 4
    elseif sub(str, i, i + 4) == "false" then return false, i + 5
    elseif sub(str, i, i + 3) == "null" then return nil, i + 4
    else
        local num = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
        if not num or num == "" then error("bad json at " .. i) end
        return tonumber(num), i + #num
    end
end

function M.decode(str)
    local v = decode_value(str, 1)
    return v
end

return M
