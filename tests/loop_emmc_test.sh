#!/usr/bin/env bash
# Loop-device integration test for tools/emmc-install-opi4pro.sh
# Fakes an A733 board: SD (loop, sysfs type=SD) + eMMC (loop, exposed as /dev/mmcblk90, type=MMC).
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W=/tmp/gmtest; rm -rf "$W"; mkdir -p "$W"
PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
chk()  { if eval "$1"; then ok "$2"; else bad "$2"; fi; }

cleanup_all() {
  umount /mnt/emmc-target 2>/dev/null; umount "$W/sdroot" 2>/dev/null; umount "$W/sdroot2" 2>/dev/null
  umount "$W/chk" 2>/dev/null; umount "$W/chk2" 2>/dev/null
  [[ -n "${WATCH_PID:-}" ]] && kill "$WATCH_PID" 2>/dev/null
  [[ -n "${WATCH2_PID:-}" ]] && kill "$WATCH2_PID" 2>/dev/null
  rm -f /dev/mmcblk90 /dev/mmcblk90p1 /dev/mmcblk91p1 /dev/mmcblk92 /dev/mmcblk92p1 /dev/mmcblk93p1 /dev/loop[0-9]p1
  losetup -D 2>/dev/null
}
trap cleanup_all EXIT
cleanup_all

# attach an image with partition scan; this sandbox has no udev, so force the
# rescan and create the /dev/loopNp1 node by hand when needed
attach() {
  local img="$1" dev n i
  dev=$(losetup -P -f --show "$img"); n=$(basename "$dev")
  for i in $(seq 1 50); do
    [[ -e /sys/class/block/${n}p1/dev ]] && break
    partx -a "$dev" 2>/dev/null || partx -u "$dev" 2>/dev/null || true; sleep 0.1
  done
  if [[ -e /sys/class/block/${n}p1/dev && ! -b ${dev}p1 ]]; then
    local mm; mm=$(cat /sys/class/block/${n}p1/dev); mknod "${dev}p1" b ${mm%:*} ${mm#*:}
  fi
  echo "$dev"
}

# ---------- SD card: 600M, msdos, p1 @ 65536, ext4 with fake Armbian root ----------
truncate -s 600M "$W/sd.img"
parted -s "$W/sd.img" mklabel msdos mkpart primary ext4 65536s 100%
SD=$(attach "$W/sd.img"); SDN=$(basename "$SD")
mkfs.ext4 -q -L armbi_root "${SD}p1"
# pretend an old SD bootloader exists at 8K so we can see the wipe
printf 'eGON.BT0-FAKE' | dd of="$SD" bs=1024 seek=8 conv=notrunc status=none
mkdir -p "$W/sdroot"; mount "${SD}p1" "$W/sdroot"
SD_UUID=$(blkid -s UUID -o value "${SD}p1")
mkdir -p "$W/sdroot"/{boot,etc,home/peshovp/RPI-BS/tools,usr/bin,var/log}
echo "rootdev=UUID=$SD_UUID" > "$W/sdroot/boot/armbianEnv.txt"
echo "UUID=$SD_UUID / ext4 defaults,commit=120,errors=remount-ro 0 1" > "$W/sdroot/etc/fstab"
for i in $(seq 1 300); do head -c 2048 /dev/urandom > "$W/sdroot/usr/bin/f$i"; done
ln -s f1 "$W/sdroot/usr/bin/link1"; ln "$W/sdroot/usr/bin/f2" "$W/sdroot/usr/bin/hard2"
cp -r "$REPO/tools/." "$W/sdroot/home/peshovp/RPI-BS/tools/" 2>/dev/null
mknod /dev/mmcblk91p1 b $(tr ':' ' ' < /sys/class/block/${SDN}p1/dev)
SD_SRC_LIST_BEFORE=$(cd "$W/sdroot" && find . | sort | sha256sum)

# ---------- eMMC: 1.6G, exposed as /dev/mmcblk90 ----------
truncate -s 1600M "$W/emmc.img"
# stale content, like a previous bad armbian-install (partition at 16 MiB)
parted -s "$W/emmc.img" mklabel msdos mkpart primary ext4 32768s 100%
EM=$(attach "$W/emmc.img"); EMN=$(basename "$EM")
mkfs.ext4 -q "${EM}p1"
mknod /dev/mmcblk90 b $(tr ':' ' ' < /sys/class/block/$EMN/dev)
# keep /dev/mmcblk90p1 pointing at the CURRENT loop partition (it is re-created by parted)
( while true; do
    if [[ -e /sys/class/block/${EMN}p1/dev ]]; then
      want=$(cat /sys/class/block/${EMN}p1/dev)
      have=$( [[ -b /dev/mmcblk90p1 ]] && stat -c '%Hr:%Lr' /dev/mmcblk90p1)
      [[ "$want" != "$have" ]] && { rm -f /dev/mmcblk90p1; mknod /dev/mmcblk90p1 b ${want%:*} ${want#*:}; }
    else rm -f /dev/mmcblk90p1; fi
    sleep 0.1; done ) & WATCH_PID=$!
sleep 0.5

# ---------- fake sysfs ----------
FS="$W/sys"; mkdir -p "$FS/block/mmcblk90/device" "$FS/block/$SDN/device"
echo MMC > "$FS/block/mmcblk90/device/type"; cat /sys/class/block/$EMN/size > "$FS/block/mmcblk90/size"
ln -s /sys/class/block/${EMN}p1 "$FS/block/mmcblk90/mmcblk90p1"
echo SD > "$FS/block/$SDN/device/type"; ln -s /sys/class/block/${SDN}p1 "$FS/block/$SDN/${SDN}p1"; ln -s /sys/class/block/${SDN}p1 "$FS/block/$SDN/mmcblk91p1"

# ---------- fake u-boot (real A733 offsets and sizes) ----------
UB="$W/uboot"; mkdir -p "$UB"
head -c $((240*1024))  /dev/urandom > "$UB/boot0_sdcard.fex"
head -c $((1360*1024)) /dev/urandom > "$UB/boot_package.fex"
cat > "$W/platform_install.sh" <<'EOF'
write_uboot_platform ()
{
    local SCRIPT_DIR="$1" DEVICE="$2";
    dd conv=notrunc,fsync status=none if="${SCRIPT_DIR}/boot0_sdcard.fex" of="${DEVICE}" bs=1k seek=8 || return 1
    dd conv=notrunc,fsync status=none if="${SCRIPT_DIR}/boot_package.fex" of="${DEVICE}" bs=1k seek=16400 || return 1
    sync "${DEVICE}"
}
EOF

# rsync wrapper: records what is mounted at the target right before the copy
mkdir -p "$W/bin"
cat > "$W/bin/rsync" <<EOF
#!/usr/bin/env bash
echo "\$(findmnt -no SOURCE /mnt/emmc-target 2>/dev/null)" > $W/mounted_at_rsync
[[ -f $W/rsync_fail ]] && { echo "simulated rsync failure" >&2; exit 23; }
exec /usr/bin/rsync "\$@"
EOF
chmod +x "$W/bin/rsync"

# Sandbox shim: this sandbox kernel ignores BLKRRPART on loop devices (only
# BLKPG via partx works), so partprobe cannot create/remove partitions here.
# On a real board udev + partprobe do this. The shim only re-syncs kernel
# partitions with the on-disk table; it does not change the tested logic.
cat > "$W/bin/partprobe" <<'EOS'
#!/usr/bin/env bash
for d in "$@"; do partx -d "$d" 2>/dev/null; partx -a "$d" 2>/dev/null; done; exit 0
EOS
chmod +x "$W/bin/partprobe"

run_migrate() {
  ( export PATH="$W/bin:$PATH" GM_SYSFS="$FS" GM_TEST_ROOT_PART=/dev/mmcblk91p1 GM_ROOT_SRC="$W/sdroot/" \
           GM_UBOOT_DIR="$UB" GM_EMMC_PLATFORM_SCRIPT="$W/platform_install.sh" GM_EMMC_FORCE="${1:-0}"
    source "$REPO/tools/emmc-install-opi4pro.sh"
    [[ -n "${2:-}" ]] && GM_EMMC_PART_START="$2"
    geomaxima_emmc_migrate 1 0 > "$W/out_${3:-x}.log" 2>&1
    echo "rc=$?"
    echo "part=${GM_EMMC_RESULT_PART:-}" )
}

echo "== T1: fresh migration =="
R=$(run_migrate 0 "" t1); echo "$R" | sed 's/^/    /'
chk '[[ "$R" == *rc=0* ]]' "returns 0"
chk '[[ "$R" == *part=/dev/mmcblk90p1* ]]' "GM_EMMC_RESULT_PART exported"
chk '[[ "$(cat $W/mounted_at_rsync)" == "/dev/mmcblk90p1" ]]' "eMMC mounted right before rsync (RETURN-trap blocker regression) [got: $(cat $W/mounted_at_rsync 2>/dev/null)]"
chk '[[ "$(cat /sys/class/block/${EMN}p1/start)" == 65536 ]]' "eMMC partition starts at sector 65536"
chk 'e2fsck -fn /dev/mmcblk90p1 >/dev/null 2>&1' "eMMC fs clean"
chk 'cmp -s <(dd if=$EM bs=1k skip=8 count=240 status=none) $UB/boot0_sdcard.fex' "boot0 at 8K on eMMC"
chk 'cmp -s <(dd if=$EM bs=1k skip=16400 count=1360 status=none) $UB/boot_package.fex' "boot_package at 16400K on eMMC"
mkdir -p "$W/chk"; mount -o ro /dev/mmcblk90p1 "$W/chk"
NEW_UUID=$(blkid -s UUID -o value /dev/mmcblk90p1)
chk '[[ "$NEW_UUID" != "$SD_UUID" ]]' "new UUID differs from SD"
chk 'grep -q "rootdev=UUID=$NEW_UUID" $W/chk/boot/armbianEnv.txt' "armbianEnv.txt rootdev updated"
chk 'grep -q "^UUID=$NEW_UUID " $W/chk/etc/fstab' "fstab updated"
chk '[[ -f $W/chk/etc/apt/preferences.d/geomaxima-no-debian-kernel ]]' "kernel pin present on eMMC"
chk '[[ -f $W/chk/etc/geomaxima/migrated-from-sd ]]' "migration marker present"
chk '[[ $(find $W/chk/usr/bin -type f | wc -l) -eq $(find $W/sdroot/usr/bin -type f | wc -l) ]]' "all files copied"
chk '[[ -L $W/chk/usr/bin/link1 ]]' "symlink preserved"
chk '[[ $(stat -c %i $W/chk/usr/bin/f2) == $(stat -c %i $W/chk/usr/bin/hard2) ]]' "hardlink preserved"
chk '[[ -f $W/chk/home/peshovp/RPI-BS/tools/geomaxima-firstboot.sh || -f $W/chk/home/peshovp/RPI-BS/tools/emmc-install-opi4pro.sh ]]' "checkout copied"
umount "$W/chk"
chk '! mountpoint -q /mnt/emmc-target' "target unmounted after success"
chk '[[ "$(cd $W/sdroot && find . | sort | sha256sum)" == "$SD_SRC_LIST_BEFORE" ]]' "SD source tree unchanged"
chk '[[ ! -e $W/sdroot/mnt/emmc-target ]]' "nothing written into SD's own /mnt/emmc-target"

echo "== T2: re-run -> already prepared =="
H1=$(sha256sum "$W/emmc.img" | cut -d' ' -f1)
R=$(run_migrate 0 "" t2); echo "$R" | sed 's/^/    /'
chk '[[ "$R" == *rc=2* ]]' "returns 2"
chk '[[ "$(sha256sum $W/emmc.img | cut -d" " -f1)" == "$H1" ]]' "eMMC byte-identical (nothing written)"

echo "== T3: forced re-run with rsync failure =="
touch "$W/rsync_fail"
R=$(run_migrate 1 "" t3); echo "$R" | sed 's/^/    /'; rm -f "$W/rsync_fail"
chk '[[ "$R" == *rc=1* ]]' "returns 1"
chk '[[ "$R" != *part=/dev* ]]' "no GM_EMMC_RESULT_PART on failure"
chk '! mountpoint -q /mnt/emmc-target' "target unmounted after failure"
mount -o ro /dev/mmcblk90p1 "$W/chk" 2>/dev/null
chk '[[ ! -f $W/chk/etc/geomaxima/migrated-from-sd ]]' "no marker after failed migration"
umount "$W/chk" 2>/dev/null
chk '[[ "$(cd $W/sdroot && find . | sort | sha256sum)" == "$SD_SRC_LIST_BEFORE" ]]' "SD source tree unchanged"

echo "== T4: overlap guard (partition start 32768) =="
H2=$(sha256sum "$W/emmc.img" | cut -d' ' -f1)
R=$(run_migrate 1 32768 t4); echo "$R" | sed 's/^/    /'
chk '[[ "$R" == *rc=1* ]]' "returns 1"
chk 'grep -q "overlap" $W/out_t4.log' "reports overlap"
chk '[[ "$(sha256sum $W/emmc.img | cut -d" " -f1)" == "$H2" ]]' "eMMC untouched (guard runs before any write)"

echo "== T5: SD bootloader wipe =="
umount "$W/sdroot"
MBR_BEFORE=$(dd if=$SD bs=512 count=1 status=none | sha256sum)
R=$( ( export GM_SYSFS="$FS" GM_TEST_ROOT_PART=/dev/mmcblk91p1; source "$REPO/tools/emmc-install-opi4pro.sh"
       geomaxima_wipe_sd_bootloader > "$W/out_t5.log" 2>&1; echo "rc=$?" ) )
echo "    $R"
chk '[[ "$R" == rc=0 ]]' "returns 0"
chk '[[ "$(dd if=$SD bs=512 count=1 status=none | sha256sum)" == "$MBR_BEFORE" ]]' "MBR / partition table intact"
chk 'cmp -s <(dd if=$SD bs=1k skip=8 count=$((32768-8)) status=none) <(head -c $(( (32768-8)*1024 )) /dev/zero)' "8K..32M zeroed"
chk 'e2fsck -fn ${SD}p1 >/dev/null 2>&1' "SD filesystem still clean"

echo "== T6: install.sh phase-1 flow (SD->eMMC handoff) =="
# T6 uses ENTIRELY SEPARATE device numbers (mmcblk92 for the eMMC target,
# mmcblk93 for the "SD" source) rather than reusing the mmcblk90/mmcblk91
# fixture T1-T5 already exercised - T5 above already unmounted/wiped that
# SD's own bootloader area, so its state is no longer a valid "booted
# system" fixture for install.sh to run against. A fresh, independent set
# avoids any interference with (or dependency on) T1-T5's shared state.
truncate -s 600M "$W/sd2.img"
parted -s "$W/sd2.img" mklabel msdos mkpart primary ext4 65536s 100%
SD2=$(attach "$W/sd2.img"); SD2N=$(basename "$SD2")
mkfs.ext4 -q -L armbi_root "${SD2}p1"
mkdir -p "$W/sdroot2"; mount "${SD2}p1" "$W/sdroot2"
SD2_UUID=$(blkid -s UUID -o value "${SD2}p1")
mkdir -p "$W/sdroot2"/{boot,etc,home/peshovp/RPI-BS/tools,home/peshovp/RPI-BS/web_app,usr/bin,var/log}
echo "rootdev=UUID=$SD2_UUID" > "$W/sdroot2/boot/armbianEnv.txt"
echo "UUID=$SD2_UUID / ext4 defaults,commit=120,errors=remount-ro 0 1" > "$W/sdroot2/etc/fstab"
cp -r "$REPO/tools/." "$W/sdroot2/home/peshovp/RPI-BS/tools/" 2>/dev/null
touch "$W/sdroot2/home/peshovp/RPI-BS/web_app/server.py"
cp "$REPO/install.sh" "$W/sdroot2/home/peshovp/RPI-BS/install.sh"
mknod /dev/mmcblk93p1 b $(tr ':' ' ' < /sys/class/block/${SD2N}p1/dev)

truncate -s 1600M "$W/emmc3.img"
parted -s "$W/emmc3.img" mklabel msdos mkpart primary ext4 32768s 100%
EM3=$(attach "$W/emmc3.img"); EM3N=$(basename "$EM3")
mkfs.ext4 -q "${EM3}p1"
mknod /dev/mmcblk92 b $(tr ':' ' ' < /sys/class/block/$EM3N/dev)
( while true; do
    if [[ -e /sys/class/block/${EM3N}p1/dev ]]; then
      want=$(cat /sys/class/block/${EM3N}p1/dev)
      have=$( [[ -b /dev/mmcblk92p1 ]] && stat -c '%Hr:%Lr' /dev/mmcblk92p1)
      [[ "$want" != "$have" ]] && { rm -f /dev/mmcblk92p1; mknod /dev/mmcblk92p1 b ${want%:*} ${want#*:}; }
    else rm -f /dev/mmcblk92p1; fi
    sleep 0.1; done ) & WATCH2_PID=$!
sleep 0.5

FS2="$W/sys2"; mkdir -p "$FS2/block/mmcblk92/device" "$FS2/block/$SD2N/device"
echo MMC > "$FS2/block/mmcblk92/device/type"; cat /sys/class/block/$EM3N/size > "$FS2/block/mmcblk92/size"
ln -s /sys/class/block/${EM3N}p1 "$FS2/block/mmcblk92/mmcblk92p1"
echo SD > "$FS2/block/$SD2N/device/type"; ln -s /sys/class/block/${SD2N}p1 "$FS2/block/$SD2N/${SD2N}p1"; ln -s /sys/class/block/${SD2N}p1 "$FS2/block/$SD2N/mmcblk93p1"

# Stub poweroff/reboot (install.sh's phase-1 flow calls one of these on
# every path) - a real call would kill this sandbox/runner. Recorded to a
# file so the test can assert which one (if either) was invoked.
rm -f "$W/power_action"
cat > "$W/bin/poweroff" <<EOF
#!/usr/bin/env bash
echo "poweroff" >> $W/power_action
EOF
cat > "$W/bin/reboot" <<EOF
#!/usr/bin/env bash
echo "reboot" >> $W/power_action
EOF
chmod +x "$W/bin/poweroff" "$W/bin/reboot"

run_install_phase1() {
  ( export PATH="$W/bin:$PATH" GM_SYSFS="$FS2" GM_TEST_ROOT_PART=/dev/mmcblk93p1 GM_ROOT_SRC="$W/sdroot2/" \
           GM_UBOOT_DIR="$UB" GM_EMMC_PLATFORM_SCRIPT="$W/platform_install.sh" \
           GM_TEST_FORCE_PLATFORM=armbian-a733 GM_PHASE=1 GM_EMMC=yes GM_DRY_RUN=0 \
           SUDO_USER=peshovp INSTALL_DIR="$W/sdroot2/home/peshovp/RPI-BS" GM_REEXECD=1
    cd "$W/sdroot2/home/peshovp/RPI-BS"
    bash install.sh > "$W/out_install_phase1.log" 2>&1
    echo "rc=$?" )
}

R=$(run_install_phase1); echo "$R" | sed 's/^/    /'
chk '[[ "$R" == *rc=0* ]]' "install.sh phase-1 exits 0"
chk '[[ "$(cat $W/power_action 2>/dev/null)" == "poweroff" ]]' "install.sh phase-1 calls poweroff (default GM_WIPE_SD_BOOT=no path), not reboot"
mkdir -p "$W/chk2"; mount -o ro /dev/mmcblk92p1 "$W/chk2"
chk '[[ -f $W/chk2/etc/geomaxima/install.env ]]' "install.env written to eMMC"
chk 'grep -q "^GM_INSTALL_USER=peshovp$" $W/chk2/etc/geomaxima/install.env' "install.env has GM_INSTALL_USER"
chk 'grep -q "^GM_PHASE=2$" $W/chk2/etc/geomaxima/install.env' "install.env has GM_PHASE=2"
chk '[[ -f $W/chk2/etc/systemd/system/geomaxima-firstboot.service ]]' "geomaxima-firstboot.service written to eMMC"
chk 'grep -q "ExecStart=.*/tools/geomaxima-firstboot.sh" $W/chk2/etc/systemd/system/geomaxima-firstboot.service' "unit ExecStart points at tools/geomaxima-firstboot.sh"
chk '[[ -L $W/chk2/etc/systemd/system/multi-user.target.wants/geomaxima-firstboot.service ]]' "geomaxima-firstboot.service enabled (symlink present)"
chk '[[ -f $W/chk2/etc/apt/preferences.d/geomaxima-no-debian-kernel ]]' "kernel pin present on eMMC (phase-1 path)"
umount "$W/chk2"
chk '! mountpoint -q /mnt/emmc-target' "target unmounted after install.sh phase-1"

kill "$WATCH2_PID" 2>/dev/null
umount "$W/sdroot2" 2>/dev/null
rm -f /dev/mmcblk92 /dev/mmcblk92p1 /dev/mmcblk93p1
losetup -d "$SD2" 2>/dev/null; losetup -d "$EM3" 2>/dev/null

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
