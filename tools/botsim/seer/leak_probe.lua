package.path = "assets/?.lua;tools/?.lua;" .. package.path

local kind = table.remove(arg, 1)
local script = table.remove(arg, 1)

local E = require("bot.sim.engine")
local ST = require("bot.sim.state")
local FE = require("bot.nn.features")
local F = require("bot.seer.fair")
local LK = require("botsim.seer.leaks")

local function is_real(s)
    local x = tostring(s.seed)
    return x:find("^BENCH") or x:find("^OTHER") or x:find("^FAIR[LR]")
end

local REAL
local san0, world0 = F.sanitize, F.world

local scope, name = kind:match("^(%w+):(.+)$")
scope, name = scope or "none", name or kind

F.sanitize = function(x)
    if is_real(x) then REAL = x end
    local b = san0(x)
    if scope == "view" and REAL and is_real(x) then LK.sanitize[name](b, x) end
    return b
end

F.world = function(base, key)
    local w = world0(base, key)
    if REAL then
        if scope == "world" then LK.world[name](w, REAL, base) end
        if scope == "ro" and key:find("^RO") then LK.world[name](w, REAL, base) end
        if scope == "search" and key:find("^FW") then LK.world[name](w, REAL, base) end
    end
    return w
end

local PEEK = {
    boss = function(c) return E.get_new_boss(c) end,
    tag = function(c) return E.get_next_tag(c) end,
    voucher = function(c) return E.get_next_voucher(c) end,
    shop = function(c)
        E.I.enter_shop(c)
        return c.sj_id[1] or 0
    end,
    deck = function(c) return c.deck[c.n_deck] or 0 end,
}

if scope == "peek" then
    local state0 = FE.state
    local cache_key, cache_val
    FE.state = function(s, buf)
        local r = state0(s, buf)
        if REAL then
            local key = tostring(REAL.seed) .. ":" .. REAL.step
            if key ~= cache_key then
                cache_key = key
                local ok, v = pcall(PEEK[name], ST.clone(REAL))
                cache_val = ok and (v % 2) or 0
            end
            local g = buf.g or buf
            g[FE.G.money] = g[FE.G.money] + 0.15 * cache_val
        end
        return r
    end
end

print("leak probe: " .. kind .. " on " .. script)
io.stdout:flush()
arg[0] = script
dofile(script)
