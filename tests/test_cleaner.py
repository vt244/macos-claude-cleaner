"""Destructive integration tests confined to a temporary fixture on macOS.

No HOME override, no real Keychain calls, no real Claude data or processes.
Only cc_platform/process/Keychain boundaries are replaced. The manifest,
filesystem checks and deletion code run unchanged under Apple's Bash 3.2.
"""
import hashlib
import os
from pathlib import Path
import platform
import pty
import select
import shutil
import subprocess
import tempfile
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "clean-claude.sh"
CONFIRM_PROMPT = "Для безвозвратного удаления перечисленных данных введите DELETE: "
DRIVER = r'''
source "$1"
TEST_HOME=$2
TEST_CONTROL=$3
shift 3
cc_platform() {
    CC_HOME=$TEST_HOME
    CC_UID=$(/usr/bin/id -u)
    CC_USER=fixture-user
    CC_TEMP=$TEST_CONTROL/tmp
    CC_SYSTEM_TEMP=$TEST_CONTROL/system-tmp
}
cc_process_snapshot() {
    [[ ! -f "$TEST_CONTROL/ps-error" ]] || return 1
    if [[ -f "$TEST_CONTROL/swap-link" ]]; then
        /bin/mv "$CC_HOME/.claude/debug" "$CC_HOME/.claude/debug-original"
        /bin/ln -s "$CC_HOME/project" "$CC_HOME/.claude/debug"
        /bin/rm "$TEST_CONTROL/swap-link"
    fi
    if [[ -f "$TEST_CONTROL/swap-directory" ]]; then
        /bin/mv "$CC_HOME/.claude/debug" "$CC_HOME/.claude/debug-original"
        /bin/mkdir "$CC_HOME/.claude/debug"
        printf 'new' > "$CC_HOME/.claude/debug/log.txt"
        /bin/rm "$TEST_CONTROL/swap-directory"
    fi
    /bin/cat "$TEST_CONTROL/processes"
}
cc_process_args() { /bin/cat "$TEST_CONTROL/args"; }
cc_security() {
    printf '%s\0' "$@" >> "$TEST_CONTROL/security-calls"
    local item="$TEST_CONTROL/keys/$3--$5"
    case "$1" in
        find-generic-password)
            [[ ! -f "$TEST_CONTROL/keychain-locked" ]] || return 36
            [[ -f "$item" ]] && return 0
            return 44 ;;
        delete-generic-password)
            [[ ! -f "$TEST_CONTROL/keychain-denied" ]] || return 36
            /bin/rm "$item" ;;
        *) return 99 ;;
    esac
}
cc_main "$@"
'''


@unittest.skipUnless(platform.system() == "Darwin", "Requires macOS stat/find and Bash 3.2")
class CleanerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="claude-cleaner-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / 'home with spaces; $(touch PWNED)'
        self.control = self.root / "control"
        self.home.mkdir()
        (self.control / "keys").mkdir(parents=True)
        (self.control / "processes").touch()
        (self.control / "args").touch()
        self.write("Library/Keychains/login.keychain-db", "fake keychain")

    def write(self, relative, content="fixture data"):
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def run_cleaner(self, *args, expected=0, interactive=True, answer="DELETE", before_confirm=None):
        env = os.environ.copy()
        for key in ("CLAUDE_CONFIG_DIR", "CLAUDE_CODE_TMPDIR", "XDG_CACHE_HOME"):
            env.pop(key, None)
        command = ["/bin/bash", "-c", DRIVER, "fixture-driver", str(SCRIPT),
                   str(self.home), str(self.control), *args]
        if interactive:
            # Exercise the real terminal check and prompt; send a reply only
            # after observing the complete plan. Never stub confirmation itself.
            master, slave = pty.openpty()
            process = None
            output = bytearray()
            answered = False
            deadline = time.monotonic() + 30
            try:
                process = subprocess.Popen(command, stdin=slave, stdout=subprocess.PIPE,
                                           stderr=subprocess.STDOUT, env=env)
                os.close(slave)
                slave = None
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]:
                        raise subprocess.TimeoutExpired(command, 30, output=bytes(output))
                    data = os.read(process.stdout.fileno(), 65536)
                    if not data:
                        break
                    output.extend(data)
                    if not answered and CONFIRM_PROMPT.encode() in output:
                        if before_confirm is not None:
                            before_confirm(output.decode())
                        reply = b"\x04" if answer is None else (answer + "\n").encode()
                        os.write(master, reply)
                        answered = True
                result = subprocess.CompletedProcess(command, process.wait(timeout=5),
                                                     output.decode(), "")
            finally:
                if process is not None:
                    if process.poll() is None:
                        process.kill()
                    process.wait(timeout=5)
                    process.stdout.close()
                if slave is not None:
                    os.close(slave)
                os.close(master)
        else:
            result = subprocess.run(command, input="" if answer is None else answer + "\n",
                                    capture_output=True, text=True, env=env, timeout=30)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertFalse((self.home / "PWNED").exists())
        return result

    def snapshot(self, path):
        result = {}
        for item in path.rglob("*"):
            rel = str(item.relative_to(path))
            if item.is_symlink():
                result[rel] = ("link", os.readlink(item))
            elif item.is_file():
                result[rel] = ("file", hashlib.sha256(item.read_bytes()).hexdigest())
            elif item.is_dir():
                result[rel] = ("dir",)
        return result

    def test_dry_run_does_not_prompt_or_access_keychain(self):
        self.write(".claude/projects/test/session.jsonl")
        self.write(".claude/projects/test/memory/MEMORY.md")
        self.write(".claude/history.jsonl")
        self.write("Library/Application Support/Claude/Local Storage/leveldb/00001.ldb")
        before = self.snapshot(self.home)
        result = self.run_cleaner("--dry-run", interactive=False)
        self.assertIn("Ничего не удалено", result.stdout)
        self.assertNotIn(CONFIRM_PROMPT, result.stdout)
        self.assertEqual(before, self.snapshot(self.home))
        self.assertFalse((self.control / "security-calls").exists())

    def test_apply_and_repeat_remove_only_named_data(self):
        doomed = [
            ".claude.json", ".claude.json.backup", ".claude.json.backup.1234",
            ".claude/projects/project/session.jsonl",
            ".claude/projects/project/memory/MEMORY.md",
            ".claude/debug/log\nwith newline.txt", ".claude/history.jsonl",
            ".claude/settings.json", ".claude/shell-snapshots/snapshot-123.sh",
            ".claude/file-history/uuid/abcdef@v1", ".claude/.credentials.json",
            ".cache/claude/staging/cache.bin", ".local/state/claude/lock",
            "Library/Caches/claude-cli-nodejs/project/debug.txt",
            "Library/Application Support/Claude/config.json",
            "Library/Application Support/Claude/claude_desktop_config.json",
            "Library/Application Support/Claude/ant-did",
            "Library/Application Support/Claude/Cache/Cache_Data/data_0",
            "Library/Application Support/Claude/Local Storage/leveldb/000003.ldb",
            "Library/Preferences/com.anthropic.claudefordesktop.plist",
            "Library/Logs/Claude/main.log",
        ]
        for path in doomed:
            self.write(path)
        (self.home / ".claude/file-history/uuid/abcdef@v1").chmod(0o755)
        (self.home / ".claude/shell-snapshots/snapshot-123.sh").chmod(0o755)
        protected = [
            "project/src/main.py", "project/CLAUDE.md", "project/.mcp.json",
            "project/.claude/settings.local.json", "project/.claude/worktrees/a/main.py",
            ".codex/sessions/session.jsonl", ".zsh_history",
            "Library/Application Support/OtherApp/Cache/data",
            "Library/Caches/com.example.claude-helper/data",
            "Applications/Claude.app/Contents/MacOS/Claude",
            ".local/bin/claude", ".local/share/claude/versions/1.2.3",
        ]
        for path in protected:
            self.write(path, "must survive")
        self.run_cleaner("--apply")
        self.run_cleaner("--apply")
        for path in doomed:
            self.assertFalse((self.home / path).exists(), path)
        for path in protected:
            self.assertEqual((self.home / path).read_text(), "must survive", path)

    def test_user_authored_paths_are_reported_and_preserved(self):
        protected = [
            ".claude/CLAUDE.md", ".claude/skills/custom/script.py",
            ".claude/hooks/custom.sh", ".claude/plugins/marketplaces/local/main.js",
            ".claude/worktrees/feature/main.py", ".claude/unknown/important.txt",
            "Library/Application Support/Claude/git-worktrees.json",
            "Library/Application Support/Claude/local-agent-mode-sessions/a/output.xlsx",
            "Library/Application Support/Claude/claude-code-vm/vm.img",
        ]
        for path in protected:
            self.write(path, "keep")
        self.write(".claude/history.jsonl")
        result = self.run_cleaner("--apply", expected=1)
        self.assertIn("СОХРАНИТЬ", result.stdout)
        self.assertFalse((self.home / ".claude/history.jsonl").exists())
        for path in protected:
            self.assertEqual((self.home / path).read_text(), "keep")

    def test_source_and_repository_in_cache_block_whole_candidate(self):
        for marker in ("main.py", "page.html", "script.ps1", ".git", "package.json", "sub/worktrees/file.txt"):
            with self.subTest(marker=marker):
                self.write(f".claude/cache/{marker}", "keep source")
                log = self.write(".claude/cache/cache.txt")
                before = self.snapshot(self.home / ".claude/cache")
                self.run_cleaner("--apply", expected=1)
                self.assertEqual(before, self.snapshot(self.home / ".claude/cache"))
                self.assertTrue(log.exists())
                shutil.rmtree(self.home / ".claude/cache")

    def test_root_symlink_is_not_followed(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "history.jsonl").write_text("keep")
        (self.home / ".claude").symlink_to(outside, target_is_directory=True)
        self.run_cleaner("--apply", expected=1)
        self.assertEqual((outside / "history.jsonl").read_text(), "keep")
        self.assertTrue((self.home / ".claude").is_symlink())

    def test_parent_symlink_is_not_followed(self):
        outside = self.root / "other-library"
        outside.mkdir()
        (outside / "Caches/claude-cli-nodejs").mkdir(parents=True)
        protected = outside / "Caches/claude-cli-nodejs/valuable.txt"
        protected.write_text("keep")
        os.rename(self.home / "Library", self.home / "Library-original")
        (self.home / "Library").symlink_to(outside, target_is_directory=True)
        self.run_cleaner("--apply", "--keep-keychain", expected=1)
        self.assertEqual(protected.read_text(), "keep")

    def test_nested_symlink_and_hardlink_are_preserved(self):
        original = self.write("project/main.py", "keep")
        cache = self.home / ".claude/cache"
        cache.mkdir(parents=True)
        (cache / "link").symlink_to(original)
        history = self.write("project/history.jsonl", "keep history")
        os.link(history, self.home / ".claude/history.jsonl")
        self.run_cleaner("--apply", expected=1)
        self.assertEqual(original.read_text(), "keep")
        self.assertTrue((cache / "link").is_symlink())
        self.assertEqual(history.stat().st_nlink, 2)

    def test_unexpected_directory_instead_of_file_is_preserved(self):
        file = self.write(".claude.json/precious.txt", "keep")
        self.run_cleaner("--apply", expected=1)
        self.assertEqual(file.read_text(), "keep")

    def test_scope_is_respected(self):
        cli = self.write(".claude/history.jsonl")
        desktop = self.write("Library/Application Support/Claude/config.json")
        self.run_cleaner("--scope", "code", "--apply")
        self.assertFalse(cli.exists())
        self.assertTrue(desktop.exists())
        cli = self.write(".claude/history.jsonl")
        self.run_cleaner("--scope", "desktop", "--apply")
        self.assertTrue(cli.exists())
        self.assertFalse(desktop.exists())

    def test_active_process_prevents_any_deletion(self):
        for executable in ("claude", "/Applications/Claude.app/Contents/MacOS/Claude",
                           "/x/.local/share/claude/versions/2.0", "/usr/bin/node"):
            with self.subTest(executable=executable):
                history = self.write(".claude/history.jsonl", "keep")
                (self.control / "processes").write_text(f"{os.getuid()} 999 {executable}\n")
                (self.control / "args").write_text("node /lib/@anthropic-ai/claude-code/cli.js")
                self.run_cleaner("--apply", expected=3)
                self.assertEqual(history.read_text(), "keep")
                self.assertFalse((self.control / "security-calls").exists())

    def test_process_inspection_failure_prevents_deletion(self):
        path = self.write(".claude/history.jsonl", "keep")
        (self.control / "ps-error").touch()
        self.run_cleaner("--apply", expected=3)
        self.assertEqual(path.read_text(), "keep")

    def test_path_replaced_after_plan_is_not_deleted(self):
        for mode in ("swap-link", "swap-directory"):
            with self.subTest(mode=mode):
                debug = self.home / ".claude/debug"
                if debug.is_symlink():
                    debug.unlink()
                self.write(".claude/debug/log.txt", "old")
                self.write("project/keep.txt", "keep")
                (self.control / mode).touch()
                self.run_cleaner("--apply", expected=1)
                self.assertEqual((self.home / "project/keep.txt").read_text(), "keep")
                self.assertTrue(debug.exists())

    def test_exact_keychain_service_and_account_only(self):
        keys = self.control / "keys"
        doomed = ["Claude Code-credentials--fixture-user", "Claude Code--fixture-user",
                  "Claude Code-device-keys--fixture-user", "Claude Safe Storage--Claude Key"]
        preserved = ["OtherApp--fixture-user", "Claude Code-credentials--other-account"]
        for name in doomed + preserved:
            (keys / name).write_text("secret never printed")
        result = self.run_cleaner("--apply")
        for name in doomed:
            self.assertFalse((keys / name).exists())
        for name in preserved:
            self.assertTrue((keys / name).exists())
        calls = (self.control / "security-calls").read_bytes().split(b"\0")
        self.assertNotIn(b"-w", calls)
        self.assertNotIn(b"-g", calls)
        self.assertNotIn("secret never printed", result.stdout + result.stderr)

    def test_keychain_error_is_not_silently_treated_as_missing(self):
        (self.control / "keychain-locked").touch()
        self.run_cleaner("--apply", expected=1)
        calls = (self.control / "security-calls").read_bytes()
        self.assertNotIn(b"delete-generic-password", calls)

    def test_keep_keychain_never_calls_security(self):
        self.run_cleaner("--apply", "--keep-keychain")
        self.assertFalse((self.control / "security-calls").exists())

    def test_invalid_or_noninteractive_invocation_cannot_delete(self):
        history = self.write(".claude/history.jsonl", "keep")
        for args in (("--yes",), ("--apply", "--yes"), ("--scope",), ("--scope", "bad"),
                     ("--unknown",), ("--apply", "--dry-run"), ("--apply",), ()):
            with self.subTest(args=args):
                self.run_cleaner(*args, interactive=False, expected=2)
                self.assertEqual(history.read_text(), "keep")
                self.assertFalse((self.control / "security-calls").exists())

    def test_default_shows_complete_plan_before_confirmation(self):
        history = self.write(".claude/history.jsonl", "keep until DELETE")
        desktop = self.write("Library/Application Support/Claude/config.json")
        key = self.control / "keys/Claude Code-credentials--fixture-user"
        key.write_text("keep until DELETE")
        before = self.snapshot(self.home)
        reached_prompt = []

        def check_before_confirm(output):
            reached_prompt.append(True)
            self.assertEqual(before, self.snapshot(self.home))
            self.assertTrue(key.exists())
            self.assertFalse((self.control / "security-calls").exists())
            prompt_at = output.index(CONFIRM_PROMPT)
            for entry in ("history.jsonl", "config.json", "KEYCHAIN", "УДАЛИТЬ ЕСЛИ ПУСТО"):
                self.assertLess(output.index(entry), prompt_at)
            self.assertNotIn("УДАЛЕНО", output)

        result = self.run_cleaner(before_confirm=check_before_confirm)
        self.assertTrue(reached_prompt)
        self.assertFalse(history.exists())
        self.assertFalse(desktop.exists())
        self.assertFalse(key.exists())
        self.assertLess(result.stdout.index(CONFIRM_PROMPT), result.stdout.index("УДАЛЕНО"))

    def test_decline_blank_or_eof_never_changes_data(self):
        self.write(".claude/history.jsonl", "keep")
        key = self.control / "keys/Claude Code-credentials--fixture-user"
        key.write_text("keep")
        before = self.snapshot(self.home)
        for args in ((), ("--apply",)):
            for answer in ("", "нет", "yes", "delete", "DELETE ", None):
                with self.subTest(args=args, answer=answer):
                    result = self.run_cleaner(*args, answer=answer)
                    self.assertIn(CONFIRM_PROMPT, result.stdout)
                    self.assertIn("Отменено. Ничего не удалено.", result.stdout)
                    self.assertEqual(before, self.snapshot(self.home))
                    self.assertTrue(key.exists())
                    self.assertFalse((self.control / "security-calls").exists())

    def test_temp_tree_is_scoped_to_exact_user_directory(self):
        known = self.control / "system-tmp" / f"claude-{os.getuid()}"
        other = self.control / "system-tmp" / f"claude-{os.getuid()}-other"
        for path in (known, other):
            path.mkdir(parents=True)
            (path / "log.txt").write_text("data")
        self.run_cleaner("--apply")
        self.assertFalse(known.exists())
        self.assertTrue((other / "log.txt").exists())

    def test_empty_roots_are_removed_but_shared_parents_remain(self):
        cli_root = self.home / ".claude"
        desktop_root = self.home / "Library/Application Support/Claude"
        cli_root.mkdir()
        desktop_root.mkdir(parents=True)
        self.run_cleaner("--apply")
        self.assertFalse(cli_root.exists())
        self.assertFalse(desktop_root.exists())
        self.assertTrue(desktop_root.parent.exists())

    def test_executable_in_cache_and_unknown_backup_are_preserved(self):
        executable = self.write(".claude/cache/my-program", "keep")
        executable.chmod(0o755)
        backup = self.write(".claude.json.backup.important.py", "keep source")
        self.run_cleaner("--apply", expected=1)
        self.assertEqual(executable.read_text(), "keep")
        self.assertEqual(backup.read_text(), "keep source")

    def test_custom_script_in_snapshots_is_preserved(self):
        script = self.write(".claude/shell-snapshots/my-script.sh", "keep script")
        script.chmod(0o755)
        self.run_cleaner("--apply", expected=1)
        self.assertEqual(script.read_text(), "keep script")


if __name__ == "__main__":
    unittest.main()
