import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(HERE, "..")))

import autopilot
import ci
import gates
import steps
import store as storemod


class FakeResults:
    @staticmethod
    def parse_games(paths):
        out = []
        for p in paths:
            with open(p) as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("{"):
                        out.append(json.loads(line))
        return out

    @staticmethod
    def aggregate(games, **meta):
        cells = {}
        for g in games:
            r = cells.setdefault((g["deck"], g["stake"]), dict(meta, deck=g["deck"], stake=g["stake"], n=0, wins=0, ante_sum=0, time_sum=0.0))
            r["n"] += 1
            r["wins"] += g["won"]
            r["ante_sum"] += g["ante"]
            r["time_sum"] += g["time"]
        return list(cells.values())

    @staticmethod
    def render(state, rows):
        return "# results\n%s %s %d rows\n" % (state["step"], state["status"], len(rows))


class World:
    def __init__(self, root, store_root):
        self.root = root
        self.store_root = store_root
        self.runs = []
        self.calls = []
        self.boxes = []
        self.spent = 0.0
        self.cost = 0.5
        self.leak_fail = False
        self.shuffle_fail = False
        self.job_state = "done"
        self.eval_wins = 7
        self.auto_complete = True
        self.run_n = 0
        self.teacher = None

    def __call__(self, argv, env=None, timeout=None):
        self.calls.append(list(argv))
        if argv[0] == "gh":
            return self.gh(argv[1:])
        if argv[1].endswith("hz.py"):
            return self.hz(argv[2:])
        return 1, "unknown command"

    def gh(self, a):
        if a[:2] == ["workflow", "run"]:
            f = dict(x.split("=", 1) for x in a if "=" in x and not x.startswith("-"))
            self.runs.append({"databaseId": 1000 + len(self.runs), "displayTitle": "botsim work " + f["tag"], "tag": f["tag"],
                              "jobs": json.loads(f["jobs"]), "status": "completed" if self.auto_complete else "in_progress",
                              "conclusion": "success", "createdAt": "2026-10-26T00:00:%02dZ" % len(self.runs)})
            return 0, ""
        if a[:2] == ["run", "list"]:
            return 0, json.dumps([{k: r[k] for k in ("databaseId", "displayTitle", "status", "conclusion", "createdAt")} for r in self.runs])
        if a[:2] == ["run", "view"]:
            r = self.find(int(a[2]))
            return (0, json.dumps({k: r[k] for k in ("databaseId", "displayTitle", "status", "conclusion")})) if r else (1, "")
        if a[:2] == ["run", "download"]:
            self.download(self.find(int(a[2])), a[a.index("-D") + 1])
            return 0, ""
        return 1, "bad gh"

    def find(self, rid):
        for r in self.runs:
            if r["databaseId"] == rid:
                return r
        return None

    def download(self, r, dest):
        for j in r["jobs"]:
            d = os.path.join(dest, "%s-%s" % (r["tag"], j["label"]))
            os.makedirs(d, exist_ok=True)
            cmd = j["cmd"]
            if "fair_test.lua" in cmd:
                with open(os.path.join(d, "leak.txt"), "w") as f:
                    f.write("fair tests: 9 passed, %d failed\n" % (2 if self.leak_fail else 0))
            if "fair_shuffle.lua" in cmd:
                with open(os.path.join(d, "shuffle.json"), "w") as f:
                    json.dump({"who": "fair", "games": 1, "identical": 0 if self.shuffle_fail else 1, "diffs": []}, f)
            if "fair.lua" in cmd or "teacher.lua" in cmd or "eval.lua" in cmd:
                with open(os.path.join(d, "games.jsonl"), "w") as f:
                    for s in range(2):
                        f.write(json.dumps({"deck": "b_red", "stake": 1, "seed": "BENCH%04d" % s, "won": 1, "ante": 3, "time": 1.0}) + "\n")
            if "teacher.lua" in cmd:
                with open(os.path.join(d, "teach.bspr"), "w") as f:
                    f.write("records")
            if "train.py" in cmd:
                with open(os.path.join(d, "imitation.bnnw"), "w") as f:
                    f.write("net")

    def hz(self, a):
        cmd = a[0]
        if cmd == "plan":
            return 0, json.dumps({"cost_eur": self.cost})
        if cmd == "spend":
            return 0, json.dumps({"spent_eur": self.spent, "cap_eur": 100, "left_eur": 100 - self.spent})
        if cmd == "list":
            return 0, json.dumps(self.boxes)
        if cmd == "doctor":
            return 0, "all good"
        if cmd == "up":
            if "--dry-run" in a:
                return 0, "dry"
            self.run_n += 1
            self.run = "r%d" % self.run_n
            self.boxes = [{"name": "botsim-0"}]
            conf = os.environ["BOTSIM_CONFIG"]
            os.makedirs(conf, exist_ok=True)
            with open(os.path.join(conf, "current_run.json"), "w") as f:
                json.dump({"run": self.run, "boxes": ["b0"]}, f)
            self.spent += self.cost
            return 0, "up"
        if cmd == "deploy":
            return 0, "deployed"
        if cmd == "run":
            if "--dry-run" not in a:
                self.write_metrics()
            return 0, "ok\n" + json.dumps({"started": ["b0"], "refused": [], "failed": [], "readback": {"b0": {"start": 1, "env": {}}}})
        if cmd == "down":
            if "--dry-run" not in a:
                self.boxes = []
            return 0, "down"
        return 1, "bad hz"

    def write_metrics(self):
        d = os.path.join(self.store_root, "runs", self.run)
        os.makedirs(os.path.join(d, "checkpoints"), exist_ok=True)
        lines = [{"type": "state", "state": "running"},
                 {"type": "eval", "who": "gen", "gen": 1, "deck": "b_red", "stake": 1, "n": 10, "wins": self.eval_wins, "ante": 6.0, "promoted": True},
                 {"type": "state", "state": self.job_state}]
        if self.teacher is not None:
            lines = [{"type": "state", "state": "running"}, dict(type="teacher", **self.teacher), {"type": "state", "state": self.job_state}]
        with open(os.path.join(d, "metrics.jsonl"), "w") as f:
            for m in lines:
                f.write(json.dumps(m) + "\n")
        with open(os.path.join(d, "checkpoints", "gen_0001.bnnw"), "w") as f:
            f.write("gen1")

    def hz_calls(self, name):
        return [c for c in self.calls if c[0] != "gh" and len(c) > 2 and c[2] == name]

    def dispatches(self):
        return [c for c in self.calls if c[:3] == ["gh", "workflow", "run"]]


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.store_root = os.path.join(self.tmp, "store")
        os.environ["BOTSIM_CONFIG"] = os.path.join(self.tmp, "conf")
        self.world = World(self.tmp, self.store_root)
        self.alerts = []
        self.t = [1_800_000_000.0]
        self.profiles = autopilot.load_profiles()
        for p in self.profiles.values():
            if "paid" in p:
                p["paid"]["wait_minutes"] = 0
            if "paid" in p.get("teacher", {}):
                p["teacher"]["paid"]["wait_minutes"] = 0

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def now(self):
        self.t[0] += 5
        return self.t[0]

    def ap(self, *argv):
        return autopilot.main(["--store-local", self.store_root, "--dir", "ap"] + list(argv), runner=self.world,
                              alert_fn=lambda t, m, p: self.alerts.append((t, m, p)) or True, now=self.now,
                              sleep=lambda s: None, results=FakeResults, profiles=self.profiles, me="test")

    def state(self):
        with open(os.path.join(self.store_root, "ap", "state.json")) as f:
            return json.load(f)

    def ticks(self, n=40):
        for _ in range(n):
            if self.state()["status"] in ("done", "stopped"):
                break
            self.ap("tick")
        return self.state()


class TestTiny(Base):
    def test_full_tiny_path(self):
        self.ap("init", "--profile", "tiny")
        st = self.ticks()
        self.assertEqual(st["status"], "done", st.get("reason"))
        self.assertEqual(st["best"]["name"], "imitation")
        steps = {json.loads(j)["step"] for j in open(os.path.join(self.store_root, "ap", "results.jsonl")).read().splitlines() for _ in [0]}
        self.assertTrue({"fair_bench", "fair_speed", "imitation"} <= steps)
        for name in ("up", "deploy", "run", "down"):
            for c in self.world.hz_calls(name):
                self.assertIn("--dry-run", c)
        self.assertTrue(self.world.hz_calls("up"))
        self.assertFalse(self.world.boxes)
        self.assertTrue(os.path.exists(os.path.join(self.store_root, "ap", "RESULTS.md")))
        self.assertTrue(os.path.exists(os.path.join(self.store_root, "ap", "checkpoints", "imitation.bnnw")))
        self.assertIsNone(st["lock"])
        self.assertEqual(st["teacher"]["games"], 2)

    def test_redo_teacher(self):
        self.ap("init", "--profile", "tiny")
        st = self.ticks()
        self.assertEqual(st["status"], "done", st.get("reason"))
        with self.assertRaises(SystemExit):
            self.ap("redo", "nosuchstep")
        self.ap("redo", "teacher")
        st = self.state()
        self.assertEqual((st["step"], st["status"], st["attempt"]), ("teacher", "running", 1))
        self.assertEqual(st["teacher"]["games"], 0)
        self.assertIsNone(st["best"]["name"])
        st = self.ticks()
        self.assertEqual(st["status"], "done", st.get("reason"))
        self.assertEqual(st["teacher"]["games"], 2)

    def test_init_refuses_existing(self):
        self.ap("init", "--profile", "tiny")
        with self.assertRaises(SystemExit):
            self.ap("init", "--profile", "tiny")
        self.ap("init", "--profile", "tiny", "--reset")

    def test_gate_fails_twice_stops(self):
        self.world.leak_fail = True
        self.ap("init", "--profile", "tiny")
        st = self.ticks()
        self.assertEqual(st["status"], "stopped")
        self.assertEqual(st["gates"]["fair_bench"]["fails"], 2)
        self.assertEqual(len(self.world.dispatches()), 2)
        self.assertTrue(any(p == 5 for _, _, p in self.alerts))

    def test_double_tick_no_double_dispatch(self):
        self.world.auto_complete = False
        self.ap("init", "--profile", "tiny")
        self.ap("tick")
        self.ap("tick")
        self.ap("tick")
        self.assertEqual(len(self.world.dispatches()), 1)
        self.assertIsNotNone(self.state()["job"]["run_id"])

    def test_dispatch_recorded_before_gh(self):
        self.world.auto_complete = False
        self.ap("init", "--profile", "tiny")
        seen = []
        orig = self.world.gh

        def gh(a):
            if a[:2] == ["workflow", "run"]:
                seen.append(self.state()["job"])
            return orig(a)
        self.world.gh = gh
        self.ap("tick")
        self.assertTrue(seen and seen[0]["tag"])

    def test_lock(self):
        self.world.auto_complete = False
        self.ap("init", "--profile", "tiny")
        path = os.path.join(self.store_root, "ap", "state.json")
        st = self.state()
        st["lock"] = {"id": "other", "t": self.t[0]}
        with open(path, "w") as f:
            json.dump(st, f)
        self.ap("tick")
        self.assertEqual(len(self.world.dispatches()), 0)
        st = self.state()
        st["lock"] = {"id": "other", "t": self.t[0] - 46 * 60}
        with open(path, "w") as f:
            json.dump(st, f)
        self.ap("tick")
        self.assertEqual(len(self.world.dispatches()), 1)
        self.assertIsNone(self.state()["lock"])


class TestPaid(Base):
    def setUp(self):
        super().setUp()
        self.ap("init", "--profile", "tiny-paid")

    def ups(self):
        return [c for c in self.world.hz_calls("up") if "--dry-run" not in c]

    def test_refused_without_approval(self):
        st = self.ticks(4)
        self.assertEqual(st["status"], "waiting")
        self.assertIn("approved", st["reason"])
        self.assertFalse(self.ups())
        self.assertEqual(sum(1 for t, _, _ in self.alerts if t == "waiting"), 1)

    def test_refused_over_round_cap(self):
        self.ap("approve", "--eur", "5", "--round-cap", "0.2")
        st = self.ticks(4)
        self.assertEqual(st["status"], "waiting")
        self.assertIn("per-round cap", st["reason"])
        self.assertFalse(self.ups())

    def test_refused_over_budget_left(self):
        self.ap("approve", "--eur", "0.3", "--round-cap", "1")
        st = self.ticks(4)
        self.assertIn("used up", st["reason"])
        self.assertFalse(self.ups())

    def test_refused_over_total_cap(self):
        self.world.spent = 99.8
        self.ap("approve", "--eur", "5", "--round-cap", "1")
        st = self.ticks(4)
        self.assertEqual(st["status"], "waiting")
        self.assertIn("100", st["reason"])
        self.assertFalse(self.ups())

    def test_round_success(self):
        self.ap("approve", "--eur", "5", "--round-cap", "1")
        st = self.ticks(10)
        self.assertEqual(st["status"], "done", st.get("reason"))
        self.assertEqual(len(self.ups()), 1)
        self.assertEqual(self.world.boxes, [])
        self.assertAlmostEqual(st["paid"]["spent_eur"], 0.5)
        self.assertTrue(st["best"]["name"].startswith("expert-r1"))
        self.assertTrue(os.path.exists(os.path.join(self.store_root, st["best"]["path"])))
        self.assertTrue(os.path.exists(os.path.join(self.store_root, "ap", "hz", "r1.json")))
        run = [c for c in self.world.hz_calls("run")][0]
        self.assertIn("BOTSIM_DELETE_WHEN_DONE=1", run)
        self.assertIn("TRAIN_PATIENCE=4", run)
        self.assertIn("--json", run)

    def test_round_fails_twice_stops_and_downs(self):
        self.world.job_state = "failed"
        self.ap("approve", "--eur", "5", "--round-cap", "1")
        st = self.ticks(12)
        self.assertEqual(st["status"], "stopped")
        self.assertEqual(len(self.ups()), 2)
        prechecks = [r for r in self.world.runs if r["tag"].endswith("precheck")]
        self.assertEqual(len(prechecks), 2)
        self.assertTrue(self.world.hz_calls("down"))
        self.assertEqual(self.world.boxes, [])
        self.assertTrue(any(p == 5 for _, _, p in self.alerts))

    def test_stop_downs_live_round(self):
        self.world.job_state = "running"
        self.ap("approve", "--eur", "5", "--round-cap", "1")
        for _ in range(3):
            self.ap("tick")
        self.assertEqual(self.state()["job"]["kind"], "hetzner")
        self.assertTrue(self.world.boxes)
        self.ap("tick")
        self.assertEqual(len(self.ups()), 1)
        self.ap("stop", "test")
        self.assertEqual(self.state()["status"], "stopped")
        self.assertEqual(self.world.boxes, [])


class TestTeacherPaid(Base):
    def setUp(self):
        super().setUp()
        self.ap("init", "--profile", "tiny-teach")
        self.world.teacher = {"games": 2, "records": 40, "bytes": 1000, "files": 1, "leak_ok": True, "start": 1, "seeds": 2, "complete": True}

    def test_needs_approval(self):
        st = self.ticks(4)
        self.assertEqual(st["status"], "waiting")
        self.assertFalse([c for c in self.world.hz_calls("up") if "--dry-run" not in c])

    def test_round_counts_games(self):
        self.ap("approve", "--eur", "5", "--round-cap", "1")
        st = self.ticks(10)
        self.assertEqual(st["status"], "done", st.get("reason"))
        self.assertEqual(st["teacher"]["games"], 2)
        self.assertEqual(st["teacher"]["next"], 3)
        self.assertEqual(st["teacher"]["artifacts"][0]["hz_run"], "r1")
        run = self.world.hz_calls("run")[0]
        self.assertIn("teacher", run)
        self.assertIn("TEACH_SEEDS=2", run)
        self.assertEqual(self.world.boxes, [])
        self.assertFalse(self.world.dispatches())

    def test_leak_fail_retries_then_stops(self):
        self.world.teacher["leak_ok"] = False
        self.ap("approve", "--eur", "5", "--round-cap", "1")
        st = self.ticks(10)
        self.assertEqual(st["status"], "stopped")
        self.assertEqual(self.world.boxes, [])

    def test_imitation_fetches_hetzner_records(self):
        import steps
        ctx = type("C", (), {})()
        ctx.prof = self.profiles["full"]
        ctx.st = {"teacher": {"artifacts": [{"hz_run": "r9"}]}}
        cmd = steps.imitation_jobs(ctx)[0]["cmd"]
        self.assertIn("fetchdir runs/r9/teacher data/r9", cmd)
        self.assertIn('${f%.gz.000}', cmd)


class TestPieces(unittest.TestCase):
    def test_find_run_by_name(self):
        runs = [{"databaseId": 1, "displayTitle": "botsim work abc-1", "status": "completed", "conclusion": "success", "createdAt": "1"},
                {"databaseId": 2, "displayTitle": "botsim work abc-10", "status": "in_progress", "conclusion": None, "createdAt": "2"},
                {"databaseId": 3, "displayTitle": "other", "status": "completed", "conclusion": "success", "createdAt": "3"}]
        run = lambda argv, env=None: (0, json.dumps(runs))
        self.assertEqual(ci.find_run(run, "abc-10")["id"], 2)
        self.assertEqual(ci.find_run(run, "abc-1")["id"], 1)
        self.assertIsNone(ci.find_run(run, "abc-2"))

    def test_last_json(self):
        self.assertEqual(ci.last_json("x\n{\"a\": 1}\nNOT\n"), {"a": 1})
        self.assertIsNone(ci.last_json("nothing"))

    def test_gates(self):
        self.assertTrue(gates.leak("...\nfair tests: 12 passed, 0 failed\n")["ok"])
        self.assertFalse(gates.leak("fair tests: 12 passed, 1 failed")["ok"])
        self.assertFalse(gates.leak("")["ok"])
        self.assertTrue(gates.shuffle({"games": 3, "identical": 3})["ok"])
        self.assertFalse(gates.shuffle({"games": 3, "identical": 2})["ok"])
        self.assertTrue(gates.worse(10, 100, 30, 100))
        base = {"white": [39, 150], "time_sum": 12240.0}
        self.assertAlmostEqual(steps.speed_limit({"max_ratio": 1.5}, base), 122.4)
        self.assertEqual(steps.speed_limit({"max_ratio": 1.5}, {}), 0.0)
        self.assertEqual(steps.speed_limit({"max_s": 60}, base), 60)
        self.assertFalse(gates.worse(29, 100, 30, 100))
        self.assertTrue(gates.improves({"ante": 6, "rate": 0.1}, {"ante": 5, "rate": 0.5}))
        self.assertFalse(gates.improves({"ante": 5, "rate": 0.1}, {"ante": 5, "rate": 0.5}))

    def test_local_store(self):
        d = tempfile.mkdtemp()
        try:
            s = storemod.Local(d)
            s.write_json("a/b.json", {"x": 1})
            self.assertEqual(s.read_json("a/b.json"), {"x": 1})
            s.append("a/log.md", "one")
            s.append("a/log.md", "two")
            self.assertEqual(s.read_text("a/log.md"), "one\ntwo\n")
            self.assertIsNone(s.read_json("missing.json"))
        finally:
            shutil.rmtree(d)


if __name__ == "__main__":
    unittest.main()
