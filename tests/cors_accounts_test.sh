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
import time
import tempfile
import stat
import importlib.util

repo_root = os.environ.get('GM_REPO_ROOT', '.')
module_path = os.path.join(repo_root, 'addons', 'features', 'cors_position', 'cors_accounts.py')

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

def load_module():
    try:
        spec = importlib.util.spec_from_file_location('cors_accounts', module_path)
        if spec is None or spec.loader is None:
            raise ImportError(f"Cannot load module from {module_path}")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    except Exception as e:
        raise ImportError(f"Failed to load cors_accounts: {e}")

try:
    mod = load_module()
except ImportError as e:
    failed += 1
    print(f"FAIL: module load: {e}")
    print(f"RESULT: {passed} passed, {failed} failed")
    sys.exit(failed)

events = []
def recorder(category, event, details):
    events.append((category, event, details))

mod.log_event = recorder

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
        result = mod.create_account(dict(GOOD), path=path)
        assert "id" in result, "Missing id"
        assert len(result["id"]) == 12, f"Bad id length: {len(result['id'])}"
        assert all(c in '0123456789abcdef' for c in result["id"]), f"Bad id chars: {result['id']}"
        assert result.get("has_password") is True, "has_password should be True"
        assert "password" not in result, "password should not be in public view"
        assert result.get("tls") is False, "tls default should be False"
        assert result.get("mode") == "vrs", "mode default should be vrs"
        assert result.get("frame") == "ETRF2000@2005.0", "frame default should be ETRF2000@2005.0"
        assert result.get("epoch") is None, "epoch default should be None"
        assert result.get("enabled") is True, "enabled default should be True"
        assert result.get("use_for_crosscheck") is True, "use_for_crosscheck default should be True"
        assert result.get("use_for_quick_start") is False, "use_for_quick_start default should be False"

test("A: create_account returns public view with defaults", test_a)

def test_b():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        mod.create_account(dict(GOOD), path=path)
        file_mode = stat.S_IMODE(os.stat(path).st_mode)
        assert file_mode == 0o600, f"File mode {oct(file_mode)}, expected 0o600"
        dir_mode = stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode)
        assert dir_mode == 0o700, f"Dir mode {oct(dir_mode)}, expected 0o700"
        dir_contents = os.listdir(os.path.dirname(path))
        assert len(dir_contents) == 1, f"Expected 1 file, got {len(dir_contents)}: {dir_contents}"
        assert dir_contents[0] == "cors_accounts.json", f"Unexpected file: {dir_contents[0]}"

test("B: file and directory permissions", test_b)

def test_c():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        mod.create_account(dict(GOOD), path=path)
        listed = mod.list_accounts(path=path)
        assert len(listed) == 1, f"Expected 1 account, got {len(listed)}"
        assert "password" not in listed[0], "password should not be in list"
        json_str = json.dumps(listed)
        assert "pw-secret-1" not in json_str, "Password leaked in list JSON"

test("C: list_accounts is public view", test_c)

def test_d():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        created = mod.create_account(dict(GOOD), path=path)
        full = mod.get_account(created["id"], path=path)
        assert full["password"] == "pw-secret-1", "get_account should return password"
        try:
            mod.get_account("unknown-id-123", path=path)
            assert False, "Should have raised CorsAccountsError"
        except mod.CorsAccountsError:
            pass

test("D: get_account returns full record", test_d)

def test_e():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        created = mod.create_account(dict(GOOD), path=path)
        mod.update_account(created["id"], {"port": 2102, "password": ""}, path=path)
        full = mod.get_account(created["id"], path=path)
        assert full["port"] == 2102, "Port should be updated"
        assert full["password"] == "pw-secret-1", "Empty password should keep old"
        mod.update_account(created["id"], {"port": 2103}, path=path)
        full = mod.get_account(created["id"], path=path)
        assert full["password"] == "pw-secret-1", "Absent password should keep old"
        mod.update_account(created["id"], {"password": "pw-secret-2"}, path=path)
        full = mod.get_account(created["id"], path=path)
        assert full["password"] == "pw-secret-2", "New password should replace"

test("E: update_account password handling", test_e)

def test_f():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        bad_cases = [
            ({"port": 0}, "port"),
            ({"port": True}, "port"),
            ({"port": "2101"}, "port"),
            ({"host": "http://x"}, "host"),
            ({"host": "a b"}, "host"),
            ({"mountpoint": "a/b"}, "mountpoint"),
            ({"name": ""}, "name"),
            ({"password": "pw\nline"}, "password"),
            ({"foo": "bar"}, "unknown field"),
            ({"mode": "x"}, "mode"),
            ({"frame": "x"}, "frame"),
        ]
        for override, expected in bad_cases:
            data = dict(GOOD)
            data.update(override)
            try:
                mod.create_account(data, path=path)
                assert False, f"Should have raised for {override}"
            except mod.CorsAccountsError as e:
                msg = str(e)
                assert "pw-secret-1" not in msg, f"Password in error: {msg}"
                assert "user-secret-1" not in msg, f"Username in error: {msg}"

test("F: validation errors", test_f)

def test_g():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        data = dict(GOOD)
        data["frame"] = "ITRF2020@epoch"
        try:
            mod.create_account(data, path=path)
            assert False, "Should have raised for missing epoch"
        except mod.CorsAccountsError:
            pass
        data["epoch"] = 2015.0
        created = mod.create_account(data, path=path)
        data2 = dict(GOOD)
        data2["frame"] = "ETRF2000@2005.0"
        data2["epoch"] = 2010.0
        try:
            mod.create_account(data2, path=path)
            assert False, "Should have raised for epoch with non-epoch frame"
        except mod.CorsAccountsError:
            pass
        data3 = dict(GOOD)
        data3["epoch"] = 1800.0
        try:
            mod.create_account(data3, path=path)
            assert False, "Should have raised for epoch out of range"
        except mod.CorsAccountsError:
            pass
        mod.update_account(created["id"], {"frame": "ETRF2000@2005.0"}, path=path)
        full = mod.get_account(created["id"], path=path)
        assert full["epoch"] is None, "Epoch should be cleared when switching to non-epoch frame"
        try:
            mod.update_account(created["id"], {"frame": "ETRF2000@epoch"}, path=path)
            assert False, "Should have raised for missing epoch on update"
        except mod.CorsAccountsError:
            pass
        full = mod.get_account(created["id"], path=path)
        assert full["frame"] == "ETRF2000@2005.0", "Frame should be unchanged after failed update"

test("G: epoch/frame consistency rules", test_g)

def test_h():
    global events
    events = []
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        created = mod.create_account(dict(GOOD), path=path)
        mod.update_account(created["id"], {"port": 2102}, path=path)
        mod.delete_account(created["id"], path=path)
        assert len(events) >= 3, f"Expected at least 3 events, got {len(events)}"
        event_names = [e[1] for e in events]
        assert "account_created" in event_names, "Missing account_created event"
        assert "account_updated" in event_names, "Missing account_updated event"
        assert "account_deleted" in event_names, "Missing account_deleted event"
        categories = [e[0] for e in events]
        assert all(c == "cors" for c in categories), "All events should be in cors category"
        events_json = json.dumps(events)
        assert "pw-secret-1" not in events_json, "Password in audit events"
        assert "pw-secret-2" not in events_json, "Password in audit events"
        assert "user-secret-1" not in events_json, "Username in audit events"
        assert "caster.example.org" not in events_json, "Host in audit events"
        update_event = [e for e in events if e[1] == "account_updated"][0]
        fields = update_event[2].get("fields", [])
        assert fields == sorted(fields), f"Fields not sorted: {fields}"

test("H: audit events contain no secrets", test_h)

def test_i():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        created = mod.create_account(dict(GOOD), path=path)
        assert mod.delete_account(created["id"], path=path) is True, "First delete should return True"
        assert mod.delete_account(created["id"], path=path) is False, "Second delete should return False"
        assert len(mod.list_accounts(path=path)) == 0, "List should be empty after delete"

test("I: delete_account", test_i)

def test_j():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        for i in range(mod.MAX_ACCOUNTS):
            data = dict(GOOD)
            data["name"] = f"Net {i}"
            data["host"] = f"host{i}.example.org"
            mod.create_account(data, path=path)
        data = dict(GOOD)
        data["name"] = "Net extra"
        data["host"] = "extra.example.org"
        try:
            mod.create_account(data, path=path)
            assert False, "Should have raised for account limit"
        except mod.CorsAccountsError as e:
            assert "account limit reached" in str(e), f"Wrong error message: {e}"

test("J: account limit", test_j)

def test_k():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write("not json")
        try:
            mod.list_accounts(path=path)
            assert False, "Should have raised for corrupt JSON"
        except mod.CorsAccountsError:
            pass
        with open(path, "w") as f:
            json.dump({"accounts": [1]}, f)
        try:
            mod.list_accounts(path=path)
            assert False, "Should have raised for non-dict account"
        except mod.CorsAccountsError:
            pass
        os.unlink(path)
        result = mod.list_accounts(path=path)
        assert result == [], f"Missing file should return [], got {result}"

test("K: corrupt store handling", test_k)

def test_l():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        stale = os.path.join(os.path.dirname(path), ".cors_accounts_stale.tmp")
        with open(stale, "w") as f:
            f.write("stale")
        result = mod.create_account(dict(GOOD), path=path)
        assert "id" in result, "Should create account despite stale temp file"

test("L: stale temp file does not cause collision", test_l)

def test_m():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "cors_accounts.json")
        ids = []
        for i in range(5):
            data = dict(GOOD)
            data["name"] = f"Net {i}"
            data["host"] = f"host{i}.example.org"
            created = mod.create_account(data, path=path)
            ids.append(created["id"])
        assert len(set(ids)) == 5, f"IDs not unique: {ids}"

test("M: unique account IDs", test_m)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF

exit $?
