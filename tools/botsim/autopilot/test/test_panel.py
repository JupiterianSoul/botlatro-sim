import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
AP = os.path.dirname(HERE)
sys.path.insert(0, AP)

import panel
import results

STATE = {
    "status": "running", "reason": "", "step": "ladder", "attempt": 2, "profile": "full", "stake": 3,
    "flags": {"fair_speed_ok": True, "expert_ok": False},
    "paid": {"approved_eur": 20, "round_cap_eur": 5, "spent_eur": 7.5},
    "gates": {"fair_bench": {"fails": 0, "last": {"ok": True}}, "ladder": {"fails": 1, "last": {"ok": False, "why": "slow"}}},
    "job": {"kind": "hetzner", "run": "r20261026-1", "round_cost_eur": 2.5},
    "updated": 1000,
}
RESULTS = """# Bot-latro autopilot results

step ladder, status running, spent 7.5 of 20 EUR approved

## Board

Best fair checkpoint: fair-seer-lite (fair_lite, BENCH)

| deck | stake 1 | stake 2 |
| --- | --- | --- |
| b_red | 60% (30) | 41% (12) |
| b_blue | - | 50% (8) |

## Not counted

Nothing.
"""
LOG = "\n".join("- 2026-10-26 10:%02d ladder: event %d" % (i, i) for i in range(30)) + "\n"


class PanelTest(unittest.TestCase):
    def test_summary(self):
        hz = {"run": "r20261026-1", "dashboard_url": "http://1.2.3.4:20000/sec/"}
        s = panel.summarize(STATE, RESULTS, LOG, hz, now=5)
        self.assertEqual(s["step"], "ladder")
        self.assertEqual(s["attempt"], 2)
        self.assertEqual(s["spend"]["spent_eur"], 7.5)
        self.assertEqual(s["spend"]["fraction"], 0.375)
        self.assertFalse(s["spend"]["over"])
        self.assertEqual(s["live"]["url"], "http://1.2.3.4:20000/sec/")
        self.assertEqual(s["live"]["run"], "r20261026-1")
        self.assertEqual([g["step"] for g in s["gates"]], ["fair_bench", "ladder"])
        self.assertEqual(s["gates"][1]["fails"], 1)
        self.assertEqual(s["gates"][1]["last"]["why"], "slow")
        self.assertEqual(len(s["log"]), 20)
        self.assertTrue(s["log"][-1].endswith("event 29"))

    def test_no_live_link_for_ci_job(self):
        st = dict(STATE, job={"kind": "ci", "tag": "x"})
        self.assertIsNone(panel.summarize(st, "", "", {"dashboard_url": "u"})["live"])
        self.assertIsNone(panel.summarize(dict(STATE, job=None), "", "", None)["live"])

    def test_board(self):
        b = panel.parse_board(RESULTS)
        self.assertEqual(b["checkpoint"], "fair-seer-lite")
        self.assertEqual(b["who"], "fair_lite")
        self.assertEqual(b["set"], "BENCH")
        self.assertEqual(b["stakes"], [1, 2])
        self.assertEqual(b["decks"], ["b_red", "b_blue"])
        self.assertEqual(b["cells"]["b_red|1"], {"pct": 60.0, "n": 30})
        self.assertNotIn("b_blue|1", b["cells"])

    def test_board_from_results_render(self):
        rows = [{"t": 0, "step": "s", "checkpoint": "ck", "who": "w", "set": "BENCH", "deck": "b_red", "stake": 1,
                 "n": 10, "wins": 4, "ante_sum": 50, "time_sum": 10.0, "fair": True, "ci_run": None}]
        b = panel.parse_board(results.render(STATE, rows))
        self.assertEqual(b["cells"]["b_red|1"], {"pct": 40.0, "n": 10})

    def test_board_empty(self):
        b = panel.parse_board(results.render({}, []))
        self.assertEqual(b["decks"], [])
        self.assertIsNone(b["checkpoint"])
        self.assertEqual(panel.parse_board("")["cells"], {})

    def test_empty_state(self):
        s = panel.summarize({}, "", "", None)
        self.assertFalse(s["ok"])
        self.assertEqual(s["log"], [])
        self.assertEqual(s["spend"]["fraction"], 0.0)

    def test_over_budget(self):
        st = dict(STATE, paid={"approved_eur": 5, "spent_eur": 6})
        sp = panel.summarize(st, "", "")["spend"]
        self.assertTrue(sp["over"])
        self.assertEqual(sp["fraction"], 1.0)

    def test_fetch_throttle(self):
        calls = []
        t = [100.0]
        f = panel.Fetcher(root="/nonexistent-panel-cache", refresh=lambda r: calls.append(r), clock=lambda: t[0])
        f.get()
        t[0] += 30
        f.get()
        self.assertEqual(len(calls), 1)
        t[0] += 31
        f.get()
        self.assertEqual(len(calls), 2)

    def test_fetch_error_kept(self):
        def boom(r):
            raise RuntimeError("no network")
        f = panel.Fetcher(root="/nonexistent-panel-cache", refresh=boom, clock=lambda: 1.0)
        out = f.get()
        self.assertEqual(out["error"], "no network")
        self.assertFalse(out["ok"])


if __name__ == "__main__":
    unittest.main()
