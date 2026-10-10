#!/usr/bin/env bash
# Unit-style test for web_app/RTKBaseConfigManager.py's
# _backup_before_write() - 2026-10-05 archive incident fix: settings.conf
# was rewritten twice around the incident with no prior copy kept,
# making it impossible to confirm what archive_rotate/datadir/
# min_free_space actually were beforehand. This verifies every backup
# lands OUTSIDE datadir, is never named exactly "settings.conf" (so no
# script that reads settings.conf by exact filename can ever pick one
# up), is 0600/dir 0700, and that SETTINGS_BACKUP_COUNT rotation keeps
# exactly that many distinct backups even across rapid same-second
# writes.
#
# LINUX-ONLY for the permission assertions specifically: os.chmod's
# 0700/0600 POSIX bits are meaningless on a Windows filesystem (NTFS has
# no matching concept) even when Python itself runs under Windows - the
# DIR_MODE/ALL_FILES_0600 checks only mean something run on Linux.
# Confirmed passing 6/6 on WSL Ubuntu 24.04 this session.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

PYTHON=python3
command -v python3 >/dev/null 2>&1 || PYTHON=python
if ! "$PYTHON" -c "import configparser" >/dev/null 2>&1; then
  echo "SKIP: no usable python3 interpreter in this environment"
  exit 0
fi

W="$(mktemp -d /tmp/gm_settings_backup_test.XXXXXX)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

OUT=$("$PYTHON" - "$REPO" "$W" << 'PYEOF'
import sys, os, stat

repo, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(repo, "web_app"))
from RTKBaseConfigManager import RTKBaseConfigManager

default_path = os.path.join(tmp, "settings.conf.default")
user_path = os.path.join(tmp, "settings.conf")
with open(default_path, "w") as f:
    f.write(
        "[general]\nversion=2.7.0\n"
        "[local_storage]\ndatadir=$BASEDIR/data\narchive_rotate='60'\nmin_free_space='500'\n"
        "[main]\nposition='0 0 0'\ncom_port=''\ncom_port_settings=''\nreceiver=''\n"
        "receiver_firmware=''\nreceiver_format=''\nantenna_info=''\ntcp_host_addr=''\n"
        "tcp_port=''\ngnss_rcv_web_ip=''\ngnss_rcv_web_proxy_port=''\n"
        "[log]\nlogdir=$BASEDIR/logs\nlevel=0\n"
    )

mgr = RTKBaseConfigManager(default_path, user_path)
data_dir = os.path.join(tmp, "data")

for i in range(25):
    mgr.update_setting("local_storage", "min_free_space", str(500 + i), write_file=True)

backup_dir = os.path.join(tmp, "settings_conf_backups")
print("BACKUP_DIR_EXISTS", os.path.isdir(backup_dir))
print("BACKUP_DIR_NOT_IN_DATADIR", not backup_dir.startswith(data_dir))

backups = sorted(os.listdir(backup_dir)) if os.path.isdir(backup_dir) else []
print("NUM_BACKUPS", len(backups))
print("COLLIDES_WITH_LIVE_FILE", "settings.conf" in backups)

if os.path.isdir(backup_dir):
    dir_mode = stat.S_IMODE(os.stat(backup_dir).st_mode)
    print("DIR_MODE", oct(dir_mode))
    all_0600 = all(stat.S_IMODE(os.stat(os.path.join(backup_dir, b)).st_mode) == 0o600 for b in backups)
    print("ALL_FILES_0600", all_0600)
PYEOF
)

echo "$OUT"

echo "$OUT" | grep -q "^BACKUP_DIR_EXISTS True" && ok "backup directory created" || bad "backup directory not created"
echo "$OUT" | grep -q "^BACKUP_DIR_NOT_IN_DATADIR True" && ok "backup directory is NOT inside datadir" || bad "backup directory is inside datadir"
echo "$OUT" | grep -q "^NUM_BACKUPS 20" && ok "exactly 20 backups kept (SETTINGS_BACKUP_COUNT) despite 25 rapid writes" || bad "backup rotation count is wrong"
echo "$OUT" | grep -q "^COLLIDES_WITH_LIVE_FILE False" && ok "no backup file is named exactly settings.conf" || bad "a backup collided with the live settings.conf filename"
echo "$OUT" | grep -q "^DIR_MODE 0o700" && ok "backup directory is 0700" || bad "backup directory has the wrong permissions"
echo "$OUT" | grep -q "^ALL_FILES_0600 True" && ok "every backup file is 0600" || bad "a backup file has the wrong permissions"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
