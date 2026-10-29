package.path = "assets/?.lua;tools/?.lua;" .. package.path

local E = require("bot.sim.engine")
local ST = require("bot.sim.state")
local SN = require("bot.sim.snapshot")
local S = require("bot.seer.seer")
local PL = require("bot.seer.play")
local TE = require("botsim.seer.teacher")
local REC = require("botsim.train.records")

local passed, failed = 0, 0
local current = ""
local function ok(v, msg)
    if v then passed = passed + 1 else
        failed = failed + 1
        print(string.format("FAIL [%s] %s", current, msg or ""))
    end
end

local QUICK = {horizon = 1, tight_horizon = 1, beam = 2, depth = 2, stop_ante = 2}
local slow = not (arg and arg[1] == "quick")

local SPEC = {
    select = {}, skip = {}, reroll_boss = {}, play = {cards = true}, discard = {cards = true}, cash_out = {}, leave = {}, reroll = {},
    buy = {card = true}, buy_and_use = {card = true}, redeem = {card = true}, open = {card = true},
    sell = {area = true, card = true}, use = {card = true, targets = true}, pick = {card = true, targets = true},
    reorder_jokers = {order = true}, endless = {},
}

local function line_str(line)
    local t = {}
    for i, a in ipairs(line) do
        local p = {a.type}
        if a.area then p[#p + 1] = a.area end
        if a.card then p[#p + 1] = a.card end
        if a.cards then p[#p + 1] = table.concat(a.cards, ".") end
        if a.targets then p[#p + 1] = "t" .. table.concat(a.targets, ".") end
        if a.order then p[#p + 1] = "o" .. table.concat(a.order, ".") end
        t[i] = table.concat(p, ":")
    end
    return table.concat(t, " ")
end

current = "determinism"
do
    local setup = {seed = "SEERTEST", deck = "b_red", stake = 1}
    local l1, s1 = S.new(QUICK):play(setup)
    local l2, s2 = S.new(QUICK):play(setup)
    ok(#l1 > 10, "line has actions")
    ok(line_str(l1) == line_str(l2), "same line for the same seed")
    ok(SN.line(s1) == SN.line(s2), "same final state")
    local l3 = S.new(QUICK):play({seed = "SEERTEST", deck = "b_red", stake = 1})
    ok(line_str(l1) == line_str(l3), "same line after other Seer objects ran")
end

current = "search leaves the real state alone"
do
    local seer = S.new(QUICK)
    local s = E.new_run({seed = "SEERPURE", deck = "b_blue", stake = 2})
    local phases = {}
    for _ = 1, 400 do
        if s.won == 1 or s.phase == "game_over" or s.ante > 2 then break end
        local before = SN.line(s)
        local rng_before = {}
        for i = 1, s.n_rk do rng_before[i] = s.rng[s.rng_ids[i]] end
        seer.plan = nil
        local a = seer:choose(s)
        phases[s.phase] = true
        ok(SN.line(s) == before, "choose does not change the state (" .. s.phase .. ")")
        local same = true
        for i = 1, #rng_before do if s.rng[s.rng_ids[i]] ~= rng_before[i] then same = false end end
        ok(same, "choose does not move the RNG")
        if not a or not E.step(s, a) then break end
    end
    ok(phases.play and phases.shop and phases.blind_select, "covered play, shop and blind select")
end

current = "line is legal and replays exactly"
do
    for _, setup in ipairs({{seed = "SEERREP1", deck = "b_yellow", stake = 1}, {seed = "SEERREP2", deck = "b_plasma", stake = 4},
        {seed = "SEERREP3", deck = "b_red", stake = 1, challenge = "c_omelette_1"}}) do
        local seer = S.new(QUICK)
        local s = E.new_run(setup)
        local line = {}
        local legal, forced_ok = true, true
        for _ = 1, 1000 do
            if s.won == 1 or s.phase == "game_over" or s.ante > 2 then break end
            local a = seer:choose(s)
            if not a then break end
            local spec = SPEC[a.type]
            if not spec then legal = false end
            for k in pairs(a) do
                if k ~= "type" and not (spec and spec[k]) then legal = false end
            end
            if a.type == "play" then
                local fp = PL.forced_pos(s)
                if fp > 0 then
                    local has = false
                    for _, p in ipairs(a.cards) do if p == fp then has = true end end
                    if not has then forced_ok = false end
                end
            end
            if not E.step(s, a) then
                legal = false
                break
            end
            line[#line + 1] = S.copy_action(a)
        end
        ok(legal, "every action is a SPEC action the sim accepts (" .. setup.seed .. ")")
        ok(forced_ok, "plays keep the forced card")
        local rs, bad = S.replay(setup, line)
        ok(bad == nil, "replay accepts every action")
        ok(SN.line(rs) == SN.line(s), "replay ends in the same state")
    end
end

current = "blind solver"
do
    local worse, n = 0, 0
    for i = 1, 6 do
        local s = E.new_run({seed = string.format("SOLVE%03d", i), deck = "b_red", stake = 1})
        E.step(s, {type = "select"})
        for _ = 1, 3 do
            if s.phase ~= "play" then break end
            local g = ST.clone(s)
            local gh = 0
            for _ = 1, 30 do
                if g.phase ~= "play" then break end
                local a = PL.fast_action(g)
                if a.type == "play" then gh = gh + 1 end
                if not E.step(g, a) then break end
            end
            local acts, cleared = PL.solve(s)
            local c = ST.clone(s)
            local sh = 0
            for _, a in ipairs(acts) do
                if a.type == "play" then sh = sh + 1 end
                ok(E.step(c, a), "solver action accepted")
            end
            n = n + 1
            if PL.cleared(g) then
                ok(cleared and PL.cleared(c), "solver clears when greedy does")
                if sh > gh then worse = worse + 1 end
            end
            for _, a in ipairs(acts) do E.step(s, a) end
            if s.phase == "round_eval" then E.step(s, {type = "cash_out"}) E.step(s, {type = "leave"}) E.step(s, {type = "select"}) end
        end
    end
    ok(n >= 6, "solved several blinds")
    ok(worse == 0, "solver never uses more hands than greedy")
end

current = "teacher records"
do
    local blob, info = TE.run({seed = "TEACHT01", deck = "b_red", stake = 1}, {seer = QUICK, stop_ante = 1, K = 24, n_sims = 800}, 3)
    local data = REC.decode(REC.file_header() .. blob)
    ok(#data.runs == 1, "one run")
    local run = data.runs[1]
    ok(#run.recs == info.records and info.records > 0, "records decode")
    ok(run.index == 3 and run.stake == 1, "run header")
    local onehot = true
    for _, r in ipairs(run.recs) do
        local nz, top = 0, 0
        for j, a in ipairs(r.acts) do
            if a.visits > 0 then nz = nz + 1 top = j - 1 end
        end
        if nz ~= 1 or top ~= r.chosen or r.n_sims ~= 800 or r.na > 24 then onehot = false end
    end
    ok(onehot, "visits one-hot on the chosen action")
end

current = "fair teacher records: stop ante and world votes"
do
    local blob, info = TE.run({seed = "TEACHF01", deck = "b_red", stake = 1}, {mode = "fair", budget = "lite", stop_ante = 1, K = 24, n_sims = 800}, 2)
    local data = REC.decode(REC.file_header() .. blob)
    local run = data.runs[1]
    ok(#run.recs == info.records and info.records > 0, "records decode")
    ok(info.won == 1 or info.state.ante <= 2, "fair run stops after stop_ante")
    local chosen_ok, sums_ok, soft = true, true, 0
    for _, r in ipairs(run.recs) do
        local nz, sum = 0, 0
        for _, a in ipairs(r.acts) do
            if a.visits > 0 then nz, sum = nz + 1, sum + a.visits end
        end
        if r.acts[r.chosen + 1].visits <= 0 then chosen_ok = false end
        if nz > 1 then
            soft = soft + 1
            if sum > 5 then sums_ok = false end
        end
    end
    ok(chosen_ok, "chosen action always has visits")
    ok(sums_ok, "world votes never exceed the world count")
    print(string.format("note: fair teacher %d records, %d with world votes on several moves", #run.recs, soft))
end

current = "fair teacher records: random negatives"
do
    local opts = {mode = "fair", budget = "lite", stop_ante = 1, K = 32, neg = 16, n_sims = 800}
    local b1, i1 = TE.run({seed = "TEACHF01", deck = "b_red", stake = 1}, opts, 2)
    local b2 = TE.run({seed = "TEACHF01", deck = "b_red", stake = 1}, opts, 2)
    ok(b1 == b2, "same seed gives the same records")
    local run = REC.decode(REC.file_header() .. b1).runs[1]
    local plays, with_disc, chosen_ok = 0, 0, true
    for _, r in ipairs(run.recs) do
        if r.acts[r.chosen + 1].visits <= 0 then chosen_ok = false end
        if r.na == 32 then
            local nd = 0
            for _, a in ipairs(r.acts) do if a.type == 2 then nd = nd + 1 end end
            plays = plays + 1
            if nd >= 2 then with_disc = with_disc + 1 end
        end
    end
    ok(chosen_ok, "chosen action always has visits")
    ok(plays > 0 and with_disc == plays, "every full play record carries several discards as negatives")
    print(string.format("note: %d full records, %d of them with discard negatives", plays, with_disc))
end

current = "fair teacher with a net proposing moves"
do
    local opts = {mode = "fair", budget = "lite", stop_ante = 1, K = 24, n_sims = 800, weights = "tools/botsim/train/start/r2_gen_0001.bnnw", net_sims = 8}
    local b1, i1 = TE.run({seed = "TEACHN01", deck = "b_blue", stake = 1}, opts, 1)
    local b2, i2 = TE.run({seed = "TEACHN01", deck = "b_blue", stake = 1}, opts, 1)
    ok(i1.records > 0 and #REC.decode(REC.file_header() .. b1).runs == 1, "records decode")
    ok(b1 == b2 and line_str(i1.line) == line_str(i2.line), "same seed gives the same net-guided line")
    local s = E.new_run({seed = "TEACHN01", deck = "b_blue", stake = 1})
    local legal = true
    for _, a in ipairs(i1.line) do
        if not E.step(s, a) then legal = false break end
    end
    ok(legal, "net-guided line replays")
    print(string.format("note: net-guided fair teacher %d decisions, %d searched, net move chosen %d times", i1.decisions, i1.searched, i1.net_picks))
end

current = "solve search is deterministic and replays"
do
    local setup = {seed = "SEERSLV1", deck = "b_blue", stake = 2}
    local o = {horizon = 1, tight_horizon = 1, beam = 2, depth = 2, stop_ante = 1}
    local r1 = S.new(o):solve(setup, {max_lines = 4, boost = {horizon = 2, depth = 2}})
    local r2 = S.new(o):solve(setup, {max_lines = 4, boost = {horizon = 2, depth = 2}})
    ok(r1.lines >= 2, "solve tried several lines")
    ok(line_str(r1.line) == line_str(r2.line), "same best line for the same seed")
    ok(r1.replay_ok, "best line replays")
    local rs = S.replay(setup, r1.line)
    ok(rs.ante == r1.final_ante or rs.won == 1, "replayed line reaches the reported ante")
    ok(r1.verdict:match("^No win found") or r1.verdict:match("^Win found"), "verdict wording")
end

if slow then
    current = "solve first: a found win replays to a win"
    local setup = {seed = "SEER0002", deck = "b_red", stake = 1}
    local msgs = 0
    local r = S.new():solve(setup, {max_lines = 3}, function() msgs = msgs + 1 end)
    ok(msgs >= 1, "progress callback")
    ok(r.replay_ok, "best line replays")
    if r.won then
        local rs = S.replay(setup, r.line)
        ok(rs.won == 1, "replayed line wins")
        ok(r.verdict:match("^Win found"), "verdict says win")
    else
        ok(r.verdict:match("^No win found"), "verdict says no win found")
        print("note: " .. setup.seed .. " gave no win within 3 lines, win replay not exercised")
    end
    print(r.verdict, string.format("lines %d time %.1fs", r.lines, r.time))
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
