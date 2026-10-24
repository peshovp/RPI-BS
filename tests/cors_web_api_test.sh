#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GM_REPO_ROOT="$REPO"

python3 << 'PYEOF'
import os
import sys
import json
import time
import tempfile
import threading

repo = os.environ["GM_REPO_ROOT"]
sys.path.insert(0, repo)
sys.path.insert(0, os.path.join(repo, "tests"))

import cors_fakes as cf
cf.install_stubs()

from addons.features.cors_position import cors_api as api
from addons.features.cors_position import cors_client as client
from addons.features.cors_position import cors_job as cj
from addons.features.auto_survey import survey_requests as sr

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

def fake_request(result=None, exc=None, record=None):
    def request_fn(action, params):
        if record is not None:
            record.append((action, params))
        if exc is not None:
            raise exc
        return result
    return request_fn

def test_a():
    record = []
    fn = fake_request(result={"ok": True, "message": "started", "data": {"job_id": "job123abc456"}}, record=record)
    status, body = api.handle_compute("abc123", request_fn=fn)
    assert status == 202, f"Expected 202, got {status}"
    assert body == {"ok": True, "job_id": "job123abc456"}, f"Wrong body: {body}"
    assert record == [("cors_compute", {"account_id": "abc123"})], f"Wrong call: {record}"

    fn = fake_request(result={"ok": False, "message": "a CORS computation is already running"})
    status, body = api.handle_compute("abc123", request_fn=fn)
    assert status == 409, f"Expected 409, got {status}"
    assert body == {"ok": False, "error": "a CORS computation is already running"}

    fn = fake_request(result={"ok": False, "message": "unknown account"})
    status, body = api.handle_compute("abc123", request_fn=fn)
    assert status == 404, f"Expected 404, got {status}"

    fn = fake_request(result={"ok": False, "message": "account is disabled"})
    status, body = api.handle_compute("abc123", request_fn=fn)
    assert status == 409, f"Expected 409, got {status}"

    fn = fake_request(result={"ok": False, "message": "something else"})
    status, body = api.handle_compute("abc123", request_fn=fn)
    assert status == 400, f"Expected 400, got {status}"
    assert body == {"ok": False, "error": "something else"}

    fn = fake_request(result=None)
    status, body = api.handle_compute("abc123", request_fn=fn)
    assert status == 504, f"Expected 504, got {status}"
    assert body == {"ok": False, "error": "the survey service did not answer in time"}

    fn = fake_request(exc=RuntimeError("no service"))
    status, body = api.handle_compute("abc123", request_fn=fn)
    assert status == 503, f"Expected 503, got {status}"
    assert body == {"ok": False, "error": "the survey service is not available"}

    fn = fake_request(exc=ValueError("secret"))
    status, body = api.handle_compute("abc123", request_fn=fn)
    assert status == 500, f"Expected 500, got {status}"
    assert body == {"ok": False, "error": "internal error"}

    fn = fake_request(exc=OSError("secret"))
    status, body = api.handle_compute("abc123", request_fn=fn)
    assert status == 500, f"Expected 500, got {status}"
    assert body == {"ok": False, "error": "internal error"}

    for bad_id in ["../x", "", 5, "a" * 40]:
        record = []
        fn = fake_request(record=record)
        status, body = api.handle_compute(bad_id, request_fn=fn)
        assert status == 404, f"Expected 404 for {bad_id}, got {status}"
        assert body == {"ok": False, "error": "unknown account"}
        assert record == [], f"request_fn called for invalid id {bad_id}"

test("A: handle_compute", test_a)

def test_b():
    fn = fake_request(result={"ok": True, "message": "cancel requested", "data": None})
    status, body = api.handle_cancel(request_fn=fn)
    assert status == 200, f"Expected 200, got {status}"
    assert body == {"ok": True, "message": "cancel requested"}

    fn = fake_request(result={"ok": False, "message": "no job"})
    status, body = api.handle_cancel(request_fn=fn)
    assert status == 400, f"Expected 400, got {status}"
    assert body == {"ok": False, "error": "no job"}

    fn = fake_request(result=None)
    status, body = api.handle_cancel(request_fn=fn)
    assert status == 504, f"Expected 504, got {status}"

    fn = fake_request(exc=RuntimeError("no service"))
    status, body = api.handle_cancel(request_fn=fn)
    assert status == 503, f"Expected 503, got {status}"

    fn = fake_request(exc=ValueError("secret"))
    status, body = api.handle_cancel(request_fn=fn)
    assert status == 500, f"Expected 500, got {status}"
    assert body == {"ok": False, "error": "internal error"}

test("B: handle_cancel", test_b)

def test_c():
    record = []
    fn = fake_request(result={"ok": True, "data": {"applied": [1, 2, 3]}}, record=record)
    status, body = api.handle_apply({"job_id": "job123abc456", "confirm": True}, request_fn=fn)
    assert status == 200, f"Expected 200, got {status}"
    assert body == {"ok": True, "result": {"applied": [1, 2, 3]}}
    assert record == [("cors_apply", {"job_id": "job123abc456", "confirmed": True, "force": False})]

    record = []
    fn = fake_request(result={"ok": True, "data": None}, record=record)
    status, body = api.handle_apply({"job_id": "job123abc456", "confirm": True, "force": True}, request_fn=fn)
    assert record[0][1]["force"] is True

    for confirm_val in [None, False, "true", 1, "yes"]:
        record = []
        fn = fake_request(record=record)
        body = {"job_id": "job123abc456"}
        if confirm_val is not None:
            body["confirm"] = confirm_val
        status, body = api.handle_apply(body, request_fn=fn)
        assert status == 400, f"Expected 400 for confirm={confirm_val}, got {status}"
        assert body == {"ok": False, "error": "confirmation required"}
        assert record == [], f"request_fn called for confirm={confirm_val}"

    for bad_body in [None, [], "x"]:
        status, body = api.handle_apply(bad_body, request_fn=fake_request())
        assert status == 400, f"Expected 400 for {bad_body}, got {status}"
        assert body == {"ok": False, "error": "JSON object required"}

    for bad_id in [None, 5, "../x", ""]:
        body = {"job_id": bad_id, "confirm": True}
        status, body = api.handle_apply(body, request_fn=fake_request())
        assert status == 400, f"Expected 400 for job_id={bad_id}, got {status}"
        assert body == {"ok": False, "error": "job_id is required"}

    fn = fake_request(result={"ok": False, "message": "change too large", "data": None})
    status, body = api.handle_apply({"job_id": "job123abc456", "confirm": True}, request_fn=fn)
    assert status == 409, f"Expected 409, got {status}"
    assert body == {"ok": False, "error": "change too large", "result": None}

    fn = fake_request(result=None)
    status, body = api.handle_apply({"job_id": "job123abc456", "confirm": True}, request_fn=fn)
    assert status == 504, f"Expected 504, got {status}"

    fn = fake_request(exc=RuntimeError("no service"))
    status, body = api.handle_apply({"job_id": "job123abc456", "confirm": True}, request_fn=fn)
    assert status == 503, f"Expected 503, got {status}"

    fn = fake_request(exc=ValueError("secret"))
    status, body = api.handle_apply({"job_id": "job123abc456", "confirm": True}, request_fn=fn)
    assert status == 500, f"Expected 500, got {status}"
    assert body == {"ok": False, "error": "internal error"}

test("C: handle_apply", test_c)

def test_d():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "job.json")
        status, body = api.handle_job(job_path=path)
        assert status == 200, f"Expected 200, got {status}"
        assert body == {"ok": True, "job": {"status": "idle"}}

        cj.save_job({"status": "done", "stage": "complete"}, path)
        status, body = api.handle_job(job_path=path)
        assert body["job"]["status"] == "done"
        assert body["job"]["stage"] == "complete"

        cj.save_job({"status": "running", "stage": "computing"}, path)
        status, body = api.handle_job(job_path=path, runner_active_fn=lambda: True)
        assert body["job"]["status"] == "running"

        status, body = api.handle_job(job_path=path, runner_active_fn=lambda: False)
        assert body["job"]["status"] == "failed"
        assert body["job"]["stage"] == "interrupted"
        assert body["job"]["info"] == "the survey service is not running"
        with open(path) as f:
            disk = json.load(f)
        assert disk["status"] == "running"

        with open(path, "w") as f:
            f.write("not json")
        status, body = api.handle_job(job_path=path)
        assert body["job"]["status"] == "idle"

test("D: handle_job", test_d)

def test_e():
    with tempfile.TemporaryDirectory() as d:
        def runner():
            for _ in range(50):
                req = sr.take_next_request(request_dir=d)
                if req is not None:
                    assert req["action"] == "cors_compute"
                    sr.write_result(req["id"], True, "started", {"job_id": "job123abc456"}, request_dir=d)
                    return
                time.sleep(0.05)

        t = threading.Thread(target=runner)
        t.start()
        time.sleep(0.1)

        result = client.request("cors_compute", {"account_id": "abc123"}, timeout=5, request_dir=d, start_service=lambda: True)
        t.join(timeout=5)
        assert result is not None
        assert result["ok"] is True
        assert result["data"] == {"job_id": "job123abc456"}

test("E: client.request end to end", test_e)

def test_f():
    with tempfile.TemporaryDirectory() as d:
        try:
            client.request("cors_compute", {}, timeout=1, request_dir=d, start_service=lambda: False)
            assert False, "Expected RuntimeError"
        except RuntimeError:
            pass
        pending = os.path.join(d, "pending")
        if os.path.exists(pending):
            assert len(os.listdir(pending)) == 0, "Pending request not withdrawn"

    with tempfile.TemporaryDirectory() as d:
        result = client.request("cors_compute", {}, timeout=1, request_dir=d, start_service=lambda: True)
        assert result is None
        pending = os.path.join(d, "pending")
        if os.path.exists(pending):
            assert len(os.listdir(pending)) == 0, "Pending request not withdrawn after timeout"

    with tempfile.TemporaryDirectory() as d:
        try:
            client.request("cors_hack", {}, timeout=1, request_dir=d, start_service=lambda: True)
            assert False, "Expected ValueError"
        except ValueError:
            pass

test("F: client.request failure paths", test_f)

def test_g():
    routes_path = os.path.join(repo, "addons", "features", "cors_position", "cors_routes.py")
    with open(routes_path) as f:
        content = f.read()

    assert '"/accounts/<account_id>/compute"' in content, "Missing compute route"
    assert '"/job"' in content, "Missing job route"
    assert '"/job/cancel"' in content, "Missing cancel route"
    assert '"/job/apply"' in content, "Missing apply route"

    lines = content.split("\n")
    for i, line in enumerate(lines):
        if "@cors_bp.route(" in line:
            next_line = lines[i + 1].strip() if i + 1 < len(lines) else ""
            assert next_line == "@login_required", f"Route at line {i+1} not followed by @login_required"

test("G: routes exist", test_g)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF

exit $?
