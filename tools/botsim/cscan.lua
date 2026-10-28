local M = {on = false}

local ok_ffi, ffi = pcall(require, "ffi")
local want = os.getenv("BOTSIM_CLIB")
if not ok_ffi or want == "0" or want == "off" then return M end

local function find_lib()
    if want and want ~= "" and want ~= "1" then return want end
    local info = debug.getinfo(1, "S").source
    local dir = info:sub(1, 1) == "@" and info:sub(2):match("^(.*)/[^/]*$") or "tools/botsim"
    return dir .. "/c/libbotsim.so"
end

local path = find_lib()
local f = io.open(path, "rb")
if not f then return M end
f:close()

ffi.cdef([[
const char *bs_joker_names(void);
const char *bs_blind_names(void);
const char *bs_key_names(void);
int bs_version(void);
int bs_max_hand(void);
int bs_max_jokers(void);
int bs_max_cons(void);
int bs_max_id(void);
int bs_combo_count(int n);
]])
local okl, L = pcall(ffi.load, path)
if not okl then return M end

local MAXH, MAXJ, MAXC, MAXID, NK = L.bs_max_hand(), L.bs_max_jokers(), L.bs_max_cons(), L.bs_max_id(), 8
local cdef = ([[
typedef struct {
    double c_enh[H2], c_bonus[H2], c_debuff[H2], c_pta[H2], c_pdebuff[H2];
    double j_mult[J1], j_x[J1], j_ex[J1], j_n[J1];
    double h_level[13], h_chips[13], h_mult[13], h_played[13], h_pround[13], h_vis[13];
    double rng_v[NK];
    double money, dollar_buffer, consumable_buffer, blind_triggered, blind_eye, blind_mouth;
    int n_hand;
} bs_mut;
typedef struct {
    bs_mut m;
    double c_rank[H2], c_suit[H2], c_osuit[H2], c_ed[H2], c_seal[H2], c_uid[H2];
    int hand[H2];
    double j_id[J1], j_ed[J1], j_debuff[J1], j_h[J1];
    double cons_hand[C1];
    double rng_hc[NK];
    double hashed_seed, hands_left, discards_left, hands_played, round_hands_played;
    double blind, blind_disabled, blind_suit, blind_face, most_played, prob;
    double n_cons, cons_limit, joker_limit, n_deck, starting_deck_size, n_playing, tarot_used;
    double chips_cap, plasma, observatory, idol_rank, idol_suit, ancient_suit, next_uid;
    int nh0, n_jok;
} bs_state;
typedef struct {
    int jid[NJN];
    int bid[NBN];
    double type_hand[MID], t_mult[MID], t_chips[MID], rarity[MID];
    double loyalty_every, loyalty_x;
    double hs_chips[13], hs_mult[13], hl_chips[13], hl_mult[13];
} bs_static;
void bs_init(const bs_static *st);
int bs_scan(bs_state *s, int fp, int five, int top, double *out_v, int *out_i);
]])

local function names(p)
    local t = {}
    for n in ffi.string(p):gmatch("([^,]+)") do t[#t + 1] = n end
    return t
end
local jnames, bnames, knames = names(L.bs_joker_names()), names(L.bs_blind_names()), names(L.bs_key_names())
cdef = cdef:gsub("H2", MAXH + 2):gsub("J1", MAXJ + 1):gsub("C1", MAXC + 1):gsub("NK", NK)
    :gsub("NJN", #jnames):gsub("NBN", #bnames):gsub("MID", MAXID)
ffi.cdef(cdef)
if L.bs_version() ~= 100000 + ffi.sizeof("bs_state") or #knames ~= NK then return M end

local E = require("bot.sim.engine")
local D = require("bot.sim.data")
local rng = require("bot.sim.rng")
local PL = require("bot.seer.play")
local J = E.J

if D.NUM_JOKERS >= MAXID then return M end

local st = ffi.new("bs_static")
for i, n in ipairs(jnames) do st.jid[i - 1] = J[n] end
for i, n in ipairs(bnames) do st.bid[i - 1] = D.BLIND_ID[n] end
for i, j in ipairs(D.JOKERS) do
    local c = j.config
    st.type_hand[i] = c.type and D.HAND_ID[c.type] or 0
    st.t_mult[i] = c.t_mult or 0
    st.t_chips[i] = c.t_chips or 0
    st.rarity[i] = j.rarity
end
local lc = D.JOKERS[J.loyalty_card].config.extra
st.loyalty_every, st.loyalty_x = lc.every, lc.Xmult
for h = 1, 12 do
    st.hs_chips[h], st.hs_mult[h] = D.HAND_S_CHIPS[h], D.HAND_S_MULT[h]
    st.hl_chips[h], st.hl_mult[h] = D.HAND_L_CHIPS[h], D.HAND_L_MULT[h]
end
L.bs_init(st)

local kids = {}
for i, n in ipairs(knames) do kids[i] = rng.key_id(n) end
local key_names = rng.key_names
local pseudohash = rng.pseudohash
local V_OBS = D.VOUCHER_ID.v_observatory
local PLANET_HAND = D.PLANET_HAND
local BLINDS = D.BLINDS
local E_STONE, E_STEEL = 6, 5
local J_THROW, J_STENCIL, J_SWASH, J_STONE, J_STEEL, J_LICENSE, J_EROSION = J.throwback, J.stencil, J.swashbuckler, J.stone, J.steel_joker, J.drivers_license, J.erosion
local joker_sell = E.joker_sell

local P = ffi.new("bs_state")
local out_v = ffi.new("double[8192]")
local out_i = ffi.new("int[8192]")

local function marshal(s)
    local nh, nj = s.n_hand, s.n_jok
    local hand = s.hand
    local c_rank, c_suit, c_osuit, c_enh, c_ed, c_seal = s.c_rank, s.c_suit, s.c_osuit, s.c_enh, s.c_ed, s.c_seal
    local c_bonus, c_uid, c_debuff, c_pta, c_pd = s.c_bonus, s.c_uid, s.c_debuff, s.c_pta, s.c_perma_debuff
    local m = P.m
    for i = 1, nh do
        local c = hand[i]
        P.c_rank[i], P.c_suit[i], P.c_osuit[i], P.c_ed[i], P.c_seal[i], P.c_uid[i] = c_rank[c], c_suit[c], c_osuit[c], c_ed[c], c_seal[c], c_uid[c]
        m.c_enh[i], m.c_bonus[i], m.c_debuff[i], m.c_pta[i], m.c_pdebuff[i] = c_enh[c], c_bonus[c], c_debuff[c], c_pta[c], c_pd[c]
    end
    local j_id, j_ed, j_debuff, j_h = s.j_id, s.j_ed, s.j_debuff, s.j_h
    local j_mult, j_x, j_ex, j_n = s.j_mult, s.j_x, s.j_ex, s.j_n
    local dyn = false
    for k = 1, nj do
        local id = j_id[k]
        P.j_id[k], P.j_ed[k], P.j_debuff[k], P.j_h[k] = id, j_ed[k], j_debuff[k], j_h[k]
        m.j_mult[k], m.j_x[k], m.j_ex[k], m.j_n[k] = j_mult[k], j_x[k], j_ex[k], j_n[k]
        if id == J_THROW or id == J_STENCIL or id == J_SWASH or id == J_STONE or id == J_STEEL or id == J_LICENSE or id == J_EROSION then dyn = true end
    end
    local n_playing = 0
    if dyn then
        local stones, steels, enh, alive = 0, 0, 0, 0
        local c_alive = s.c_alive
        for q = 1, s.n_cards do
            if c_alive[q] == 1 then
                alive = alive + 1
                local e = c_enh[q]
                if e ~= 0 then enh = enh + 1 end
                if e == E_STONE then stones = stones + 1 elseif e == E_STEEL then steels = steels + 1 end
            end
        end
        n_playing = alive
        for k = 1, nj do
            local id = j_id[k]
            if id == J_THROW then
                m.j_x[k] = 1 + s.skips * 0.25
            elseif id == J_STENCIL then
                local x = s.joker_limit - nj
                for q = 1, nj do
                    if j_id[q] == J_STENCIL then x = x + 1 end
                end
                m.j_x[k] = x
            elseif id == J_SWASH then
                local t = 0
                for q = 1, nj do
                    if q ~= k then t = t + joker_sell(s, q) end
                end
                m.j_mult[k] = t
            elseif id == J_STONE then
                m.j_n[k] = stones
            elseif id == J_STEEL then
                m.j_n[k] = steels
            elseif id == J_LICENSE then
                m.j_n[k] = enh
            end
        end
    end
    local h_level, h_chips, h_mult, h_played, h_pround, h_vis = s.h_level, s.h_chips, s.h_mult, s.h_played, s.h_pround, s.h_vis
    for h = 1, 12 do
        m.h_level[h], m.h_chips[h], m.h_mult[h] = h_level[h], h_chips[h], h_mult[h]
        m.h_played[h], m.h_pround[h], m.h_vis[h] = h_played[h], h_pround[h], h_vis[h]
    end
    local srng, hc, seed = s.rng, s.hcache, s.seed
    for i = 1, NK do
        local id = kids[i]
        local v = srng[id]
        m.rng_v[i - 1] = v == nil and -1 or v
        local h = hc[id]
        if not h then
            h = pseudohash(key_names[id] .. seed)
            hc[id] = h
        end
        P.rng_hc[i - 1] = h
    end
    m.money, m.dollar_buffer, m.consumable_buffer = s.money, s.dollar_buffer, s.consumable_buffer
    m.blind_triggered, m.blind_eye, m.blind_mouth = s.blind_triggered, s.blind_eye, s.blind_mouth
    local nc = s.n_cons
    local cons = s.cons
    for i = 1, nc do P.cons_hand[i] = PLANET_HAND[cons[i]] or 0 end
    local b = s.blind
    P.hashed_seed, P.hands_left, P.discards_left, P.hands_played, P.round_hands_played = s.hashed_seed, s.hands_left, s.discards_left, s.hands_played, s.round_hands_played
    P.blind, P.blind_disabled, P.blind_suit, P.most_played, P.prob = b, s.blind_disabled, s.blind_suit, s.most_played, s.prob
    P.blind_face = (b > 0 and BLINDS[b] and BLINDS[b].face) and 1 or 0
    P.n_cons, P.cons_limit, P.joker_limit, P.n_deck, P.starting_deck_size = nc, s.cons_limit, s.joker_limit, s.n_deck, s.starting_deck_size
    P.n_playing, P.tarot_used, P.chips_cap, P.plasma = n_playing, s.tarot_used, s.chips_cap, s.plasma
    P.observatory = s.used_v[V_OBS] == 1 and 1 or 0
    P.idol_rank, P.idol_suit, P.ancient_suit, P.next_uid = s.idol_rank, s.idol_suit, s.ancient_suit, s.next_uid
    P.nh0, P.n_jok = nh, nj
end

local lua_scan = PL.scan
local combos, forced_pos = PL.combos, PL.forced_pos
local BID = D.BLIND_ID
local SMALL_OK = {[BID.bl_eye] = true, [BID.bl_mouth] = true, [BID.bl_psychic] = true}
local find_joker = E.find_joker

local function wants_small(s)
    if s.n_hand < 5 or SMALL_OK[s.blind] then return true end
    return find_joker(s, J.half) or find_joker(s, J.square) or false
end

local function c_scan(s, ov, oc, fast, top)
    if s.n_hand > MAXH or s.n_jok > MAXJ or s.n_cons > MAXC then return lua_scan(s, ov, oc, fast, top) end
    local five = fast and not wants_small(s)
    top = top or PL.FAST_TOP
    if not (five and top > 0) then top = 0 end
    marshal(s)
    local n = L.bs_scan(P, forced_pos(s), five and 1 or 0, top, out_v, out_i)
    if n < 0 then return lua_scan(s, ov, oc, fast, top) end
    local list = combos(s.n_hand)
    for i = 1, n do
        ov[i] = out_v[i - 1]
        oc[i] = list[out_i[i - 1]]
    end
    for i = n + 1, #ov do ov[i], oc[i] = nil, nil end
    return n
end

M.on = true
M.lua_scan = lua_scan
M.c_scan = c_scan
M.path = path

function M.enable(on)
    PL.scan = on and c_scan or lua_scan
    M.active = on
end

M.enable(true)
return M
