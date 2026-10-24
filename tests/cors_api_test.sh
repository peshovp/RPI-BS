#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${GM_REPO_ROOT:-$(dirname "$SCRIPT_DIR")}"

if ! command -v python3 &>/dev/null; then
    echo "SKIP: python3 not found"
    exit 0
fi

export GM_REPO_ROOT="$REPO"

python3 << 'PYEOF'
import os
import sys
import json
import tempfile
import importlib.util

repo_root = os.environ.get('GM_REPO_ROOT', '.')
sys.path.insert(0, os.path.join(repo_root, 'addons', 'features', 'cors_position'))

import cors_accounts as store
import cors_api as api

passed = 0
failed = 0

def test(name, fn):
    global passed, failed
    try:
        fn()
        passed += 1
        print(f"PASS: {name}")
    except Exception as e:
        failed += 1
        print(f"FAIL: {name}: {e}")

events = []
def recorder(category, event, details):
    events.append((category, event, details))

store.log_event = recorder

GOOD = {
    "name": "Net A",
    "host": "caster.example.org",
    "port": 2101,
    "mountpoint": "AUTO",
    "username": "user-secret-1",
    "password": "pw-secret-1"
}

def test_a():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        status, body = api.handle_list(path=path)
        assert status == 200, f"Expected 200, got {status}"
        assert body["ok"] is True, "ok should be True"
        assert body["accounts"] == [], f"Expected empty list, got {body['accounts']}"

test("A: list on missing store returns empty", test_a)

def test_b():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        status, body = api.handle_create(GOOD, path=path)
        assert status == 201, f"Expected 201, got {status}"
        assert body["ok"] is True, "ok should be True"
        assert "id" in body["account"], "Missing id in account"
        assert body["account"].get("has_password") is True, "has_password should be True"
        assert "password" not in body["account"], "password should not be in response"

test("B: create returns 201 with public view", test_b)

def test_c():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        for bad in [None, [], "x"]:
            status, body = api.handle_create(bad, path=path)
            assert status == 400, f"Expected 400 for {bad}, got {status}"
            assert body["error"] == "JSON object required", f"Wrong error: {body['error']}"

test("C: create with non-dict body returns 400", test_c)

def test_d():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        bad = dict(GOOD)
        bad["port"] = 0
        status, body = api.handle_create(bad, path=path)
        assert status == 400, f"Expected 400, got {status}"
        assert body["ok"] is False, "ok should be False"
        body_json = json.dumps(body)
        assert "pw-secret-1" not in body_json, "Password in error response"
        assert "user-secret-1" not in body_json, "Username in error response"
        assert "caster.example.org" not in body_json, "Host in error response"

test("D: create validation error returns 400 without secrets", test_d)

def test_e():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        api.handle_create(GOOD, path=path)
        status, body = api.handle_list(path=path)
        assert status == 200, f"Expected 200, got {status}"
        assert len(body["accounts"]) == 1, f"Expected 1 account, got {len(body['accounts'])}"
        body_json = json.dumps(body)
        assert "pw-secret-1" not in body_json, "Password leaked in list response"

test("E: list after create returns public view", test_e)

def test_f():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        created = api.handle_create(GOOD, path=path)[1]["account"]
        status, body = api.handle_update(created["id"], {"port": 2102}, path=path)
        assert status == 200, f"Expected 200, got {status}"
        assert body["account"]["port"] == 2102, "Port should be updated"
        full = store.get_account(created["id"], path=path)
        assert full["password"] == "pw-secret-1", "Password should be preserved"
        status, body = api.handle_update("abcdef123456", {"port": 2103}, path=path)
        assert status == 404, f"Expected 404 for unknown id, got {status}"
        for bad_id in ["../x", "", 123]:
            status, body = api.handle_update(bad_id, {"port": 2104}, path=path)
            assert status == 404, f"Expected 404 for {bad_id}, got {status}"
            status, body = api.handle_delete(bad_id, path=path)
            assert status == 404, f"Expected 404 for delete {bad_id}, got {status}"

test("F: update and delete with valid/invalid ids", test_f)

def test_g():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        created = api.handle_create(GOOD, path=path)[1]["account"]
        status, body = api.handle_update(created["id"], {"mode": "x"}, path=path)
        assert status == 400, f"Expected 400, got {status}"
        full = store.get_account(created["id"], path=path)
        assert full["mode"] == "vrs", "Mode should be unchanged after failed update"

test("G: update with bad value returns 400 and leaves account unchanged", test_g)

def test_h():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        created = api.handle_create(GOOD, path=path)[1]["account"]
        status, body = api.handle_delete(created["id"], path=path)
        assert status == 200, f"Expected 200, got {status}"
        assert body["ok"] is True, "ok should be True"
        status, body = api.handle_delete(created["id"], path=path)
        assert status == 404, f"Expected 404 for second delete, got {status}"

test("H: delete returns 200 then 404", test_h)

def test_i():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        for i in range(store.MAX_ACCOUNTS):
            data = dict(GOOD)
            data["name"] = f"Net {i}"
            data["host"] = f"host{i}.example.org"
            api.handle_create(data, path=path)
        data = dict(GOOD)
        data["name"] = "Net extra"
        data["host"] = "extra.example.org"
        status, body = api.handle_create(data, path=path)
        assert status == 409, f"Expected 409, got {status}"
        assert body["error"] == "account limit reached", f"Wrong error: {body['error']}"

test("I: account limit returns 409", test_i)

def test_j():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write("not json")
        status, body = api.handle_list(path=path)
        assert status == 500, f"Expected 500, got {status}"
        assert body["error"] == "accounts store is unreadable", f"Wrong error: {body['error']}"
        body_json = json.dumps(body)
        assert "not json" not in body_json, "Raw file content leaked in error"

test("J: corrupt store returns 500 without leaking content", test_j)

def test_k():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        original = store.list_accounts
        def raise_runtime_error(*args, **kwargs):
            raise RuntimeError("secret pw-secret-1")
        store.list_accounts = raise_runtime_error
        try:
            status, body = api.handle_list(path=path)
            assert status == 500, f"Expected 500, got {status}"
            assert body["error"] == "internal error", f"Wrong error: {body['error']}"
            body_json = json.dumps(body)
            assert "pw-secret-1" not in body_json, "Secret leaked in internal error"
        finally:
            store.list_accounts = original

test("K: unexpected exception returns 500 without leaking secrets", test_k)

def test_l():
    global events
    events = []
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        created = api.handle_create(GOOD, path=path)[1]["account"]
        api.handle_update(created["id"], {"port": 2102}, path=path)
        api.handle_delete(created["id"], path=path)
        events_json = json.dumps(events)
        assert "pw-secret-1" not in events_json, "Password in audit events"
        assert "user-secret-1" not in events_json, "Username in audit events"
        assert "caster.example.org" not in events_json, "Host in audit events"

test("L: audit events contain no secrets", test_l)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF

exit $?
