#!/usr/bin/env bash
# Propose mode of the survey: the final PPP-AR result is stored as a proposal and
# the broadcast position (settings.conf) is never changed by the survey itself.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -n "${GM_REPO_ROOT:-}" ] && REPO="$GM_REPO_ROOT"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available"
    exit 0
fi

python3 - "$REPO" <<'PYEOF'
import sys, os, json, tempfile, importlib, importlib.abc, importlib.machinery
import unittest.mock
from pathlib import Path
from types import SimpleNamespace

REPO = sys.argv[1]
sys.path.insert(0, REPO)


import types
try:
    import numpy  # noqa: F401
except ImportError:
    numpy = types.ModuleType('numpy')
    numpy.bool_ = type('bool_', (), {})
    numpy.integer = type('integer', (), {})
    numpy.floating = type('floating', (), {})
    numpy.ndarray = type('ndarray', (), {})
    sys.modules['numpy'] = numpy


class Stub(importlib.abc.MetaPathFinder, importlib.abc.Loader):
    def find_spec(self, name, path=None, target=None):
        if name.split('.')[0] in ('scipy', 'pyproj'):
            return importlib.machinery.ModuleSpec(name, self, is_package=True)
        return None
    def create_module(self, spec):
        m = unittest.mock.MagicMock()
        m.__path__ = []
        m.__name__ = spec.name
        m.__spec__ = spec
        return m
    def exec_module(self, module):
        pass


sys.meta_path.append(Stub())

ctrl_mod = importlib.import_module('addons.features.auto_survey.survey_controller')
sm_mod = importlib.import_module('addons.features.auto_survey.state_manager')
SC = ctrl_mod.SurveyController

passed = 0
failed = 0


def test(name, fn):
    global passed, failed
    try:
        fn()
        print(f"PASS: {name}")
        passed += 1
    except Exception as e:
        import traceback
        print(f"FAIL: {name} - {e!r}")
        traceback.print_exc()
        failed += 1


def new_state(tmp):
    return sm_mod.StateManager(state_file=os.path.join(tmp, 'state.json'))


class FakeRtkbase:
    def __init__(self):
        self.updates = []
        self.position = (42.65236966, 26.43258495, 208.145)

    def update_position(self, lat, lon, h):
        self.updates.append((lat, lon, h))
        return True

    def get_position(self):
        return self.position

    def get_antenna_arp_offset(self):
        return {'height_m': 0.0, 'east_m': 0.0, 'north_m': 0.0}


def make_controller(tmp, apply_mode):
    c = SC.__new__(SC)
    c.is_runner = True
    c.state = new_state(tmp)
    c.state.start_survey(24, apply_mode=apply_mode)
    c.rtkbase = FakeRtkbase()
    c.geoid = SimpleNamespace(ellipsoidal_to_orthometric=lambda lat, lon, h: None)
    c._running = False
    c.restarts = 0

    def restart():
        c.restarts += 1
        return {'success': True}
    c.restart_rtkbase_services = restart
    c._protect_slot_dir = lambda p: None
    c._resolve_antenna_calibration = lambda: {'antenna_type': 'X', 'antenna_calibrated': False}
    return c


# The real transform needs pyproj; replace only the geodesy helpers, keep the controller code real.
BGS = {
    'lat_dd': 42.65236, 'lon_dd': 26.43245, 'height_m': 208.150,
    'regulation_reference': 'test',
    'epoch_reduction': {'velocity_source': 't', 'velocity_neu_mm_per_yr': {}, 'from_epoch': 2026.8,
                        'to_epoch': 2005.0, 'dt_years': -21.8, 'velocity_is_station_specific': False},
    'etrf2000_t_obs': {'lat_dd': 42.0, 'lon_dd': 26.0, 'height_m': 200.0, 'epoch': 2026.8},
    'coordinate_provisional': True, 'coordinate_provisional_reason': 'proxy',
}


def patched():
    return unittest.mock.patch.multiple(
        ctrl_mod,
        extract_observation_epoch=lambda f: 2026.8,
        itrf2020_to_bgs2005=lambda point, t: dict(BGS),
        verify_rtcm_broadcast_ecef=lambda *a, **k: {'ok': True, 'distance_m': 0.0, 'detail': ''},
        arp_to_marker=lambda lat, lon, h, off: {'lat': lat, 'lon': lon, 'height': h},
        verify_arp_to_marker_offset=lambda *a, **k: {'ok': True, 'distance_m': 0.0, 'detail': ''},
        _announce_planned_disconnect=lambda *a, **k: None,
    )


def apply_final(c):
    with patched():
        return c._apply_geodetic_position(
            lat=42.0, lon=26.0, height=200.0, obs_file=Path('/nonexistent/x.obs'), is_final=True,
            ppp_backend='pride-pppar', position_std={'std_h_meters': 0.0}, num_epochs=1,
            quality_metrics={})


# ---- state manager -------------------------------------------------------------------------
def t_state_defaults():
    with tempfile.TemporaryDirectory() as tmp:
        sm = new_state(tmp)
        st = sm.get_status()
        assert st['apply_mode'] == 'apply' and st['proposal'] is None
        assert sm.get_apply_mode() == 'apply'


def t_state_start_modes():
    with tempfile.TemporaryDirectory() as tmp:
        sm = new_state(tmp)
        assert sm.start_survey(24, apply_mode='propose')
        assert sm.get_apply_mode() == 'propose'
        sm2 = new_state(tmp)  # persisted
        assert sm2.get_apply_mode() == 'propose'
        sm2.reset_survey()
        assert sm2.start_survey(24, apply_mode='bogus')
        assert sm2.get_apply_mode() == 'apply'


def t_state_proposal_roundtrip():
    with tempfile.TemporaryDirectory() as tmp:
        sm = new_state(tmp)
        sm.start_survey(24, apply_mode='propose')
        assert sm.record_proposal({'lat': 1.0, 'lon': 2.0, 'height': 3.0}, {'horizontal_m': 0.1})
        pr = new_state(tmp).get_status()['proposal']
        assert pr['position']['lat'] == 1.0 and pr['applied'] is False and pr['reference']['horizontal_m'] == 0.1
        assert sm.mark_proposal_applied()
        assert new_state(tmp).get_status()['proposal']['applied'] is True
        sm.reset_survey()
        st = sm.get_status()
        assert st['proposal'] is None and st['apply_mode'] == 'apply'


def t_state_legacy_file_backfilled():
    with tempfile.TemporaryDirectory() as tmp:
        sm = new_state(tmp)
        sm.start_survey(24)
        path = os.path.join(tmp, 'state.json')
        data = json.load(open(path))
        data.pop('apply_mode', None)
        data.pop('proposal', None)
        json.dump(data, open(path, 'w'))
        sm2 = new_state(tmp)
        assert sm2.get_apply_mode() == 'apply' and sm2.get_status()['proposal'] is None


# ---- controller ----------------------------------------------------------------------------
def t_propose_does_not_touch_settings():
    with tempfile.TemporaryDirectory() as tmp:
        c = make_controller(tmp, 'propose')
        assert apply_final(c) is True
        assert c.rtkbase.updates == [], f"settings.conf was written: {c.rtkbase.updates}"
        assert c.restarts == 0, "services were restarted in propose mode"
        pr = c.state.get_status()['proposal']
        assert pr and pr['applied'] is False
        assert abs(pr['position']['lat'] - 42.65236) < 1e-9
        ref = pr['reference']
        assert ref['lat'] == 42.65236966
        # 42.65236 - 42.65236966 deg = -9.66e-6 deg = about -1.07 m north
        assert abs(ref['north_m'] - (-9.66e-6 * 111132.92)) < 1e-3, ref
        assert abs(ref['up_m'] - (208.150 - 208.145)) < 1e-9
        assert ref['horizontal_m'] > 1.0


def t_apply_mode_still_applies():
    with tempfile.TemporaryDirectory() as tmp:
        c = make_controller(tmp, 'apply')
        assert apply_final(c) is True
        assert c.rtkbase.updates == [(BGS['lat_dd'], BGS['lon_dd'], BGS['height_m'])]
        assert c.restarts == 1
        assert c.state.get_status()['proposal'] is None


def t_completed_propose_not_auto_applied():
    with tempfile.TemporaryDirectory() as tmp:
        c = make_controller(tmp, 'propose')
        apply_final(c)
        c.state.complete_survey(c.state.get_status()['current_position'])
        assert c.state.get_status()['survey_state'] == 'completed'
        assert c.state.get_status()['applied'] is False
        c.get_status()
        c.get_status()
        assert c.rtkbase.updates == [], "get_status auto-applied a propose-mode result"


def t_completed_apply_mode_still_auto_applies():
    with tempfile.TemporaryDirectory() as tmp:
        c = make_controller(tmp, 'apply')
        c.state._state['survey_state'] = 'completed'
        c.state._state['current_position'] = {'lat': 42.0, 'lon': 24.0, 'height': 500.0}
        c.get_status()
        assert c.rtkbase.updates == [(42.0, 24.0, 500.0)]


def t_apply_proposal_guards():
    with tempfile.TemporaryDirectory() as tmp:
        c = make_controller(tmp, 'propose')
        r = c.apply_proposal(False)
        assert not r['ok'] and r['reason'] == 'confirmation required'
        r = c.apply_proposal(True)
        assert not r['ok'] and r['reason'] == 'a survey is in progress'  # state is RUNNING
        c.state._state['survey_state'] = 'completed'
        r = c.apply_proposal(True)
        assert not r['ok'] and r['reason'] == 'no proposal'
        apply_final(c)
        c.state.mark_proposal_applied()
        r = c.apply_proposal(True)
        assert not r['ok'] and r['reason'] == 'proposal already applied'
        assert c.rtkbase.updates == []


def t_apply_proposal_success_uses_guarded_apply():
    with tempfile.TemporaryDirectory() as tmp:
        c = make_controller(tmp, 'propose')
        apply_final(c)
        c.state._state['survey_state'] = 'completed'
        seen = {}

        def fake_apply(rtkbase, lat, lon, h, **kw):
            seen.update(lat=lat, lon=lon, h=h, source=kw.get('source'), force=kw.get('force'))
            return {'ok': True, 'reason': None}

        with unittest.mock.patch('addons.features.cors_position.cors_apply.apply_position', fake_apply):
            r = c.apply_proposal(True, force=True)
        assert r['ok'], r
        assert seen['source'] == 'survey_proposal' and seen['force'] is True
        assert abs(seen['lat'] - 42.65236) < 1e-9
        st = c.state.get_status()
        assert st['proposal']['applied'] is True and st['applied'] is True


def t_apply_proposal_failure_keeps_proposal():
    with tempfile.TemporaryDirectory() as tmp:
        c = make_controller(tmp, 'propose')
        apply_final(c)
        c.state._state['survey_state'] = 'completed'
        with unittest.mock.patch('addons.features.cors_position.cors_apply.apply_position',
                                 lambda *a, **k: {'ok': False, 'reason': 'jump too large'}):
            r = c.apply_proposal(True)
        assert not r['ok'] and r['reason'] == 'jump too large'
        assert c.state.get_status()['proposal']['applied'] is False


def t_final_result_reaches_state_while_finalizing():
    # The final result is computed in the FINALIZING state; it must still be recorded
    # (otherwise the survey ends as failed with "No final position computed").
    for mode in ('propose', 'apply'):
        with tempfile.TemporaryDirectory() as tmp:
            c = make_controller(tmp, mode)
            assert c.state.begin_finalizing()
            assert c.state.get_status()['survey_state'] == 'finalizing'
            assert apply_final(c) is True
            pos = c.state.get_status()['current_position']
            assert pos and abs(pos['lat'] - 42.65236) < 1e-9, f"{mode}: result not recorded in finalizing state"
            assert (len(c.rtkbase.updates) == 0) == (mode == 'propose')


# ---- runner / requests ---------------------------------------------------------------------
def t_runner_passes_apply_mode():
    from addons.features.auto_survey import survey_runner
    got = {}

    class Ctl:
        def start_survey(self, target_hours, apply_mode='apply'):
            got.update(hours=target_hours, mode=apply_mode)
            return True

        def apply_proposal(self, confirmed, force=False):
            got['apply'] = (confirmed, force)
            return {'ok': True, 'reason': None, 'apply_result': {'ok': True}}

    r = survey_runner.SurveyRunner.__new__(survey_runner.SurveyRunner)
    r.controller = Ctl()
    r.cors = None
    res = r.handle_request({'action': 'start', 'params': {'target_hours': 24, 'apply_mode': 'propose'}})
    assert res['ok'] and got == {'hours': 24, 'mode': 'propose'}, (res, got)
    res = r.handle_request({'action': 'start', 'params': {'target_hours': 24, 'apply_mode': 'x'}})
    assert not res['ok']
    res = r.handle_request({'action': 'start', 'params': {'target_hours': 24}})
    assert got['mode'] == 'apply'
    res = r.handle_request({'action': 'apply_proposal', 'params': {'confirmed': True}})
    assert res['ok'] and got['apply'] == (True, False)
    res = r.handle_request({'action': 'apply_proposal', 'params': {'confirmed': 'yes'}})
    assert got['apply'] == (False, False)
    assert 'apply_proposal' in importlib.import_module(
        'addons.features.auto_survey.survey_requests').ALLOWED_ACTIONS


for name, fn in [
    ("state: defaults", t_state_defaults),
    ("state: start modes persisted, invalid mode -> apply", t_state_start_modes),
    ("state: proposal round trip and reset", t_state_proposal_roundtrip),
    ("state: legacy file without the keys is backfilled", t_state_legacy_file_backfilled),
    ("propose mode never writes settings.conf nor restarts; reference diff is stored", t_propose_does_not_touch_settings),
    ("apply mode still applies as before", t_apply_mode_still_applies),
    ("completed propose survey is not auto-applied by get_status", t_completed_propose_not_auto_applied),
    ("completed apply survey is still auto-applied by get_status", t_completed_apply_mode_still_auto_applies),
    ("apply_proposal guards (confirm, in progress, none, already applied)", t_apply_proposal_guards),
    ("apply_proposal success goes through the guarded apply", t_apply_proposal_success_uses_guarded_apply),
    ("apply_proposal failure keeps the proposal", t_apply_proposal_failure_keeps_proposal),
    ("the final result is recorded while the survey is finalizing", t_final_result_reaches_state_while_finalizing),
    ("runner passes apply_mode and handles apply_proposal", t_runner_passes_apply_mode),
]:
    test(name, fn)

print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PYEOF
exit $?
