package.path = "assets/?.lua;tools/?.lua;" .. package.path

local T = {passed = 0, failed = 0, current = ""}

function T.eq(a, b, msg)
    if a == b then
        T.passed = T.passed + 1
    else
        T.failed = T.failed + 1
        print(string.format("FAIL [%s] %s: expected %s, got %s", T.current, msg or "", tostring(b), tostring(a)))
    end
end

function T.near(a, b, msg)
    if type(a) == "number" and math.abs(a - b) < 1e-9 then
        T.passed = T.passed + 1
    else
        T.eq(a, b, msg)
    end
end

function T.ok(v, msg) T.eq(not not v, true, msg) end

local function extract(path, names)
    local f = assert(io.open(path, "r"))
    local src = f:read("*a")
    f:close()
    local lines = {}
    for l in (src .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = l end
    local out = {}
    for _, name in ipairs(names) do
        local start
        for i, l in ipairs(lines) do
            if l:match("^function " .. name:gsub("%.", "%%.") .. "%(") then start = i break end
        end
        assert(start, "missing " .. name)
        local i = start + 1
        while not lines[i]:match("^end") do i = i + 1 end
        for j = start, i do out[#out + 1] = lines[j] end
    end
    return table.concat(out, "\n")
end
T.extract = extract

function T.load_game_functions(path, names, env)
    local code = extract(path, names)
    local chunk = assert(loadstring(code, "=" .. path))
    setfenv(chunk, env)
    chunk()
    return env
end

local files = {"test_rng", "test_eval", "test_score", "test_blinds", "test_run", "test_econ"}
for _, name in ipairs(files) do
    T.current = name
    local fn = assert(loadfile("tools/botsim/test/" .. name .. ".lua"))
    fn(T)
end
print(string.format("%d passed, %d failed", T.passed, T.failed))
os.exit(T.failed == 0 and 0 or 1)
