import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
AP = os.path.dirname(HERE)
sys.path.insert(0, AP)

import results


def game(deck, stake, seed, won, ante, t=10.0):
    return {"deck": deck, "stake": stake, "seed": seed, "won": won, "ante": ante, "time": t}


class ResultsTest(unittest.TestCase):
    def test_parse_skips_noise(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "g.jsonl")
            with open(p, "w") as fh:
                fh.write("# header\n")
                fh.write(json.dumps(game("b_red", 1, "BENCH0001", 1, 9)) + "\n")
                fh.write("{broken\n")
                fh.write("| table |\n")
                fh.write(json.dumps(game("b_red", 1, "BENCH0002", 0, 4, 5.5)) + "\n")
            g = results.parse_games([p, os.path.join(d, "missing")])
        self.assertEqual(len(g), 2)
        self.assertEqual(g[1]["time"], 5.5)

    def test_aggregate(self):
        gs = [game("b_red", 1, "a", 1, 9), game("b_red", 1, "b", 0, 3), game("b_blue", 2, "c", 0, 5)]
        rows = results.aggregate(gs, t=7, step="fair_bench", checkpoint="ck", who="fair_lite", set="BENCH", fair=True, ci_run=5)
        self.assertEqual(len(rows), 2)
        red = [r for r in rows if r["deck"] == "b_red"][0]
        self.assertEqual((red["n"], red["wins"], red["ante_sum"], red["time_sum"]), (2, 1, 12, 20.0))
        self.assertTrue(red["fair"])
        self.assertEqual(red["ci_run"], 5)
        self.assertEqual(red["t"], 7)

    def test_wilson(self):
        lo, hi = results.wilson(0, 0)
        self.assertEqual((lo, hi), (0.0, 0.0))
        lo, hi = results.wilson(50, 100)
        self.assertAlmostEqual(lo, 0.4038, places=3)
        self.assertAlmostEqual(hi, 0.5962, places=3)
        lo, hi = results.wilson(0, 10)
        self.assertEqual(lo, 0.0)
        self.assertGreater(hi, 0.2)
        self.assertLessEqual(results.wilson(10, 10)[1], 1.0)

    def test_win_rate(self):
        rows = results.aggregate([game("b_red", 1, "a", 1, 9), game("b_red", 2, "b", 0, 3), game("b_blue", 2, "c", 1, 8)])
        self.assertEqual(results.win_rate(rows), (2, 3))
        self.assertEqual(results.win_rate(rows, 2), (1, 2))
        self.assertEqual(results.win_rate(rows, 5), (0, 0))

    def test_render(self):
        fair = results.aggregate([game("b_red", 1, "a", 1, 9), game("b_red", 1, "b", 0, 3)], t=1, checkpoint="good", who="fair_lite", set="BENCH", fair=True)
        bad = results.aggregate([game("b_red", 1, "a", 1, 9)], t=2, checkpoint="leaky", who="cheat", set="BENCH", fair=False)
        state = {"step": "fair_bench", "status": "running", "paid": {"spent_eur": 1.5, "approved_eur": 10}, "updated": 1000}
        text = results.render(state, fair + bad)
        self.assertIn("fair_bench", text)
        self.assertIn("1.5 of 10 EUR", text)
        self.assertIn("## good", text)
        self.assertIn("overall", text)
        self.assertIn("50.0%", text)
        self.assertIn("Best fair checkpoint: good", text)
        self.assertIn("## Not counted", text)
        self.assertIn("leaky", text)
        self.assertNotIn("## leaky", text)
        self.assertNotIn("\u2014", text)

    def test_render_empty(self):
        text = results.render({}, [])
        self.assertIn("No fair checkpoint measured yet", text)
        self.assertIn("Nothing.", text)

    def test_cli(self):
        with tempfile.TemporaryDirectory() as d:
            g = os.path.join(d, "g.jsonl")
            with open(g, "w") as fh:
                fh.write(json.dumps(game("b_red", 1, "BENCH0001", 1, 9)) + "\n")
            cli = os.path.join(AP, "results.py")
            out = subprocess.run([sys.executable, cli, "ingest", "--checkpoint", "ck", "--who", "w", "--step", "s",
                                  "--set", "BENCH", "--fair", "1", "--ci-run", "9", g], capture_output=True, text=True, check=True).stdout
            rows = [json.loads(x) for x in out.splitlines()]
            self.assertEqual(rows[0]["wins"], 1)
            self.assertTrue(rows[0]["fair"])
            rp, sp, op = os.path.join(d, "r.jsonl"), os.path.join(d, "s.json"), os.path.join(d, "R.md")
            open(rp, "w").write(out)
            json.dump({"step": "x"}, open(sp, "w"))
            subprocess.run([sys.executable, cli, "render", "--state", sp, "--rows", rp, "--out", op], check=True)
            self.assertIn("b_red", open(op).read())


if __name__ == "__main__":
    unittest.main()
