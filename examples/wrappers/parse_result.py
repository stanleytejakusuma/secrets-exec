#!/usr/bin/env python3
"""Parse an opt-in broker frame; never execute a consumer or authorize from metadata."""
import json
import re
import sys

PREFIX = b"SECRETS_EXEC_META_V1 "


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate metadata field")
        result[key] = value
    return result


def parse_result(stdout, *, expected_call_id=None):
    """Return (metadata, untouched body bytes), or raise ValueError on a bad frame.

    Pass captured stdout as bytes. Keep process status/stderr separately; a valid
    header is neither authenticated provenance nor proof of a successful fetch.
    An expected ID catches mismatched results, not same-user forgery.
    """
    first, newline, body = stdout.partition(b"\n")
    if not newline or not first.startswith(PREFIX):
        raise ValueError("missing metadata header")
    meta = json.loads(first[len(PREFIX):].decode("utf-8"), object_pairs_hook=_unique_object)
    fields = {"schema", "call_id", "consumer", "credential_source"}
    if not isinstance(meta, dict) or set(meta) != fields:
        raise ValueError("invalid metadata fields")
    if meta["schema"] != "secrets-exec/metadata/1":
        raise ValueError("unsupported metadata schema")
    if not isinstance(meta["call_id"], str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,96}", meta["call_id"]):
        raise ValueError("invalid call identifier")
    if expected_call_id is not None and meta["call_id"] != expected_call_id:
        raise ValueError("mismatched call identifier")
    if not isinstance(meta["consumer"], str) or not meta["consumer"]:
        raise ValueError("invalid consumer name")
    source = meta["credential_source"]
    if source is not None:
        if not isinstance(source, dict) or set(source) != {"consumer", "bundle", "key_names"}:
            raise ValueError("invalid credential source fields")
        if source["consumer"] != meta["consumer"]:
            raise ValueError("mismatched consumer name")
        if not isinstance(source["bundle"], str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", source["bundle"]):
            raise ValueError("invalid bundle name")
        keys = source["key_names"]
        if not isinstance(keys, list) or not keys or not all(
            isinstance(key, str) and re.fullmatch(r"[A-Za-z0-9_.-]+", key) for key in keys
        ):
            raise ValueError("invalid key names")
    return meta, body


if __name__ == "__main__":
    # Filter already-captured output. Do not reflect malformed header text in errors.
    try:
        metadata, payload = parse_result(sys.stdin.buffer.read())
    except ValueError:
        sys.exit("invalid broker metadata frame")
    sys.stdout.buffer.write(payload)
