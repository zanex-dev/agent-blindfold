"""Integration tests for the local grant store. All host messages and homes are synthetic."""
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import unittest

from run_tests import find_bash_bin

ROOT = Path(__file__).resolve().parents[1]
PS = shutil.which("powershell") or shutil.which("pwsh")
BASH = find_bash_bin()


class HostContract:
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="agent-blindfold-test-", dir=ROOT)
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.ws = self.root / "project"
        self.home = self.root / "profile"
        self.ws.mkdir()
        self.home.mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("AGENT_BLINDFOLD_")}
        self.env.update(HOME=str(self.home), USERPROFILE=str(self.home),
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.config = self.home / ".gemini/config"
        self.config.mkdir(parents=True)
        self.store = self.config / "agent-blindfold-grants"

    def command(self, name, *args):
        suffix = "ps1" if self.windows_engine else "sh"
        path = ROOT / (name + "." + suffix)
        if self.windows_engine:
            return [PS, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(path), *args]
        return [BASH, path.as_posix(), *args]

    def invoke(self, name, *args, payload=None, raw=None, env=None):
        data = raw if raw is not None else json.dumps(payload or {}).encode()
        r = subprocess.run(self.command(name, *args), input=data, capture_output=True,
                           cwd=self.ws, env=env or self.env, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr.decode(errors="replace"))
        return r

    def session(self):
        return self.invoke("scripts/session_start", payload={"conversationId":"synthetic","workspacePaths":[str(self.ws)]})

    def host_read(self):
        target = self.ws / "logo.png"
        target.touch()
        payload = {"toolCall":{"name":"read_file","args":{"Path":str(target)}},"workspacePaths":[str(self.ws)]}
        return json.loads(self.invoke("scripts/guard", payload=payload).stdout)["decision"]

    def cli(self, ps, unix):
        return self.invoke("scripts/unlock", *(ps if self.windows_engine else unix))

    def test_old_project_file_requires_local_reauthorization(self):
        (self.config / "agent-blindfold.json").write_text('{"sessionAutoGrant":"off"}')
        legacy = self.ws / ".allow_media"
        legacy.write_text("pre-existing project data")
        self.session()
        self.assertEqual(self.host_read(), "deny")
        self.assertFalse(self.store.exists())
        self.cli(["-Mode","timed","-TTL","15m"], ["--timed","15m"])
        self.assertEqual(self.host_read(), "allow")
        self.cli(["-Lock"], ["--lock"])
        self.assertEqual(self.host_read(), "deny")
        self.assertEqual(legacy.read_text(), "pre-existing project data")

    def test_gitfile_workspace_is_clean_after_auto_grant(self):
        if not shutil.which("git"):
            self.skipTest("requires Git")
        subprocess.run(["git","init","-q","--separate-git-dir",str(self.root/"metadata")],
                       cwd=self.ws, env=self.env, check=True, capture_output=True)
        self.session()
        self.assertEqual(len(list(self.store.glob("*.json"))), 1)
        result = subprocess.check_output(["git","status","--porcelain"], cwd=self.ws, env=self.env)
        self.assertEqual(result, b"")
        self.assertFalse((self.ws/".allow_media").exists())

    def test_bad_policy_pauses_new_grants(self):
        (self.config/"agent-blindfold.json").write_text("{")
        output = self.session()
        self.assertTrue(output.stderr)
        self.assertFalse(self.store.exists())
        self.assertEqual(self.host_read(), "deny")

    def test_status_and_session_use_same_overrides(self):
        (self.config/"agent-blindfold.json").write_text('{"sessionAutoGrant":"off","defaultTTL":"2h"}')
        self.env.update(AGENT_BLINDFOLD_AUTO_GRANT="timed", AGENT_BLINDFOLD_DEFAULT_TTL="30m")
        status = self.cli(["-Status"], ["--status"]).stdout.decode()
        self.assertIn("timed (environment)", status)
        self.assertIn("30m (environment)", status)
        self.session()
        record = json.loads(next(self.store.glob("*.json")).read_text())
        self.assertEqual(record["ttl_seconds"], 1800)

    def test_invalid_messages_produce_host_specific_denial(self):
        for host in ("antigravity", "claude"):
            for payload in (b"", b"{", b"{}"):
                args = ["-HookHost", host] if self.windows_engine else [host]
                result = self.invoke("scripts/guard", *args, raw=payload)
                message = json.loads(result.stdout)
                decision = message["decision"] if host == "antigravity" else message["hookSpecificOutput"]["permissionDecision"]
                self.assertEqual(decision, "deny")
                self.assertTrue(result.stderr)

    def failure(self, name, *args):
        r = subprocess.run(self.command(name, *args), input=b"{}", capture_output=True,
                           cwd=self.ws, env=self.env, timeout=30)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        return r

    def test_root_selector_never_resolves_to_current_project(self):
        self.cli(["-Mode","permanent"], ["--permanent"])
        root = self.ws.anchor
        args = ["-Lock","-Workspace",root] if self.windows_engine else ["--lock","--workspace",root]
        self.failure("scripts/unlock", *args)
        self.assertEqual(self.host_read(), "allow")
        self.assertEqual(len(list(self.store.glob("*.json"))), 1)

    def test_invalid_target_does_not_create_policy(self):
        args = ["-Target","unknown"] if self.windows_engine else ["--target","unknown"]
        self.failure("install", *args)
        self.assertFalse((self.config/"agent-blindfold.json").exists())

    def test_partial_uninstall_preserves_grants_final_uninstall_revokes(self):
        (self.home/".claude").mkdir()
        self.invoke("install")
        self.cli(["-Mode","permanent"], ["--permanent"])
        def remove(target):
            args = ["-Uninstall","-Target",target] if self.windows_engine else ["--uninstall","--target",target]
            self.invoke("install", *args)
        remove("claude")
        self.assertEqual(self.host_read(), "allow")
        remove("antigravity")
        self.assertFalse(self.store.exists())
        self.assertEqual(self.host_read(), "deny")

    def test_uninstall_retains_scripts_if_claude_settings_invalid(self):
        claude = self.home / ".claude"
        claude.mkdir()
        args = ["-Target","claude"] if self.windows_engine else ["--target","claude"]
        self.invoke("install", *args)
        settings = claude/"settings.json"
        settings.write_text("{")
        self.failure("install", *args, "-Uninstall" if self.windows_engine else "--uninstall")
        suffix = "ps1" if self.windows_engine else "sh"
        self.assertTrue((claude/"hooks/agent-blindfold"/("guard." + suffix)).is_file())
        self.assertEqual(settings.read_text(), "{")

    def test_invalid_mode_ttl_and_document_type_pause_grants(self):
        for value in (["timed"], {"sessionAutoGrant":"unknown"}, {"defaultTTL":"0h"},
                      {"defaultTTL":"9"*40 + "d"}):
            (self.config/"agent-blindfold.json").write_text(json.dumps(value))
            self.session()
            self.assertFalse(self.store.exists(), value)

    def test_mixed_hooks_survive_reinstall_and_uninstall(self):
        claude = self.home / ".claude"
        claude.mkdir()
        path = claude / "settings.json"
        self.invoke("install")
        cfg = json.loads(path.read_text())
        other = {"type":"command", "command":"echo agent-blindfold-local-audit"}
        for event in ("SessionStart","PreToolUse"):
            owned = cfg["hooks"][event][0]["hooks"][0]
            # Exercise the exact command style written by the original 1.1.2 installers.
            if self.windows_engine and event == "PreToolUse":
                owned["command"] = owned["command"][:-len(" -HookHost claude")]
            if not self.windows_engine:
                owned["command"] = '"' + shlex.split(owned["command"])[0] + '"'
            cfg["hooks"][event][0]["hooks"].insert(0, other)
        path.write_text(json.dumps(cfg))
        self.invoke("install")
        installed = json.loads(path.read_text())["hooks"]
        for groups in installed.values():
            self.assertEqual(sum(h == other for g in groups for h in g["hooks"]), 1)
            self.assertEqual(sum(len(g["hooks"]) for g in groups), 2)
        self.invoke("install", "-Uninstall" if self.windows_engine else "--uninstall")
        cleaned = json.loads(path.read_text())["hooks"]
        for event in ("SessionStart","PreToolUse"):
            self.assertEqual([h for group in cleaned[event] for h in group["hooks"]], [other])


@unittest.skipUnless(PS, "PowerShell unavailable")
class PowerShellContract(HostContract, unittest.TestCase):
    windows_engine = True


@unittest.skipUnless(BASH, "Bash unavailable")
class BashContract(HostContract, unittest.TestCase):
    windows_engine = False

    def test_unavailable_interpreter_returns_deny(self):
        for host in ("antigravity", "claude"):
            env = dict(self.env, PATH=str(self.root/"empty-path"), VIRTUAL_ENV="")
            r = self.invoke("scripts/guard", host, raw=b"", env=env)
            data = json.loads(r.stdout)
            decision = data["decision"] if host == "antigravity" else data["hookSpecificOutput"]["permissionDecision"]
            self.assertEqual(decision, "deny")

    def select(self, env):
        script = (ROOT/"scripts/python_runtime.sh").as_posix()
        output = subprocess.check_output(
            [BASH, "-c", 'source "$1" && blindfold_select_python && printf "%s" "$PYTHON_BIN"', "test", script],
            cwd=self.ws, env=env, timeout=30)
        return Path(output.decode("utf-8"))

    def test_activated_venv_is_selected_without_path_fallback(self):
        venv = self.root/"venv with spaces"
        subprocess.run([sys.executable, "-m", "venv", "--without-pip", str(venv)],
                       capture_output=True, check=True, timeout=30)
        env = dict(self.env, PATH=str(self.root/"empty-path"), VIRTUAL_ENV=str(venv))
        self.assertEqual(self.select(env).parent.parent, venv)
        output = self.invoke("scripts/session_start", env=env, payload={"cwd":str(self.ws),"session_id":"offline"})
        self.assertEqual(output.stdout, b"")
        self.assertEqual(len(list(self.store.glob("*.json"))), 1)

    def test_broken_path_shim_does_not_hide_later_python(self):
        first, second = self.root/"bin1", self.root/"bin2"
        first.mkdir()
        second.mkdir()
        broken, working = first/"python3", second/"python3"
        broken.write_bytes(b"#!/bin/sh\nexit 99\n")
        real = Path(sys.executable).as_posix()
        working.write_bytes(("#!/bin/sh\nexec " + shlex.quote(real) + ' "$@"\n').encode())
        broken.chmod(0o755)
        working.chmod(0o755)
        env = dict(self.env, PATH=os.pathsep.join(map(str,(first, second))), VIRTUAL_ENV="")
        self.assertEqual(self.select(env).resolve(), Path(sys.executable).resolve())

    def test_runtime_error_does_not_reexecute_application(self):
        bin_dir = self.root/"bin"
        bin_dir.mkdir()
        shim = bin_dir/"python3"
        attempts = self.root/"attempts"
        # A successful interpreter probe followed by an application error.
        shim.write_bytes(b'#!/bin/sh\ncase " $* " in *" -c "*) printf "%s" "$0";; '
                         b'*) printf x >> "$ATTEMPTS"; exit 3;; esac\n')
        shim.chmod(0o755)
        env = dict(self.env, PATH=str(bin_dir), VIRTUAL_ENV="", ATTEMPTS=attempts.as_posix())
        result = self.invoke("scripts/guard","claude",raw=b"{}",env=env)
        decision = json.loads(result.stdout)["hookSpecificOutput"]["permissionDecision"]
        self.assertEqual((decision,attempts.read_text()),("deny","x"))

    @unittest.skipUnless(os.name == "nt", "Windows launcher contract")
    def test_windows_launcher_without_python_path_entry(self):
        folder = self.root/"launcher-only"
        folder.mkdir()
        launcher = folder/"py"
        real = shlex.quote(Path(sys.executable).as_posix())
        launcher.write_bytes(('#!/bin/sh\n[ "$1" = "-3" ] || exit 1\nshift\nexec ' + real + ' "$@"\n').encode())
        launcher.chmod(0o755)
        env = dict(self.env, PATH=str(folder), VIRTUAL_ENV="")
        self.assertEqual(self.select(env).resolve(), Path(sys.executable).resolve())

@unittest.skipUnless(os.name == "nt" and BASH and PS, "Windows dual-engine interoperability")
class CrossEngineContract(unittest.TestCase):
    def test_same_unicode_workspace_shares_grants(self):
        with tempfile.TemporaryDirectory(prefix="agent-blindfold-cross-", dir=ROOT) as temp:
            folder = Path(temp)
            home, ws = folder/"home", folder/"工程 MixedCase"
            home.mkdir()
            ws.mkdir()
            env = dict(os.environ, HOME=str(home), USERPROFILE=str(home))
            powershell = [PS,"-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",str(ROOT/"scripts/unlock.ps1")]
            shell = [BASH,(ROOT/"scripts/unlock.sh").as_posix()]
            def call(command):
                return subprocess.check_output(command, cwd=ws, env=env, timeout=30).decode(errors="replace")
            call(powershell + ["-Mode","permanent"])
            self.assertIn("UNLOCKED (PERMANENT)", call(shell + ["--status"]))
            call(shell + ["--lock"])
            self.assertIn("LOCKED", call(powershell + ["-Status"]))
            call(shell + ["--timed","30m"])
            self.assertIn("UNLOCKED (TIMED", call(powershell + ["-Status"]))
            self.assertEqual(len(list((home/".gemini/config/agent-blindfold-grants").glob("*.json"))), 1)
