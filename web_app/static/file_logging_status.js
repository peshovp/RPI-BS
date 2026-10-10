// GeoMaxima - 2026-10-10: visible warning when raw GNSS data is NOT
// being recorded (File service off or inactive) and no survey
// currently owns it on purpose - shared by status.html and
// settings.html, both of which have an
// <div id="file_logging_warning"> element for this script to fill in.
//
// Uses the SAME active/enabled/ownership signal gnss_monitor.py's
// Watchdog check already reads (server-side, via
// web_app/server.py's getServicesStatus()'s "file_logging_status"
// socketio event) - no second detection logic here, this file only
// renders what the server already computed.
$(document).ready(function () {
    var warningElt = document.getElementById("file_logging_warning");
    if (!warningElt) {
        return;
    }

    var ns = "/test";
    var fileLoggingSocket = (typeof socket !== "undefined" && socket) ? socket : io.connect(ns);

    fileLoggingSocket.on("file_logging_status", function (msg) {
        var status = JSON.parse(msg);
        if (status.owned_by_survey) {
            warningElt.className = "alert alert-info";
            warningElt.textContent = "Raw logging owned by Autosurvey.";
            warningElt.style.display = "";
        } else if (status.active !== true || status.enabled !== true) {
            warningElt.className = "alert alert-warning";
            warningElt.textContent = "File logging is OFF - raw GNSS data is NOT being recorded.";
            warningElt.style.display = "";
        } else {
            warningElt.style.display = "none";
        }
    });

    // Ask once on page load - status.html has no other trigger for
    // this (it never emits the heavier "get services status" event,
    // which assumes service-toggle DOM elements this page doesn't
    // have); settings.html already requests "get services status" at
    // load, whose handler emits "file_logging_status" too, but asking
    // again here is harmless (idempotent) and keeps this script
    // self-contained regardless of which page includes it.
    fileLoggingSocket.emit("get file logging status");
});
