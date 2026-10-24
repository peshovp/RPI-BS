(function () {
    "use strict";

    var panel = document.getElementById("cors-job-panel");
    if (!panel) {
        return;
    }

    var badge = document.getElementById("cors-job-badge");
    var statusEl = document.getElementById("cors-job-status");
    var resultEl = document.getElementById("cors-job-result");
    var resPosition = document.getElementById("cors-res-position");
    var resCurrent = document.getElementById("cors-res-current");
    var resDiff = document.getElementById("cors-res-diff");
    var resQuality = document.getElementById("cors-res-quality");
    var resFrame = document.getElementById("cors-res-frame");
    var resHint = document.getElementById("cors-res-hint");
    var resConverted = document.getElementById("cors-res-converted");
    var applyBlock = document.getElementById("cors-job-apply");
    var confirmCheckbox = document.getElementById("cors-confirm");
    var forceRow = document.getElementById("cors-force-row");
    var forceCheckbox = document.getElementById("cors-force");
    var applyBtn = document.getElementById("cors-apply-btn");
    var cancelBtn = document.getElementById("cors-cancel-job-btn");

    var pollTimer = null;
    var currentJobId = null;
    var forceNeeded = false;
    var panelShownByStart = false;
    var pollErrors = 0;

    function clearPoll() {
        if (pollTimer) {
            clearTimeout(pollTimer);
            pollTimer = null;
        }
    }

    function schedulePoll() {
        clearPoll();
        pollTimer = setTimeout(function () {
            poll();
        }, 3000);
    }

    function setStatus(text, cls) {
        if (cls) {
            statusEl.className = cls;
        } else {
            statusEl.className = "small mb-2 text-muted";
        }
        statusEl.textContent = text;
    }

    function showPanel() {
        panel.classList.remove("d-none");
    }

    function hidePanel() {
        panel.classList.add("d-none");
    }

    function fmtNum(val, decimals) {
        if (val === null || val === undefined) {
            return "-";
        }
        return Number(val).toFixed(decimals);
    }

    function render(job) {
        if (!job) {
            return;
        }

        var status = job.status;
        var accountName = job.account_name || "";
        var stage = job.stage || "";
        var info = job.info || "";

        if (job.job_id !== currentJobId) {
            currentJobId = job.job_id;
            forceNeeded = false;
            if (confirmCheckbox) {
                confirmCheckbox.checked = false;
            }
            if (forceCheckbox) {
                forceCheckbox.checked = false;
            }
        }

        if (status === "running") {
            showPanel();
            badge.textContent = "Running";
            badge.className = "badge badge-info";
            setStatus(accountName + ": " + stage + " - " + info);
            cancelBtn.classList.remove("d-none");
        } else if (status === "failed" || status === "cancelled") {
            showPanel();
            badge.textContent = status === "failed" ? "Failed" : "Cancelled";
            badge.className = "badge badge-danger";
            setStatus(accountName + ": failed at " + stage + ": " + info);
            cancelBtn.classList.add("d-none");
        } else if (status === "done") {
            showPanel();
            badge.textContent = "Done";
            badge.className = "badge badge-success";
            setStatus(accountName + ": finished, review the proposal below");
            cancelBtn.classList.add("d-none");
        } else if (status === "applied") {
            showPanel();
            badge.textContent = "Applied";
            badge.className = "badge badge-primary";
            setStatus("Applied at " + (job.applied_at || "unknown"));
            cancelBtn.classList.add("d-none");
        } else {
            badge.textContent = "Idle";
            badge.className = "badge badge-secondary";
            if (!panelShownByStart) {
                hidePanel();
            }
            cancelBtn.classList.add("d-none");
        }

        var result = job.result;
        var comparison = job.comparison;

        if (result && result.lat !== null) {
            resultEl.classList.remove("d-none");

            var posText = "lat " + fmtNum(result.lat, 8) + ", lon " + fmtNum(result.lon, 8) + ", h " + fmtNum(result.h, 3) + " m (ellipsoidal)";
            resPosition.textContent = posText;

            resCurrent.textContent = "(settings.conf)";

            if (comparison) {
                var diffText = "N " + fmtNum(comparison.d_north_m, 3) + " m / E " + fmtNum(comparison.d_east_m, 3) + " m / U " + fmtNum(comparison.d_up_m, 3) + " m (horizontal " + fmtNum(comparison.horizontal_m, 3) + " m, vertical " + fmtNum(comparison.vertical_m, 3) + " m)";
                resDiff.textContent = diffText;
            } else {
                resDiff.textContent = "no current position";
            }

            var summary = result.summary;
            if (summary) {
                var fixed = summary.fixed !== null ? summary.fixed : "-";
                var total = summary.total !== null ? summary.total : "-";
                var fixRatio = summary.fix_ratio !== null ? fmtNum(summary.fix_ratio * 100, 1) + " %" : "-";
                var used = summary.used !== null ? summary.used : "-";
                var sigmaN = summary.std_n_m !== null ? fmtNum(summary.std_n_m * 1000, 1) : "-";
                var sigmaE = summary.std_e_m !== null ? fmtNum(summary.std_e_m * 1000, 1) : "-";
                var sigmaU = summary.std_u_m !== null ? fmtNum(summary.std_u_m * 1000, 1) : "-";
                resQuality.textContent = "fixed epochs " + fixed + " of " + total + " (fix ratio " + fixRatio + "), used " + used + ", sigma N/E/U " + sigmaN + "/" + sigmaE + "/" + sigmaU + " mm";
            } else {
                resQuality.textContent = "-";
            }

            var frameText = job.frame || "-";
            if (job.epoch !== null && job.epoch !== undefined) {
                frameText = frameText + " epoch " + job.epoch;
            }
            resFrame.textContent = frameText;

            if (job.converted) {
                var convText = "lat " + fmtNum(job.converted.lat, 8) + ", lon " + fmtNum(job.converted.lon, 8) + ", h " + fmtNum(job.converted.h, 3) + " m (via " + job.converted.method + ", shift " + fmtNum(job.converted.shift_m, 2) + " m)";
                if (job.converted.provisional) {
                    convText = convText + " - provisional: " + (job.converted.provisional_reason || "see documentation");
                }
                resConverted.textContent = convText;
            } else {
                var notAvail = "not available";
                if (job.conversion_error) {
                    notAvail = notAvail + ": " + job.conversion_error;
                }
                resConverted.textContent = notAvail;
            }

            if (comparison) {
                resHint.classList.remove("d-none");
                if (comparison.within_threshold) {
                    resHint.className = "alert alert-success py-1 small";
                } else {
                    resHint.className = "alert alert-warning py-1 small";
                }
                resHint.textContent = comparison.hint || "";
            } else {
                resHint.classList.add("d-none");
            }
        } else {
            resultEl.classList.add("d-none");
        }

        var applicable = status === "done" && result && result.ok && job.converted !== null;
        if (status === "done" && result && result.ok && job.converted === null) {
            applyBlock.classList.add("d-none");
            resHint.classList.remove("d-none");
            resHint.className = "alert alert-warning py-1 small";
            resHint.textContent = "Cannot be applied: " + (job.conversion_error || "no BGS2005 position could be derived") + ". Check the coordinate system and epoch of the account.";
        } else if (applicable) {
            applyBlock.classList.remove("d-none");
        } else {
            applyBlock.classList.add("d-none");
        }

        if (forceNeeded) {
            forceRow.classList.remove("d-none");
        } else {
            forceRow.classList.add("d-none");
        }

        updateApplyButton(applicable);
    }

    function updateApplyButton(applicable) {
        if (!applicable) {
            applyBtn.disabled = true;
            return;
        }
        applyBtn.disabled = !confirmCheckbox.checked;
    }

    function poll() {
        fetch("/api/cors/job", {
            credentials: "same-origin",
            headers: { "Accept": "application/json" }
        }).then(function (resp) {
            if (!resp.ok) {
                throw new Error("HTTP " + resp.status);
            }
            return resp.json();
        }).then(function (data) {
            pollErrors = 0;
            if (!data.ok) {
                throw new Error(data.error || "API error");
            }
            var job = data.job;
            render(job);
            if (job.status === "running") {
                schedulePoll();
            }
        }).catch(function (err) {
            pollErrors += 1;
            setStatus("Could not read the job state", "small mb-2 text-danger");
            if (pollErrors < 5) {
                schedulePoll();
            } else {
                clearPoll();
            }
        });
    }

    window.corsJobStart = function (account) {
        panelShownByStart = true;
        showPanel();

        if (!account.enabled) {
            setStatus("Account is disabled", "small mb-2 text-danger");
            return;
        }

        setStatus("Starting ...");
        fetch("/api/cors/accounts/" + account.id + "/compute", {
            method: "POST",
            credentials: "same-origin",
            headers: { "Accept": "application/json", "Content-Type": "application/json" },
            body: "{}"
        }).then(function (resp) {
            return resp.json();
        }).then(function (data) {
            if (data.ok) {
                poll();
            } else {
                setStatus(data.error || "Failed to start", "small mb-2 text-danger");
                poll();
            }
        }).catch(function (err) {
            setStatus("Failed to start: " + err.message, "small mb-2 text-danger");
            poll();
        });
    };

    if (confirmCheckbox) {
        confirmCheckbox.addEventListener("change", function () {
            var job = null;
            fetch("/api/cors/job", {
                credentials: "same-origin",
                headers: { "Accept": "application/json" }
            }).then(function (resp) {
                return resp.json();
            }).then(function (data) {
                if (data.ok) {
                    job = data.job;
                    var applicable = job.status === "done" && job.result && job.result.ok && job.converted !== null;
                    updateApplyButton(applicable);
                }
            }).catch(function () {});
        });
    }

    if (applyBtn) {
        applyBtn.addEventListener("click", function () {
            var job = null;
            fetch("/api/cors/job", {
                credentials: "same-origin",
                headers: { "Accept": "application/json" }
            }).then(function (resp) {
                return resp.json();
            }).then(function (data) {
                if (!data.ok) {
                    throw new Error(data.error || "API error");
                }
                job = data.job;
                if (!job.converted) {
                    throw new Error("No BGS2005 position to apply");
                }

                var posText = "lat " + fmtNum(job.converted.lat, 8) + ", lon " + fmtNum(job.converted.lon, 8) + ", h " + fmtNum(job.converted.h, 3) + " m (ellipsoidal)";
                var diffText = "no current position";
                if (job.comparison) {
                    diffText = "N " + fmtNum(job.comparison.d_north_m, 3) + " m / E " + fmtNum(job.comparison.d_east_m, 3) + " m / U " + fmtNum(job.comparison.d_up_m, 3) + " m (horizontal " + fmtNum(job.comparison.horizontal_m, 3) + " m, vertical " + fmtNum(job.comparison.vertical_m, 3) + " m)";
                }

                var confirmText = "Apply this position as the broadcast position (BGS2005)?\n" + posText + "\nDifference: " + diffText;
                if (forceCheckbox.checked) {
                    confirmText = confirmText + "\nFORCED: the difference to the current position is large.";
                }
                if (!window.confirm(confirmText)) {
                    return null;
                }

                applyBtn.disabled = true;
                return fetch("/api/cors/job/apply", {
                    method: "POST",
                    credentials: "same-origin",
                    headers: { "Accept": "application/json", "Content-Type": "application/json" },
                    body: JSON.stringify({ job_id: job.job_id, confirm: true, force: forceCheckbox.checked })
                });
            }).then(function (resp) {
                if (resp === null) {
                    return null;
                }
                return resp.json().then(function (data) {
                    return { resp: resp, data: data };
                });
            }).then(function (result) {
                if (result === null) {
                    updateApplyButton(true);
                    return;
                }
                var data = result.data;
                if (data.ok) {
                    setStatus("Position applied.", "small mb-2 text-success");
                    if (confirmCheckbox) {
                        confirmCheckbox.checked = false;
                    }
                    if (forceCheckbox) {
                        forceCheckbox.checked = false;
                    }
                    poll();
                } else {
                    setStatus(data.error || "Apply failed", "small mb-2 text-danger");
                    if (data.error && data.error.indexOf("change too large") !== -1) {
                        forceNeeded = true;
                        forceRow.classList.remove("d-none");
                    }
                    updateApplyButton(true);
                }
            }).catch(function (err) {
                setStatus("Apply failed: " + err.message, "small mb-2 text-danger");
                updateApplyButton(true);
            });
        });
    }

    if (cancelBtn) {
        cancelBtn.addEventListener("click", function () {
            fetch("/api/cors/job/cancel", {
                method: "POST",
                credentials: "same-origin",
                headers: { "Accept": "application/json" }
            }).then(function (resp) {
                return resp.json();
            }).then(function (data) {
                poll();
            }).catch(function () {
                poll();
            });
        });
    }

    poll();
})();
