#!/usr/bin/env bash
# Integration test for the OTA updater (addons/tools/perform_update.sh) and
# tools/repo_update.sh, against a local git "origin" - no network, no root.
#
# Confirmed live (test station, OTA delivering 2b01198): a root-owned
# tests/ directory made the updater's `git reset --hard origin/main` (run
# as the repo owner) fail half-way - most new files written, HEAD/index on
# the old commit - and the updater reported success.
#
# Scenarios:
#   S1 new updater, a root-owned directory in the working tree
#      -> ownership normalized, reset succeeds, clean, reported success,
#         no duplicated log lines, quotes in status messages survive
#   S2 a reset failure normalization can't fix
#      -> stops, reported FAILED with git's error text, later steps not run
#   S3 new updater starting from the half-updated state -> ends clean
#   S4 THE REAL NEXT OTA: the OLD updater from 2b01198 (what is on the
#      station's disk now) against the new commit -> its reset fails
#      half-way again, and the new tools/repo_update.sh hook (reached via
#      tools/wireguard_setup.sh) finishes it -> ends clean at origin/main
#   S5 the hook outside an OTA (install.sh context) never resets a checkout
#
# No second real UID exists here (no root), so "root-owned" paths are
# simulated: made unwritable (chmod) and listed in GM_TEST_FOREIGN_LIST,
# the test seam of tools/repo_update.sh; the stubbed chown makes them
# writable again and removes them from the list. Real find/chown ownership
# semantics are therefore not exercised here.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d /tmp/gm_ota_test.XXXXXX)"
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
chk() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }
cleanup() { chmod -R u+rwX "$W" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT

# --- stubs ------------------------------------------------------------------
mkdir -p "$W/bin"
cat > "$W/bin/sudo" <<'EOF'
#!/usr/bin/env bash
# run as the caller: drop -u <user> and flags, keep the environment
while (( $# )); do case "$1" in -u) shift 2 ;; -n|-E|-H) shift ;; --) shift; break ;; *) break ;; esac; done
exec "$@"
EOF
cat > "$W/bin/chown" <<'EOF'
#!/usr/bin/env bash
# "give back to the owner": make writable, drop from the simulated root-owned list
echo "chown $*" >> "$GM_SIM_CALLS"
args=(); for a in "$@"; do [[ "$a" == -* || "$a" == *: || "$a" == *:* ]] && continue; args+=("$a"); done
for p in "${args[@]}"; do
    chmod u+rwX "$p" 2>/dev/null
    [[ -n "${GM_TEST_FOREIGN_LIST:-}" && -f "$GM_TEST_FOREIGN_LIST" ]] && { grep -vxF -- "$p" "$GM_TEST_FOREIGN_LIST" > "$GM_TEST_FOREIGN_LIST.tmp"; mv "$GM_TEST_FOREIGN_LIST.tmp" "$GM_TEST_FOREIGN_LIST"; }
done
exit 0
EOF
for c in raspi-config apt-get systemctl; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$GM_SIM_CALLS"\nexit 0\n' "$c" > "$W/bin/$c"
done
printf '#!/usr/bin/env bash\nexit 22\n' > "$W/bin/curl"     # ANTEX download "fails"
printf '#!/usr/bin/env bash\nexit 1\n'  > "$W/bin/ip"       # no kernel WireGuard
printf '#!/usr/bin/env bash\n:\n'      > "$W/bin/sleep"     # no waiting
chmod +x "$W"/bin/*
export PATH="$W/bin:$PATH" GM_SIM_CALLS="$W/calls" GM_ALLOW_NONROOT=1
export GM_ETC="$W/etc" GM_RUN="$W/run" GM_STATE_DIR="$W/state" GM_DNS_SETTLE_SECONDS=0 GM_DNS_BEFORE_SECONDS=0
mkdir -p "$GM_ETC" "$GM_RUN"
git config --global --get user.email >/dev/null || export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# --- repos ------------------------------------------------------------------
# new_tree <dir>: the files the updater path needs, at this checkout's versions
new_tree() {
    mkdir -p "$1/addons/tools" "$1/tools" "$1/tests"
    cp "$REPO/addons/tools/perform_update.sh" "$1/addons/tools/"
    cp "$REPO/tools/repo_update.sh" "$REPO/tools/dns_setup.sh" "$REPO/tools/wireguard_setup.sh" "$1/tools/"
    cp "$REPO/.gitignore" "$1/"
    chmod +x "$1/addons/tools/perform_update.sh"
}
# old_tree <dir>: the same files at 2b01198 - the updater now on the station
old_tree() {
    mkdir -p "$1/addons/tools" "$1/tools" "$1/tests"
    local f; for f in addons/tools/perform_update.sh tools/dns_setup.sh tools/wireguard_setup.sh .gitignore; do
        git -C "$REPO" show "2b01198:$f" > "$1/$f"
    done
    chmod +x "$1/addons/tools/perform_update.sh"
}
# make_origin <name> <tree-fn-for-first-commit>: commit A (given tree,
# tests/fixture v1) then commit B (new tree, fixture v2, a new tests file)
make_origin() {
    local src="$W/$1-src"
    rm -rf "$src"; mkdir -p "$src"; git -C "$src" init -q -b main
    "$2" "$src"; echo v1 > "$src/tests/fixture.txt"; echo readme-a > "$src/README.md"
    git -C "$src" add -A; git -C "$src" commit -qm A
    new_tree "$src"; echo v2 > "$src/tests/fixture.txt"; echo new > "$src/tests/new.txt"; echo readme-b > "$src/README.md"
    git -C "$src" add -A; git -C "$src" commit -qm B
    git clone -q --bare "$src" "$W/$1.git"
}
# make_station <name>: clone of origin, reset to commit A (origin/main = B)
make_station() {
    rm -rf "$W/$1"; git clone -q "$W/$2.git" "$W/$1"
    git -C "$W/$1" reset -q --hard HEAD~1
}
run_updater() {   # <station> [updater path]; status -> $W/status.json, log -> $W/log
    rm -f "$W/status.json"; : > /tmp/ota_update.log; : > "$GM_SIM_CALLS"
    bash "${2:-$1/addons/tools/perform_update.sh}" "$1" "$W/status.json" > "$W/log" 2>&1; echo $? > "$W/rc"
    sleep 0; cp /tmp/ota_update.log "$W/otalog" 2>/dev/null
}
json() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2]))" "$W/status.json" "$1" 2>/dev/null; }
head_is_origin() { [[ "$(git -C "$1" rev-parse HEAD)" == "$(git -C "$1" rev-parse origin/main)" ]]; }
clean() { [[ -z "$(git -C "$1" status --porcelain)" ]]; }

make_origin new new_tree

echo "== S1: new updater, root-owned tests/ directory =="
S="$W/s1"; make_station s1 new
chmod 555 "$S/tests"; printf '%s\n' "$S/tests" "$S/tests/fixture.txt" > "$W/foreign"
export GM_TEST_FOREIGN_LIST="$W/foreign"
run_updater "$S"
chk '[[ $(cat "$W/rc") == 0 ]]' "updater exits 0"
chk 'grep -q "chown -h" "$GM_SIM_CALLS" && [[ ! -s "$W/foreign" ]]' "root-owned paths handed back to the owner"
chk 'head_is_origin "$S"' "HEAD == origin/main"
chk 'clean "$S"' "git status clean (no M/??, runtime dirs ignored)"
chk '[[ "$(cat "$S/tests/fixture.txt")" == v2 && -f "$S/tests/new.txt" ]]' "files in the formerly root-owned directory updated"
chk '[[ "$(json success)" == True && "$(json completed)" == True ]]' "status: success"
chk 'python3 -c "import json,sys; sys.exit(0 if \"never the \x27wireguard\x27 metapackage\" in json.load(open(sys.argv[1]))[\"log\"] else 1)" "$W/status.json"' "status line with quotes kept (no Python SyntaxError)"
chk '! grep -q SyntaxError "$W/otalog"' "no SyntaxError in the OTA log"
chk '[[ $(grep -c "handing 2 path(s)" "$W/otalog") -eq 1 ]]' "log lines written once, not twice"

echo "== S2: reset failure normalization can't fix -> FAILED, stops =="
S="$W/s2"; make_station s2 new
chmod 555 "$S/tests"; : > "$W/foreign"          # unwritable but not "root-owned": nothing to hand back
run_updater "$S"
chk '[[ $(cat "$W/rc") != 0 ]]' "updater exits non-zero"
chk '[[ "$(json success)" == False && "$(json completed)" == True ]]' "status: completed, not success"
chk 'json error | grep -q "Git reset to origin/main FAILED" && json error | grep -qi "unable to unlink\|Permission denied\|error"' "error carries git's own error text"
chk '! grep -q "Ensuring SPI" "$W/otalog" && ! grep -q "raspi-config" "$GM_SIM_CALLS"' "later steps not run"
chk '! head_is_origin "$S"' "HEAD left on the old commit (nothing claimed)"
chmod 755 "$S/tests"

echo "== S3: new updater from the half-updated state =="
S="$W/s3"; make_station s3 new
chmod 555 "$S/tests"; printf '%s\n' "$S/tests" > "$W/foreign"
git -C "$S" reset -q --hard origin/main 2>/dev/null   # fails half-way, like on the station
chk '! head_is_origin "$S" && ! clean "$S"' "precondition: half-updated (HEAD old, tracked changes)"
run_updater "$S"
chk '[[ $(cat "$W/rc") == 0 ]] && head_is_origin "$S" && clean "$S"' "ends clean at origin/main"

echo "== S4: the OLD (2b01198) updater now on the station, against the new commit =="
make_origin old old_tree
S="$W/s4"; make_station s4 old
chk 'grep -q "tee -a /tmp/ota_update.log; then" "$S/addons/tools/perform_update.sh"' "precondition: station runs the 2b01198 updater (reset piped through tee)"
chmod 555 "$S/tests"; printf '%s\n' "$S/tests" "$S/tests/fixture.txt" > "$W/foreign"
run_updater "$S"
chk 'grep -q "unable to unlink\|Permission denied" "$W/otalog"' "the old updater's own reset fails half-way again"
chk 'grep -q "\[repo\] interrupted update detected" "$W/otalog"' "the new hook detected it"
chk 'grep -q "\[repo\] update finished: checkout is clean" "$W/otalog"' "the new hook finished the update"
chk 'head_is_origin "$S" && clean "$S"' "ends clean at origin/main"
chk '[[ -f "$S/tools/repo_update.sh" && "$(cat "$S/tests/fixture.txt")" == v2 ]]' "new files in place"

echo "== S5: the hook outside an OTA never resets a checkout =="
S="$W/s5"; make_station s5 new
echo "local work" >> "$S/README.md"
( cd "$S" && GM_OTA_RUNNING=0 bash -c 'source tools/repo_update.sh; geomaxima_finish_interrupted_update' ) > "$W/log" 2>&1
chk 'grep -q "local work" "$S/README.md" && ! head_is_origin "$S"' "local change and HEAD untouched"
( cd "$S" && GM_OTA_RUNNING=1 bash -c 'source tools/repo_update.sh; geomaxima_finish_interrupted_update' ) > "$W/log" 2>&1
chk 'head_is_origin "$S" && clean "$S"' "…and with an OTA running it does finish (control)"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
