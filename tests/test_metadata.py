#!/usr/bin/env python3
"""Offline broker framing tests: copy the engine and replace every SSH site."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PREFIX = b"SECRETS_EXEC_META_V1 "
VALUES = {"TOKEN_A": "fixture-value-alpha-8274", "TOKEN_B": "fixture-value-beta-9362"}
BODY = b'consumer output\n\x00unchanged bytes\xff\n'


class MetadataTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="metadata-test-")
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        (self.home / "bin").mkdir()
        self.conf = self.home / ".config/secrets-exec"
        self.conf.mkdir(parents=True)
        self.audit = self.conf / "audit.log"
        self.transport = self.home / "ssh.jsonl"
        fake = self.home / "fake-transport"
        fake.write_text('''#!/usr/bin/python3 -I
import json, os, shlex, sys
from pathlib import Path
assert not any(n.startswith('SECRETS_EXEC_') for n in os.environ)
words = shlex.split(sys.argv[-1])
with open(os.environ['FIXTURE_TRANSPORT'], 'a') as stream:
    stream.write(json.dumps(words) + '\\n')
values = json.loads(os.environ['FIXTURE_VALUES'])
if words[0] == 'kv-list':
    print('keys:')
    print('\\n'.join(values))
elif words[0] == 'kv-get':
    if os.environ.get('FIXTURE_HEADER_OUTPUT'):
        first = Path(os.environ['FIXTURE_HEADER_OUTPUT']).read_bytes().split(b'\\n', 1)[0]
        assert first.startswith(b'SECRETS_EXEC_META_V1 ')
        assert json.loads(first.split(b' ', 1)[1])['credential_source']['key_names'] == ['TOKEN_A']
    if os.environ.get('FIXTURE_FETCH_FAIL') == '1':
        sys.exit(255)
    print(values.get(words[2], ''))
else:
    sys.exit(99)
''')
        fake.chmod(0o700)
        source = (ROOT / "bin/secrets-exec").read_text()
        needle = "ssh -n -o BatchMode=yes"
        self.assertEqual(source.count(needle), 1, "the single transport site must be stubbed")
        source = source.replace(needle, shlex.quote(str(fake)) + " -n -o BatchMode=yes")
        self.assertNotIn(needle, source)
        self.engine = self.home / "bin/secrets-exec"
        self.engine.write_text(source)
        self.engine.chmod(0o700)
        self.consumer = self.home / "consumer-reader"
        self.consumer.write_text('''#!/usr/bin/python3 -I
import json, os, subprocess, sys
from pathlib import Path
Path(os.environ['FIXTURE_RAN']).touch()
state = {'internal': [n for n in os.environ if n.startswith('SECRETS_EXEC_') or n == 'call_id' or n.startswith('_metadata_')],
         'present': [bool(os.environ.get(n)) for n in ('DEMO_TOKEN', 'DEMO_SECOND')]}
Path(os.environ['FIXTURE_STATE']).write_text(json.dumps(state))
if sys.argv[1:] == ['nested']:
    child = subprocess.run([os.environ['FIXTURE_ENGINE'], '--list'], capture_output=True, check=True)
    assert not child.stdout.startswith(b'SECRETS_EXEC_META_V1 ')
sys.stdout.buffer.write(b'consumer output\\n\\x00unchanged bytes\\xff\\n')
''')
        self.consumer.chmod(0o700)
        self.registry = self.conf / "consumers.conf"
        self.row("exact", "TOKEN_A", "DEMO_TOKEN")
        self.backend = self.conf / "backend.conf"
        self.backend.write_text("host=keyhost.example\nget=kv-get {bundle} {key}\nlist=kv-list {bundle}\n")
        self.env = {"PATH": "/usr/bin:/bin", "HOME": str(self.home),
                    "FIXTURE_TRANSPORT": str(self.transport), "FIXTURE_VALUES": json.dumps(VALUES),
                    "FIXTURE_RAN": str(self.home / "ran"), "FIXTURE_STATE": str(self.home / "state.json"),
                    "FIXTURE_ENGINE": str(self.engine)}

    def row(self, name, keys, destinations, command=None, bundle="fixture", guard=""):
        self.registry.write_text(f"{name}|{bundle}|{keys}|{destinations}|{command or self.consumer}|{guard}\n")

    def run_engine(self, *args, metadata=True, call_id="fixture-call-1", extra=None):
        env = dict(self.env)
        if metadata:
            env["SECRETS_EXEC_METADATA"] = "1"
        if call_id is not None:
            env["SECRETS_EXEC_CALL_ID"] = call_id
        env.update(extra or {})
        result = subprocess.run([str(self.engine), *args], env=env, capture_output=True, timeout=20)
        self.assert_no_values(result)
        return result

    def frame(self, result):
        first, sep, body = result.stdout.partition(b"\n")
        self.assertTrue(first.startswith(PREFIX), "first stdout line must be a metadata header")
        self.assertEqual(sep, b"\n")
        meta = json.loads(first[len(PREFIX):])
        self.assertEqual(set(meta), {"schema", "call_id", "consumer", "credential_source"})
        self.assertEqual(meta["schema"], "secrets-exec/metadata/1")
        self.assertRegex(meta["call_id"], r"^[A-Za-z0-9._-]{1,96}$")
        self.assertNotIn(PREFIX, body, "broker must emit exactly one header")
        return meta, body

    def assert_no_values(self, result):
        output = result.stdout + result.stderr
        for path in (self.audit, self.transport):
            if path.is_file():
                output += path.read_bytes()
        for value in VALUES.values():
            self.assertNotIn(value.encode(), output)

    def assert_not_run(self, fetch=False):
        self.assertFalse((self.home / "ran").exists())
        if not fetch:
            self.assertFalse(self.transport.exists())

    def test_exact(self):
        result = self.run_engine("exact")
        self.assertEqual(result.returncode, 0, result.stderr)
        meta, body = self.frame(result)
        self.assertEqual(meta, {"schema": "secrets-exec/metadata/1", "call_id": "fixture-call-1",
                               "consumer": "exact", "credential_source": {
                                   "consumer": "exact", "bundle": "fixture", "key_names": ["TOKEN_A"]}})
        self.assertEqual(body, BODY)

    def test_wildcard_resolved(self):
        self.row("wild", "*A", "DEMO_TOKEN")
        result = self.run_engine("wild")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.frame(result)[0]["credential_source"]["key_names"], ["TOKEN_A"])
        self.assertEqual([json.loads(line)[0] for line in self.transport.read_text().splitlines()],
                         ["kv-list", "kv-get"])

    def test_multi_key(self):
        self.row("multi", "TOKEN_A+TOKEN_B", "DEMO_TOKEN+DEMO_SECOND")
        result = self.run_engine("multi")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.frame(result)[0]["credential_source"]["key_names"], ["TOKEN_A", "TOKEN_B"])
        self.assertEqual(json.loads((self.home / "state.json").read_text())["present"], [True, True])

    def test_policy_refusals_have_null_source(self):
        cases = [("missing",), ("bad\nname",), ("exact", "https://example.invalid"), ("exact", "--unsafe")]
        self.row("exact", "TOKEN_A", "DEMO_TOKEN", guard="--unsafe")
        for args in cases:
            with self.subTest(args=args):
                result = self.run_engine(*args)
                self.assertEqual(result.returncode, 2)
                self.assertIsNone(self.frame(result)[0]["credential_source"])
                self.assert_not_run()

    def test_malformed_backend_null_source(self):
        self.backend.write_text("host=-option\nget=kv-get {bundle} {key}\nlist=kv-list {bundle}\n")
        result = self.run_engine("exact")
        self.assertEqual(result.returncode, 2)
        self.assertIsNone(self.frame(result)[0]["credential_source"])
        self.assert_not_run()

    def test_invalid_selection_null_source(self):
        self.row("bad", "TOK;EN", "DEMO_TOKEN")
        result = self.run_engine("bad")
        self.assertEqual(result.returncode, 2)
        self.assertIsNone(self.frame(result)[0]["credential_source"])
        self.assert_not_run()

    def test_ambiguous_wildcard_null_source(self):
        self.row("wild", "TOKEN_*", "DEMO_TOKEN")
        result = self.run_engine("wild")
        self.assertEqual(result.returncode, 2)
        self.assertIsNone(self.frame(result)[0]["credential_source"])
        self.assert_not_run(fetch=True)
        self.assertEqual(len(self.transport.read_text().splitlines()), 1)

    def test_list_null_and_body_unchanged(self):
        for arg in ("--list", "-l"):
            result = self.run_engine(arg)
            meta, body = self.frame(result)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(meta["consumer"], "list")
            self.assertIsNone(meta["credential_source"])
            self.assertEqual(body, self.run_engine(arg, metadata=False).stdout)
        self.assert_not_run()

    def test_no_arguments_has_null_header(self):
        result = self.run_engine()
        self.assertEqual(result.returncode, 1)
        self.assertIsNone(self.frame(result)[0]["credential_source"])
        self.assert_not_run()

    def test_plain_stdout_byte_identical(self):
        for flag in (None, "0", "yes"):
            extra = {} if flag is None else {"SECRETS_EXEC_METADATA": flag}
            result = self.run_engine("exact", metadata=False, call_id=None, extra=extra)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, BODY)
            self.assertEqual(result.stderr, b"")

    def test_controls_cleared_in_transport_consumer_and_nested_call(self):
        result = self.run_engine("exact", "nested", extra={"SECRETS_EXEC_OTHER": "ignored", "call_id": "inherited", "_metadata_sent": "inherited"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.home / "state.json").read_text())["internal"], [])
        self.assertEqual(self.frame(result)[1], BODY)

    def test_invalid_ids_not_echoed(self):
        for bad in ("", "bad\nforged=1", "x" * 97, "bad id", "quote'", "nonascii-é"):
            with self.subTest(length=len(bad)):
                before = self.audit.read_bytes() if self.audit.exists() else b""
                result = self.run_engine("exact", call_id=bad)
                self.assertEqual(result.returncode, 2)
                meta, _ = self.frame(result)
                self.assertNotEqual(meta["call_id"], bad)
                if bad:
                    self.assertNotIn(bad.encode(), result.stdout + result.stderr + self.audit.read_bytes()[len(before):])
                self.assertEqual(len(self.audit.read_bytes()[len(before):].splitlines()), 1)
                self.assert_not_run()

    def test_invalid_id_refused_without_metadata(self):
        result = self.run_engine("exact", metadata=False, call_id="bad id")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, b"")
        self.assert_not_run()

    def test_identifier_boundaries(self):
        for cid in ("a", "A._-09", "x" * 96):
            with self.subTest(call_id=cid):
                result = self.run_engine("exact", call_id=cid)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.frame(result)[0]["call_id"], cid)

    def test_generated_identifiers_are_distinct_and_correlated(self):
        ids = []
        for _ in range(2):
            result = self.run_engine("exact", call_id=None)
            self.assertEqual(result.returncode, 0, result.stderr)
            ids.append(self.frame(result)[0]["call_id"])
        self.assertNotEqual(*ids)
        records = self.audit.read_text().splitlines()
        self.assertEqual(len(records), 4)
        for cid, pair in zip(ids, (records[:2], records[2:])):
            for line in pair:
                self.assertIn("call_id=" + cid, line)
                self.assertIn(" via=secrets-exec args=", line)

    def test_fetch_failure_preserves_selection(self):
        result = self.run_engine("exact", extra={"FIXTURE_FETCH_FAIL": "1"})
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.frame(result)[0]["credential_source"]["key_names"], ["TOKEN_A"])
        self.assert_not_run(fetch=True)

    def test_multi_fetch_failure_preserves_all_selected_names(self):
        self.row("multi", "TOKEN_A+TOKEN_B", "DEMO_TOKEN+DEMO_SECOND")
        result = self.run_engine("multi", extra={"FIXTURE_VALUES": json.dumps({"TOKEN_A": VALUES["TOKEN_A"]})})
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.frame(result)[0]["credential_source"]["key_names"], ["TOKEN_A", "TOKEN_B"])
        self.assert_not_run(fetch=True)

    def test_closed_header_pipe_prevents_fetch(self):
        env = dict(self.env, SECRETS_EXEC_METADATA="1")
        read_fd, write_fd = os.pipe()
        os.close(read_fd)
        try:
            result = subprocess.run([str(self.engine), "exact"], env=env, stdout=write_fd,
                                    stderr=subprocess.PIPE, timeout=10)
        finally:
            os.close(write_fd)
        self.assertNotEqual(result.returncode, 0)
        self.assert_not_run()

    def test_reserved_destinations(self):
        for destination in ("SECRETS_EXEC_CALL_ID", "SECRETS_EXEC_METADATA", "SECRETS_EXEC_ANYTHING", "call_id", "_metadata_keys", "_metadata_bundle", "_metadata_sent", "_call_id_input", "_invalid_call_id"):
            with self.subTest(destination=destination):
                self.row("reserved", "TOKEN_A", destination)
                result = self.run_engine("reserved")
                self.assertEqual(result.returncode, 2)
                self.assertIsNone(self.frame(result)[0]["credential_source"])
                self.assert_not_run()
        self.row("reserved", "TOKEN_A+TOKEN_B", "DEMO_TOKEN+SECRETS_EXEC_CALL_ID")
        result = self.run_engine("reserved")
        self.assertEqual(result.returncode, 2)
        self.assertIsNone(self.frame(result)[0]["credential_source"])
        self.assert_not_run()

    def test_header_written_before_fetch(self):
        output = self.home / "stdout.bin"
        env = dict(self.env, SECRETS_EXEC_METADATA="1", FIXTURE_HEADER_OUTPUT=str(output))
        with output.open("wb") as stream:
            result = subprocess.run([str(self.engine), "exact"], env=env, stdout=stream,
                                    stderr=subprocess.PIPE, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_bytes().partition(b"\n")[2], BODY)

    def test_lock_failure_prevents_consumer(self):
        fake_lock = self.home / "failed-lock"
        fake_lock.write_text("#!/bin/sh\nexit 1\n")
        fake_lock.chmod(0o700)
        source = self.engine.read_text()
        self.assertIn("/usr/bin/flock -x 9", source)
        self.engine.write_text(source.replace("/usr/bin/flock -x 9", shlex.quote(str(fake_lock)) + " -x 9"))
        result = self.run_engine("exact")
        self.assertEqual(result.returncode, 1)
        self.assert_not_run(fetch=True)
        self.assertEqual(self.audit.read_bytes(), b"")

    def test_audit_unwritable_prevents_consumer(self):
        self.audit.mkdir()
        result = self.run_engine("exact")
        self.assertEqual(result.returncode, 1)
        self.frame(result)
        self.assert_not_run(fetch=True)

    def test_parallel_records_are_complete_and_not_interleaved(self):
        self.assert_parallel_records()

    def test_missing_flock_uses_serialized_python_fallback(self):
        source = self.engine.read_text()
        self.engine.write_text(source.replace("/usr/bin/flock", str(self.home / "missing-flock")))
        self.assert_parallel_records()

    def assert_parallel_records(self):
        args = ["x" * 4096] * 20
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda i: self.run_engine("exact", *args, call_id=f"parallel-{i}"), range(8)))
        for i, result in enumerate(results):
            self.assertEqual(result.returncode, 0, result.stderr[:200])
            self.assertEqual(self.frame(result)[0]["call_id"], f"parallel-{i}")
        records = self.audit.read_text().splitlines()
        self.assertEqual(len(records), 16)
        events = {}
        for line in records:
            tokens = shlex.split(line)
            cids = [t for t in tokens if t.startswith("call_id=")]
            self.assertEqual(len(cids), 1)
            index = next(i for i, t in enumerate(tokens) if t.startswith("args="))
            self.assertEqual(tokens[index - 1], "via=secrets-exec")
            self.assertEqual(tokens[index:], ["args=exact", *args])
            events.setdefault(cids[0], []).extend(t for t in tokens if t.startswith("outcome="))
        self.assertEqual(len(events), 8)
        for outcomes in events.values():
            self.assertCountEqual(outcomes, ["outcome=allowed", "outcome=exit"])

    def test_escaped_audit_stays_on_one_line(self):
        result = self.run_engine("exact", "line\nnext", "space value", "'quote'")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.audit.read_text().splitlines()), 2)
        self.assertIn("$'line\\nnext'", self.audit.read_text())


if __name__ == "__main__":
    unittest.main()
