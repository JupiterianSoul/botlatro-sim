#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAXH 16
#define MAXJ 32
#define MAXC 32
#define MAXID 256
#define NK 8
#define BS_VERSION 1

#define JOKER_LIST(X) \
    X(four_fingers) X(shortcut) X(smeared) X(pareidolia) X(splash) X(blueprint) X(brainstorm) \
    X(hiker) X(lucky_cat) X(wee) X(photograph) X(8_ball) X(idol) X(scary_face) X(smiley) X(ticket) \
    X(scholar) X(walkie_talkie) X(business) X(fibonacci) X(even_steven) X(odd_todd) X(greedy_joker) \
    X(lusty_joker) X(wrathful_joker) X(gluttenous_joker) X(rough_gem) X(onyx_agate) X(arrowhead) \
    X(bloodstone) X(ancient) X(triboulet) X(sock_and_buskin) X(hanging_chad) X(dusk) X(selzer) X(hack) \
    X(shoot_the_moon) X(baron) X(reserved_parking) X(raised_fist) X(mime) X(loyalty_card) \
    X(seeing_double) X(half) X(abstract) X(acrobat) X(mystic_summit) X(misprint) X(banner) X(stuntman) \
    X(matador) X(supernova) X(ceremonial) X(vagabond) X(superposition) X(seance) X(flower_pot) \
    X(square) X(runner) X(ice_cream) X(castle) X(blue_joker) X(erosion) X(stone) X(steel_joker) \
    X(bull) X(drivers_license) X(blackboard) X(stencil) X(swashbuckler) X(joker) X(trousers) \
    X(ride_the_bus) X(flash) X(popcorn) X(green_joker) X(red_card) X(fortune_teller) X(gros_michel) \
    X(cavendish) X(card_sharp) X(bootstraps) X(caino) X(space) X(midas_mask) X(vampire) X(todo_list) \
    X(dna) X(obelisk) X(baseball) X(hologram)

#define BLIND_LIST(X) X(bl_psychic) X(bl_eye) X(bl_mouth) X(bl_arm) X(bl_ox) X(bl_flint) X(bl_pillar) X(bl_final_leaf)

#define KEY_LIST(X) X(lucky_mult) X(lucky_money) X(8ball) X(business) X(bloodstone) X(parking) X(space) X(misprint)

#define ENUM_J(n) J_##n,
#define ENUM_B(n) B_##n,
#define ENUM_K(n) K_##n,
enum { JOKER_LIST(ENUM_J) NJ_NAMES };
enum { BLIND_LIST(ENUM_B) NB_NAMES };
enum { KEY_LIST(ENUM_K) NK_NAMES };
#define STR_(n) #n ","

typedef struct {
    double c_enh[MAXH + 2], c_bonus[MAXH + 2], c_debuff[MAXH + 2], c_pta[MAXH + 2], c_pdebuff[MAXH + 2];
    double j_mult[MAXJ + 1], j_x[MAXJ + 1], j_ex[MAXJ + 1], j_n[MAXJ + 1];
    double h_level[13], h_chips[13], h_mult[13], h_played[13], h_pround[13], h_vis[13];
    double rng_v[NK];
    double money, dollar_buffer, consumable_buffer, blind_triggered, blind_eye, blind_mouth;
    int n_hand;
} bs_mut;

typedef struct {
    bs_mut m;
    double c_rank[MAXH + 2], c_suit[MAXH + 2], c_osuit[MAXH + 2], c_ed[MAXH + 2], c_seal[MAXH + 2], c_uid[MAXH + 2];
    int hand[MAXH + 2];
    double j_id[MAXJ + 1], j_ed[MAXJ + 1], j_debuff[MAXJ + 1], j_h[MAXJ + 1];
    double cons_hand[MAXC + 1];
    double rng_hc[NK];
    double hashed_seed, hands_left, discards_left, hands_played, round_hands_played;
    double blind, blind_disabled, blind_suit, blind_face, most_played, prob;
    double n_cons, cons_limit, joker_limit, n_deck, starting_deck_size, n_playing, tarot_used;
    double chips_cap, plasma, observatory, idol_rank, idol_suit, ancient_suit, next_uid;
    int nh0, n_jok;
} bs_state;

typedef struct {
    int jid[NJ_NAMES];
    int bid[NB_NAMES];
    double type_hand[MAXID], t_mult[MAXID], t_chips[MAXID], rarity[MAXID];
    double loyalty_every, loyalty_x;
    double hs_chips[13], hs_mult[13], hl_chips[13], hl_mult[13];
} bs_static;

static bs_static G;
static int ind_play[MAXID], rep_play[MAXID], ind_hand[MAXID];

const char *bs_joker_names(void) { return JOKER_LIST(STR_); }
const char *bs_blind_names(void) { return BLIND_LIST(STR_); }
const char *bs_key_names(void) { return KEY_LIST(STR_); }
int bs_version(void) { return BS_VERSION * 100000 + (int)sizeof(bs_state); }
int bs_max_hand(void) { return MAXH; }
int bs_max_jokers(void) { return MAXJ; }
int bs_max_cons(void) { return MAXC; }
int bs_max_id(void) { return MAXID; }

#define JID(n) G.jid[J_##n]

void bs_init(const bs_static *st) {
    G = *st;
    memset(ind_play, 0, sizeof ind_play);
    memset(rep_play, 0, sizeof rep_play);
    memset(ind_hand, 0, sizeof ind_hand);
    int ip[] = {J_hiker, J_lucky_cat, J_wee, J_photograph, J_8_ball, J_idol, J_scary_face, J_smiley, J_ticket, J_scholar,
        J_walkie_talkie, J_business, J_fibonacci, J_even_steven, J_odd_todd, J_greedy_joker, J_lusty_joker, J_wrathful_joker,
        J_gluttenous_joker, J_rough_gem, J_onyx_agate, J_arrowhead, J_bloodstone, J_ancient, J_triboulet};
    for (unsigned i = 0; i < sizeof ip / sizeof ip[0]; i++) ind_play[G.jid[ip[i]]] = 1;
    int rp[] = {J_sock_and_buskin, J_hanging_chad, J_dusk, J_selzer, J_hack};
    for (unsigned i = 0; i < sizeof rp / sizeof rp[0]; i++) rep_play[G.jid[rp[i]]] = 1;
    int ih[] = {J_shoot_the_moon, J_baron, J_reserved_parking, J_raised_fist};
    for (unsigned i = 0; i < sizeof ih / sizeof ih[0]; i++) ind_hand[G.jid[ih[i]]] = 1;
}

enum { E_BONUS = 1, E_MULT, E_WILD, E_GLASS, E_STEEL, E_STONE, E_GOLD, E_LUCKY };
enum { ED_FOIL = 1, ED_HOLO, ED_POLY };
enum { SEAL_GOLD = 1, SEAL_RED };
static const double ENH_BONUS[9] = {0, 30, 0, 0, 0, 0, 50, 0, 0};
static const double ENH_MULT[9] = {0, 0, 4, 0, 0, 0, 0, 0, 20};
static const double NOMINAL[15] = {0, 0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 10, 10, 11};
static const double SN[5] = {0, 0.04, 0.03, 0.02, 0.01};
static const double SO[5] = {0, 0.004, 0.003, 0.002, 0.001};

static inline double lmod(double a, double b) { return a - floor(a / b) * b; }

static uint64_t R[4];

static inline uint64_t rstep(void) {
    uint64_t z, r;
    z = R[0];
    z = (((z << 31) ^ z) >> 45) ^ ((z & (~0ULL << 1)) << 18);
    r = z;
    R[0] = z;
    z = R[1];
    z = (((z << 19) ^ z) >> 30) ^ ((z & (~0ULL << 6)) << 28);
    r ^= z;
    R[1] = z;
    z = R[2];
    z = (((z << 24) ^ z) >> 48) ^ ((z & (~0ULL << 9)) << 7);
    r ^= z;
    R[2] = z;
    z = R[3];
    z = (((z << 21) ^ z) >> 39) ^ ((z & (~0ULL << 17)) << 8);
    r ^= z;
    R[3] = z;
    return (r & 0x000fffffffffffffULL) | 0x3ff0000000000000ULL;
}

static inline uint64_t d2u(double d) { uint64_t u; memcpy(&u, &d, 8); return u; }
static inline double u2d(uint64_t u) { double d; memcpy(&d, &u, 8); return d; }

static void rseed(double d) {
    static const uint64_t lo[4] = {2ULL, 64ULL, 512ULL, 131072ULL};
    for (int i = 0; i < 4; i++) {
        d = d * 3.14159265358979323846 + 2.7182818284590452354;
        uint64_t u = d2u(d);
        if (u < lo[i]) u += lo[i];
        R[i] = u;
    }
    for (int i = 0; i < 10; i++) rstep();
}

static inline double rrand(void) { return u2d(rstep()) - 1.0; }

static double round13(double x) {
    double p = x * 1e13;
    double fl = floor(p);
    double f = p - fl;
    if (f > 0.49 && f < 0.51) {
        char b[64];
        snprintf(b, sizeof b, "%.13f", x);
        return fabs(strtod(b, NULL));
    }
    if (f >= 0.5) fl = fl + 1;
    return fl / 1e13;
}

static double seed_by(bs_state *s, int k) {
    double v = s->m.rng_v[k];
    if (v < 0) v = s->rng_hc[k];
    v = round13(lmod(2.134453429141 + v * 1.72431234, 1));
    s->m.rng_v[k] = v;
    return (v + s->hashed_seed) / 2;
}

static double random_k(bs_state *s, int k) {
    rseed(seed_by(s, k));
    return rrand();
}

static double random_int_k(bs_state *s, int k, double lo, double hi) {
    rseed(seed_by(s, k));
    double d = rrand();
    return floor(d * (hi - lo + 1.0)) + lo;
}

static int present[13], scoring[8];
static int fl_[8], st_[8], flush_ok[8], ranks[8], cnt[16];

static inline int is_suit_flush(const bs_state *s, int cid, int suit, int smeared) {
    if (s->m.c_enh[cid] == E_STONE) return 0;
    if (s->m.c_enh[cid] == E_WILD && s->m.c_debuff[cid] == 0) return 1;
    int cs = (int)s->c_suit[cid];
    if (smeared && ((cs == 2 || cs == 4) == (suit == 2 || suit == 4))) return 1;
    return cs == suit;
}

static inline double nominal_key(const bs_state *s, int cid) {
    int r = (int)s->c_rank[cid];
    double m = 1;
    if (s->m.c_enh[cid] == E_STONE) m = -1000;
    double sn = SN[(int)s->c_suit[cid]];
    double so = SO[(int)s->c_osuit[cid]];
    double nom = r == 14 ? 11 : (r > 10 ? 10 : r);
    double face = r == 11 ? 0.1 : r == 12 ? 0.2 : r == 13 ? 0.3 : r == 14 ? 0.4 : 0;
    return nom + sn * m + so * 0.0001 * m + face;
}

static inline int nominal_greater(const bs_state *s, int a, int b) {
    double ka = nominal_key(s, a), kb = nominal_key(s, b);
    if (ka != kb) return ka > kb;
    return s->c_uid[a] < s->c_uid[b];
}

static int evaluate(const bs_state *s, const int *cards, int n, int four, int shortcut, int smeared, int splash) {
    for (int i = 1; i <= 12; i++) present[i] = 0;
    for (int r = 2; r <= 14; r++) cnt[r] = 0;
    for (int i = 1; i <= n; i++) {
        int cid = cards[i];
        scoring[i] = 0;
        fl_[i] = 0;
        st_[i] = 0;
        if (s->m.c_enh[cid] == E_STONE) {
            ranks[i] = 0;
        } else {
            int r = (int)s->c_rank[cid];
            ranks[i] = r;
            cnt[r]++;
        }
    }
    int r5 = 0, r4 = 0, r3 = 0, r2a = 0, r2b = 0, n2 = 0;
    for (int r = 14; r >= 2; r--) {
        int c = cnt[r];
        if (c == 5) r5 = r;
        else if (c == 4) { if (r4 == 0) r4 = r; }
        else if (c == 3) { if (r3 == 0) r3 = r; }
        else if (c == 2) {
            n2++;
            if (r2a == 0) r2a = r; else if (r2b == 0) r2b = r;
        }
    }
    int need = four ? 4 : 5;
    int has_flush = 0;
    if (n <= 5 && n >= need) {
        for (int suit = 1; suit <= 4; suit++) {
            int fc = 0;
            for (int i = 1; i <= n; i++) {
                int ok = is_suit_flush(s, cards[i], suit, smeared);
                flush_ok[i] = ok;
                if (ok) fc++;
            }
            if (fc >= need) {
                has_flush = 1;
                for (int i = 1; i <= n; i++) fl_[i] = flush_ok[i];
                break;
            }
        }
    }
    int has_straight = 0;
    if (n <= 5 && n >= need) {
        int len = 0, skipped = 0;
        for (int j = 1; j <= 14; j++) {
            int r = j == 1 ? 14 : j;
            if (cnt[r] > 0) {
                len++;
                skipped = 0;
                for (int i = 1; i <= n; i++) if (ranks[i] == r) st_[i] = 1;
            } else if (shortcut && !skipped && j != 14) {
                skipped = 1;
            } else {
                len = 0;
                skipped = 0;
                if (!has_straight) for (int i = 1; i <= n; i++) st_[i] = 0;
                if (has_straight) break;
            }
            if (len >= need) has_straight = 1;
        }
        if (!has_straight) for (int i = 1; i <= n; i++) st_[i] = 0;
    }
    int p5 = r5 > 0, p4 = r4 > 0, p3 = r3 > 0, p2 = n2 > 0;
    if (p5 && has_flush) present[1] = 1;
    if (p3 && p2 && has_flush) present[2] = 1;
    if (p5) present[3] = 1;
    if (has_flush && has_straight) present[4] = 1;
    if (p4 || p5) present[5] = 1;
    if (p3 && p2) present[6] = 1;
    if (has_flush) present[7] = 1;
    if (has_straight) present[8] = 1;
    if (p3 || present[5]) present[9] = 1;
    if (n2 == 2 || (r3 > 0 && n2 == 1)) present[10] = 1;
    if (p2 || present[9]) present[11] = 1;
    if (n > 0) present[12] = 1;
    int top;
    if (present[1]) {
        top = 1;
        for (int i = 1; i <= n; i++) scoring[i] = ranks[i] == r5;
    } else if (present[2]) {
        top = 2;
        for (int i = 1; i <= n; i++) scoring[i] = ranks[i] == r3 || ranks[i] == r2a;
    } else if (p5) {
        top = 3;
        for (int i = 1; i <= n; i++) scoring[i] = ranks[i] == r5;
    } else if (present[4]) {
        top = 4;
        for (int i = 1; i <= n; i++) scoring[i] = fl_[i] || st_[i];
    } else if (p4) {
        top = 5;
        for (int i = 1; i <= n; i++) scoring[i] = ranks[i] == r4;
    } else if (present[6]) {
        top = 6;
        for (int i = 1; i <= n; i++) scoring[i] = ranks[i] == r3 || ranks[i] == r2a;
    } else if (has_flush) {
        top = 7;
        for (int i = 1; i <= n; i++) scoring[i] = fl_[i];
    } else if (has_straight) {
        top = 8;
        for (int i = 1; i <= n; i++) scoring[i] = st_[i];
    } else if (p3) {
        top = 9;
        for (int i = 1; i <= n; i++) scoring[i] = ranks[i] == r3;
    } else if (present[10]) {
        top = 10;
        int rb = r2b > 0 ? r2b : r3;
        for (int i = 1; i <= n; i++) scoring[i] = ranks[i] == r2a || ranks[i] == rb;
    } else if (p2) {
        top = 11;
        for (int i = 1; i <= n; i++) scoring[i] = ranks[i] == r2a;
    } else if (n > 0) {
        top = 12;
        int best = 1;
        for (int i = 2; i <= n; i++) if (nominal_greater(s, cards[i], cards[best])) best = i;
        scoring[best] = 1;
    } else {
        return 0;
    }
    if (splash) {
        for (int i = 1; i <= n; i++) scoring[i] = 1;
    } else {
        for (int i = 1; i <= n; i++) if (s->m.c_enh[cards[i]] == E_STONE) scoring[i] = 1;
    }
    return top;
}

static inline int find_joker(const bs_state *s, int id) {
    for (int k = 1; k <= s->n_jok; k++) if (s->j_id[k] == id && s->j_debuff[k] == 0) return 1;
    return 0;
}

static inline double get_id(const bs_state *s, int cid) {
    if (s->m.c_enh[cid] == E_STONE) return -1;
    return s->c_rank[cid];
}

static inline int is_face(const bs_state *s, int cid, int from_boss, int pareidolia) {
    if (s->m.c_debuff[cid] == 1 && !from_boss) return 0;
    if (s->m.c_enh[cid] != E_STONE) {
        double r = s->c_rank[cid];
        if (r == 11 || r == 12 || r == 13) return 1;
    }
    return pareidolia;
}

static inline int is_suit(const bs_state *s, int cid, double suit, int bypass, int smeared) {
    if (s->m.c_debuff[cid] == 1 && !bypass) return 0;
    double e = s->m.c_enh[cid];
    if (e == E_STONE) return 0;
    if (e == E_WILD) return 1;
    double cs = s->c_suit[cid];
    if (smeared && ((cs == 2 || cs == 4) == (suit == 2 || suit == 4))) return 1;
    return cs == suit;
}

static inline double card_chips(const bs_state *s, int cid) {
    if (s->m.c_debuff[cid] == 1) return 0;
    int e = (int)s->m.c_enh[cid];
    if (e == E_STONE) return ENH_BONUS[e] + s->m.c_bonus[cid];
    return NOMINAL[(int)s->c_rank[cid]] + ENH_BONUS[e] + s->m.c_bonus[cid];
}

static void level_up(bs_state *s, int h, double amount) {
    double lv = fmax(0, s->m.h_level[h] + amount);
    s->m.h_level[h] = lv;
    s->m.h_mult[h] = fmax(G.hs_mult[h] + G.hl_mult[h] * (lv - 1), 1);
    s->m.h_chips[h] = fmax(G.hs_chips[h] + G.hl_chips[h] * (lv - 1), 0);
}

static void blind_debuff_card(bs_state *s, int cid) {
    double b = s->blind;
    if (s->blind_disabled == 0 && b > 0) {
        if (s->blind_suit > 0 && is_suit(s, cid, s->blind_suit, 1, find_joker(s, JID(smeared)))) {
            s->m.c_debuff[cid] = 1;
            return;
        }
        if (s->blind_face != 0 && is_face(s, cid, 1, find_joker(s, JID(pareidolia)))) {
            s->m.c_debuff[cid] = 1;
            return;
        }
        if (b == G.bid[B_bl_pillar] && s->m.c_pta[cid] == 1) {
            s->m.c_debuff[cid] = 1;
            return;
        }
        if (b == G.bid[B_bl_final_leaf]) {
            s->m.c_debuff[cid] = 1;
            return;
        }
    }
    s->m.c_debuff[cid] = s->m.c_pdebuff[cid];
}

static inline int cons_free(const bs_state *s) { return s->n_cons + s->m.consumable_buffer < s->cons_limit; }

static int debuff_hand(bs_state *s, int n, int text) {
    if (s->blind_disabled == 1) return 0;
    double b = s->blind;
    s->m.blind_triggered = 0;
    if (b == G.bid[B_bl_psychic] && n < 5) {
        s->m.blind_triggered = 1;
        return 1;
    }
    if (b == G.bid[B_bl_eye]) {
        double bit = pow(2, text);
        if (lmod(floor(s->m.blind_eye / bit), 2) == 1) {
            s->m.blind_triggered = 1;
            return 1;
        }
        s->m.blind_eye = s->m.blind_eye + bit;
    }
    if (b == G.bid[B_bl_mouth]) {
        if (s->m.blind_mouth > 0 && s->m.blind_mouth != text) {
            s->m.blind_triggered = 1;
            return 1;
        }
        s->m.blind_mouth = text;
    }
    if (b == G.bid[B_bl_arm]) {
        s->m.blind_triggered = 0;
        if (s->m.h_level[text] > 1) {
            s->m.blind_triggered = 1;
            level_up(s, text, -1);
        }
    }
    if (b == G.bid[B_bl_ox]) {
        s->m.blind_triggered = 0;
        if (text == s->most_played) {
            s->m.blind_triggered = 1;
            s->m.money = 0;
        }
    }
    return 0;
}

static int sc_buf[8], eff_k[MAXJ + 1], eff_bp[MAXJ + 1];
static int smeared_, pareidolia_, lucky_;
static double tmp2[MAXJ + 1];
static int tmpi[MAXJ + 1];

static void resolve_blueprints(const bs_state *s) {
    int nj = s->n_jok;
    for (int k = 1; k <= nj; k++) {
        int cur = k, bp = 0, res = 0;
        if (s->j_debuff[k] == 0) {
            res = k;
            int hops = 0;
            for (;;) {
                double id = s->j_id[cur];
                int other;
                if (id == JID(blueprint)) other = cur + 1;
                else if (id == JID(brainstorm)) other = 1;
                else break;
                if (other > nj || other == cur) { res = 0; break; }
                hops++;
                if (hops > nj + 1) { res = 0; break; }
                if (s->j_debuff[other] == 1) { res = 0; break; }
                cur = other;
                bp = 1;
                res = cur;
            }
        }
        eff_k[k] = res;
        eff_bp[k] = bp;
    }
}

typedef struct { double c, m, x, d; } fx4;

static fx4 joker_individual_play(bs_state *s, int ek, int bp, int cid, int ns) {
    fx4 z = {0, 0, 0, 0};
    double id = s->j_id[ek];
    int smeared = smeared_, pareidolia = pareidolia_;
    double prob = s->prob;
    if (id == JID(hiker)) {
        s->m.c_bonus[cid] = s->m.c_bonus[cid] + 5;
        return z;
    } else if (id == JID(lucky_cat)) {
        if (!bp && lucky_ == 1) s->m.j_x[ek] = s->m.j_x[ek] + 0.25;
        return z;
    } else if (id == JID(wee)) {
        if (!bp && get_id(s, cid) == 2) s->m.j_ex[ek] = s->m.j_ex[ek] + 8;
        return z;
    } else if (id == JID(photograph)) {
        int first = 0;
        for (int i = 1; i <= ns; i++) if (is_face(s, sc_buf[i], 0, pareidolia)) { first = sc_buf[i]; break; }
        if (cid == first) z.x = 2;
    } else if (id == JID(8_ball)) {
        if (cons_free(s) && get_id(s, cid) == 8 && random_k(s, K_8ball) < prob / 4) {
            s->m.consumable_buffer = s->m.consumable_buffer + 1;
        }
    } else if (id == JID(idol)) {
        if (get_id(s, cid) == s->idol_rank && is_suit(s, cid, s->idol_suit, 0, smeared)) z.x = 2;
    } else if (id == JID(scary_face)) {
        if (is_face(s, cid, 0, pareidolia)) z.c = 30;
    } else if (id == JID(smiley)) {
        if (is_face(s, cid, 0, pareidolia)) z.m = 5;
    } else if (id == JID(ticket)) {
        if (s->m.c_enh[cid] == E_GOLD) z.d = 4;
    } else if (id == JID(scholar)) {
        if (get_id(s, cid) == 14) { z.c = 20; z.m = 4; }
    } else if (id == JID(walkie_talkie)) {
        double r = get_id(s, cid);
        if (r == 10 || r == 4) { z.c = 10; z.m = 4; }
    } else if (id == JID(business)) {
        if (is_face(s, cid, 0, pareidolia) && random_k(s, K_business) < prob / 2) z.d = 2;
    } else if (id == JID(fibonacci)) {
        double r = get_id(s, cid);
        if (r == 2 || r == 3 || r == 5 || r == 8 || r == 14) z.m = 8;
    } else if (id == JID(even_steven)) {
        double r = get_id(s, cid);
        if (r <= 10 && r >= 0 && lmod(r, 2) == 0) z.m = 4;
    } else if (id == JID(odd_todd)) {
        double r = get_id(s, cid);
        if ((r <= 10 && r >= 0 && lmod(r, 2) == 1) || r == 14) z.c = 31;
    } else if (id == JID(greedy_joker)) {
        if (is_suit(s, cid, 4, 0, smeared)) z.m = 3;
    } else if (id == JID(lusty_joker)) {
        if (is_suit(s, cid, 2, 0, smeared)) z.m = 3;
    } else if (id == JID(wrathful_joker)) {
        if (is_suit(s, cid, 1, 0, smeared)) z.m = 3;
    } else if (id == JID(gluttenous_joker)) {
        if (is_suit(s, cid, 3, 0, smeared)) z.m = 3;
    } else if (id == JID(rough_gem)) {
        if (is_suit(s, cid, 4, 0, smeared)) z.d = 1;
    } else if (id == JID(onyx_agate)) {
        if (is_suit(s, cid, 3, 0, smeared)) z.m = 7;
    } else if (id == JID(arrowhead)) {
        if (is_suit(s, cid, 1, 0, smeared)) z.c = 50;
    } else if (id == JID(bloodstone)) {
        if (is_suit(s, cid, 2, 0, smeared) && random_k(s, K_bloodstone) < prob / 2) z.x = 1.5;
    } else if (id == JID(ancient)) {
        if (is_suit(s, cid, s->ancient_suit, 0, smeared)) z.x = 1.5;
    } else if (id == JID(triboulet)) {
        double r = get_id(s, cid);
        if (r == 12 || r == 13) z.x = 2;
    }
    return z;
}

static void suit_counts_flower(const bs_state *s, int ns, int *h, int *d, int *sp, int *cl) {
    int smeared = smeared_;
    for (int i = 1; i <= ns; i++) {
        int cid = sc_buf[i];
        if (s->m.c_enh[cid] != E_WILD) {
            if (is_suit(s, cid, 2, 1, smeared) && *h == 0) *h = 1;
            else if (is_suit(s, cid, 4, 1, smeared) && *d == 0) *d = 1;
            else if (is_suit(s, cid, 1, 1, smeared) && *sp == 0) *sp = 1;
            else if (is_suit(s, cid, 3, 1, smeared) && *cl == 0) *cl = 1;
        }
    }
    for (int i = 1; i <= ns; i++) {
        int cid = sc_buf[i];
        if (s->m.c_enh[cid] == E_WILD) {
            if (is_suit(s, cid, 2, 0, smeared) && *h == 0) *h = 1;
            else if (is_suit(s, cid, 4, 0, smeared) && *d == 0) *d = 1;
            else if (is_suit(s, cid, 1, 0, smeared) && *sp == 0) *sp = 1;
            else if (is_suit(s, cid, 3, 0, smeared) && *cl == 0) *cl = 1;
        }
    }
}

static void joker_main(bs_state *s, int ek, int text, int n_full, int ns, double *oc, double *om, double *ox) {
    double id = s->j_id[ek];
    int iid = (int)id;
    *oc = 0; *om = 0; *ox = 0;
    if (id == JID(loyalty_card)) {
        double every = G.loyalty_every;
        double rem = lmod(every - 1 - (s->hands_played - s->j_h[ek]), every + 1);
        s->m.j_n[ek] = rem;
        if (rem == every) *ox = G.loyalty_x;
        return;
    }
    int th = (int)G.type_hand[iid];
    if (id != JID(seeing_double) && s->m.j_x[ek] > 1 && (th == 0 || present[th])) { *ox = s->m.j_x[ek]; return; }
    if (G.t_mult[iid] > 0 && th > 0 && present[th]) { *om = G.t_mult[iid]; return; }
    if (G.t_chips[iid] > 0 && th > 0 && present[th]) { *oc = G.t_chips[iid]; return; }
    if (id == JID(half)) {
        if (n_full <= 3) *om = 20;
    } else if (id == JID(abstract)) {
        *om = s->n_jok * 3;
    } else if (id == JID(acrobat)) {
        if (s->hands_left == 0) *ox = 3;
    } else if (id == JID(mystic_summit)) {
        if (s->discards_left == 0) *om = 15;
    } else if (id == JID(misprint)) {
        *om = random_int_k(s, K_misprint, 0, 23);
    } else if (id == JID(banner)) {
        if (s->discards_left > 0) *oc = s->discards_left * 30;
    } else if (id == JID(stuntman)) {
        *oc = 250;
    } else if (id == JID(matador)) {
        if (s->m.blind_triggered == 1) s->m.dollar_buffer = s->m.dollar_buffer + 8;
    } else if (id == JID(supernova)) {
        *om = s->m.h_played[text];
    } else if (id == JID(ceremonial)) {
        if (s->m.j_mult[ek] > 0) *om = s->m.j_mult[ek];
    } else if (id == JID(vagabond)) {
        if (cons_free(s) && s->m.money <= 4) s->m.consumable_buffer = s->m.consumable_buffer + 1;
    } else if (id == JID(superposition)) {
        if (cons_free(s)) {
            int aces = 0;
            for (int i = 1; i <= ns; i++) if (get_id(s, sc_buf[i]) == 14) aces++;
            if (aces >= 1 && present[8]) s->m.consumable_buffer = s->m.consumable_buffer + 1;
        }
    } else if (id == JID(seance)) {
        if (cons_free(s) && present[4]) s->m.consumable_buffer = s->m.consumable_buffer + 1;
    } else if (id == JID(flower_pot)) {
        int h = 0, d = 0, sp = 0, cl = 0;
        suit_counts_flower(s, ns, &h, &d, &sp, &cl);
        if (h > 0 && d > 0 && sp > 0 && cl > 0) *ox = 3;
    } else if (id == JID(seeing_double)) {
        int h = 0, d = 0, sp = 0, cl = 0;
        int smeared = smeared_;
        for (int i = 1; i <= ns; i++) {
            int cid = sc_buf[i];
            if (s->m.c_enh[cid] != E_WILD) {
                if (is_suit(s, cid, 2, 0, smeared)) h++;
                if (is_suit(s, cid, 4, 0, smeared)) d++;
                if (is_suit(s, cid, 1, 0, smeared)) sp++;
                if (is_suit(s, cid, 3, 0, smeared)) cl++;
            }
        }
        for (int i = 1; i <= ns; i++) {
            int cid = sc_buf[i];
            if (s->m.c_enh[cid] == E_WILD) {
                if (is_suit(s, cid, 3, 0, smeared) && cl == 0) cl++;
                else if (is_suit(s, cid, 4, 0, smeared) && d == 0) d++;
                else if (is_suit(s, cid, 1, 0, smeared) && sp == 0) sp++;
                else if (is_suit(s, cid, 2, 0, smeared) && h == 0) h++;
            }
        }
        if ((h > 0 || d > 0 || sp > 0) && cl > 0) *ox = 2;
    } else if (id == JID(wee) || id == JID(square) || id == JID(runner) || id == JID(ice_cream)) {
        *oc = s->m.j_ex[ek];
    } else if (id == JID(castle)) {
        if (s->m.j_ex[ek] > 0) *oc = s->m.j_ex[ek];
    } else if (id == JID(blue_joker)) {
        if (s->n_deck > 0) *oc = 2 * s->n_deck;
    } else if (id == JID(erosion)) {
        double d = s->starting_deck_size - s->n_playing;
        if (d > 0) *om = 4 * d;
    } else if (id == JID(stone)) {
        double t = s->m.j_n[ek];
        if (t > 0) *oc = 25 * t;
    } else if (id == JID(steel_joker)) {
        double t = s->m.j_n[ek];
        if (t > 0) *ox = 1 + 0.2 * t;
    } else if (id == JID(bull)) {
        double m = s->m.money + s->m.dollar_buffer;
        if (m > 0) *oc = 2 * fmax(0, m);
    } else if (id == JID(drivers_license)) {
        if (s->m.j_n[ek] >= 16) *ox = 3;
    } else if (id == JID(blackboard)) {
        int black = 0, all = 0;
        for (int i = 1; i <= s->m.n_hand; i++) {
            all++;
            int cid = s->hand[i];
            if (is_suit_flush(s, cid, 3, smeared_) || is_suit_flush(s, cid, 1, smeared_)) black++;
        }
        if (black == all) *ox = 3;
    } else if (id == JID(stencil)) {
        if (s->joker_limit - s->n_jok > 0) *ox = s->m.j_x[ek];
    } else if (id == JID(swashbuckler) || id == JID(joker) || id == JID(trousers) || id == JID(ride_the_bus) || id == JID(flash)
               || id == JID(popcorn) || id == JID(green_joker) || id == JID(red_card)) {
        if (s->m.j_mult[ek] > 0) *om = s->m.j_mult[ek];
    } else if (id == JID(fortune_teller)) {
        if (s->tarot_used > 0) *om = s->tarot_used;
    } else if (id == JID(gros_michel)) {
        *om = 15;
    } else if (id == JID(cavendish)) {
        *ox = 3;
    } else if (id == JID(card_sharp)) {
        if (s->m.h_pround[text] > 1) *ox = 3;
    } else if (id == JID(bootstraps)) {
        double m = floor((s->m.money + s->m.dollar_buffer) / 5);
        if (m >= 1) *om = 2 * m;
    } else if (id == JID(caino)) {
        if (s->m.j_n[ek] > 1) *ox = s->m.j_n[ek];
    }
}

static void remove_hand_pos(bs_state *s, const int *pos, int n) {
    int keep[MAXH + 2], nk = 0, k = 1;
    for (int i = 1; i <= s->nh0; i++) {
        if (k <= n && pos[k] == i) { k++; continue; }
        keep[++nk] = i;
    }
    for (int i = 1; i <= nk; i++) s->hand[i] = keep[i];
    s->m.n_hand = nk;
}

static double play_eval(bs_state *s, const int *cards, int n, int four, int shortcut, int splash) {
    int smeared = smeared_, pareidolia = pareidolia_;
    int text = evaluate(s, cards, n, four, shortcut, smeared, splash);
    int ns = 0;
    for (int i = 1; i <= n; i++) if (scoring[i]) sc_buf[++ns] = cards[i];
    s->m.h_played[text] += 1;
    s->m.h_pround[text] += 1;
    s->m.h_vis[text] = 1;
    int nj = s->n_jok;
    double chips = 0, mult = 0;
    double prob = s->prob;
    if (debuff_hand(s, n, text)) return 0;
    for (int k = 1; k <= nj; k++) {
        int ek = eff_k[k];
        if (ek <= 0) continue;
        double id = s->j_id[ek];
        int bp = eff_bp[k] == 1;
        if (id == JID(trousers) && !bp) {
            if (present[10] || present[6]) s->m.j_mult[ek] += 2;
        } else if (id == JID(space)) {
            if (random_k(s, K_space) < prob / 4) level_up(s, text, 1);
        } else if (id == JID(square) && !bp) {
            if (n == 4) s->m.j_ex[ek] += 4;
        } else if (id == JID(runner) && !bp) {
            if (present[8]) s->m.j_ex[ek] += 15;
        } else if (id == JID(midas_mask) && !bp) {
            for (int i = 1; i <= ns; i++) {
                int cid = sc_buf[i];
                if (is_face(s, cid, 0, pareidolia)) {
                    s->m.c_enh[cid] = E_GOLD;
                    s->m.c_pta[cid] = 0;
                    s->m.c_pdebuff[cid] = 0;
                    blind_debuff_card(s, cid);
                }
            }
        } else if (id == JID(vampire) && !bp) {
            int c = 0;
            for (int i = 1; i <= ns; i++) {
                int cid = sc_buf[i];
                if (s->m.c_enh[cid] != 0 && s->m.c_debuff[cid] == 0) {
                    c++;
                    s->m.c_enh[cid] = 0;
                    s->m.c_pta[cid] = 0;
                    s->m.c_pdebuff[cid] = 0;
                    blind_debuff_card(s, cid);
                }
            }
            if (c > 0) s->m.j_x[ek] = s->m.j_x[ek] + 0.1 * c;
        } else if (id == JID(todo_list)) {
            if (text == s->m.j_n[ek]) s->m.dollar_buffer = s->m.dollar_buffer + 4;
        } else if (id == JID(dna)) {
            if (s->round_hands_played == 0 && n == 1) {
                int src = cards[1];
                int cid = s->nh0 + 1;
                s->c_rank[cid] = s->c_rank[src];
                s->c_suit[cid] = s->c_suit[src];
                s->c_osuit[cid] = s->c_osuit[src];
                s->m.c_enh[cid] = s->m.c_enh[src];
                s->c_ed[cid] = s->c_ed[src];
                s->c_seal[cid] = s->c_seal[src];
                s->m.c_bonus[cid] = s->m.c_bonus[src];
                s->c_uid[cid] = s->next_uid + 1;
                s->m.c_pta[cid] = s->m.c_pta[src];
                s->m.c_pdebuff[cid] = s->m.c_pdebuff[src];
                s->m.c_debuff[cid] = 0;
                blind_debuff_card(s, cid);
                s->m.n_hand++;
                s->hand[s->m.n_hand] = cid;
                for (int q = 1; q <= nj; q++)
                    if (s->j_id[q] == JID(hologram) && s->j_debuff[q] == 0) s->m.j_x[q] = s->m.j_x[q] + 1 * 0.25;
            }
        } else if (id == JID(ride_the_bus) && !bp) {
            int faces = 0;
            for (int i = 1; i <= ns; i++) if (is_face(s, sc_buf[i], 0, pareidolia)) faces = 1;
            if (faces) s->m.j_mult[ek] = 0; else s->m.j_mult[ek] += 1;
        } else if (id == JID(obelisk) && !bp) {
            int reset = 1;
            double pm = s->m.h_played[text];
            for (int h = 1; h <= 12; h++) if (h != text && s->m.h_played[h] >= pm && s->m.h_vis[h] == 1) reset = 0;
            if (reset) {
                if (s->m.j_x[ek] > 1) s->m.j_x[ek] = 1;
            } else {
                s->m.j_x[ek] = s->m.j_x[ek] + 0.2;
            }
        } else if (id == JID(green_joker) && !bp) {
            s->m.j_mult[ek] += 1;
        }
    }
    mult = s->m.h_mult[text];
    chips = s->m.h_chips[text];
    if (s->blind == G.bid[B_bl_flint] && s->blind_disabled == 0) {
        s->m.blind_triggered = 1;
        mult = fmax(floor(mult * 0.5 + 0.5), 1);
        chips = fmax(floor(chips * 0.5 + 0.5), 0);
    }
    for (int i = 1; i <= ns; i++) {
        int cid = sc_buf[i];
        if (s->m.c_debuff[cid] == 1) {
            s->m.blind_triggered = 1;
            continue;
        }
        int reps = 1;
        if (s->c_seal[cid] == SEAL_RED) reps++;
        for (int k = 1; k <= nj; k++) {
            int ek = eff_k[k];
            if (ek <= 0) continue;
            double id = s->j_id[ek];
            if (!rep_play[(int)id]) continue;
            if (id == JID(sock_and_buskin)) {
                if (is_face(s, cid, 0, pareidolia)) reps++;
            } else if (id == JID(hanging_chad)) {
                if (cid == sc_buf[1]) reps += 2;
            } else if (id == JID(dusk)) {
                if (s->hands_left == 0) reps++;
            } else if (id == JID(selzer)) {
                reps++;
            } else if (id == JID(hack)) {
                double r = get_id(s, cid);
                if (r == 2 || r == 3 || r == 4 || r == 5) reps++;
            }
        }
        for (int rep = 0; rep < reps; rep++) {
            int e = (int)s->m.c_enh[cid];
            int lucky = 0;
            if (s->m.c_debuff[cid] != 0) continue;
            double cc = card_chips(s, cid);
            double cm = ENH_MULT[e];
            if (e == E_LUCKY) {
                if (random_k(s, K_lucky_mult) < prob / 5) lucky = 1; else cm = 0;
            }
            double cx = 0;
            if (e == E_GLASS) cx = 2;
            double pd = 0;
            if (s->c_seal[cid] == SEAL_GOLD) pd = pd + 3;
            if (e == E_LUCKY) {
                if (random_k(s, K_lucky_money) < prob / 15) {
                    lucky = 1;
                    pd = pd + 20;
                }
            }
            lucky_ = lucky;
            if (cc > 0) chips = chips + cc;
            if (cm > 0) mult = mult + cm;
            if (pd > 0) s->m.dollar_buffer = s->m.dollar_buffer + pd;
            if (cx > 0) mult = mult * cx;
            double ed = s->c_ed[cid];
            if (ed == ED_FOIL) chips = chips + 50;
            else if (ed == ED_HOLO) mult = mult + 10;
            else if (ed == ED_POLY) mult = mult * 1.5;
            for (int k = 1; k <= nj; k++) {
                int ek = eff_k[k];
                if (ek > 0 && ind_play[(int)s->j_id[ek]]) {
                    fx4 f = joker_individual_play(s, ek, eff_bp[k] == 1, cid, ns);
                    if (f.c != 0) chips = chips + f.c;
                    if (f.m != 0) mult = mult + f.m;
                    if (f.d != 0) s->m.dollar_buffer = s->m.dollar_buffer + f.d;
                    if (f.x != 0) mult = mult * f.x;
                }
            }
        }
    }
    int nh = s->m.n_hand;
    for (int i = 1; i <= nh; i++) {
        int cid = s->hand[i];
        int reps = 1;
        for (int j = 1; j <= reps; j++) {
            double hx = 0;
            if (s->m.c_debuff[cid] == 0 && s->m.c_enh[cid] == E_STEEL) hx = 1.5;
            int any = hx > 0;
            int nfx = 0;
            for (int k = 1; k <= nj; k++) {
                int ek = eff_k[k];
                if (ek <= 0 || !ind_hand[(int)s->j_id[ek]]) continue;
                double id = s->j_id[ek];
                double r = get_id(s, cid);
                if (id == JID(shoot_the_moon)) {
                    if (r == 12) {
                        nfx++;
                        if (s->m.c_debuff[cid] == 0) { tmpi[nfx] = 1; tmp2[nfx] = 13; } else tmpi[nfx] = 0;
                    }
                } else if (id == JID(baron)) {
                    if (r == 13) {
                        nfx++;
                        if (s->m.c_debuff[cid] == 0) { tmpi[nfx] = 2; tmp2[nfx] = 1.5; } else tmpi[nfx] = 0;
                    }
                } else if (id == JID(reserved_parking)) {
                    if (is_face(s, cid, 0, pareidolia) && random_k(s, K_parking) < prob / 2) {
                        nfx++;
                        if (s->m.c_debuff[cid] == 0) { tmpi[nfx] = 3; tmp2[nfx] = 1; } else tmpi[nfx] = 0;
                    }
                } else if (id == JID(raised_fist)) {
                    double tm = 15, tid = 15;
                    int rc = 0;
                    for (int q = 1; q <= nh; q++) {
                        int qc = s->hand[q];
                        if (tid >= s->c_rank[qc] && s->m.c_enh[qc] != E_STONE) {
                            tm = NOMINAL[(int)s->c_rank[qc]];
                            tid = s->c_rank[qc];
                            rc = qc;
                        }
                    }
                    if (rc == cid) {
                        nfx++;
                        if (s->m.c_debuff[cid] == 0) { tmpi[nfx] = 1; tmp2[nfx] = 2 * tm; } else tmpi[nfx] = 0;
                    }
                }
            }
            if (j == 1 && (any || nfx > 0)) {
                if (s->m.c_debuff[cid] == 0 && s->c_seal[cid] == SEAL_RED) reps++;
                for (int k = 1; k <= nj; k++) {
                    int ek = eff_k[k];
                    if (ek > 0 && s->j_id[ek] == JID(mime)) reps++;
                }
            }
            if (hx > 0) mult = mult * hx;
            for (int q = 1; q <= nfx; q++) {
                int t = tmpi[q];
                if (t == 1) mult = mult + tmp2[q];
                else if (t == 2) mult = mult * tmp2[q];
                else if (t == 3) s->m.dollar_buffer = s->m.dollar_buffer + tmp2[q];
            }
        }
    }
    int ncons = (int)s->n_cons;
    for (int k = 1; k <= nj + ncons; k++) {
        if (k <= nj) {
            double ed = s->j_debuff[k] == 0 ? s->j_ed[k] : 0;
            if (ed == ED_FOIL) chips = chips + 50; else if (ed == ED_HOLO) mult = mult + 10;
            int ek = eff_k[k];
            if (ek > 0) {
                double jc, jm, jx;
                joker_main(s, ek, text, n, ns, &jc, &jm, &jx);
                if (jm != 0) mult = mult + jm;
                if (jc != 0) chips = chips + jc;
                if (jx != 0) mult = mult * jx;
            }
            double rar = G.rarity[(int)s->j_id[k]];
            for (int o = 1; o <= nj; o++) {
                int eo = eff_k[o];
                if (eo > 0 && s->j_id[eo] == JID(baseball) && rar == 2 && eo != k) mult = mult * 1.5;
            }
            if (ed == ED_POLY) mult = mult * 1.5;
        } else {
            if (s->observatory == 1 && s->cons_hand[k - nj] == text) mult = mult * 1.5;
        }
    }
    if (s->chips_cap == 1) chips = fmin(chips, fmax(s->m.money, 0));
    if (s->plasma == 1) {
        double tot = chips + mult;
        chips = floor(tot / 2);
        mult = floor(tot / 2);
    }
    return floor(chips * mult);
}

static int combo_n = -1, combo_count;
static int8_t combo_pos[8192][6];

static void build_combos(int n) {
    if (combo_n == n) return;
    combo_n = n;
    combo_count = 0;
    int cur[6], depth = 0, next[6];
    next[0] = 1;
    for (;;) {
        if (next[depth] <= n && depth < 5) {
            cur[depth + 1] = next[depth];
            next[depth]++;
            depth++;
            int8_t *c = combo_pos[combo_count++];
            c[0] = (int8_t)depth;
            for (int i = 1; i <= depth; i++) c[i] = (int8_t)cur[i];
            next[depth] = cur[depth] + 1;
        } else {
            if (depth == 0) break;
            depth--;
        }
    }
}

int bs_combo_count(int n) {
    if (n < 0 || n > MAXH) return -1;
    build_combos(n);
    return combo_count;
}

static double nom_v[8192];
static int nom_i[8192], sel[8192];

int bs_scan(bs_state *s, int fp, int five, int top, double *out_v, int *out_i) {
    int nh = s->nh0;
    if (nh > MAXH || s->n_jok > MAXJ || s->n_cons > MAXC) return -1;
    build_combos(nh);
    for (int i = 1; i <= nh; i++) s->hand[i] = i;
    s->m.n_hand = nh;
    int four = find_joker(s, JID(four_fingers)), shortcut = find_joker(s, JID(shortcut));
    smeared_ = find_joker(s, JID(smeared));
    pareidolia_ = find_joker(s, JID(pareidolia));
    int splash = find_joker(s, JID(splash));
    resolve_blueprints(s);
    int n = 0;
    for (int i = 0; i < combo_count; i++) {
        const int8_t *c = combo_pos[i];
        int ok = fp == 0;
        for (int q = 1; q <= c[0] && !ok; q++) if (c[q] == fp) ok = 1;
        if (ok && (!five || c[0] == 5)) sel[n++] = i;
    }
    int cards[8];
    if (five && top > 0 && n > top) {
        for (int i = 0; i < n; i++) {
            const int8_t *c = combo_pos[sel[i]];
            int m = c[0];
            for (int q = 1; q <= m; q++) cards[q] = c[q];
            int text = evaluate(s, cards, m, four, shortcut, smeared_, splash);
            double chips = s->m.h_chips[text];
            for (int q = 1; q <= m; q++) if (scoring[q]) chips = chips + card_chips(s, cards[q]);
            nom_v[i] = chips * s->m.h_mult[text];
            nom_i[i] = i;
        }
        for (int i = 1; i < n; i++) {
            int v = nom_i[i], j = i - 1;
            while (j >= 0 && (nom_v[nom_i[j]] < nom_v[v] || (nom_v[nom_i[j]] == nom_v[v] && nom_i[j] > v))) {
                nom_i[j + 1] = nom_i[j];
                j--;
            }
            nom_i[j + 1] = v;
        }
        for (int i = 0; i < top; i++) nom_i[i] = sel[nom_i[i]];
        for (int i = 0; i < top; i++) sel[i] = nom_i[i];
        n = top;
    }
    bs_mut base = s->m;
    double hl = s->hands_left;
    s->hands_left = hl - 1;
    base.dollar_buffer = 0;
    for (int i = 0; i < n; i++) {
        const int8_t *c = combo_pos[sel[i]];
        int m = c[0];
        int pos[6];
        for (int q = 1; q <= m; q++) pos[q] = c[q];
        s->m = base;
        remove_hand_pos(s, pos, m);
        for (int q = 1; q <= m; q++) cards[q] = pos[q];
        out_v[i] = play_eval(s, cards, m, four, shortcut, splash);
        out_i[i] = sel[i] + 1;
    }
    s->m = base;
    s->hands_left = hl;
    return n;
}
