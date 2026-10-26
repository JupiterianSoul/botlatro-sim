local src = assert(io.open("assets/game.lua")):read("*a")

local function grab(name)
    local s = src:find("self%." .. name .. " = self%." .. name .. " or {")
    assert(s, name)
    local b = src:find("{", s, true)
    local depth, i = 0, b
    while true do
        local c = src:sub(i, i)
        if c == "{" then depth = depth + 1 elseif c == "}" then depth = depth - 1 if depth == 0 then break end end
        i = i + 1
    end
    local stubT = setmetatable({}, {__index = function() return {} end})
    local env = setmetatable({self = stubT, G = setmetatable({}, {__index = function() return {} end}), localize = function(x) return x end}, {__index = _G})
    local f = assert(loadstring("return " .. src:sub(b, i)))
    setfenv(f, env)
    return f()
end

local centers = grab("P_CENTERS")
local tags = grab("P_TAGS")

local function ser(v, ind)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
        local ks = type(k) == "number" and ("[" .. k .. "]") or (k:match("^[%a_][%w_]*$") and k or string.format("[%q]", k))
        parts[#parts + 1] = ks .. " = " .. ser(v[k])
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local sets = {Tarot = {}, Planet = {}, Spectral = {}, Voucher = {}, Booster = {}, Enhanced = {}}
for k, v in pairs(centers) do
    if sets[v.set] and not v.wip then
        local e = {key = k, name = v.name, order = v.order, cost = v.cost, config = v.config, set = v.set}
        if v.set == "Booster" then e.weight = v.weight or 1 e.kind = v.kind end
        if v.set == "Voucher" then e.requires = v.requires end
        if v.effect then e.effect = v.effect end
        sets[v.set][#sets[v.set] + 1] = e
    end
end
local tlist = {}
for k, v in pairs(tags) do
    tlist[#tlist + 1] = {key = k, name = v.name, order = v.order, min_ante = v.min_ante, requires = v.requires, config = v.config}
end
local out = {"return {"}
for _, name in ipairs({"Tarot", "Planet", "Spectral", "Voucher", "Booster", "Enhanced"}) do
    local l = sets[name]
    table.sort(l, function(a, b) return a.order < b.order end)
    out[#out + 1] = "    " .. name .. " = {"
    for _, e in ipairs(l) do out[#out + 1] = "        " .. ser(e) .. "," end
    out[#out + 1] = "    },"
end
table.sort(tlist, function(a, b) return a.order < b.order end)
out[#out + 1] = "    Tag = {"
for _, e in ipairs(tlist) do out[#out + 1] = "        " .. ser(e) .. "," end
out[#out + 1] = "    },"
out[#out + 1] = "}"
local f = assert(io.open("assets/bot/sim/data_centers.lua", "w"))
f:write(table.concat(out, "\n"), "\n")
f:close()
