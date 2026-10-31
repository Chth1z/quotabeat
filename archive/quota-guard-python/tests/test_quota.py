"""Tests of scripts/quota.py: each runs it as Claude Code does (a process, JSON on stdin, exit code and output read
back) against a config folder of its own, with QUOTA_GUARD_FAST shortening the guard's waits.

    python -m unittest discover -s <skill>/tests -v
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

SKILL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QUOTA = os.path.join(SKILL, "scripts", "quota.py")
spec = importlib.util.spec_from_file_location("quota", QUOTA)
quota = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quota)
TERMINAL, DESKTOP = "acct-terminal", "acct-desktop"


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="quota-guard-test-")
        self.addCleanup(shutil.rmtree, self.dir, True)
        with open(os.path.join(self.dir, ".claude.json"), "w", encoding="utf-8") as f:
            json.dump({"oauthAccount": {"accountUuid": TERMINAL}}, f)
        self.transcript = os.path.join(self.dir, "projects", "p", "s1.jsonl")
        os.makedirs(os.path.dirname(self.transcript))
        self.lines = 0

    def env(self, **extra):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "QUOTA_GUARD"))}
        env.update(CLAUDE_CONFIG_DIR=self.dir, QUOTA_GUARD_FAST="1", **extra)
        return env

    def run_quota(self, *args, stdin=None, **env):
        return subprocess.run([sys.executable, "-I", "-S", QUOTA] + list(args), capture_output=True, timeout=60,
                              input=json.dumps(stdin).encode() if stdin is not None else b"", env=self.env(**env))

    def start_quota(self, *args, stdin=None, **env):
        p = subprocess.Popen([sys.executable, "-I", "-S", QUOTA] + list(args), stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env(**env))
        p.stdin.write(json.dumps(stdin).encode())
        p.stdin.close()
        self.addCleanup(self.end, p)
        return p

    @staticmethod
    def end(p):
        if p.poll() is None:
            p.kill()
        p.communicate()

    def statusline(self, five=None, week=None, session="s1", **env):
        limits = {}
        for name, value in (("five_hour", five), ("seven_day", week)):
            if value is not None:
                limits[name] = {"used_percentage": value[0], "resets_at": value[1]}
        return self.run_quota("statusline", stdin={"session_id": session, "rate_limits": limits,
                                                   "context_window": {"used_percentage": 12}}, **env)

    def live(self):
        with open(os.path.join(self.dir, "quota_live.json"), encoding="utf-8") as f:
            return json.load(f)

    def write(self, *entries, partial=None):
        with open(self.transcript, "a", encoding="utf-8") as f:
            for e in entries:
                f.write(json.dumps(e) + "\n")
            if partial:
                f.write(partial)

    def entry(self, kind, content, sidechain=False, at=None, model="claude-opus-5-5"):
        self.lines += 1
        message = {"role": kind, "content": content}
        if kind == "assistant":
            message["model"] = model
        return {"parentUuid": None, "isSidechain": sidechain, "type": kind, "message": message,
                "uuid": "u%d" % self.lines, "timestamp": quota.iso(at or time.time())}

    def typed(self, args):
        return self.entry("user", "<command-message>quota-guard</command-message>\n<command-name>/quota-guard"
                                  "</command-name>\n<command-args>%s</command-args>" % args)

    def skill_call(self, args, **kw):
        return self.entry("assistant", [{"type": "tool_use", "id": "toolu_%d" % self.lines, "name": "Skill",
                                         "input": {"skill": "quota-guard", "args": args}}], **kw)

    def reply(self, at=None):
        return self.entry("assistant", [{"type": "text", "text": "ok"}], at=at)

    def hook(self, event, **extra):
        data = {"session_id": "s1", "transcript_path": self.transcript, "cwd": self.dir, "hook_event_name": event}
        data.update(extra)
        return data

    def state(self):
        return quota.load(os.path.join(self.dir, "quota-guard", "s1.json")) or {}


class Readings(Base):
    def test_statusline_writes_the_reading_with_its_account_and_prints_the_line(self):
        now = time.time()
        out = self.statusline(five=(23.5, now + 3600), week=(41.2, now + 3 * 86400)).stdout.decode().strip()
        self.assertRegex(out, r"^5h 24% \(\d\d:\d\d\) \| 7d 41% \(\w{3} \d\d:\d\d\) \| ctx 12%$")
        live = self.live()
        self.assertEqual((live["account"], live["session"]), (TERMINAL, "s1"))
        self.assertEqual(live["five_hour"]["utilization"], 23.5)

    def test_within_a_window_the_larger_stands_and_a_later_window_supersedes(self):
        now = time.time()
        self.statusline(five=(40, now + 3600))
        self.statusline(five=(30, now + 3600 + 5))  # an idle session's line on old data
        self.assertEqual(self.live()["five_hour"]["utilization"], 40)
        self.statusline(five=(5, now + 5 * 3600))   # the next window
        self.assertEqual(self.live()["five_hour"]["utilization"], 5)
        self.statusline(five=(90, now + 3600))      # the earlier window again: never goes back
        self.assertEqual(self.live()["five_hour"]["utilization"], 5)

    def test_a_window_missing_from_a_response_keeps_its_reading(self):
        now = time.time()
        self.statusline(five=(40, now + 3600), week=(60, now + 86400))
        self.statusline(five=(41, now + 3600))
        self.assertEqual(self.live()["seven_day"]["utilization"], 60)

    def test_readings_are_per_account(self):
        now = time.time()
        self.statusline(five=(40, now + 3600))
        out = self.run_quota("status", CLAUDE_CODE_ACCOUNT_UUID=DESKTOP).stdout.decode()
        self.assertIn("another account's", out)
        self.statusline(five=(10, now + 3600), CLAUDE_CODE_ACCOUNT_UUID=DESKTOP)  # its 40 doesn't carry over
        self.assertEqual((self.live()["account"], self.live()["five_hour"]["utilization"]), (DESKTOP, 10))
        out = self.run_quota("status").stdout.decode()
        self.assertIn("another account's", out)

    def test_status_shows_the_usage_and_the_sessions_guard(self):
        now = time.time()
        self.statusline(five=(23, now + 3600), week=(41, now + 3 * 86400))
        self.write(self.typed("80 week=90"))
        out = self.run_quota("status", CLAUDE_CODE_SESSION_ID="s1").stdout.decode()
        self.assertRegex(out, r"5h\s+23%\s+resets \d\d:\d\d \(in 59m\)")
        self.assertRegex(out, r"7d\s+41%\s+resets \w{3} \d\d:\d\d \(in 2d23h\)")
        self.assertIn("guard: 5h 80%, 7d 90%", out)


class Arming(unittest.TestCase):
    def test_parse(self):
        cases = {
            "": (87, 95, None), "80": (80, 95, None), "80 90": (80, 90, None), "80% 96%": (80, 96, None),
            "week=90": (87, 90, None), "5h 70 week off": (70, None, None), "week=off 80": (80, None, None),
            "7d:93, 5h:85": (85, 93, None), "spend=90": (87, 95, 90), "banana 80": (80, 95, None),
        }
        for args, (five, week, spend) in cases.items():
            kind, marks = quota.parse(args)
            self.assertEqual((kind, marks["five_hour"], marks["seven_day"], marks["spend_limit"]),
                             ("arm", five, week, spend), args)
        for args, kind in (("stop", "stop"), ("off", "stop"), ("STOP now", "stop"), ("status", "status")):
            self.assertEqual(quota.parse(args)[0], kind, args)


class Scan(Base):
    def test_the_newest_real_invocation_sets_the_marks(self):
        quoted = "<command-name>/quota-guard</command-name><command-args>5</command-args>"
        blob = {"type": "api-request-blob", "messages": [self.skill_call("10")]}
        self.write(self.typed("80 90"), self.reply(), self.skill_call("50", sidechain=True), blob,
                   self.entry("assistant", [{"type": "text", "text": quoted}]),
                   self.entry("user", [{"type": "tool_result", "tool_use_id": "t", "content": quoted}]),
                   self.skill_call("70 off"), partial='{"type":"user","message":{"content":"<command-name>/quota-g')
        state = {}
        quota.scan(state, self.transcript, "quota-guard")
        self.assertEqual((state["marks"]["five_hour"], state["marks"]["seven_day"]), (70, None))
        self.assertLess(state["offset"], os.path.getsize(self.transcript))  # the line being written waits
        self.write(self.typed("status"), self.typed("stop"))
        quota.scan(state, self.transcript, "quota-guard")
        self.assertIsNone(state["marks"])


class Guard(Base):
    def arm(self, args="87 95"):
        self.write(self.typed(args), self.reply())

    def test_the_notice_comes_once_per_window_and_not_in_subagents(self):
        now = time.time()
        self.statusline(five=(88, now + 3600), week=(50, now + 86400))
        self.arm()
        out = json.loads(self.run_quota("hook", stdin=self.hook("PostToolUse")).stdout)
        text = out["hookSpecificOutput"]["additionalContext"]
        self.assertIn("The 5-hour usage is 88% (mark 87%", text)
        self.assertIn("end the turn", text)
        self.assertIn("pausing until", out["systemMessage"])
        self.assertEqual(self.run_quota("hook", stdin=self.hook("PostToolUse")).stdout, b"")
        self.statusline(week=(96, now + 86400))
        self.assertEqual(self.run_quota("hook", stdin=self.hook("PostToolUse", agent_id="a1")).stdout, b"")
        out = json.loads(self.run_quota("hook", stdin=self.hook("PostToolUse")).stdout)
        self.assertIn("The weekly usage is 96% (mark 95%", out["hookSpecificOutput"]["additionalContext"])

    def test_below_the_marks_or_disarmed_it_says_nothing(self):
        now = time.time()
        self.statusline(five=(50, now + 3600))
        self.arm()
        self.assertEqual(self.run_quota("hook", stdin=self.hook("PostToolUse")).stdout, b"")
        self.statusline(five=(99, now + 3600))
        self.write(self.typed("stop"))
        self.assertEqual(self.run_quota("hook", stdin=self.hook("PostToolUse")).stdout, b"")

    def test_a_session_without_a_reading_of_its_own_is_told_once(self):
        now = time.time()
        self.statusline(five=(50, now + 3600))  # the terminal's account
        self.arm()
        self.run_quota("hook", stdin=self.hook("PostToolUse"), CLAUDE_CODE_ACCOUNT_UUID=DESKTOP)
        self.write(self.reply(at=now + quota.GRACE + 60))
        out = json.loads(self.run_quota("hook", stdin=self.hook("PostToolUse"), CLAUDE_CODE_ACCOUNT_UUID=DESKTOP).stdout)
        self.assertIn("another account's", out["hookSpecificOutput"]["additionalContext"])
        self.write(self.reply(at=now + quota.GRACE + 90))
        self.assertEqual(self.run_quota("hook", stdin=self.hook("PostToolUse"), CLAUDE_CODE_ACCOUNT_UUID=DESKTOP).stdout, b"")

    def test_stop_at_a_mark_waits_for_the_reset_and_wakes_the_session(self):
        reset = time.time() + 3
        self.statusline(five=(88, reset))
        self.arm()
        begun = time.time()
        p = self.run_quota("hook", stdin=self.hook("Stop"))
        self.assertEqual(p.returncode, 2)
        self.assertGreaterEqual(time.time() - begun, 1)
        self.assertIn("The 5-hour window has reset (this session paused at 5h 88% (mark 87%))", p.stderr.decode())
        self.assertIsNone(self.state()["until"])

    def test_stop_below_the_marks_ends_at_once(self):
        self.statusline(five=(50, time.time() + 3600))
        self.arm()
        p = self.run_quota("hook", stdin=self.hook("Stop"))
        self.assertEqual((p.returncode, p.stderr), (0, b""))

    def waiting(self, **env):
        """A Stop hook started at a mark, once it waits."""
        p = self.start_quota("hook", stdin=self.hook("Stop"), **env)
        for _ in range(200):
            if self.state().get("waiter") == p.pid:
                return p
            time.sleep(0.05)
        self.fail("the Stop hook never started waiting")

    def test_a_waiting_stop_gives_way(self):
        def paused():
            self.statusline(five=(88, time.time() + 600))
            return self.waiting()

        self.arm()
        for change in (lambda: self.write(self.reply()),                       # the session went on
                       lambda: self.write(self.typed("stop")) or self.run_quota("hook", stdin=self.hook("PostToolUse")),
                       lambda: self.run_quota("hook", stdin=self.hook("SessionEnd")),
                       lambda: self.start_quota("hook", stdin=self.hook("Stop"))):  # a newer Stop
            self.arm()
            p = paused()
            change()
            self.assertEqual(p.wait(timeout=10), 0)
            self.assertEqual(p.stderr.read(), b"")

    def test_the_pause_command_runs_once_a_pause(self):
        marker = os.path.join(self.dir, "paused.txt")
        script = os.path.join(self.dir, "on_pause.py")
        with open(script, "w", encoding="utf-8") as f:
            f.write("import os\nopen(%r, 'a').write(os.environ['QUOTA_GUARD_WINDOWS'] + '\\t' + os.getcwd() + '\\n')\n"
                    % marker)
        command = '"%s" "%s"' % (sys.executable, script)
        self.statusline(five=(88, time.time() + 4))
        self.arm()
        first = self.waiting(QUOTA_GUARD_ON_PAUSE=command)
        # a heartbeat's turn ends during the same pause: its Stop takes over the wait, the command doesn't run again
        self.assertEqual(self.run_quota("hook", stdin=self.hook("Stop"), QUOTA_GUARD_ON_PAUSE=command).returncode, 2)
        self.assertEqual(first.wait(timeout=10), 0)
        time.sleep(0.5)
        with open(marker, encoding="utf-8") as f:
            runs = [line.split("\t") for line in f.read().splitlines()]
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0][0], "five_hour")
        self.assertEqual(os.path.normcase(os.path.realpath(runs[0][1])), os.path.normcase(os.path.realpath(self.dir)))

    def test_the_status_line_shows_the_guard(self):
        self.statusline(five=(50, time.time() + 3600))
        self.arm("80 off")
        self.run_quota("hook", stdin=self.hook("PostToolUse"))
        self.assertTrue(self.statusline().stdout.decode().rstrip().endswith("| guard 80/-"))


class Install(Base):
    def test_install_pins_the_hooks_and_keeps_a_foreign_status_line_unless_told(self):
        settings = os.path.join(self.dir, "settings.json")
        theirs = {"type": "command", "command": "my-line.sh"}
        with open(settings, "w", encoding="utf-8") as f:
            json.dump({"theme": "dark", "language": "繁體中文", "statusLine": theirs}, f)
        p = self.run_quota("install")
        self.assertEqual(p.returncode, 1)
        self.assertEqual(quota.load(settings)["statusLine"], theirs)
        self.assertEqual(self.run_quota("install", "--replace").returncode, 0)
        target = os.path.join(self.dir, "skills", "quota-guard")
        script = os.path.join(target, "scripts", "quota.py").replace("\\", "/")
        self.assertTrue(os.path.exists(os.path.join(target, "scripts", "quota.py")))
        self.assertFalse(os.path.exists(os.path.join(target, "tests")))
        with open(os.path.join(target, "SKILL.md"), encoding="utf-8") as f:
            commands = [line.strip() for line in f if line.strip().startswith("command:")]
        self.assertEqual(len(commands), 3)
        for line in commands:
            self.assertIn(sys.executable.replace("\\", "/"), line)
            self.assertTrue(line.endswith(script + " hook'") or line.endswith(script + '" hook\''), line)
        written = quota.load(settings)
        self.assertEqual((written["theme"], written["language"]), ("dark", "繁體中文"))
        self.assertTrue(written["statusLine"]["command"].endswith("statusline"))
        self.assertEqual(self.run_quota("install").returncode, 0)  # its own line is no obstacle
        self.assertEqual(self.run_quota("uninstall").returncode, 0)
        self.assertEqual(quota.load(settings)["statusLine"], theirs)
        self.assertFalse(os.path.exists(os.path.join(self.dir, "quota-guard", "statusline-before.json")))


if __name__ == "__main__":
    unittest.main()
