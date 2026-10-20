#!/usr/bin/env python3
"""Validate file-meta document schema and 24h filter logic (Linux stand-in for PS DryRun)."""
from __future__ import annotations

import json
import os
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

REQUIRED_FIELDS = {
    "fullPath",
    "fileName",
    "directory",
    "extension",
    "length",
    "creationTimeUtc",
    "lastWriteTimeUtc",
    "lastAccessTimeUtc",
    "attributes",
    "isReadOnly",
    "isHidden",
    "drive",
    "hostName",
    "collectedAtUtc",
    "lookbackHours",
}


def ext_date(dt: datetime) -> dict:
    return {"$date": dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"}


def to_doc(path: Path, collected_at: datetime, lookback_hours: int = 24) -> dict:
    st = path.stat()
    return {
        "fullPath": str(path.resolve()),
        "fileName": path.name,
        "directory": str(path.parent.resolve()),
        "extension": path.suffix,
        "length": st.st_size,
        "creationTimeUtc": ext_date(datetime.fromtimestamp(st.st_ctime, tz=timezone.utc)),
        "lastWriteTimeUtc": ext_date(datetime.fromtimestamp(st.st_mtime, tz=timezone.utc)),
        "lastAccessTimeUtc": ext_date(datetime.fromtimestamp(st.st_atime, tz=timezone.utc)),
        "attributes": "Archive",
        "isReadOnly": not os.access(path, os.W_OK),
        "isHidden": path.name.startswith("."),
        "drive": str(path.resolve().anchor).rstrip("/\\") or "/",
        "hostName": os.uname().nodename,
        "collectedAtUtc": ext_date(collected_at),
        "lookbackHours": lookback_hours,
    }


def main() -> None:
    lookback = 24
    cutoff = datetime.now(timezone.utc) - timedelta(hours=lookback)
    collected_at = datetime.now(timezone.utc)

    with tempfile.TemporaryDirectory(prefix="filemeta-") as tmp:
        root = Path(tmp)
        fresh = root / "fresh.txt"
        stale = root / "stale.txt"
        fresh.write_text("new", encoding="utf-8")
        stale.write_text("old", encoding="utf-8")

        # Make stale older than 24h
        old_ts = time.time() - (lookback + 2) * 3600
        os.utime(stale, (old_ts, old_ts))

        matched = []
        for p in root.rglob("*"):
            if not p.is_file():
                continue
            mtime = datetime.fromtimestamp(p.stat().st_mtime, tz=timezone.utc)
            if mtime >= cutoff:
                matched.append(to_doc(p, collected_at, lookback))

        assert any(d["fileName"] == "fresh.txt" for d in matched), "fresh file should match"
        assert all(d["fileName"] != "stale.txt" for d in matched), "stale file should be filtered"

        jsonl_path = root / "out.jsonl"
        with jsonl_path.open("w", encoding="utf-8") as fh:
            for doc in matched:
                missing = REQUIRED_FIELDS - set(doc)
                assert not missing, f"missing fields: {missing}"
                assert isinstance(doc["creationTimeUtc"], dict) and "$date" in doc["creationTimeUtc"]
                assert isinstance(doc["length"], int)
                fh.write(json.dumps(doc, ensure_ascii=False) + "\n")

        lines = jsonl_path.read_text(encoding="utf-8").strip().splitlines()
        assert len(lines) == len(matched) >= 1
        parsed = [json.loads(line) for line in lines]
        assert parsed[0]["lookbackHours"] == 24

        artifact = Path("/opt/cursor/artifacts/file-meta-schema-sample.jsonl")
        artifact.parent.mkdir(parents=True, exist_ok=True)
        artifact.write_text("\n".join(lines) + "\n", encoding="utf-8")

        print("OK: 24h filter + schema validation passed")
        print(f"matched={len(matched)} sample -> {artifact}")
        print(lines[0][:200] + "...")


if __name__ == "__main__":
    main()
