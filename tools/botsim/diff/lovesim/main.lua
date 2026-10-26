function love.load(args)
    local repo, outdir = args[1], args[2]
    package.path = repo .. "/assets/?.lua;" .. repo .. "/tools/?.lua;" .. package.path
    local replay = assert(loadfile(repo .. "/tools/botsim/replay.lua"))
    local fails = {}
    for i = 3, #args do
        local l = args[i]
        local b = l:match("([^/]+)%.log%.jsonl$")
        if b then
            _G.arg = {[0] = "replay.lua", l, outdir .. "/" .. b .. ".snap.jsonl"}
            local ok, err = pcall(replay)
            if not ok then fails[#fails + 1] = b .. ": " .. tostring(err) end
        end
    end
    if #fails > 0 then
        local f = io.open(outdir .. "/failures.txt", "a")
        for _, x in ipairs(fails) do f:write(x, "\n") end
        f:close()
    end
    io.write(string.format("lovesim: %d logs, %d failures, %s\n", #args - 2, #fails, jit and jit.version or "no jit"))
    love.event.quit(0)
end
