// GeoMaxima - 2026-10-10: File service is survey-only (OFF by default,
// runs only while an Autosurvey runs). Shows warnings for abnormal states.
$(document).ready(function () {
    var warningElt = document.getElementById("file_logging_warning");
    if (!warningElt) {
        return;
    }

    var ns = "/test";
    var fileLoggingSocket = (typeof socket !== "undefined" && socket) ? socket : io.connect(ns);

    fileLoggingSocket.on("file_logging_status", function (msg) {
        var status = JSON.parse(msg);
        window.gmSurveyRunning = status.survey_running === true;

        if (status.survey_running === true && status.active === true) {
            warningElt.className = "alert alert-info";
            warningElt.textContent = "Raw logging is running for the Autosurvey.";
            warningElt.style.display = "";
        } else if (status.survey_running === true && status.active !== true) {
            warningElt.className = "alert alert-danger";
            warningElt.textContent = "CRITICAL: a survey is running but File logging is NOT active - raw GNSS data is NOT being recorded.";
            warningElt.style.display = "";
        } else if (status.survey_running !== true && status.active === true) {
            warningElt.className = "alert alert-warning";
            warningElt.textContent = "File logging is running without a survey. The File service is survey-only; switch it off unless you really need raw logging.";
            warningElt.style.display = "";
        } else {
            warningElt.style.display = "none";
        }
    });

    fileLoggingSocket.emit("get file logging status");
});
