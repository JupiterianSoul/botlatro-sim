local OUT = os.getenv("BOTSIM_OUT") or "."
local MODE = os.getenv("BOTSIM_MODE") or "generate"
local RUNS_FILE = os.getenv("BOTSIM_RUNS") or ""
local LOGS = os.getenv("BOTSIM_LOGS") or ""
local POLICY = os.getenv("BOTSIM_POLICY") or "mixed"
local POLICY_SEED = tonumber(os.getenv("BOTSIM_POLICY_SEED") or "1") or 1
local MAX_STEPS = tonumber(os.getenv("BOTSIM_MAX_STEPS") or "300") or 300
local MAX_ANTE = tonumber(os.getenv("BOTSIM_MAX_ANTE") or "0") or 0
local MAX_SECONDS = tonumber(os.getenv("BOTSIM_SECONDS") or "1200") or 1200
local RUN_SECONDS = tonumber(os.getenv("BOTSIM_RUN_SECONDS") or "240") or 240
local SHOP_CAP = tonumber(os.getenv("BOTSIM_SHOP_CAP") or "10") or 10
local TAG = os.getenv("BOTSIM_TAG") or "rec"
local STABLE = 3
local STUCK_UPDATES = 6000

local J = require("botsim_json")

local logf = io.open(OUT .. "/recorder_" .. TAG .. ".log", "w")
local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    logf:write(string.format("[%8.1f] %s\n", love.timer.getTime(), table.concat(parts, " ")))
    logf:flush()
end

local ERRORS = 0
local function record_error(kind, msg)
    ERRORS = ERRORS + 1
    if ERRORS < 60 then log("ERROR", kind, tostring(msg)) end
end

love.system.openURL = function() return true end
love.system.setClipboardText = function() end

require "game_main"
local TURBO_T = require("turbo")
TURBO_T.install()
if love.audio and love.audio.setVolume then love.audio.setVolume(0) end

love.errorhandler = function(msg)
    record_error("FATAL", debug.traceback(tostring(msg), 2))
    log("FATAL_EXIT")
    logf:close()
    return nil
end
love.errhand = nil

local B = BOT_BRIDGE

local rs = (POLICY_SEED * 2654435761) % 4294967296
if rs == 0 then rs = 12345 end
local function rnd()
    rs = (rs * 1103515245 + 12345) % 2147483648
    return rs / 2147483648
end

local RANKS = {[10] = "T", [11] = "J", [12] = "Q", [13] = "K", [14] = "A"}
local SUITS = {Spades = "S", Hearts = "H", Diamonds = "D", Clubs = "C"}

local function edition_key(card)
    local e = card.edition
    if type(e) ~= "table" then return nil end
    if type(e.key) == "string" then return e.key end
    if type(e.type) == "string" then return "e_" .. e.type end
    for _, k in ipairs({"foil", "holo", "polychrome", "negative"}) do
        if e[k] then return "e_" .. k end
    end
    return nil
end

local function is_playing_card(card)
    local set = card.ability and card.ability.set
    return (set == "Default" or set == "Enhanced") and card.base and card.base.id
end

local function card_str(card)
    if not is_playing_card(card) then
        local key = card.config and card.config.center and card.config.center.key or "?"
        local ed = edition_key(card)
        return ed and (key .. ":" .. ed) or key
    end
    local s = (RANKS[card.base.id] or tostring(card.base.id)) .. (SUITS[card.base.suit] or "?")
    local center = card.config and card.config.center
    if center and center.key and center.key ~= "c_base" then s = s .. ":" .. center.key end
    local ed = edition_key(card)
    if ed then s = s .. ":" .. ed end
    if card.seal then s = s .. ":s_" .. string.lower(card.seal) end
    local pb = card.ability and card.ability.perma_bonus
    if type(pb) == "number" and pb ~= 0 then s = s .. ":+" .. J.number(pb) end
    return s
end

local function cards_of(area)
    local out = J.array({})
    for _, c in ipairs(area and area.cards or {}) do out[#out + 1] = card_str(c) end
    return out
end

local function joker_ab(card)
    local ab = J.object({})
    local a = card.ability or {}
    for k, v in pairs(a) do
        if type(v) == "number" and type(k) == "string" then ab[k] = v end
    end
    local ex = a.extra
    if type(ex) == "number" then
        ab.extra = ex
    elseif type(ex) == "table" then
        for k, v in pairs(ex) do
            if type(v) == "number" and type(k) == "string" then ab["extra." .. k] = v end
        end
    end
    return ab
end

local function null_or(v)
    if v == nil then return J.null end
    return v
end

local function jokers_of()
    local out = J.array({})
    for _, c in ipairs(G.jokers and G.jokers.cards or {}) do
        local a = c.ability or {}
        out[#out + 1] = {
            __order = {"key", "ed", "eternal", "perishable", "rental", "sell", "ab"},
            key = c.config and c.config.center and c.config.center.key or "?",
            ed = null_or(edition_key(c)),
            eternal = a.eternal and true or false,
            perishable = a.perishable and true or false,
            rental = a.rental and true or false,
            sell = c.sell_cost or 0,
            ab = joker_ab(c),
        }
    end
    return out
end

local function consumables_of()
    local out = J.array({})
    for _, c in ipairs(G.consumeables and G.consumeables.cards or {}) do out[#out + 1] = card_str(c) end
    return out
end

local function shop_of()
    if not (G.shop and G.shop_jokers and G.shop_jokers.cards) then return nil end
    local jok, vou, boo = J.array({}), J.array({}), J.array({})
    for _, c in ipairs(G.shop_jokers.cards) do
        local key = is_playing_card(c) and card_str(c) or (c.config and c.config.center and c.config.center.key or "?")
        jok[#jok + 1] = {__order = {"key", "ed", "cost"}, key = key, ed = null_or(edition_key(c)), cost = c.cost}
    end
    for _, c in ipairs(G.shop_vouchers and G.shop_vouchers.cards or {}) do
        vou[#vou + 1] = {__order = {"key", "cost"}, key = c.config.center.key, cost = c.cost}
    end
    for _, c in ipairs(G.shop_booster and G.shop_booster.cards or {}) do
        boo[#boo + 1] = {__order = {"key", "cost"}, key = c.config.center.key, cost = c.cost}
    end
    return {__order = {"jokers", "vouchers", "boosters"}, jokers = jok, vouchers = vou, boosters = boo}
end

local function levels_of()
    local out = J.object({})
    for name, h in pairs(G.GAME.hands or {}) do
        if type(h) == "table" then
            out[name] = {__order = {"level", "chips", "mult", "played"}, level = h.level, chips = h.chips, mult = h.mult, played = h.played}
        end
    end
    return out
end

local function vouchers_of()
    local out = J.array({})
    for k, v in pairs(G.GAME.used_vouchers or {}) do
        if v then out[#out + 1] = k end
    end
    table.sort(out)
    return out
end

local function tags_of()
    local out = J.array({})
    for _, t in ipairs(G.GAME.tags or {}) do out[#out + 1] = t.key or "?" end
    return out
end

local function rng_of()
    local out = J.object({})
    for k, v in pairs(G.GAME.pseudorandom or {}) do
        if k ~= "seed" and k ~= "hashed_seed" and type(v) == "number" then
            out[tostring(k)] = J.raw(string.format("%.13f", v))
        end
    end
    return out
end

local function deck_of()
    local out = J.array({})
    local cards = G.deck and G.deck.cards or {}
    for i = #cards, 1, -1 do out[#out + 1] = card_str(cards[i]) end
    return out
end

local ORDER = {"step", "phase", "ante", "round", "money", "chips", "hands_left", "discards_left", "hand_size", "blind", "hand", "deck", "discard_count", "jokers", "consumables", "shop", "reroll_cost", "pack", "levels", "vouchers", "tags", "rng"}

local function snapshot(step, phase)
    local g = G.GAME
    local cr = g.current_round or {}
    local s = {__order = ORDER, step = step, phase = phase}
    s.ante = g.round_resets and g.round_resets.ante
    s.round = g.round
    s.money = g.dollars
    s.chips = g.chips
    s.hands_left = cr.hands_left
    s.discards_left = cr.discards_left
    s.hand_size = G.hand and G.hand.config and G.hand.config.card_limit
    local bl = g.blind
    if g.facing_blind and bl and bl.config and bl.config.blind and bl.config.blind.key then
        s.blind = {__order = {"key", "target"}, key = bl.config.blind.key, target = bl.chips}
    end
    s.hand = cards_of(G.hand)
    s.deck = deck_of()
    s.discard_count = G.discard and G.discard.cards and #G.discard.cards or 0
    s.jokers = jokers_of()
    s.consumables = consumables_of()
    s.shop = shop_of()
    s.reroll_cost = cr.reroll_cost
    if phase == "pack" and G.pack_cards then s.pack = cards_of(G.pack_cards) end
    s.levels = levels_of()
    s.vouchers = vouchers_of()
    s.tags = tags_of()
    s.rng = rng_of()
    return s
end

local function pos_of(area, id)
    for i, c in ipairs(area and area.cards or {}) do
        if c.sort_id == id then return i end
    end
    return nil
end

local function id_at(area, pos)
    local c = area and area.cards and area.cards[pos]
    return c and c.sort_id
end

local function map_list(list, f)
    if type(list) ~= "table" then return nil end
    local out = {}
    for i, v in ipairs(list) do
        local r = f(v)
        if r == nil then return nil end
        out[i] = r
    end
    return out
end

local SHOP_AREA = {buy = "shop_jokers", buy_and_use = "shop_jokers", redeem = "shop_vouchers", open = "shop_booster", pick = "pack_cards", use = "consumeables"}

local function to_positions(a)
    local p = {type = a.type}
    local hp = function(id) return pos_of(G.hand, id) end
    if a.cards then
        p.cards = map_list(a.cards, hp)
        if not p.cards then return nil, "card not in hand" end
    end
    if a.targets and #a.targets > 0 then
        p.targets = map_list(a.targets, hp)
        if not p.targets then return nil, "target not in hand" end
    end
    if a.type == "sell" then
        local i = pos_of(G.jokers, a.card)
        if i then p.area, p.card = "jokers", i else
            i = pos_of(G.consumeables, a.card)
            if not i then return nil, "sell card not found" end
            p.area, p.card = "consumables", i
        end
    elseif SHOP_AREA[a.type] then
        p.card = pos_of(G[SHOP_AREA[a.type]], a.card)
        if not p.card then return nil, a.type .. " card not found" end
    end
    if a.type == "reorder_jokers" then
        p.order = map_list(a.order, function(id) return pos_of(G.jokers, id) end)
        if not p.order then return nil, "joker not found" end
    end
    return p
end

local function to_ids(p)
    local a = {type = p.type}
    local hid = function(pos) return id_at(G.hand, pos) end
    if p.cards then
        a.cards = map_list(p.cards, hid)
        if not a.cards then return nil, "hand position out of range" end
    end
    if p.targets then
        a.targets = map_list(p.targets, hid)
        if not a.targets then return nil, "target position out of range" end
    end
    if p.type == "sell" then
        a.card = id_at(p.area == "consumables" and G.consumeables or G.jokers, p.card)
        if not a.card then return nil, "sell position out of range" end
    elseif SHOP_AREA[p.type] then
        a.card = id_at(G[SHOP_AREA[p.type]], p.card)
        if not a.card then return nil, p.type .. " position out of range" end
    end
    if p.type == "reorder_jokers" then
        a.order = map_list(p.order, function(pos) return id_at(G.jokers, pos) end)
        if not a.order then return nil, "joker position out of range" end
    end
    return a
end

local function action_json(p)
    local t = {__order = {"type", "area", "card", "cards", "targets", "order"}}
    for k, v in pairs(p) do
        t[k] = type(v) == "table" and J.array(v) or v
    end
    return t
end

local EXCLUDED = {sort = true, new_run = true, menu = true, ready = true}

local function random_action(state, ctx)
    local legal = {}
    for _, l in ipairs(state.legal or {}) do
        if not EXCLUDED[l.type] then legal[#legal + 1] = l end
    end
    return BOT.brains.mock({phase = state.phase, legal = legal, hand = state.hand, jokers = state.jokers}, ctx)
end

local function pick_random(state, ctx, allowed)
    local legal = {}
    for _, l in ipairs(state.legal or {}) do
        if allowed[l.type] and not (l.targets_min and #(state.hand or {}) < l.targets_min) then legal[#legal + 1] = l end
    end
    if #legal == 0 then return nil end
    return BOT.brains.mock({phase = state.phase, legal = legal, hand = state.hand, jokers = state.jokers}, ctx)
end

local MIXED = {
    play = {p = 0.14, allowed = {use = true, reorder_jokers = true, sell = true}},
    shop = {p = 0.35, allowed = {buy = true, buy_and_use = true, redeem = true, open = true, reroll = true, use = true, sell = true, reorder_jokers = true, leave = true}},
    pack = {p = 0.4, allowed = {pick = true, skip = true}},
    blind_select = {p = 0.25, allowed = {skip = true, reroll_boss = true}},
}

local function policy_action(state, ctx)
    local phase = state.phase
    if phase == "win" then return {type = "endless"} end
    if phase == "shop" and (ctx.shop_turns or 0) > SHOP_CAP then return {type = "leave"} end
    if POLICY == "random" then return random_action(state, ctx) end
    if POLICY == "mixed" then
        local m = MIXED[phase]
        if m and rnd() < m.p then
            local a = pick_random(state, ctx, m.allowed)
            if a and not (phase == "blind_select" and a.type == "skip" and state.blind_on_deck == "Boss") then
                if not (a.type == "sell" and state.jokers and #state.jokers > 0 and rnd() < 0.7) then return a end
            end
        end
    end
    local ok, a = pcall(BOT.brains.rules, state, ctx)
    if ok and a and not EXCLUDED[a.type] then return a end
    return random_action(state, ctx)
end

local FALLBACK = {shop = {type = "leave"}, pack = {type = "skip"}, blind_select = {type = "select"}, round_eval = {type = "cash_out"}, win = {type = "endless"}}

local function unlock_everything()
    for _, pool in ipairs({G.P_CENTERS, G.P_BLINDS, G.P_TAGS, G.P_SEALS}) do
        for _, v in pairs(pool or {}) do
            if type(v) == "table" then v.unlocked = true v.discovered = true v.alerted = true end
        end
    end
    G.SETTINGS.tutorial_complete = true
    G.SETTINGS.tutorial_progress = nil
end

local function read_runs()
    local jobs = {}
    if MODE == "replay" then
        for path in LOGS:gmatch("%S+") do
            local lines, err = J.read_lines(path)
            if not lines or not lines[1] then
                record_error("LOG", tostring(err or ("empty log " .. path)))
            else
                local name = path:match("([^/]+)$"):gsub("%.log%.jsonl$", ""):gsub("%.jsonl$", "")
                local actions = {}
                for i = 2, #lines do actions[#actions + 1] = lines[i] end
                jobs[#jobs + 1] = {setup = lines[1], name = name, actions = actions}
            end
        end
    else
        local lines, err = J.read_lines(RUNS_FILE)
        if not lines then record_error("RUNS", tostring(err)) return jobs end
        for _, setup in ipairs(lines) do
            local ch = setup.challenge
            if ch == J.null then ch = nil end
            local name = setup.name or string.format("%s_s%d_%s%s", setup.deck or "b_red", setup.stake or 1, setup.seed, ch and ("_" .. ch) or "")
            jobs[#jobs + 1] = {setup = setup, name = name}
        end
    end
    return jobs
end

local D = {t = 0, state = "boot", jobs = {}, idx = 0, wall0 = nil}
local R

local function write_line(f, t)
    f:write(J.encode(t), "\n")
    f:flush()
end

local function finish_run(reason)
    if not R then return end
    local ante = G.GAME and G.GAME.round_resets and G.GAME.round_resets.ante
    local phases = {}
    for k, v in pairs(R.phases) do phases[#phases + 1] = k .. "=" .. v end
    table.sort(phases)
    log("RUN_END", R.name, "reason=" .. reason, "steps=" .. R.step, "ante=" .. tostring(ante), "refused=" .. R.refused, "phases=" .. table.concat(phases, ","))
    if R.snap then R.snap:close() end
    if R.logf then R.logf:close() end
    R = nil
    D.state = "next"
end

local function start_run(job)
    local setup = job.setup
    local ch = setup.challenge
    if ch == J.null then ch = nil end
    local challenge
    if ch then
        for _, c in ipairs(G.CHALLENGES or {}) do
            if c.id == ch then challenge = c break end
        end
        if not challenge then record_error("SETUP", "unknown challenge " .. tostring(ch)) return false end
    end
    local deck = setup.deck or "b_red"
    if not (G.P_CENTERS[deck] and G.P_CENTERS[deck].set == "Back") then record_error("SETUP", "unknown deck " .. tostring(deck)) return false end
    R = {name = job.name, job = job, step = 0, refused = 0, phases = {}, t0 = love.timer.getTime(), ctx = {rng = rnd, shop_turns = 0}, next_action = 1}
    R.snap = io.open(OUT .. "/" .. job.name .. ".snap.jsonl", "w")
    if MODE ~= "replay" then
        R.logf = io.open(OUT .. "/" .. job.name .. ".log.jsonl", "w")
        R.setup_line = {__order = {"seed", "deck", "stake", "challenge", "hands_order"}, seed = setup.seed, deck = deck, stake = setup.stake or 1, challenge = ch or J.null}
    end
    log("RUN_START", job.name, "seed=" .. tostring(setup.seed), "deck=" .. deck, "stake=" .. tostring(setup.stake or 1), "challenge=" .. tostring(ch), "mode=" .. MODE)
    B.win_seen = nil
    if G.OVERLAY_MENU then G.FUNCS.exit_overlay_menu() end
    if G.STAGE == G.STAGES.RUN and G.GAME then B.leaving_game = G.GAME end
    G.FUNCS.start_run(nil, {stake = setup.stake or 1, seed = setup.seed, back = G.P_CENTERS[deck], challenge = challenge})
    D.state = "settle"
    D.settle_n, D.stable_n, D.after = 0, 0, "first"
    return true
end

local function next_job()
    D.idx = D.idx + 1
    local job = D.jobs[D.idx]
    if not job then
        D.state = "done"
        log("ALL_DONE", "runs=" .. #D.jobs, "errors=" .. ERRORS)
        D.quit_at = D.t + 1
        return
    end
    if not start_run(job) then D.state = "next" end
end

local function hands_order()
    local out = J.array({})
    for k in pairs(G.GAME.hands or {}) do out[#out + 1] = k end
    return out
end

local function take_snapshot(phase)
    R.phases[phase] = (R.phases[phase] or 0) + 1
    if R.step == 0 then
        local order = hands_order()
        if R.setup_line then
            R.setup_line.hands_order = order
            write_line(R.logf, R.setup_line)
            R.setup_line = nil
        elseif MODE == "replay" then
            local want = R.job.setup.hands_order
            if type(want) == "table" and table.concat(want, ",") ~= table.concat(order, ",") then
                log("HANDS_ORDER_DIFFERS", R.name, "the log was recorded with another pairs() order of G.GAME.hands")
            end
        end
    end
    local ok, s = pcall(snapshot, R.step, phase)
    if not ok then
        record_error("SNAPSHOT", s)
        write_line(R.snap, {__order = {"step", "error"}, step = R.step, error = "snapshot failed: " .. tostring(s)})
        return
    end
    write_line(R.snap, s)
end

local function choose(phase)
    if MODE == "replay" then
        local p = R.job.actions[R.next_action]
        if not p then return nil, "log done" end
        R.next_action = R.next_action + 1
        local a, why = to_ids(p)
        if not a then return nil, "bad log action: " .. tostring(why), p end
        return a, nil, p
    end
    local saved = {}
    for k, v in pairs(G.GAME.pseudorandom or {}) do saved[k] = v end
    local state = B.observe({text = false})
    if phase == "shop" then R.ctx.shop_turns = (R.ctx.shop_turns or 0) + 1 else R.ctx.shop_turns = 0 end
    local tries = 0
    while tries < 6 do
        tries = tries + 1
        local a
        if tries == 1 then a = policy_action(state, R.ctx)
        elseif tries < 6 then a = random_action(state, R.ctx)
        else a = FALLBACK[phase] or (phase == "play" and G.hand.cards[1] and {type = "play", cards = {G.hand.cards[1].sort_id}}) end
        local rng_now = G.GAME.pseudorandom
        for k in pairs(rng_now) do if saved[k] == nil then rng_now[k] = nil end end
        for k, v in pairs(saved) do rng_now[k] = v end
        if a then
            local ok, why = B.validate(a, phase)
            if ok then
                local p, perr = to_positions(a)
                if p then return a, nil, p end
                record_error("POSITIONS", perr)
            else
                R.refused = R.refused + 1
            end
        end
    end
    return nil, "no valid action"
end

local function act_once()
    local phase = B.phase()
    if phase == "busy" or phase == "menu" then
        D.state = "settle"
        D.settle_n, D.stable_n, D.after = 0, 0, "action"
        return
    end
    if phase == "game_over" then return finish_run("game_over") end
    if R.step >= MAX_STEPS then return finish_run("max_steps") end
    if MAX_ANTE > 0 and (G.GAME.round_resets.ante or 0) > MAX_ANTE then return finish_run("max_ante") end
    if love.timer.getTime() - R.t0 > RUN_SECONDS then return finish_run("run_time") end
    local a, why, p = choose(phase)
    if not a then
        if MODE == "replay" and why ~= "log done" then
            R.step = R.step + 1
            write_line(R.snap, {__order = {"step", "error"}, step = R.step, error = why})
        end
        return finish_run(why == "log done" and "log_done" or why)
    end
    local ok, err = B.act(a)
    if not ok then
        R.refused = R.refused + 1
        if MODE == "replay" then
            R.step = R.step + 1
            write_line(R.snap, {__order = {"step", "error"}, step = R.step, error = "refused: " .. tostring(err)})
            return finish_run("refused")
        end
        record_error("REFUSED", R.name .. " " .. J.encode(action_json(p)) .. " " .. tostring(err))
        return
    end
    R.step = R.step + 1
    if R.logf then write_line(R.logf, action_json(p)) end
    D.state = "settle"
    D.settle_n, D.stable_n, D.after = 0, 0, "action"
end

local function driver(dt)
    D.t = D.t + dt
    if not (G and G.STATE and G.STATES) then return end
    G.SETTINGS.GAMESPEED = TURBO_T.on and TURBO_T.speed or 4
    if D.quit_at then
        if D.t > D.quit_at then
            log("QUIT", "errors=" .. ERRORS)
            D.quit_at = 1e18
            love.event.quit()
        end
        return
    end
    if D.state == "boot" then
        if G.STATE ~= G.STATES.MENU then return end
        unlock_everything()
        if BoosterManager then BoosterManager.get_inventory = function() return {} end end
        D.jobs = read_runs()
        D.wall0 = love.timer.getTime()
        log("AT_MENU", "mode=" .. MODE, "jobs=" .. #D.jobs, "policy=" .. POLICY)
        D.state = "next"
        return
    end
    if D.wall0 and love.timer.getTime() - D.wall0 > MAX_SECONDS and D.state ~= "done" then
        log("TIME_LIMIT")
        if R then finish_run("time_limit") end
        D.state = "done"
        D.quit_at = D.t + 1
        return
    end
    if D.state == "next" then return next_job() end
    if not R then return end
    if D.state == "settle" then
        D.settle_n = D.settle_n + 1
        local phase = B.phase()
        if phase == "busy" or phase == "menu" then
            D.stable_n = 0
            if D.settle_n > STUCK_UPDATES then
                record_error("STUCK", R.name .. " step " .. R.step .. " state=" .. tostring(G.STATE) .. " overlay=" .. tostring(G.OVERLAY_MENU ~= nil) .. " busy=" .. tostring(B.busy()))
                write_line(R.snap, {__order = {"step", "error"}, step = R.step + 1, error = "stuck after action"})
                finish_run("stuck")
            end
            return
        end
        if D.after == "first" and phase ~= "blind_select" then
            D.stable_n = 0
            return
        end
        D.stable_n = D.stable_n + 1
        if D.settle_n < 2 or D.stable_n < STABLE then return end
        take_snapshot(phase)
        D.state = "ready"
        return
    end
    if D.state == "ready" then act_once() end
end

local game_update = love.update
love.update = function(dt)
    local ok, err = xpcall(game_update, debug.traceback, dt)
    if not ok then record_error("UPDATE", err) end
    local ok2, err2 = xpcall(driver, debug.traceback, dt)
    if not ok2 then record_error("DRIVER", err2) end
end

local game_draw = love.draw
love.draw = function()
    local ok, err = xpcall(game_draw, debug.traceback)
    if not ok then
        record_error("DRAW", err)
        pcall(love.graphics.origin)
        pcall(love.graphics.setCanvas)
        pcall(love.graphics.setShader)
        while pcall(love.graphics.pop) do end
    end
end

log("HARNESS_READY", "mode=" .. MODE, "tag=" .. TAG)
