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
import math
import re
from datetime import datetime, timedelta
import importlib.util

repo_root = os.environ.get('GM_REPO_ROOT', '.')
sys.path.insert(0, os.path.join(repo_root, 'addons', 'features', 'cors_position'))

import cors_rtk_parse as p

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

def nmea_checksum(sentence):
    """Compute NMEA checksum for a sentence (without $ and *)."""
    cs = 0
    for ch in sentence:
        cs ^= ord(ch)
    return f"{cs:02X}"

def make_gga(talker, lat, lon, quality, sats, hdop, alt, geoid):
    """Build a GGA sentence with correct checksum."""
    lat_dir = "N" if lat >= 0 else "S"
    lon_dir = "E" if lon >= 0 else "W"
    lat_abs = abs(lat)
    lon_abs = abs(lon)
    lat_deg = int(lat_abs)
    lat_min = (lat_abs - lat_deg) * 60
    lon_deg = int(lon_abs)
    lon_min = (lon_abs - lon_deg) * 60
    body = f"${talker}GGA,123519,{lat_deg:02d}{lat_min:07.4f},{lat_dir},{lon_deg:03d}{lon_min:07.4f},{lon_dir},{quality},{sats:02d},{hdop:.1f},{alt:.1f},M,{geoid:.1f},M,,"
    return body + "*" + nmea_checksum(body[1:])

# Test A: parse_gga famous sample
def test_a():
    result = p.parse_gga("$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47")
    assert result is not None, "Famous GGA sample should parse"
    assert abs(result["lat"] - 48.1173) < 1e-6, f"lat {result['lat']} != 48.1173"
    assert abs(result["lon"] - 11.516667) < 1e-6, f"lon {result['lon']} != 11.516667"
    assert result["quality"] == 1, f"quality {result['quality']} != 1"
    assert result["sats"] == 8, f"sats {result['sats']} != 8"
    assert abs(result["hdop"] - 0.9) < 1e-6, f"hdop {result['hdop']} != 0.9"
    assert abs(result["alt_msl"] - 545.4) < 1e-6, f"alt {result['alt_msl']} != 545.4"
    assert abs(result["geoid_sep"] - 46.9) < 1e-6, f"geoid {result['geoid_sep']} != 46.9"

    # GNGGA variant
    result2 = p.parse_gga(make_gga("GN", 48.1173, 11.516667, 1, 8, 0.9, 545.4, 46.9))
    assert result2 is not None, "GNGGA variant should parse"

    # Wrong checksum
    result3 = p.parse_gga("$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*48")
    assert result3 is None, "Wrong checksum should fail"

    # No checksum
    result4 = p.parse_gga("$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,")
    assert result4 is not None, "No checksum should be accepted"

    # Southern/western
    sw = make_gga("GP", -33.5, -70.5, 1, 8, 0.9, 10.0, 0.0)
    result5 = p.parse_gga(sw)
    assert result5 is not None, "Southern/western GGA should parse"
    assert abs(result5["lat"] - (-33.5)) < 1e-6, f"lat {result5['lat']} != -33.5"
    assert abs(result5["lon"] - (-70.5)) < 1e-6, f"lon {result5['lon']} != -70.5"

test("A: parse_gga famous sample and variants", test_a)

# Test B: parse_gga rejections
def test_b():
    # RMC sentence
    result = p.parse_gga("$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A")
    assert result is None, "RMC sentence should be rejected"

    # Empty lat field
    result2 = p.parse_gga("$GPGGA,123519,,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*00")
    assert result2 is None, "Empty lat should be rejected"

    # Garbage
    result3 = p.parse_gga("hello")
    assert result3 is None, "Garbage should be rejected"

    # Too few fields
    result4 = p.parse_gga("$GPGGA,1,2")
    assert result4 is None, "Too few fields should be rejected"

    # Non-numeric quality
    result5 = p.parse_gga("$GPGGA,123519,4807.038,N,01131.000,E,x,08,0.9,545.4,M,46.9,M,,*00")
    assert result5 is None, "Non-numeric quality should be rejected"

test("B: parse_gga rejections", test_b)

# Test C: read_rinex_approx_xyz
def test_c():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "obs.rnx")
        # Build RINEX header with APPROX POSITION XYZ
        x, y, z = 4178200.1234, 2084711.5678, 4328800.9876
        pos_line = f"{x:14.4f}{y:14.4f}{z:14.4f}"
        pos_line = pos_line.ljust(60) + "APPROX POSITION XYZ"
        end_line = "END OF HEADER".ljust(60)
        with open(path, "w") as f:
            f.write("RINEX VERSION / TYPE\n")
            f.write(pos_line + "\n")
            f.write(end_line + "\n")

        result = p.read_rinex_approx_xyz(path)
        assert result is not None, "Should find APPROX POSITION XYZ"
        assert abs(result[0] - x) < 1e-4, f"x {result[0]} != {x}"
        assert abs(result[1] - y) < 1e-4, f"y {result[1]} != {y}"
        assert abs(result[2] - z) < 1e-4, f"z {result[2]} != {z}"

        # All zeros
        path2 = os.path.join(d, "obs2.rnx")
        zero_line = "0.000000000000000.000000000000000.00000000000000".ljust(60) + "APPROX POSITION XYZ"
        with open(path2, "w") as f:
            f.write(zero_line + "\n")
            f.write(end_line + "\n")
        result2 = p.read_rinex_approx_xyz(path2)
        assert result2 is None, "All zeros should return None"

        # No label
        path3 = os.path.join(d, "obs3.rnx")
        with open(path3, "w") as f:
            f.write("Some other line\n")
            f.write(end_line + "\n")
        result3 = p.read_rinex_approx_xyz(path3)
        assert result3 is None, "No label should return None"

        # Missing file
        try:
            p.read_rinex_approx_xyz(os.path.join(d, "missing.rnx"))
            assert False, "Should raise FileNotFoundError"
        except FileNotFoundError:
            pass

        # After END OF HEADER
        path4 = os.path.join(d, "obs4.rnx")
        with open(path4, "w") as f:
            f.write(end_line + "\n")
            f.write(pos_line + "\n")
        result4 = p.read_rinex_approx_xyz(path4)
        assert result4 is None, "After END OF HEADER should return None"

test("C: read_rinex_approx_xyz", test_c)

# Test D: ecef roundtrip
def test_d():
    coords = [
        (42.65236966, 26.43258495, 208.145),
        (0.0, 0.0, 0.0),
        (-33.5, -70.5, 2500.0),
        (89.9, 10.0, 100.0),
        (90.0, 0.0, 100.0),
    ]
    for lat, lon, h in coords:
        ecef = p.geodetic_to_ecef(lat, lon, h)
        back = p.ecef_to_geodetic(*ecef)
        assert abs(back[0] - lat) < 1e-9, f"lat roundtrip failed for ({lat},{lon},{h}): {back[0]}"
        if lat != 90.0:
            assert abs(back[1] - lon) < 1e-9, f"lon roundtrip failed for ({lat},{lon},{h}): {back[1]}"
        assert abs(back[2] - h) < 1e-4, f"h roundtrip failed for ({lat},{lon},{h}): {back[2]}"

    # Known value
    ecef = p.geodetic_to_ecef(0.0, 0.0, 0.0)
    assert abs(ecef[0] - 6378137.0) < 1e-6, f"Known ECEF x failed: {ecef[0]}"
    assert abs(ecef[1]) < 1e-6, f"Known ECEF y failed: {ecef[1]}"
    assert abs(ecef[2]) < 1e-6, f"Known ECEF z failed: {ecef[2]}"

test("D: ecef roundtrip", test_d)

# Test E: build_rnx2rtkp_conf
def test_e():
    conf = p.build_rnx2rtkp_conf()
    assert re.search(r"^pos1-posmode\s*=static$", conf, re.MULTILINE), "Missing pos1-posmode=static"
    assert re.search(r"^pos2-armode\s*=fix-and-hold$", conf, re.MULTILINE), "Missing pos2-armode=fix-and-hold"
    assert re.search(r"^ant2-postype\s*=rinexhead$", conf, re.MULTILINE), "Missing ant2-postype=rinexhead"
    assert re.search(r"^pos1-navsys\s*=13$", conf, re.MULTILINE), "Missing pos1-navsys=13"
    assert re.search(r"^pos1-elmask\s*=15\.0$", conf, re.MULTILINE), "Missing pos1-elmask=15.0"
    assert re.search(r"^pos1-frequency\s*=l1\+l2$", conf, re.MULTILINE), "Missing pos1-frequency=l1+l2"

    # Custom values
    conf2 = p.build_rnx2rtkp_conf(frequencies="l1", navsys=1)
    assert re.search(r"^pos1-frequency\s*=l1$", conf2, re.MULTILINE), "Custom frequency not reflected"
    assert re.search(r"^pos1-navsys\s*=1$", conf2, re.MULTILINE), "Custom navsys not reflected"

    # Invalid values
    try:
        p.build_rnx2rtkp_conf(frequencies="l3")
        assert False, "Invalid frequency should raise ValueError"
    except ValueError:
        pass

    for bad_navsys in [0, 64, "x"]:
        try:
            p.build_rnx2rtkp_conf(navsys=bad_navsys)
            assert False, f"Invalid navsys {bad_navsys} should raise ValueError"
        except ValueError:
            pass

    # Every non-empty line contains =
    for line in conf.split("\n"):
        if line.strip():
            assert "=" in line, f"Line without '=': {line}"

test("E: build_rnx2rtkp_conf", test_e)

# Test F: parse_pos_file
def test_f():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "solution.pos")
        lines = [
            "% Header line",
            "",
            "malformed line",
            "2026/10/24 06:00:00.000   42.652369660   26.432584950   208.1450   2  12   0.0100   0.0100   0.0200   0.0000   0.0000   0.0000   0.00    1.5",
            "2026/10/24 06:00:01.000   42.652369660   26.432584950   208.1450   2  12   0.0100   0.0100   0.0200   0.0000   0.0000   0.0000   0.00    1.5",
            "2026/10/24 06:00:02.000   42.652369660   26.432584950   208.1450   1  12   0.0100   0.0100   0.0200   0.0000   0.0000   0.0000   0.00    1.5",
            "2026/10/24 06:00:03.000   42.652369660   26.432584950   208.1450   1  12   0.0100   0.0100   0.0200   0.0000   0.0000   0.0000   0.00    1.5",
            "2026/10/24 06:00:04.000   42.652369660   26.432584950   208.1450   1  12   0.0100   0.0100   0.0200   0.0000   0.0000   0.0000   0.00    1.5",
            "2026/10/24 06:00:05.000   42.652369660   26.432584950   208.1450   1  12   0.0100   0.0100   0.0200   0.0000   0.0000   0.0000   0.00    1.5",
        ]
        with open(path, "w") as f:
            f.write("\n".join(lines) + "\n")

        epochs = p.parse_pos_file(path)
        assert len(epochs) == 6, f"Expected 6 epochs, got {len(epochs)}"
        assert epochs[0]["q"] == 2, f"First epoch q should be 2, got {epochs[0]['q']}"
        assert epochs[-1]["q"] == 1, f"Last epoch q should be 1, got {epochs[-1]['q']}"
        assert epochs[1]["time"] == datetime(2026, 10, 24, 6, 0, 1), f"Second epoch time wrong: {epochs[1]['time']}"
        assert abs(epochs[0]["lat"] - 42.65236966) < 1e-9, f"lat wrong: {epochs[0]['lat']}"
        assert epochs[0]["ns"] == 12, f"ns wrong: {epochs[0]['ns']}"
        assert abs(epochs[0]["sdn"] - 0.01) < 1e-6, f"sdn wrong: {epochs[0]['sdn']}"

        # Line with only 8 fields should be skipped
        path2 = os.path.join(d, "solution2.pos")
        with open(path2, "w") as f:
            f.write("2026/10/24 06:00:00.000   42.652369660   26.432584950   208.1450   1  12   0.0100   0.0100\n")
        epochs2 = p.parse_pos_file(path2)
        assert len(epochs2) == 0, f"Short line should be skipped, got {len(epochs2)} epochs"

test("F: parse_pos_file", test_f)

# Test G: summarize_solution
def test_g():
    # Generate 300 epochs: first 90 q=2, rest q=1
    epochs = []
    base_time = datetime(2026, 10, 24, 6, 0, 0)
    for i in range(300):
        q = 2 if i < 90 else 1
        d = (i % 5) - 2
        lat = 42.65236966 + d * 1e-9
        lon = 26.43258495 + d * 1e-9
        h = 208.145 + d * 0.001
        epochs.append({
            "time": base_time + timedelta(seconds=i),
            "lat": lat,
            "lon": lon,
            "h": h,
            "q": q,
            "ns": 12,
            "sdn": 0.01,
            "sde": 0.01,
            "sdu": 0.02,
        })

    summary = p.summarize_solution(epochs, skip_seconds=60)
    assert summary["total"] == 300, f"total {summary['total']} != 300"
    assert summary["fixed"] == 210, f"fixed {summary['fixed']} != 210"
    assert abs(summary["fix_ratio"] - 0.7) < 1e-6, f"fix_ratio {summary['fix_ratio']} != 0.7"
    assert summary["first_fix_s"] == 90.0, f"first_fix_s {summary['first_fix_s']} != 90.0"
    assert summary["used"] == 210, f"used {summary['used']} != 210"
    assert abs(summary["lat"] - 42.65236966) < 2e-9, f"lat {summary['lat']} not near centre"
    assert abs(summary["h"] - 208.145) < 0.002, f"h {summary['h']} not near centre"
    assert summary["std_n_m"] < 0.01, f"std_n_m {summary['std_n_m']} >= 0.01"
    assert summary["std_e_m"] < 0.01, f"std_e_m {summary['std_e_m']} >= 0.01"
    assert 0.0005 < summary["std_u_m"] < 0.003, f"std_u_m {summary['std_u_m']} not in range"

    # With skip_seconds=200
    summary2 = p.summarize_solution(epochs, skip_seconds=200)
    assert summary2["used"] == 100, f"used with skip=200 should be 100, got {summary2['used']}"

    # Empty list
    summary3 = p.summarize_solution([])
    assert summary3["total"] == 0, f"empty total should be 0"
    assert summary3["fixed"] == 0, f"empty fixed should be 0"
    assert summary3["fix_ratio"] == 0.0, f"empty fix_ratio should be 0.0"
    assert summary3["first_fix_s"] is None, f"empty first_fix_s should be None"
    assert summary3["used"] == 0, f"empty used should be 0"
    assert summary3["lat"] is None, f"empty lat should be None"
    assert summary3["std_n_m"] is None, f"empty std_n_m should be None"

    # Single fixed epoch after skip
    single = [
        {
            "time": base_time,
            "lat": 42.65236966,
            "lon": 26.43258495,
            "h": 208.145,
            "q": 2,
            "ns": 12,
            "sdn": 0.01,
            "sde": 0.01,
            "sdu": 0.02,
        },
        {
            "time": base_time + timedelta(seconds=100),
            "lat": 42.65236966,
            "lon": 26.43258495,
            "h": 208.145,
            "q": 1,
            "ns": 12,
            "sdn": 0.01,
            "sde": 0.01,
            "sdu": 0.02,
        }
    ]
    summary4 = p.summarize_solution(single, skip_seconds=60)
    assert summary4["used"] == 1, f"single used should be 1"
    assert summary4["std_n_m"] is None, f"single std_n_m should be None"
    assert summary4["std_e_m"] is None, f"single std_e_m should be None"
    assert summary4["std_u_m"] is None, f"single std_u_m should be None"

test("G: summarize_solution", test_g)

# Test H: evaluate_solution
def test_h():
    # No fixed solution
    s1 = {"fixed": 0, "used": 0, "fix_ratio": 0.0, "std_n_m": None, "std_e_m": None, "std_u_m": None}
    ok, reason = p.evaluate_solution(s1)
    assert not ok and reason == "no fixed solution", f"Expected 'no fixed solution', got {reason}"

    # Too few fixed epochs
    s2 = {"fixed": 10, "used": 10, "fix_ratio": 1.0, "std_n_m": 0.005, "std_e_m": 0.005, "std_u_m": 0.005}
    ok, reason = p.evaluate_solution(s2)
    assert not ok and reason == "too few fixed epochs", f"Expected 'too few fixed epochs', got {reason}"

    # Fix ratio too low
    s3 = {"fixed": 100, "used": 100, "fix_ratio": 0.3, "std_n_m": 0.005, "std_e_m": 0.005, "std_u_m": 0.005}
    ok, reason = p.evaluate_solution(s3)
    assert not ok and reason == "fix ratio too low", f"Expected 'fix ratio too low', got {reason}"

    # Solution not stable (std too high)
    s4 = {"fixed": 100, "used": 100, "fix_ratio": 0.9, "std_n_m": 0.005, "std_e_m": 0.005, "std_u_m": 0.2}
    ok, reason = p.evaluate_solution(s4)
    assert not ok and reason == "solution not stable", f"Expected 'solution not stable', got {reason}"

    # std_n_m is None
    s5 = {"fixed": 100, "used": 100, "fix_ratio": 0.9, "std_n_m": None, "std_e_m": 0.005, "std_u_m": 0.005}
    ok, reason = p.evaluate_solution(s5)
    assert not ok and reason == "solution not stable", f"Expected 'solution not stable' for None std, got {reason}"

    # Good summary
    s6 = {"fixed": 210, "used": 210, "fix_ratio": 0.7, "std_n_m": 0.005, "std_e_m": 0.005, "std_u_m": 0.005}
    ok, reason = p.evaluate_solution(s6)
    assert ok and reason is None, f"Expected success, got {reason}"

test("H: evaluate_solution", test_h)

# Test I: end-to-end
def test_i():
    with tempfile.TemporaryDirectory() as d:
        # Good data (from test G)
        path = os.path.join(d, "good.pos")
        base_time = datetime(2026, 10, 24, 6, 0, 0)
        lines = []
        for i in range(300):
            q = 2 if i < 90 else 1
            d_val = (i % 5) - 2
            lat = 42.65236966 + d_val * 1e-9
            lon = 26.43258495 + d_val * 1e-9
            h = 208.145 + d_val * 0.001
            lines.append(f"2026/10/24 06:{i//60:02d}:{i%60:02d}.000   {lat:.9f}   {lon:.9f}   {h:.4f}   {q}  12   0.0100   0.0100   0.0200   0.0000   0.0000   0.0000   0.00    1.5")
        with open(path, "w") as f:
            f.write("\n".join(lines) + "\n")

        epochs = p.parse_pos_file(path)
        summary = p.summarize_solution(epochs, skip_seconds=60)
        ok, reason = p.evaluate_solution(summary)
        assert ok and reason is None, f"End-to-end good data should pass, got {reason}"

        # All q=2 (no fixed solution)
        path2 = os.path.join(d, "bad.pos")
        lines2 = []
        for i in range(100):
            lines2.append(f"2026/10/24 06:{i//60:02d}:{i%60:02d}.000   42.652369660   26.432584950   208.1450   2  12   0.0100   0.0100   0.0200   0.0000   0.0000   0.0000   0.00    1.5")
        with open(path2, "w") as f:
            f.write("\n".join(lines2) + "\n")

        epochs2 = p.parse_pos_file(path2)
        summary2 = p.summarize_solution(epochs2, skip_seconds=60)
        ok2, reason2 = p.evaluate_solution(summary2)
        assert not ok2 and reason2 == "no fixed solution", f"End-to-end bad data should fail with 'no fixed solution', got {reason2}"

test("I: end-to-end", test_i)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF

exit $?
