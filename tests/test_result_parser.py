#!/usr/bin/env python3
"""Small stdlib-only reference parser contract."""
import importlib.util
import json
from pathlib import Path
import unittest

PATH = Path(__file__).resolve().parents[1] / "examples/wrappers/parse_result.py"
spec = importlib.util.spec_from_file_location("parse_result", PATH)
parser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parser)


class ParserTests(unittest.TestCase):
    def frame(self, **updates):
        meta = {"schema": "secrets-exec/metadata/1", "call_id": "test-1", "consumer": "demo",
                "credential_source": {"consumer": "demo", "bundle": "example", "key_names": ["TOKEN"]}}
        meta.update(updates)
        return b"SECRETS_EXEC_META_V1 " + json.dumps(meta).encode() + b"\n"

    def test_strip_only_first_line_and_preserve_bytes(self):
        body = b"\x00\xff\nSECRETS_EXEC_META_V1 consumer text\n"
        meta, output = parser.parse_result(self.frame() + body, expected_call_id="test-1")
        self.assertEqual(meta["credential_source"]["key_names"], ["TOKEN"])
        self.assertEqual(output, body)

    def test_null_source(self):
        meta, body = parser.parse_result(self.frame(credential_source=None))
        self.assertIsNone(meta["credential_source"])
        self.assertEqual(body, b"")

    def test_invalid_headers_fail_closed(self):
        cases = [b"", b"plain output\n", b"SECRETS_EXEC_META_V1 {}", b"SECRETS_EXEC_META_V1 []\n",
                 b"SECRETS_EXEC_META_V1 not-json\n", b"SECRETS_EXEC_META_V1 \xff\n",
                 self.frame(schema="future"), self.frame(call_id="bad id"), self.frame(extra="field"),
                 self.frame(consumer=None), self.frame(credential_source={}),
                 self.frame(credential_source={"consumer": "other", "bundle": "example", "key_names": ["TOKEN"]}),
                 self.frame(credential_source={"consumer": "demo", "bundle": "example", "key_names": []}),
                 self.frame(credential_source={"consumer": "demo", "bundle": "example", "key_names": [3]}),
                 self.frame(credential_source={"consumer": "demo", "bundle": "example", "key_names": ["TOKEN"], "extra": True})]
        for data in cases:
            with self.subTest(data=data):
                with self.assertRaises(ValueError):
                    parser.parse_result(data)

    def test_mismatched_identifier(self):
        with self.assertRaises(ValueError):
            parser.parse_result(self.frame(), expected_call_id="different")

    def test_duplicate_json_fields_rejected(self):
        data = self.frame().replace(b'"call_id": "test-1"', b'"call_id": "wrong", "call_id": "test-1"')
        with self.assertRaises(ValueError):
            parser.parse_result(data)


if __name__ == "__main__":
    unittest.main()
