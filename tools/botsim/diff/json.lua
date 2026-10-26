local J = {}

J.null = setmetatable({}, {__tostring = function() return "null" end})
J.OBJECT = {__jsontype = "object"}
J.ARRAY = {__jsontype = "array"}

function J.object(t) return setmetatable(t or {}, J.OBJECT) end
function J.array(t) return setmetatable(t or {}, J.ARRAY) end
function J.raw(s) return {__raw = s} end

local ESC = {['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t"}

local function enc_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c) return ESC[c] or string.format("\\u%04x", c:byte()) end) .. '"'
end

function J.number(x)
    if x ~= x or x == math.huge or x == -math.huge then return "null" end
    if x == math.floor(x) and math.abs(x) < 2 ^ 53 then return string.format("%d", x) end
    local s = string.format("%.14g", x)
    if tonumber(s) ~= x then s = string.format("%.17g", x) end
    return s
end

local function is_array(t)
    local mt = getmetatable(t)
    if mt == J.ARRAY then return true end
    if mt == J.OBJECT then return false end
    if next(t) == nil then return true end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    for i = 1, n do if t[i] == nil then return false end end
    return true
end

local encode

local function enc_value(v, out)
    local tv = type(v)
    if v == nil or v == J.null then
        out[#out + 1] = "null"
    elseif tv == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif tv == "number" then
        out[#out + 1] = J.number(v)
    elseif tv == "string" then
        out[#out + 1] = enc_string(v)
    elseif tv == "table" then
        if v.__raw then out[#out + 1] = v.__raw return end
        encode(v, out)
    else
        out[#out + 1] = "null"
    end
end

encode = function(t, out)
    if is_array(t) then
        out[#out + 1] = "["
        for i = 1, #t do
            if i > 1 then out[#out + 1] = "," end
            enc_value(t[i], out)
        end
        out[#out + 1] = "]"
        return
    end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    local order = rawget(t, "__order")
    if order then
        local rank = {}
        for i, k in ipairs(order) do rank[k] = i end
        table.sort(keys, function(a, b)
            local ra, rb = rank[a] or 1e9, rank[b] or 1e9
            if ra ~= rb then return ra < rb end
            return a < b
        end)
    else
        table.sort(keys)
    end
    out[#out + 1] = "{"
    local first = true
    for _, k in ipairs(keys) do
        if k ~= "__order" then
            local v = t[k]
            if v == nil then v = t[tonumber(k)] end
            if not first then out[#out + 1] = "," end
            first = false
            out[#out + 1] = enc_string(k)
            out[#out + 1] = ":"
            enc_value(v, out)
        end
    end
    out[#out + 1] = "}"
end

function J.encode(v)
    local out = {}
    enc_value(v, out)
    return table.concat(out)
end

local function utf8_char(c)
    if c < 0x80 then return string.char(c) end
    if c < 0x800 then return string.char(0xC0 + math.floor(c / 64), 0x80 + c % 64) end
    if c < 0x10000 then return string.char(0xE0 + math.floor(c / 4096), 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64) end
    return string.char(0xF0 + math.floor(c / 262144), 0x80 + math.floor(c / 4096) % 64, 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64)
end

local function decode_error(s, i, msg)
    error(string.format("json: %s at position %d near '%s'", msg, i, s:sub(i, i + 10)), 0)
end

local function skip_ws(s, i)
    return s:find("[^ \t\r\n]", i) or #s + 1
end

local decode_value

local function decode_string(s, i)
    local out = {}
    local j = i + 1
    while true do
        local c = s:sub(j, j)
        if c == "" then decode_error(s, i, "unterminated string") end
        if c == '"' then return table.concat(out), j + 1 end
        if c == "\\" then
            local e = s:sub(j + 1, j + 1)
            if e == "u" then
                local hex = s:sub(j + 2, j + 5)
                local code = tonumber(hex, 16)
                if not code or #hex < 4 then decode_error(s, j, "bad unicode escape") end
                j = j + 6
                if code >= 0xD800 and code <= 0xDBFF and s:sub(j, j + 1) == "\\u" then
                    local lo = tonumber(s:sub(j + 2, j + 5), 16)
                    if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                        code = 0x10000 + (code - 0xD800) * 1024 + (lo - 0xDC00)
                        j = j + 6
                    end
                end
                out[#out + 1] = utf8_char(code)
            else
                local map = {b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/"}
                if not map[e] then decode_error(s, j, "bad escape") end
                out[#out + 1] = map[e]
                j = j + 2
            end
        else
            local k = s:find('["\\]', j)
            if not k then decode_error(s, i, "unterminated string") end
            out[#out + 1] = s:sub(j, k - 1)
            j = k
        end
    end
end

decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "{" then
        local t = J.object({})
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == "}" then return t, i + 1 end
        while true do
            i = skip_ws(s, i)
            if s:sub(i, i) ~= '"' then decode_error(s, i, "expected key") end
            local k
            k, i = decode_string(s, i)
            i = skip_ws(s, i)
            if s:sub(i, i) ~= ":" then decode_error(s, i, "expected ':'") end
            local v
            v, i = decode_value(s, i + 1)
            t[k] = v
            i = skip_ws(s, i)
            local d = s:sub(i, i)
            if d == "}" then return t, i + 1 end
            if d ~= "," then decode_error(s, i, "expected ',' or '}'") end
            i = i + 1
        end
    elseif c == "[" then
        local t = J.array({})
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == "]" then return t, i + 1 end
        local n = 0
        while true do
            local v
            v, i = decode_value(s, i)
            n = n + 1
            t[n] = v
            i = skip_ws(s, i)
            local d = s:sub(i, i)
            if d == "]" then return t, i + 1 end
            if d ~= "," then decode_error(s, i, "expected ',' or ']'") end
            i = i + 1
        end
    elseif c == '"' then
        return decode_string(s, i)
    elseif s:sub(i, i + 3) == "true" then
        return true, i + 4
    elseif s:sub(i, i + 4) == "false" then
        return false, i + 5
    elseif s:sub(i, i + 3) == "null" then
        return J.null, i + 4
    else
        local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
        if not num or num == "" or num == "-" then decode_error(s, i, "unexpected character") end
        local v = tonumber(num)
        if not v then decode_error(s, i, "bad number") end
        return v, i + #num
    end
end

function J.decode(s)
    local v, i = decode_value(s, 1)
    i = skip_ws(s, i)
    if i <= #s then decode_error(s, i, "trailing data") end
    return v
end

function J.read_lines(path)
    local f, err = io.open(path, "r")
    if not f then return nil, err end
    local out = {}
    local n = 0
    for line in f:lines() do
        n = n + 1
        if line:find("%S") then
            local ok, v = pcall(J.decode, line)
            if not ok then f:close() return nil, path .. ":" .. n .. ": " .. tostring(v) end
            out[#out + 1] = v
        end
    end
    f:close()
    return out
end

return J
