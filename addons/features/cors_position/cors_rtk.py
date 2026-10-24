"""CORS RTK position determination orchestration.

Captures CORS and local receiver streams, converts to RINEX,
solves a static RTK baseline, and evaluates the solution.
"""

import logging
import os
import shutil
import socket
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from subprocess import TimeoutExpired
from typing import Any, Callable, Dict, List, Optional, Tuple

from . import ntrip_client as nc
from . import cors_rtk_parse as rp
from ..auto_survey import rinex_converter as rc
from ..auto_survey.process_group import run_in_process_group

logger = logging.getLogger(__name__)


class CorsRtkError(Exception):
    """Error during CORS RTK processing."""

    def __init__(self, stage: str, kind: str, message: str):
        super().__init__(message)
        self.stage = stage
        self.kind = kind


def read_approx_from_nmea(
    host: str, port: int, timeout: float = 60.0
) -> Tuple[float, float, float]:
    """Read approximate position from receiver NMEA stream."""
    start = time.monotonic()
    try:
        sock = socket.create_connection((host, port), timeout=5.0)
    except (OSError, socket.timeout) as e:
        raise CorsRtkError(
            "approx", "no_approx_position",
            "no approximate position from the receiver"
        ) from e

    try:
        sock.settimeout(5.0)
        buf = b""
        while True:
            elapsed = time.monotonic() - start
            if elapsed >= timeout:
                raise CorsRtkError(
                    "approx", "no_approx_position",
                    "no approximate position from the receiver"
                )
            try:
                chunk = sock.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                break
            buf += chunk
            lines = buf.split(b"\n")
            buf = lines[-1]
            for line in lines[:-1]:
                parsed = rp.parse_gga(line.decode("ascii", errors="replace"))
                if parsed and parsed["quality"] >= 1 and parsed["alt_msl"] is not None:
                    h = parsed["alt_msl"] + (parsed["geoid_sep"] or 0.0)
                    return (parsed["lat"], parsed["lon"], h)
    finally:
        sock.close()

    raise CorsRtkError(
        "approx", "no_approx_position",
        "no approximate position from the receiver"
    )


def capture_local_raw(
    host: str, port: int, out_path: str, duration_s: float,
    stop_event: Optional[threading.Event] = None,
    idle_timeout: float = 30.0
) -> Dict[str, Any]:
    """Capture local receiver raw stream to file."""
    try:
        sock = socket.create_connection((host, port), timeout=5.0)
    except (OSError, socket.timeout) as e:
        raise CorsRtkError("capture_rover", "connect", "failed to connect to receiver") from e

    fd = None
    try:
        fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        sock.settimeout(0.25)
        total_bytes = 0
        start = time.monotonic()
        last_data = time.monotonic()

        while True:
            elapsed = time.monotonic() - start
            if elapsed >= duration_s:
                break
            if stop_event and stop_event.is_set():
                break

            try:
                chunk = sock.recv(4096)
            except socket.timeout:
                if time.monotonic() - last_data > idle_timeout:
                    raise CorsRtkError("capture_rover", "no_data", "no data from receiver")
                continue
            except OSError:
                break

            if not chunk:
                if total_bytes == 0:
                    raise CorsRtkError("capture_rover", "no_data", "no data from receiver")
                break

            remaining = chunk
            while remaining:
                written = os.write(fd, remaining)
                remaining = remaining[written:]
            total_bytes += len(chunk)
            last_data = time.monotonic()

        return {"bytes": total_bytes, "seconds": time.monotonic() - start}
    finally:
        if fd is not None:
            os.close(fd)
        sock.close()


def convert_obs(
    convbin: str, raw_file: str, out_dir: str, receiver_format: str,
    sample_interval: Optional[float] = None, timeout: int = 300
) -> Tuple[Path, List[Path]]:
    """Convert raw observation file to RINEX."""
    out_path = Path(out_dir)
    out_path.mkdir(parents=True, exist_ok=True)

    # FIX 1: Clean stale output files before conversion
    for pattern in ["*.obs", "*.nav", "*.[0-9][0-9]n"]:
        for f in out_path.glob(pattern):
            try:
                f.unlink()
            except Exception:
                pass

    args = rc.build_convbin_args(
        Path(convbin), Path(raw_file), out_path, receiver_format,
        sample_interval=sample_interval
    )

    try:
        result = run_in_process_group(args, timeout=timeout)
    except TimeoutExpired as e:
        raise CorsRtkError("convert", "timeout", "convbin timed out") from e

    if result.returncode != 0:
        raise CorsRtkError("convert", "convert_failed", "convbin failed")

    obs_files = list(out_path.glob("*.obs"))
    if not obs_files:
        raise CorsRtkError("convert", "convert_failed", "convbin failed")

    obs_path = max(obs_files, key=lambda p: p.stat().st_mtime)
    nav_paths = list(out_path.glob("*.nav")) + list(out_path.glob("*.[0-9][0-9]n"))

    return (obs_path, nav_paths)


def run_rnx2rtkp(
    rnx2rtkp: str, rover_obs: Path, base_obs: Path, nav_files: List[Path],
    conf_text: str, out_pos: Path, timeout: int = 900
) -> Path:
    """Run rnx2rtkp to solve static RTK baseline."""
    # FIX 2: Delete existing output file before running
    try:
        out_pos.unlink()
    except Exception:
        pass

    # FIX 2: Use string concatenation for config path
    conf_path = Path(str(out_pos) + ".conf")
    with open(conf_path, "w") as f:
        f.write(conf_text)
    os.chmod(conf_path, 0o600)

    args = [
        str(rnx2rtkp), "-k", str(conf_path), "-o", str(out_pos),
        str(rover_obs), str(base_obs)
    ] + [str(n) for n in nav_files]

    try:
        result = run_in_process_group(args, timeout=timeout)
    except TimeoutExpired as e:
        raise CorsRtkError("solve", "timeout", "rnx2rtkp timed out") from e

    if result.returncode != 0 or not out_pos.exists() or out_pos.stat().st_size == 0:
        raise CorsRtkError("solve", "solve_failed", "rnx2rtkp failed")

    return out_pos


def compute_position(
    account: Dict[str, Any], work_dir: str,
    params: Optional[Dict[str, Any]] = None,
    progress: Optional[Callable[[str, str], None]] = None,
    stop_event: Optional[threading.Event] = None
) -> Dict[str, Any]:
    """Compute position using CORS RTK. Never raises."""
    if params is None:
        params = {}

    duration_s = params.get("duration_s", 900)
    rover_host = params.get("rover_host", "127.0.0.1")
    rover_port = params.get("rover_port", 5015)
    rover_suffix = params.get("rover_suffix", ".ubx")
    nmea_host = params.get("nmea_host", "127.0.0.1")
    nmea_port = params.get("nmea_port", 5014)
    approx = params.get("approx")
    sample_interval = params.get("sample_interval", 5.0)
    frequencies = params.get("frequencies", "l1+l2")
    navsys = params.get("navsys", 13)
    convbin_path = params.get("convbin_path")
    rnx2rtkp_path = params.get("rnx2rtkp_path")
    cleanup = params.get("cleanup", True)
    min_used = params.get("min_used", 60)
    min_fix_ratio = params.get("min_fix_ratio", 0.5)
    max_std_m = params.get("max_std_m", 0.05)

    result = {
        "ok": False,
        "stage": None,
        "kind": None,
        "reason": None,
        "account_id": account["id"],
        "account_name": account["name"],
        "frame": account["frame"],
        "epoch": account["epoch"],
        "mode": account["mode"],
        "approx": None,
        "base_xyz": None,
        "summary": None,
        "lat": None,
        "lon": None,
        "h": None,
        "rover_bytes": None,
        "base_bytes": None,
        "started_at": datetime.now(timezone.utc).isoformat(),
        "finished_at": None,
    }

    work = Path(work_dir)
    try:
        work.mkdir(parents=True, mode=0o700, exist_ok=True)
        base_dir = work / "base"
        rover_dir = work / "rover"
        base_dir.mkdir(exist_ok=True)
        rover_dir.mkdir(exist_ok=True)

        if progress:
            progress("approx", "reading approximate position")
        if approx is None:
            approx = read_approx_from_nmea(nmea_host, nmea_port)
        result["approx"] = list(approx)
        lat, lon, h = approx

        if progress:
            progress("mountpoint", "selecting mountpoint")
        mountpoint = account["mountpoint"]
        if mountpoint.upper() == "AUTO":
            # FIX 3: Wrap sourcetable fetch in its own try/except
            try:
                entries = nc.fetch_sourcetable(
                    account["host"], account["port"],
                    account["username"], account["password"],
                    tls=account["tls"]
                )
                picked = nc.pick_mountpoint(
                    entries, lat, lon, need_nmea=(account["mode"] == "vrs")
                )
                if picked is None:
                    result["stage"] = "mountpoint"
                    result["kind"] = "not_found"
                    result["reason"] = "no suitable mountpoint in the sourcetable"
                    return result
                mountpoint = picked["mountpoint"]
            except nc.NtripError as e:
                result["stage"] = "mountpoint"
                result["kind"] = e.kind
                result["reason"] = str(e)
                return result

        if progress:
            progress("capture", "capturing streams")

        base_file = base_dir / "base.rtcm3"
        rover_file = rover_dir / f"rover{rover_suffix}"

        base_result = [None]
        base_error = [None]
        rover_result = [None]
        rover_error = [None]

        def capture_base():
            try:
                gga_provider = None
                if account["mode"] == "vrs":
                    gga_provider = lambda: nc.make_gga(lat, lon, h)
                base_result[0] = nc.capture_stream(
                    account["host"], account["port"], mountpoint,
                    account["username"], account["password"],
                    str(base_file), duration_s,
                    tls=account["tls"],
                    gga_provider=gga_provider,
                    stop_event=stop_event
                )
            except nc.NtripError as e:
                base_error[0] = e
            except Exception as e:
                base_error[0] = e

        def capture_rover():
            try:
                rover_result[0] = capture_local_raw(
                    rover_host, rover_port, str(rover_file),
                    duration_s, stop_event=stop_event
                )
            except CorsRtkError as e:
                rover_error[0] = e
            except Exception as e:
                rover_error[0] = e

        t_base = threading.Thread(target=capture_base)
        t_rover = threading.Thread(target=capture_rover)
        t_base.start()
        t_rover.start()
        t_base.join()
        t_rover.join()

        if stop_event and stop_event.is_set():
            result["stage"] = "capture"
            result["kind"] = "cancelled"
            result["reason"] = "cancelled"
            return result

        if base_error[0] is not None:
            e = base_error[0]
            if isinstance(e, nc.NtripError):
                result["stage"] = "capture_base"
                result["kind"] = e.kind
                result["reason"] = str(e)
            else:
                result["stage"] = "capture_base"
                result["kind"] = "internal"
                result["reason"] = "internal error"
            return result

        if rover_error[0] is not None:
            e = rover_error[0]
            if isinstance(e, CorsRtkError):
                result["stage"] = e.stage
                result["kind"] = e.kind
                result["reason"] = str(e)
            else:
                result["stage"] = "capture_rover"
                result["kind"] = "internal"
                result["reason"] = "internal error"
            return result

        result["base_bytes"] = base_result[0]["bytes"]
        result["rover_bytes"] = rover_result[0]["bytes"]

        if progress:
            progress("convert", "converting to RINEX")

        if convbin_path is None:
            convbin_path = rc.find_rtklib_tool("convbin")
            if convbin_path is None:
                result["stage"] = "tools"
                result["kind"] = "tool_missing"
                result["reason"] = "convbin not found"
                return result

        if rnx2rtkp_path is None:
            rnx2rtkp_path = rc.find_rtklib_tool("rnx2rtkp")
            if rnx2rtkp_path is None:
                result["stage"] = "tools"
                result["kind"] = "tool_missing"
                result["reason"] = "rnx2rtkp not found"
                return result

        rover_format = rc.receiver_format_for(rover_file)
        rover_obs, rover_nav = convert_obs(
            str(convbin_path), str(rover_file), str(rover_dir),
            rover_format, sample_interval=sample_interval
        )
        base_obs, base_nav = convert_obs(
            str(convbin_path), str(base_file), str(base_dir),
            "rtcm3", sample_interval=sample_interval
        )

        base_xyz = rp.read_rinex_approx_xyz(str(base_obs))
        if base_xyz is None:
            result["stage"] = "convert"
            result["kind"] = "no_base_position"
            result["reason"] = "the CORS stream carries no reference station position (RTCM 1005/1006)"
            return result
        result["base_xyz"] = list(base_xyz)

        if progress:
            progress("solve", "solving RTK baseline")

        conf = rp.build_rnx2rtkp_conf(frequencies, navsys)
        pos_file = work / "result.pos"
        run_rnx2rtkp(
            str(rnx2rtkp_path), rover_obs, base_obs,
            rover_nav + base_nav, conf, pos_file
        )

        if progress:
            progress("evaluate", "evaluating solution")

        epochs = rp.parse_pos_file(str(pos_file))
        summary = rp.summarize_solution(epochs)
        result["summary"] = summary

        ok, reason = rp.evaluate_solution(
            summary, min_used, min_fix_ratio, max_std_m
        )

        if ok:
            result["ok"] = True
            result["lat"] = summary["lat"]
            result["lon"] = summary["lon"]
            result["h"] = summary["h"]
        else:
            result["stage"] = "evaluate"
            result["kind"] = "poor_solution"
            result["reason"] = reason
            result["lat"] = summary["lat"]
            result["lon"] = summary["lon"]
            result["h"] = summary["h"]

    except CorsRtkError as e:
        result["stage"] = e.stage
        result["kind"] = e.kind
        result["reason"] = str(e)
    except nc.NtripError as e:
        result["stage"] = "capture_base"
        result["kind"] = e.kind
        result["reason"] = str(e)
    except Exception:
        result["stage"] = "internal"
        result["kind"] = "internal"
        result["reason"] = "internal error"
    finally:
        result["finished_at"] = datetime.now(timezone.utc).isoformat()
        if cleanup:
            try:
                shutil.rmtree(work, ignore_errors=True)
            except Exception:
                pass

    return result
