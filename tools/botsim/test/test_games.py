import contextlib
import io
import json
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "train"))
import games as G
import relabel as RL


def line(seed, won=0, ante=3, need=100, deck="b_red", stake=8, **kw):
    r = {"deck": deck, "stake": stake, "seed": seed, "won": won, "ante": ante, "time": 1.5, "end": "end", "moves": 9, "need": need}
    r.update(kw)
    return json.dumps(r)


def write(root, name, rows):
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, name), "w") as f:
        f.write("\n".join(rows) + "\n")


class Games(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory()
        self.d = self.t.name

    def tearDown(self):
        self.t.cleanup()

    def test_lost_final_boss_is_not_a_win(self):
        r = json.loads(line("A", won=1, ante=9, need=400000))
        self.assertFalse(G.real_win(r))
        self.assertEqual(G.real_ante(r), 8)

    def test_closed_round_is_a_win(self):
        r = json.loads(line("A", won=1, ante=9, need=0))
        self.assertTrue(G.real_win(r))
        self.assertEqual(G.real_ante(r), 9)

    def test_new_format_lost_boss_stays_a_loss(self):
        r = json.loads(line("A", won=0, ante=8, need=400000))
        self.assertFalse(G.real_win(r))
        self.assertEqual(G.real_ante(r), 8)

    def test_pairing_is_by_key_not_line_order(self):
        a = os.path.join(self.d, "a")
        b = os.path.join(self.d, "b")
        write(a, "games_0.jsonl", [line("A", ante=3), line("B", ante=5)])
        write(b, "games_0.jsonl", [line("B", ante=5), line("A", ante=3)])
        p = G.paired(G.load(a)[0], G.load(b)[0])
        self.assertEqual(p["n"], 2)
        self.assertEqual(p["diff"], 0)
        self.assertEqual(p["same"], 2)

    def test_same_seed_on_two_decks_stays_two_games(self):
        a = os.path.join(self.d, "a")
        write(a, "games_0.jsonl", [line("A", deck="b_red"), line("A", deck="b_blue")])
        self.assertEqual(len(G.load(a)[0]), 2)

    def test_merged_file_is_not_counted_twice(self):
        a = os.path.join(self.d, "a")
        write(a, "games_0.jsonl", [line("A")])
        write(a, "games.jsonl", [line("A")])
        g, st = G.load(a)
        self.assertEqual(len(g), 1)
        self.assertEqual(st["dups"], 0)

    def test_duplicates_and_conflicts_are_counted(self):
        a = os.path.join(self.d, "a")
        write(a, "games_0.jsonl", [line("A", ante=3)])
        write(a, "games_1.jsonl", [line("A", ante=3), line("A", ante=4)])
        g, st = G.load(a)
        self.assertEqual(len(g), 1)
        self.assertEqual(st["dups"], 2)
        self.assertEqual(st["conflicts"], 1)
        self.assertEqual(g[("b_red", 8, "A")]["ante"], 3)

    def test_cut_off_line_is_reported(self):
        a = os.path.join(self.d, "a")
        write(a, "games_0.jsonl", [line("A"), '{"deck":"b_red","sta'])
        g, st = G.load(a)
        self.assertEqual(len(g), 1)
        self.assertEqual(st["bad"], 1)

    def test_z_of_known_differences(self):
        new = {("d", 8, str(i)): {"ante": 4 + (i % 2), "won": 0, "need": 1} for i in range(4)}
        base = {("d", 8, str(i)): {"ante": 4, "won": 0, "need": 1} for i in range(4)}
        p = G.paired(new, base)
        self.assertAlmostEqual(p["diff"], 0.5)
        self.assertAlmostEqual(p["z"], 0.5 / ((1 / 3) ** 0.5 / 2))

    def test_summary_counts_odd_ends(self):
        a = os.path.join(self.d, "a")
        write(a, "g.jsonl", [line("A", won=1, ante=9, need=0), line("B", won=1, ante=9, need=5), json.dumps({"deck": "b_red", "stake": 8, "seed": "C", "won": 0, "ante": 2, "end": "max_moves", "need": 5})])
        s = G.summary(G.load(a)[0])
        self.assertEqual((s["n"], s["flag"], s["wins"], s["odd_end"], s["early"]), (3, 2, 1, 1, 1))
        self.assertAlmostEqual(s["ante"], (9 + 8 + 2) / 3)

    def test_same_fails_on_a_difference_and_ignores_time(self):
        a = os.path.join(self.d, "a")
        b = os.path.join(self.d, "b")
        c = os.path.join(self.d, "c")
        write(a, "g.jsonl", [line("A", ante=3)])
        write(b, "g.jsonl", [line("A", ante=3, time=77.0)])
        write(c, "g.jsonl", [line("A", ante=4)])
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(G.main(["x", "same", a, b]), 0)
            self.assertEqual(G.main(["x", "same", a, c]), 1)

    def test_relabel_lost_final_boss(self):
        head = b"BSPR" + bytes(28) + struct.pack("<H", 1) + b"x"
        rec = bytes(20) + struct.pack("<H", 0)
        run = lambda w, a: b"RUN2" + struct.pack("<IBBBBI", 1, w, a, 0, 8, 1) + rec
        data = head + run(1, 9) + run(1, 9) + run(0, 3)
        games = [{"won": 1, "ante": 9, "need": 0}, {"won": 1, "ante": 9, "need": 500}, {"won": 0, "ante": 3, "need": 100}]
        new, n, changed = RL.relabel(data, games)
        self.assertEqual((n, changed), (3, 1))
        self.assertEqual(new, head + run(1, 9) + run(0, 8) + run(0, 3))
        with self.assertRaises(ValueError):
            RL.relabel(data, games[:2])


if __name__ == "__main__":
    unittest.main()
