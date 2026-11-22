"""Notes sync server (step 2).

The app keeps its own SQLite DB and works offline; this server is the shared
copy every device syncs with. It does not understand notes: it stores rows
of the app's sync tables as JSON, numbered by a change sequence.

- push: a device sends rows it changed. Per row, the higher HLC wins
  (last-writer-wins). The losing version goes to `history`.
- pull: a device asks for every row changed after the last `seq` it saw.
- assets: attachment files by SHA-256, stored once.

Auth: `Authorization: Bearer <token>`. NOTES_ADMIN_TOKEN (env) issues one
token per device via POST /devices; device tokens are stored hashed.
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import tempfile
import time
import uuid
from contextlib import asynccontextmanager, contextmanager
from pathlib import Path
from typing import Any, Iterator

from fastapi import Depends, FastAPI, HTTPException, Request, Response
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

DATA_DIR = Path(os.environ.get("NOTES_DATA_DIR", "/data"))
ADMIN_TOKEN = os.environ.get("NOTES_ADMIN_TOKEN", "")

# The app's tables that sync. Derived tables (links, search) are rebuilt
# on each device and never travel.
SYNC_TABLES = {
    "pages",
    "blocks",
    "properties",
    "db_properties",
    "db_views",
    "assets",
}
MAX_PUSH = 2000
DAY_MS = 24 * 3600 * 1000
KEEP_MS = 30 * DAY_MS          # history and deleted files are kept 30 days
SNAPSHOT_MS = 10 * 60 * 1000   # own edits: at most one history entry / 10 min
MAX_PULL = 2000
SHA256 = re.compile(r"^[0-9a-f]{64}$")


# ---------------------------------------------------------------- storage


def db_path() -> Path:
    return DATA_DIR / "notes.db"


def assets_dir() -> Path:
    return DATA_DIR / "assets"


SCHEMA = """
CREATE TABLE IF NOT EXISTS records (
  tbl     TEXT NOT NULL,
  id      TEXT NOT NULL,
  data    TEXT NOT NULL,
  hlc     TEXT NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  device  TEXT NOT NULL,
  seq     INTEGER NOT NULL,
  PRIMARY KEY (tbl, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS records_seq ON records(seq);

-- Versions that lost a conflict or were overwritten (page_history).
CREATE TABLE IF NOT EXISTS history (
  tbl         TEXT NOT NULL,
  id          TEXT NOT NULL,
  data        TEXT NOT NULL,
  hlc         TEXT NOT NULL,
  deleted     INTEGER NOT NULL,
  device      TEXT NOT NULL,
  replaced_at INTEGER NOT NULL,
  reason      TEXT NOT NULL      -- 'overwritten' | 'rejected'
);
CREATE INDEX IF NOT EXISTS history_row ON history(tbl, id);

CREATE TABLE IF NOT EXISTS devices (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  last_seen  INTEGER
);
"""


@contextmanager
def connect() -> Iterator[sqlite3.Connection]:
    conn = sqlite3.connect(db_path(), timeout=30, isolation_level=None)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()


def init() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    (assets_dir() / "tmp").mkdir(parents=True, exist_ok=True)
    with connect() as conn:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.executescript(SCHEMA)


def hlc_ms(hlc: str) -> int:
    try:
        return int(hlc.split(".", 1)[0])
    except ValueError:
        return 0


def cleanup() -> dict[str, int]:
    """Drops history older than 30 days and files of attachments deleted
    more than 30 days ago (unless another live record has the same hash).
    Deleted rows themselves stay (they are small) so a device that was
    offline for months still learns about the delete."""
    cutoff = now_ms() - KEEP_MS
    removed_files = 0
    with connect() as conn:
        n_hist = conn.execute(
            "DELETE FROM history WHERE replaced_at < ?", (cutoff,)
        ).rowcount
        live = {
            r[0]
            for r in conn.execute(
                "SELECT json_extract(data, '$.sha256') FROM records "
                "WHERE tbl = 'assets' AND deleted = 0"
            )
        }
        for r in conn.execute(
            "SELECT hlc, json_extract(data, '$.sha256') AS sha FROM records "
            "WHERE tbl = 'assets' AND deleted = 1"
        ):
            sha = r["sha"]
            if not sha or sha in live or hlc_ms(r["hlc"]) > cutoff:
                continue
            if not SHA256.match(sha):
                continue
            f = assets_dir() / sha[:2] / sha
            if f.exists():
                f.unlink()
                removed_files += 1
    return {"history": n_hist, "files": removed_files}


async def cleanup_daily() -> None:
    while True:
        await asyncio.to_thread(cleanup)
        await asyncio.sleep(24 * 3600)


@asynccontextmanager
async def lifespan(_: FastAPI):
    init()
    task = asyncio.create_task(cleanup_daily())
    yield
    task.cancel()


app = FastAPI(title="notes-api", docs_url=None, redoc_url=None, lifespan=lifespan)


def now_ms() -> int:
    return int(time.time() * 1000)


# ------------------------------------------------------------------- auth


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def bearer(request: Request) -> str:
    header = request.headers.get("authorization", "")
    if not header.lower().startswith("bearer "):
        raise HTTPException(401, "토큰이 없어요")
    return header[7:].strip()


def is_admin(token: str) -> bool:
    return bool(ADMIN_TOKEN) and hmac.compare_digest(token, ADMIN_TOKEN)


def require_admin(request: Request) -> None:
    if not is_admin(bearer(request)):
        raise HTTPException(403, "관리자 토큰이 필요해요")


def require_device(request: Request) -> str:
    """Returns the device id (the admin token acts as device 'admin')."""
    token = bearer(request)
    if is_admin(token):
        return "admin"
    with connect() as conn:
        row = conn.execute(
            "SELECT id FROM devices WHERE token_hash = ?", (token_hash(token),)
        ).fetchone()
        if row is None:
            raise HTTPException(401, "알 수 없는 토큰이에요")
        conn.execute(
            "UPDATE devices SET last_seen = ? WHERE id = ?", (now_ms(), row["id"])
        )
        return row["id"]


# ---------------------------------------------------------------- devices


class NewDevice(BaseModel):
    name: str = Field(min_length=1, max_length=100)


@app.get("/health")
def health() -> dict[str, Any]:
    with connect() as conn:
        seq = conn.execute("SELECT COALESCE(MAX(seq), 0) FROM records").fetchone()[0]
    return {"ok": True, "seq": seq}


@app.post("/devices", dependencies=[Depends(require_admin)])
def create_device(body: NewDevice) -> dict[str, str]:
    """Issues a token for one device. It is shown only once."""
    token = secrets.token_urlsafe(32)
    device_id = str(uuid.uuid4())
    with connect() as conn:
        conn.execute(
            "INSERT INTO devices(id, name, token_hash, created_at) VALUES (?,?,?,?)",
            (device_id, body.name, token_hash(token), now_ms()),
        )
    return {"id": device_id, "name": body.name, "token": token}


@app.get("/devices", dependencies=[Depends(require_admin)])
def list_devices() -> list[dict[str, Any]]:
    with connect() as conn:
        rows = conn.execute(
            "SELECT id, name, created_at, last_seen FROM devices ORDER BY created_at"
        ).fetchall()
    return [dict(r) for r in rows]


@app.delete("/devices/{device_id}", dependencies=[Depends(require_admin)])
def delete_device(device_id: str) -> dict[str, bool]:
    """Revokes a lost device's token."""
    with connect() as conn:
        n = conn.execute("DELETE FROM devices WHERE id = ?", (device_id,)).rowcount
    if n == 0:
        raise HTTPException(404, "그런 기기가 없어요")
    return {"ok": True}


# ------------------------------------------------------------------- sync


class Change(BaseModel):
    table: str
    id: str = Field(min_length=1, max_length=100)
    # Hybrid logical clock, compared as a string. The app writes
    # "<ms:13 digits>.<counter:4 digits>.<device id>", so string order is
    # time order and ties break by device.
    hlc: str = Field(min_length=1, max_length=120)
    deleted: bool = False
    data: dict[str, Any]


class PushBody(BaseModel):
    changes: list[Change] = Field(max_length=MAX_PUSH)


def _row(r: sqlite3.Row) -> dict[str, Any]:
    return {
        "seq": r["seq"],
        "table": r["tbl"],
        "id": r["id"],
        "hlc": r["hlc"],
        "deleted": bool(r["deleted"]),
        "device": r["device"],
        "data": json.loads(r["data"]),
    }


@app.post("/sync/push")
def push(body: PushBody, device: str = Depends(require_device)) -> dict[str, Any]:
    """Applies changes; returns the server's version for rows where the
    pushed one lost, so the device can take it right away."""
    for c in body.changes:
        if c.table not in SYNC_TABLES:
            raise HTTPException(400, f"동기화하지 않는 테이블: {c.table}")
    accepted: list[dict[str, Any]] = []
    rejected: list[dict[str, Any]] = []
    with connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        try:
            seq = conn.execute("SELECT COALESCE(MAX(seq), 0) FROM records").fetchone()[0]
            for c in body.changes:
                data = json.dumps(c.data, ensure_ascii=False, separators=(",", ":"))
                cur = conn.execute(
                    "SELECT * FROM records WHERE tbl = ? AND id = ?", (c.table, c.id)
                ).fetchone()
                if cur is not None and cur["hlc"] == c.hlc:
                    # Same version sent again (retry after a lost response).
                    accepted.append({"table": c.table, "id": c.id, "seq": cur["seq"]})
                    continue
                if cur is not None and cur["hlc"] > c.hlc:
                    conn.execute(
                        "INSERT INTO history VALUES (?,?,?,?,?,?,?,?)",
                        (c.table, c.id, data, c.hlc, int(c.deleted), device,
                         now_ms(), "rejected"),
                    )
                    rejected.append(_row(cur))
                    continue
                # Keep the replaced version when another device wrote it (a
                # real conflict) or as a snapshot every 10 minutes; not for
                # every save while typing.
                if cur is not None and (
                    cur["device"] != device
                    or hlc_ms(c.hlc) - hlc_ms(cur["hlc"]) >= SNAPSHOT_MS
                ):
                    conn.execute(
                        "INSERT INTO history VALUES (?,?,?,?,?,?,?,?)",
                        (cur["tbl"], cur["id"], cur["data"], cur["hlc"],
                         cur["deleted"], cur["device"], now_ms(), "overwritten"),
                    )
                seq += 1
                conn.execute(
                    "INSERT OR REPLACE INTO records VALUES (?,?,?,?,?,?,?)",
                    (c.table, c.id, data, c.hlc, int(c.deleted), device, seq),
                )
                accepted.append({"table": c.table, "id": c.id, "seq": seq})
            conn.execute("COMMIT")
        except BaseException:
            conn.execute("ROLLBACK")
            raise
    return {"accepted": accepted, "rejected": rejected, "seq": seq}


@app.get("/sync/pull")
def pull(
    since: int = 0, limit: int = 500, device: str = Depends(require_device)
) -> dict[str, Any]:
    """Rows changed after `since`, oldest first. Repeat with `next` while
    `more` is true."""
    limit = max(1, min(limit, MAX_PULL))
    with connect() as conn:
        rows = conn.execute(
            "SELECT * FROM records WHERE seq > ? ORDER BY seq LIMIT ?",
            (since, limit + 1),
        ).fetchall()
    more = len(rows) > limit
    rows = rows[:limit]
    return {
        "changes": [_row(r) for r in rows],
        "next": rows[-1]["seq"] if rows else since,
        "more": more,
    }


@app.get("/history/page/{page_id}")
def page_history(
    page_id: str, limit: int = 200, device: str = Depends(require_device)
) -> list[dict[str, Any]]:
    """Older versions of a page's title and blocks, newest first."""
    with connect() as conn:
        rows = conn.execute(
            "SELECT h.*, d.name AS device_name FROM history h "
            "LEFT JOIN devices d ON d.id = h.device "
            "WHERE (h.tbl = 'pages' AND h.id = ?) "
            "   OR (h.tbl = 'blocks' AND json_extract(h.data, '$.pageId') = ?) "
            "ORDER BY h.replaced_at DESC LIMIT ?",
            (page_id, page_id, max(1, min(limit, 1000))),
        ).fetchall()
    return [
        {
            "table": r["tbl"],
            "id": r["id"],
            "hlc": r["hlc"],
            "deleted": bool(r["deleted"]),
            "device": r["device_name"] or r["device"],
            "replaced_at": r["replaced_at"],
            "reason": r["reason"],
            "data": json.loads(r["data"]),
        }
        for r in rows
    ]


@app.get("/history/{table}/{row_id}")
def history(
    table: str, row_id: str, device: str = Depends(require_device)
) -> list[dict[str, Any]]:
    """Older versions of one row, newest first (to restore a lost edit)."""
    with connect() as conn:
        rows = conn.execute(
            "SELECT * FROM history WHERE tbl = ? AND id = ? ORDER BY replaced_at DESC",
            (table, row_id),
        ).fetchall()
    return [
        {
            "hlc": r["hlc"],
            "deleted": bool(r["deleted"]),
            "device": r["device"],
            "replaced_at": r["replaced_at"],
            "reason": r["reason"],
            "data": json.loads(r["data"]),
        }
        for r in rows
    ]


# ----------------------------------------------------------------- assets


def asset_file(sha: str) -> Path:
    if not SHA256.match(sha):
        raise HTTPException(400, "SHA-256(소문자 16진수 64자)이어야 해요")
    return assets_dir() / sha[:2] / sha


class HashList(BaseModel):
    hashes: list[str] = Field(max_length=5000)


@app.post("/assets/missing")
def missing_assets(
    body: HashList, device: str = Depends(require_device)
) -> dict[str, list[str]]:
    """Which of these files the server does not have yet."""
    return {"missing": [h for h in body.hashes if not asset_file(h).exists()]}


@app.put("/assets/{sha}")
async def put_asset(
    sha: str, request: Request, device: str = Depends(require_device)
) -> dict[str, Any]:
    """Uploads a file (raw body). The hash is checked, so a broken upload
    never replaces a good file."""
    target = asset_file(sha)
    if target.exists():
        return {"ok": True, "size": target.stat().st_size, "existed": True}
    digest = hashlib.sha256()
    size = 0
    fd, tmp = tempfile.mkstemp(dir=assets_dir() / "tmp")
    try:
        with os.fdopen(fd, "wb") as f:
            async for chunk in request.stream():
                digest.update(chunk)
                size += len(chunk)
                f.write(chunk)
        if digest.hexdigest() != sha:
            raise HTTPException(400, "내용과 해시가 달라요")
        target.parent.mkdir(parents=True, exist_ok=True)
        os.replace(tmp, target)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    return {"ok": True, "size": size, "existed": False}


@app.api_route("/assets/{sha}", methods=["GET", "HEAD"])
def get_asset(sha: str, device: str = Depends(require_device)) -> Response:
    target = asset_file(sha)
    if not target.exists():
        raise HTTPException(404, "파일이 없어요")
    return FileResponse(target, media_type="application/octet-stream")
