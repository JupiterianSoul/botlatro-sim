local here = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = here .. "/?.lua;" .. package.path
local J = require("json")

local dir = arg[1] or "."
local p = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
local names = {}
for n in p:lines() do if n:match("%.snap%.jsonl$") then names[#names + 1] = n end end
p:close()
table.sort(names)

local PHASES = {"blind_select", "play", "shop", "pack", "round_eval", "game_over", "win"}
local out = {"### botsim real runs", "", "| run | steps | last phase | max ante | " .. table.concat(PHASES, " | ") .. " | errors |", "| --- | --- | --- | --- |" .. string.rep(" --- |", #PHASES + 1)}
local tot = {runs = 0, steps = 0, ante3 = 0}
local tph = {}
for _, n in ipairs(names) do
    local lines = J.read_lines(dir .. "/" .. n) or {}
    local cnt, max_ante, errs, last = {}, 0, 0, "-"
    for _, l in ipairs(lines) do
        if l.error then errs = errs + 1 end
        if l.phase then
            cnt[l.phase] = (cnt[l.phase] or 0) + 1
            tph[l.phase] = (tph[l.phase] or 0) + 1
            last = l.phase
        end
        if type(l.ante) == "number" and l.ante > max_ante then max_ante = l.ante end
    end
    local row = {n:gsub("%.snap%.jsonl$", ""), #lines - 1, last, max_ante}
    for _, ph in ipairs(PHASES) do row[#row + 1] = cnt[ph] or 0 end
    row[#row + 1] = errs
    for i, v in ipairs(row) do row[i] = tostring(v) end
    out[#out + 1] = "| " .. table.concat(row, " | ") .. " |"
    tot.runs = tot.runs + 1
    tot.steps = tot.steps + math.max(0, #lines - 1)
    if max_ante >= 3 and (cnt.shop or 0) > 0 then tot.ante3 = tot.ante3 + 1 end
end
local ph = {}
for _, k in ipairs(PHASES) do ph[#ph + 1] = k .. "=" .. (tph[k] or 0) end
out[#out + 1] = ""
out[#out + 1] = string.format("runs=%d steps=%d runs_with_shop_and_ante3+=%d phases: %s", tot.runs, tot.steps, tot.ante3, table.concat(ph, " "))
print(table.concat(out, "\n"))
