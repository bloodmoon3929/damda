import hashlib
import importlib

import pytest
from fastapi.testclient import TestClient

ADMIN = "admin-secret"


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("NOTES_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("NOTES_ADMIN_TOKEN", ADMIN)
    import app.main as main

    importlib.reload(main)
    with TestClient(main.app) as c:
        yield c


def auth(token):
    return {"Authorization": f"Bearer {token}"}


def device(client, name="pc"):
    r = client.post("/devices", json={"name": name}, headers=auth(ADMIN))
    assert r.status_code == 200
    return r.json()["token"]


def change(id, hlc, title="t", table="pages", deleted=False):
    return {"table": table, "id": id, "hlc": hlc, "deleted": deleted,
            "data": {"title": title}}


def test_auth(client):
    assert client.get("/health").json()["ok"] is True
    assert client.get("/sync/pull").status_code == 401
    assert client.get("/sync/pull", headers=auth("nope")).status_code == 401
    pc = device(client)
    assert client.post("/devices", json={"name": "x"}, headers=auth(pc)).status_code == 403
    assert client.get("/sync/pull", headers=auth(pc)).status_code == 200


def test_push_pull_between_devices(client):
    pc, phone = device(client, "pc"), device(client, "phone")
    r = client.post("/sync/push", headers=auth(pc), json={"changes": [
        change("p1", "0000000000001.0000.pc", "여행"),
        change("b1", "0000000000001.0001.pc", "본문", table="blocks"),
    ]}).json()
    assert [a["seq"] for a in r["accepted"]] == [1, 2] and r["rejected"] == []

    got = client.get("/sync/pull?since=0", headers=auth(phone)).json()
    assert [c["id"] for c in got["changes"]] == ["p1", "b1"]
    assert got["changes"][0]["data"] == {"title": "여행"}
    assert got["next"] == 2 and got["more"] is False

    # Paging.
    got = client.get("/sync/pull?since=0&limit=1", headers=auth(phone)).json()
    assert got["more"] is True and got["next"] == 1
    assert client.get("/sync/pull?since=2", headers=auth(phone)).json()["changes"] == []


def test_last_writer_wins_and_history(client):
    pc, phone = device(client, "pc"), device(client, "phone")
    client.post("/sync/push", headers=auth(pc),
                json={"changes": [change("p1", "0000000000005.0000.pc", "pc 수정")]})
    # Phone edited offline earlier -> loses, gets the winner back.
    r = client.post("/sync/push", headers=auth(phone),
                    json={"changes": [change("p1", "0000000000003.0000.phone", "폰 수정")]}).json()
    assert r["accepted"] == []
    assert r["rejected"][0]["data"] == {"title": "pc 수정"}
    # Later edit wins; the old one is kept in history.
    r = client.post("/sync/push", headers=auth(phone),
                    json={"changes": [change("p1", "0000000000009.0000.phone", "폰 최신")]}).json()
    assert r["accepted"][0]["seq"] == 2

    hist = client.get("/history/pages/p1", headers=auth(pc)).json()
    assert {h["data"]["title"]: h["reason"] for h in hist} == {
        "pc 수정": "overwritten", "폰 수정": "rejected"}

    # Re-sending the same version (lost response) is harmless.
    r = client.post("/sync/push", headers=auth(phone),
                    json={"changes": [change("p1", "0000000000009.0000.phone", "폰 최신")]}).json()
    assert r["accepted"][0]["seq"] == 2
    assert client.get("/health").json()["seq"] == 2


def test_tombstone_and_unknown_table(client):
    pc = device(client)
    client.post("/sync/push", headers=auth(pc), json={"changes": [
        change("p1", "0000000000001.0000.pc"),
        change("p1", "0000000000002.0000.pc", deleted=True)]})
    rows = client.get("/sync/pull", headers=auth(pc)).json()["changes"]
    assert len(rows) == 1 and rows[0]["deleted"] is True
    r = client.post("/sync/push", headers=auth(pc),
                    json={"changes": [change("x", "1", table="links")]})
    assert r.status_code == 400


def test_assets(client):
    pc = device(client)
    body = b"\x89PNG fake image"
    sha = hashlib.sha256(body).hexdigest()
    other = "0" * 64
    assert client.post("/assets/missing", headers=auth(pc),
                       json={"hashes": [sha, other]}).json()["missing"] == [sha, other]
    assert client.put(f"/assets/{'1' * 64}", headers=auth(pc), content=body).status_code == 400
    r = client.put(f"/assets/{sha}", headers=auth(pc), content=body).json()
    assert r == {"ok": True, "size": len(body), "existed": False}
    assert client.put(f"/assets/{sha}", headers=auth(pc), content=body).json()["existed"]
    assert client.get(f"/assets/{sha}", headers=auth(pc)).content == body
    assert client.get(f"/assets/{sha}").status_code == 401
    assert client.get("/assets/../notes.db", headers=auth(pc)).status_code in (400, 404)
    assert client.post("/assets/missing", headers=auth(pc),
                       json={"hashes": [sha]}).json()["missing"] == []


def test_revoke_device(client):
    pc = device(client)
    ids = [d["id"] for d in client.get("/devices", headers=auth(ADMIN)).json()]
    assert client.delete(f"/devices/{ids[0]}", headers=auth(ADMIN)).json()["ok"]
    assert client.get("/sync/pull", headers=auth(pc)).status_code == 401


def ms(n):
    return f"{n:013d}.0000.x"


def test_history_policy_and_page_history(client):
    pc, phone = device(client, "pc"), device(client, "phone")

    def block(hlc, text, who):
        r = client.post("/sync/push", headers=auth(who), json={"changes": [{
            "table": "blocks", "id": "b1", "hlc": hlc, "deleted": False,
            "data": {"pageId": "p1", "text": text}}]})
        assert r.status_code == 200

    base = 1_700_000_000_000
    block(ms(base), "v1", pc)
    block(ms(base + 1000), "v2", pc)            # typing: no history
    block(ms(base + 2000), "v3", pc)
    assert client.get("/history/page/p1", headers=auth(pc)).json() == []
    block(ms(base + 11 * 60_000), "v4", pc)     # 10+ min later: snapshot
    block(ms(base + 11 * 60_000 + 500), "phone", phone)  # other device
    hist = client.get("/history/page/p1", headers=auth(pc)).json()
    assert [(h["data"]["text"], h["device"]) for h in hist] == [
        ("v4", "pc"), ("v3", "pc")]
    assert client.get("/history/page/other", headers=auth(pc)).json() == []


def test_cleanup(client):
    import app.main as main

    pc, phone = device(client, "pc"), device(client, "phone")
    body = b"old video"
    sha = hashlib.sha256(body).hexdigest()
    client.put(f"/assets/{sha}", headers=auth(pc), content=body)
    old = main.now_ms() - 31 * main.DAY_MS
    client.post("/sync/push", headers=auth(pc), json={"changes": [
        {"table": "assets", "id": "a1", "hlc": ms(old), "deleted": False,
         "data": {"sha256": sha}},
    ]})
    client.post("/sync/push", headers=auth(phone), json={"changes": [
        {"table": "assets", "id": "a1", "hlc": ms(old + 1), "deleted": True,
         "data": {"sha256": sha}},
    ]})
    with main.connect() as conn:
        conn.execute("UPDATE history SET replaced_at = ?", (old,))
    assert main.cleanup() == {"history": 1, "files": 1}
    assert main.cleanup() == {"history": 0, "files": 0}
    assert client.get(f"/assets/{sha}", headers=auth(pc)).status_code == 404
