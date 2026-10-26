local here = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = here .. "/../?.lua;" .. package.path
local J = require("json")
local C = require("compare")

local fails, total = 0, 0
local function check(name, cond, info)
    total = total + 1
    if not cond then
        fails = fails + 1
        print("FAIL " .. name .. (info and (": " .. info) or ""))
    end
end

local function load(name)
    local t, err = J.read_lines(here .. "/" .. name)
    assert(t, err)
    return t
end

local real = load("real.jsonl")
local function run(name) return C.compare(real, load(name)) end

local r = run("sim_match.jsonl")
check("match", r.first == nil and r.compared == 3, tostring(r.first))

r = run("sim_chips_round.jsonl")
check("chips rounding", r.first == nil, r.first and r.diffs[1].path)

r = run("sim_money.jsonl")
check("money step", r.first == 2, tostring(r.first))
check("money path", r.diffs and r.diffs[1].path == "money" and r.diffs[1].real == 4 and r.diffs[1].sim == 5)

r = run("sim_partial.jsonl")
check("partial matches", r.first == nil, r.first and r.diffs[1].path)
check("partial covers rng", r.cover.rng and r.cover.rng.real == 3)
check("partial covers levels", r.cover.levels and r.cover.levels.real == 3)
check("partial covers ab", r.cover["jokers[].ab"] and r.cover["jokers[].ab"].real == 2)

r = run("sim_short.jsonl")
check("short step", r.first == 2 and r.diffs[1].path == "<step>", tostring(r.first))

r = run("sim_rng_missing.jsonl")
check("rng key missing is a diff", r.first == 1 and r.diffs[1].path == "rng.shuffle", r.first and r.diffs[1].path)

r = run("sim_blind_missing.jsonl")
check("blind missing where sim has blind elsewhere", r.first == 1 and r.diffs[1].path == "blind", r.first and r.diffs[1].path)

r = run("sim_hand_order.jsonl")
check("hand order", r.first == 1 and r.diffs[1].path == "hand", r.first and r.diffs[1].path)

r = run("sim_error.jsonl")
check("error line", r.first == 2 and r.diffs[1].path == "error", r.first and r.diffs[1].path)

local rep = C.report(run("sim_money.jsonl"), "real.jsonl", "sim_money.jsonl")
check("report text", rep:find("FIRST DIFF at step 2", 1, true) and rep:find("money: real=4 sim=5", 1, true), rep)

local obj = J.decode('{"a":[1,2.5,-3e2,"x\\u00e9\\n"],"b":null,"c":{},"d":true}')
check("decode", obj.a[3] == -300 and obj.a[4] == "x\195\169\n" and obj.b == J.null and next(obj.c) == nil and obj.d == true)
check("encode roundtrip", J.encode(obj) == '{"a":[1,2.5,-300,"x\195\169\\n"],"b":null,"c":{},"d":true}', J.encode(obj))
check("number exact", J.decode(J.number(0.1 + 0.2)) == 0.1 + 0.2)
check("bad json", not pcall(J.decode, '{"a":1,}'))

print(string.format("%d/%d checks passed", total - fails, total))
os.exit(fails == 0 and 0 or 1)
