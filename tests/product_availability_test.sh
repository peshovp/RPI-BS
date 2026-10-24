#!/usr/bin/env bash
set -uo pipefail

REPO="${GM_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not found"
    exit 0
fi

python3 - "$REPO" <<'PYEOF'
import sys
import importlib.util
from datetime import datetime

REPO = sys.argv[1]
passed = 0
failed = 0

def check(name, condition):
    global passed, failed
    if condition:
        print(f"PASS: {name}")
        passed += 1
    else:
        print(f"FAIL: {name}")
        failed += 1

try:
    mod_path = REPO + '/addons/features/auto_survey/' + 'product_availability' + '.py'
    spec = importlib.util.spec_from_file_location('product_availability', mod_path)
    pa = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pa)
except Exception as e:
    print(f"FAIL: load module: {e}")
    failed += 1
    print(f"RESULT: {passed} passed, {failed} failed")
    sys.exit(failed)

def names(year, doy, *kinds):
    d = pa.product_names(year, doy)
    s = set()
    for k in kinds:
        s.update(d[k])
    return s

try:
    result = pa.utc_days(datetime(2026, 10, 23, 21, 6), datetime(2026, 10, 23, 22, 6))
    check("A: utc_days single day", result == [(2026, 296)])
except Exception as e:
    print(f"FAIL: A: {e}")
    failed += 1

try:
    result = pa.utc_days(datetime(2026, 10, 23, 22, 0), datetime(2026, 10, 24, 3, 0))
    check("B: utc_days across midnight", result == [(2026, 296), (2026, 297)])
except Exception as e:
    print(f"FAIL: B: {e}")
    failed += 1

try:
    result = pa.utc_days(datetime(2026, 10, 23, 0, 0), datetime(2026, 10, 24, 0, 0))
    check("C: utc_days ending at midnight", result == [(2026, 296)])
except Exception as e:
    print(f"FAIL: C: {e}")
    failed += 1

try:
    result = pa.utc_days(datetime(2026, 12, 31, 12, 0), datetime(2027, 1, 1, 12, 0))
    check("D: utc_days across new year", result == [(2026, 365), (2027, 1)])
except Exception as e:
    print(f"FAIL: D: {e}")
    failed += 1

try:
    d = pa.product_names(2026, 5)
    has_rap_erp = 'WUM0MGXRAP_20260050000_01D_01D_ERP.ERP.gz' in d['erp']
    has_fin_erp = 'WUM0MGXFIN_20260050000_01D_01D_ERP.ERP.gz' in d['erp']
    has_rap_orb = 'WUM0MGXRAP_20260050000_01D_05M_ORB.SP3.gz' in d['orbit']
    check("E: product_names", has_rap_erp and has_fin_erp and has_rap_orb)
except Exception as e:
    print(f"FAIL: E: {e}")
    failed += 1

try:
    day296 = names(2026, 296, 'erp', 'orbit')
    def lister_f(year):
        return day296
    result = pa.check_products_available(datetime(2026, 10, 23, 21, 6), datetime(2026, 10, 23, 22, 6), lister_f)
    check("F: all available", result['available'] == True and result['missing'] == [])
except Exception as e:
    print(f"FAIL: F: {e}")
    failed += 1

try:
    erp_only = names(2026, 296, 'erp')
    def lister_g(year):
        return erp_only
    result = pa.check_products_available(datetime(2026, 10, 23, 21, 6), datetime(2026, 10, 23, 22, 6), lister_g)
    check("G: orbit missing", result['available'] == False and result['missing'] == ['2026 DOY 296: orbit'])
except Exception as e:
    print(f"FAIL: G: {e}")
    failed += 1

try:
    day296 = names(2026, 296, 'erp', 'orbit')
    def lister_h(year):
        return day296
    result = pa.check_products_available(datetime(2026, 10, 23, 22, 0), datetime(2026, 10, 24, 3, 0), lister_h)
    has_erp_297 = '2026 DOY 297: ERP' in result['missing']
    has_orb_297 = '2026 DOY 297: orbit' in result['missing']
    check("H: day 297 missing", result['available'] == False and has_erp_297 and has_orb_297)
except Exception as e:
    print(f"FAIL: H: {e}")
    failed += 1

try:
    fin_names = set()
    d = pa.product_names(2026, 296)
    for kind in ('erp', 'orbit'):
        for n in d[kind]:
            if 'FIN' in n:
                fin_names.add(n)
    def lister_i(year):
        return fin_names
    result = pa.check_products_available(datetime(2026, 10, 23, 21, 6), datetime(2026, 10, 23, 22, 6), lister_i)
    check("I: FIN names accepted", result['available'] == True)
except Exception as e:
    print(f"FAIL: I: {e}")
    failed += 1

try:
    def lister_j(year):
        raise OSError('no route')
    result = pa.check_products_available(datetime(2026, 10, 23, 21, 6), datetime(2026, 10, 23, 22, 6), lister_j)
    check("J: error handling", result['available'] is None and result['missing'] == [] and 'OSError' in result['error'] and 'no route' in result['error'])
except Exception as e:
    print(f"FAIL: J: {e}")
    failed += 1

try:
    calls = []
    def lister_k(year):
        calls.append(year)
        days = (365,) if year == 2026 else (1,)
        s = set()
        for d in days:
            s.update(names(year, d, 'erp', 'orbit'))
        return s
    result = pa.check_products_available(datetime(2026, 12, 31, 12, 0), datetime(2027, 1, 1, 12, 0), lister_k)
    check("K: one call per year", calls == [2026, 2027] and result['available'] == True)
except Exception as e:
    print(f"FAIL: K: {e}")
    failed += 1

try:
    class FakeFTP:
        instances = []
        def __init__(self, host, timeout=None):
            self.host = host
            self.timeout = timeout
            self.closed = False
            self.cwd_path = None
            FakeFTP.instances.append(self)
        def login(self):
            pass
        def cwd(self, path):
            self.cwd_path = path
        def nlst(self):
            return ['/pub/x/a.gz', 'b.gz']
        def close(self):
            self.closed = True

    FakeFTP.instances = []
    result = pa.list_remote_files(2026, timeout=5, ftp_factory=FakeFTP)
    inst = FakeFTP.instances[0]
    check("L1: list_remote_files basic", result == {'a.gz', 'b.gz'} and inst.cwd_path == '/pub/whu/phasebias/2026/orbit' and inst.closed)

    class FakeFTPErr:
        instances = []
        def __init__(self, host, timeout=None):
            self.host = host
            self.timeout = timeout
            self.closed = False
            FakeFTPErr.instances.append(self)
        def login(self):
            pass
        def cwd(self, path):
            pass
        def nlst(self):
            raise RuntimeError('boom')
        def close(self):
            self.closed = True

    FakeFTPErr.instances = []
    try:
        pa.list_remote_files(2026, timeout=5, ftp_factory=FakeFTPErr)
        check("L2: list_remote_files error", False)
    except RuntimeError:
        check("L2: list_remote_files error", FakeFTPErr.instances[0].closed)
except Exception as e:
    print(f"FAIL: L: {e}")
    failed += 1

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(failed)
PYEOF
