#!/usr/bin/env bash
# Shared helpers for detecting and performing a verified systemd daemon-reload.
# Sourced by tools/post_update.sh and addons/tools/perform_update.sh.
# Callers must run as root. NeedDaemonReload=yes means the unit file on disk
# is not the definition systemd has loaded.

geomaxima_managed_units() {
    systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^(str2str_|rtkbase_|geomaxima_)[^@]*\.(service|timer)$' | sort -u
}

geomaxima_units_needing_reload() {
    local unit
    for unit in $(geomaxima_managed_units); do
        local val
        val=$(systemctl show -p NeedDaemonReload --value "$unit" 2>/dev/null)
        if [ "$val" = "yes" ]; then
            echo "$unit"
        fi
    done
}

geomaxima_daemon_reload_and_verify() {
    local rc=0
    systemctl daemon-reload || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "unit_reload: systemctl daemon-reload failed (exit $rc)" >&2
        return 2
    fi
    local still
    still=$(geomaxima_units_needing_reload)
    if [ -n "$still" ]; then
        echo "unit_reload: still needing reload after daemon-reload: $still" >&2
        return 1
    fi
    return 0
}
