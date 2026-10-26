local env = setmetatable({G = {}}, {__index = _G})
local f = assert(loadfile("assets/challenges.lua"))
setfenv(f, env)
f()
local function ser(v)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t ~= "table" then return tostring(v) end
    local parts = {}
    local n = #v
    for i = 1, n do parts[#parts + 1] = ser(v[i]) end
    local keys = {}
    for k in pairs(v) do if not (type(k) == "number" and k >= 1 and k <= n) then keys[#keys + 1] = k end end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        local ks = type(k) == "number" and ("[" .. k .. "]") or (k:match("^[%a_][%w_]*$") and k or string.format("[%q]", k))
        parts[#parts + 1] = ks .. " = " .. ser(v[k])
    end
    local one = "{" .. table.concat(parts, ", ") .. "}"
    if #one <= 120 then return one end
    return "{\n" .. table.concat(parts, ",\n") .. "\n}"
end
local out = {"return {"}
for _, c in ipairs(env.G.CHALLENGES) do
    local t = {rules = c.rules, jokers = c.jokers, consumeables = c.consumeables, vouchers = c.vouchers,
        deck = c.deck, restrictions = c.restrictions}
    out[#out + 1] = "    [" .. string.format("%q", c.id) .. "] = " .. ser(t) .. ","
end
out[#out + 1] = "}"
local o = assert(io.open("assets/bot/sim/data_challenges.lua", "w"))
o:write(table.concat(out, "\n"), "\n")
o:close()
