local here = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = here .. "/?.lua;" .. package.path
local J = require("json")

local C = {}

local STRICT_MAPS = {rng = true, levels = true, ab = true}
local SHOW = 160

local function short(v)
    local s = type(v) == "string" and v or J.encode(v)
    if #s > SHOW then s = s:sub(1, SHOW) .. "..." end
    return s
end

local function is_array(v)
    return type(v) == "table" and v ~= J.null and getmetatable(v) == J.ARRAY
end

local function is_object(v)
    return type(v) == "table" and v ~= J.null and not is_array(v)
end

local function last_key(npath)
    return npath:match("([%w_]+)$") or npath
end

local function collect_paths(v, npath, out)
    if is_object(v) then
        for k, sub in pairs(v) do
            local p = npath == "" and k or (npath .. "." .. k)
            out[p] = true
            collect_paths(sub, p, out)
        end
    elseif is_array(v) then
        for _, sub in ipairs(v) do collect_paths(sub, npath .. "[]", out) end
    end
end

local function chips_equal(a, b)
    if a == b then return true end
    local fa, fb = math.floor(a), math.floor(b)
    if fa == fb then return true end
    local m = math.max(math.abs(fa), math.abs(fb))
    return m > 1e15 and math.abs(fa - fb) <= m * 1e-12
end

local function scalar_array(v)
    for _, x in ipairs(v) do
        if is_object(x) or is_array(x) then return false end
    end
    return true
end

local function compare_value(a, b, path, npath, ctx)
    if is_object(a) and is_object(b) then
        local keys = {}
        for k in pairs(a) do keys[#keys + 1] = k end
        for k in pairs(b) do if a[k] == nil then keys[#keys + 1] = k end end
        table.sort(keys)
        local strict = STRICT_MAPS[last_key(npath)] and npath ~= ""
        for _, k in ipairs(keys) do
            local p = path == "" and k or (path .. "." .. k)
            local np = npath == "" and k or (npath .. "." .. k)
            local va, vb = a[k], b[k]
            if va ~= nil and vb ~= nil then
                compare_value(va, vb, p, np, ctx)
            else
                local side = va ~= nil and "real" or "sim"
                local other_paths = side == "real" and ctx.sim_paths or ctx.real_paths
                if strict or other_paths[np] then
                    ctx.diffs[#ctx.diffs + 1] = {path = p, real = va, sim = vb, missing = true}
                else
                    local c = ctx.cover[np] or {real = 0, sim = 0}
                    ctx.cover[np] = c
                    c[side] = c[side] + 1
                end
            end
        end
        return
    end
    if is_array(a) and is_array(b) then
        if #a ~= #b or scalar_array(a) or scalar_array(b) then
            local same = #a == #b
            if same then
                for i = 1, #a do
                    if is_object(a[i]) or is_array(a[i]) or is_object(b[i]) or is_array(b[i]) then
                        same = false
                        break
                    end
                    if a[i] ~= b[i] then same = false break end
                end
            end
            if not same then ctx.diffs[#ctx.diffs + 1] = {path = path, real = a, sim = b} end
            return
        end
        for i = 1, #a do compare_value(a[i], b[i], path .. "[" .. i .. "]", npath .. "[]", ctx) end
        return
    end
    if type(a) == "number" and type(b) == "number" then
        if npath == "chips" then
            if not chips_equal(a, b) then ctx.diffs[#ctx.diffs + 1] = {path = path, real = a, sim = b} end
        elseif a ~= b then
            ctx.diffs[#ctx.diffs + 1] = {path = path, real = a, sim = b}
        end
        return
    end
    if a ~= b then ctx.diffs[#ctx.diffs + 1] = {path = path, real = a, sim = b} end
end

local function by_step(lines)
    local map, order = {}, {}
    for _, l in ipairs(lines) do
        local s = type(l) == "table" and l.step
        if type(s) == "number" and not map[s] then
            map[s] = l
            order[#order + 1] = s
        end
    end
    table.sort(order)
    return map, order
end

function C.compare(real_lines, sim_lines)
    local rmap, rorder = by_step(real_lines)
    local smap, sorder = by_step(sim_lines)
    local ctx = {cover = {}, real_paths = {}, sim_paths = {}}
    for _, s in ipairs(rorder) do collect_paths(rmap[s], "", ctx.real_paths) end
    for _, s in ipairs(sorder) do collect_paths(smap[s], "", ctx.sim_paths) end
    local res = {steps_real = #rorder, steps_sim = #sorder, compared = 0, cover = ctx.cover}
    local all, seen = {}, {}
    for _, s in ipairs(rorder) do all[#all + 1] = s seen[s] = true end
    for _, s in ipairs(sorder) do if not seen[s] then all[#all + 1] = s end end
    table.sort(all)
    for _, s in ipairs(all) do
        local r, m = rmap[s], smap[s]
        ctx.diffs = {}
        if not r or not m then
            ctx.diffs[1] = {path = "<step>", real = r and "present" or "missing", sim = m and "present" or "missing", missing = true}
        else
            res.compared = res.compared + 1
            if r.error ~= nil or m.error ~= nil then
                ctx.diffs[1] = {path = "error", real = r.error, sim = m.error}
            else
                compare_value(r, m, "", "", ctx)
            end
        end
        if #ctx.diffs > 0 and not res.first then
            res.first = s
            res.diffs = ctx.diffs
            res.phase_real = r and r.phase
            res.phase_sim = m and m.phase
        end
    end
    return res
end

local function fmt_side(v)
    if v == nil then return "<absent>" end
    return short(v)
end

function C.report(res, real_name, sim_name, opts)
    opts = opts or {}
    local out = {}
    out[#out + 1] = string.format("real: %s (%d steps)", real_name or "real", res.steps_real)
    out[#out + 1] = string.format("sim:  %s (%d steps)", sim_name or "sim", res.steps_sim)
    if res.first then
        out[#out + 1] = string.format("FIRST DIFF at step %d (phase real=%s sim=%s), %d field(s):", res.first, tostring(res.phase_real), tostring(res.phase_sim), #res.diffs)
        if opts.action then out[#out + 1] = "  action before it: " .. short(opts.action) end
        for i, d in ipairs(res.diffs) do
            if i > (opts.max_diffs or 25) then
                out[#out + 1] = string.format("  ... %d more", #res.diffs - i + 1)
                break
            end
            out[#out + 1] = string.format("  %s: real=%s sim=%s", d.path, fmt_side(d.real), fmt_side(d.sim))
        end
    end
    local paths = {}
    for p in pairs(res.cover) do paths[#paths + 1] = p end
    table.sort(paths)
    local only_real, only_sim = {}, {}
    for _, p in ipairs(paths) do
        local c = res.cover[p]
        if c.real > 0 then only_real[#only_real + 1] = string.format("%s (%d)", p, c.real) end
        if c.sim > 0 then only_sim[#only_sim + 1] = string.format("%s (%d)", p, c.sim) end
    end
    out[#out + 1] = "not covered by sim: " .. (#only_real > 0 and table.concat(only_real, ", ") or "none")
    out[#out + 1] = "only in sim: " .. (#only_sim > 0 and table.concat(only_sim, ", ") or "none")
    out[#out + 1] = res.first and string.format("result: DIFF at step %d", res.first) or string.format("result: MATCH (%d steps compared)", res.compared)
    return table.concat(out, "\n")
end

local function action_for(log_path, step)
    if not log_path then return nil end
    local lines = J.read_lines(log_path)
    return lines and lines[step + 1] or nil
end

local function list_dir(dir, suffix)
    local p = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
    local out = {}
    if not p then return out end
    for name in p:lines() do
        if name:sub(-#suffix) == suffix then out[#out + 1] = name end
    end
    p:close()
    table.sort(out)
    return out
end

local function compare_files(real_path, sim_path, log_path)
    local r, err = J.read_lines(real_path)
    if not r then return nil, err end
    local s, err2 = J.read_lines(sim_path)
    if not s then return nil, err2 end
    local res = C.compare(r, s)
    local action = res.first and action_for(log_path, res.first) or nil
    return res, nil, action
end

local function main(argv)
    if argv[1] == "--dirs" then
        local real_dir, sim_dir, md = argv[2], argv[3], argv[4] == "--md"
        if not (real_dir and sim_dir) then
            io.stderr:write("usage: compare.lua --dirs <real_dir> <sim_dir> [--md]\n")
            return 2
        end
        local names = list_dir(real_dir, ".snap.jsonl")
        local rows, details, bad, matched = {}, {}, 0, 0
        local cover = {}
        for _, name in ipairs(names) do
            local base = name:sub(1, -#".snap.jsonl" - 1)
            local log_path = real_dir .. "/" .. base .. ".log.jsonl"
            local res, err, action = compare_files(real_dir .. "/" .. name, sim_dir .. "/" .. name, log_path)
            if not res then
                bad = bad + 1
                rows[#rows + 1] = string.format("| %s | - | - | ERROR | %s |", base, short(err))
            else
                for p, c in pairs(res.cover) do
                    local t = cover[p] or {real = 0, sim = 0}
                    cover[p] = t
                    t.real, t.sim = t.real + c.real, t.sim + c.sim
                end
                if res.first then
                    bad = bad + 1
                    rows[#rows + 1] = string.format("| %s | %d | %d | DIFF at %d | %s |", base, res.steps_real, res.steps_sim, res.first, short(res.diffs[1].path))
                    if #details < 5 then details[#details + 1] = C.report(res, real_dir .. "/" .. name, sim_dir .. "/" .. name, {action = action, max_diffs = 8}) end
                else
                    matched = matched + 1
                    rows[#rows + 1] = string.format("| %s | %d | %d | MATCH | |", base, res.steps_real, res.steps_sim)
                end
            end
        end
        local out = {}
        out[#out + 1] = string.format("%s %d runs: %d match, %d differ", md and "### botsim truth check:" or "truth check:", #names, matched, bad)
        out[#out + 1] = ""
        out[#out + 1] = "| run | real steps | sim steps | result | first field |"
        out[#out + 1] = "| --- | --- | --- | --- | --- |"
        for _, r in ipairs(rows) do out[#out + 1] = r end
        local paths = {}
        for p, c in pairs(cover) do if c.real > 0 then paths[#paths + 1] = p end end
        table.sort(paths)
        out[#out + 1] = ""
        out[#out + 1] = "not covered by sim: " .. (#paths > 0 and table.concat(paths, ", ") or "none")
        for _, d in ipairs(details) do
            out[#out + 1] = ""
            if md then out[#out + 1] = "```" end
            out[#out + 1] = d
            if md then out[#out + 1] = "```" end
        end
        print(table.concat(out, "\n"))
        return (bad == 0 and #names > 0) and 0 or 1
    end
    local real_path, sim_path = argv[1], argv[2]
    if not (real_path and sim_path) then
        io.stderr:write("usage: compare.lua <real.jsonl> <sim.jsonl> [--log <actions.jsonl>]\n       compare.lua --dirs <real_dir> <sim_dir> [--md]\n")
        return 2
    end
    local log_path = argv[3] == "--log" and argv[4] or nil
    local res, err, action = compare_files(real_path, sim_path, log_path)
    if not res then
        io.stderr:write(tostring(err) .. "\n")
        return 2
    end
    print(C.report(res, real_path, sim_path, {action = action}))
    return res.first and 1 or 0
end

C.main = main

if arg and arg[0] and arg[0]:match("compare%.lua$") and not package.loaded["compare"] then
    os.exit(main(arg))
end

return C
