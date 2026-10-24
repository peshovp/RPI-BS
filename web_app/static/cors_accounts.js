(function () {
    "use strict";

    var form = document.getElementById("cors-form");
    if (!form) {
        return;
    }

    var listEl = document.getElementById("cors-accounts-list");
    var messageEl = document.getElementById("cors-message");
    var addBtn = document.getElementById("cors-add-btn");
    var saveBtn = document.getElementById("cors-save-btn");
    var cancelBtn = document.getElementById("cors-cancel-btn");
    var corsId = document.getElementById("cors-id");
    var corsName = document.getElementById("cors-name");
    var corsHost = document.getElementById("cors-host");
    var corsPort = document.getElementById("cors-port");
    var corsMountpoint = document.getElementById("cors-mountpoint");
    var corsUsername = document.getElementById("cors-username");
    var corsPassword = document.getElementById("cors-password");
    var corsMode = document.getElementById("cors-mode");
    var corsFrame = document.getElementById("cors-frame");
    var corsEpoch = document.getElementById("cors-epoch");
    var corsTls = document.getElementById("cors-tls");
    var corsEnabled = document.getElementById("cors-enabled");
    var corsCrosscheck = document.getElementById("cors-crosscheck");
    var corsQuickstart = document.getElementById("cors-quickstart");

    function init() {
        addBtn.addEventListener("click", onAdd);
        saveBtn.addEventListener("click", onSave);
        cancelBtn.addEventListener("click", onCancel);
        corsFrame.addEventListener("change", onFrameChange);
        onFrameChange();
        loadAccounts();
    }

    function onAdd() {
        corsId.value = "";
        corsName.value = "";
        corsHost.value = "";
        corsPort.value = "2101";
        corsMountpoint.value = "";
        corsUsername.value = "";
        corsPassword.value = "";
        corsPassword.placeholder = "";
        corsMode.value = "vrs";
        corsFrame.value = "ETRF2000@2005.0";
        corsEpoch.value = "";
        corsTls.checked = false;
        corsEnabled.checked = true;
        corsCrosscheck.checked = true;
        corsQuickstart.checked = false;
        onFrameChange();
        form.classList.remove("d-none");
    }

    function onEdit(account) {
        corsId.value = account.id;
        corsName.value = account.name;
        corsHost.value = account.host;
        corsPort.value = String(account.port);
        corsMountpoint.value = account.mountpoint;
        corsUsername.value = account.username;
        corsPassword.value = "";
        if (account.has_password) {
            corsPassword.placeholder = "(unchanged - leave empty to keep)";
        } else {
            corsPassword.placeholder = "";
        }
        corsMode.value = account.mode;
        corsFrame.value = account.frame;
        if (account.epoch != null) {
            corsEpoch.value = String(account.epoch);
        } else {
            corsEpoch.value = "";
        }
        corsTls.checked = account.tls;
        corsEnabled.checked = account.enabled;
        corsCrosscheck.checked = account.use_for_crosscheck;
        corsQuickstart.checked = account.use_for_quick_start;
        onFrameChange();
        form.classList.remove("d-none");
    }

    function onFrameChange() {
        var frame = corsFrame.value;
        if (frame.indexOf("@epoch") === frame.length - 6) {
            corsEpoch.disabled = false;
        } else {
            corsEpoch.disabled = true;
            corsEpoch.value = "";
        }
    }

    function onSave() {
        var id = corsId.value;
        var body = {
            name: corsName.value,
            host: corsHost.value,
            port: parseInt(corsPort.value, 10),
            mountpoint: corsMountpoint.value,
            username: corsUsername.value,
            mode: corsMode.value,
            frame: corsFrame.value,
            tls: corsTls.checked,
            enabled: corsEnabled.checked,
            use_for_crosscheck: corsCrosscheck.checked,
            use_for_quick_start: corsQuickstart.checked
        };

        if (!corsEpoch.disabled && corsEpoch.value !== "") {
            body.epoch = Number(corsEpoch.value);
        } else {
            body.epoch = null;
        }

        if (corsPassword.value !== "") {
            body.password = corsPassword.value;
        }

        var url = "/api/cors/accounts";
        var method = "POST";
        if (id) {
            url = "/api/cors/accounts/" + id;
            method = "PUT";
        }

        saveBtn.disabled = true;

        fetch(url, {
            method: method,
            credentials: "same-origin",
            headers: {
                "Content-Type": "application/json",
                "Accept": "application/json"
            },
            body: JSON.stringify(body)
        }).then(function (response) {
            return response.text().then(function (text) {
                return { status: response.status, text: text };
            });
        }).then(function (result) {
            var data;
            try {
                data = JSON.parse(result.text);
            } catch (e) {
                data = null;
            }

            if (data && data.ok) {
                corsPassword.value = "";
                corsId.value = "";
                form.classList.add("d-none");
                showMessage("Account saved.", "success");
                loadAccounts();
            } else {
                var errText = "Request failed";
                if (data && data.error) {
                    errText = data.error;
                }
                showMessage(errText, "danger");
            }
        }).catch(function () {
            showMessage("Request failed", "danger");
        }).finally(function () {
            saveBtn.disabled = false;
        });
    }

    function onCancel() {
        corsId.value = "";
        corsName.value = "";
        corsHost.value = "";
        corsPort.value = "2101";
        corsMountpoint.value = "";
        corsUsername.value = "";
        corsPassword.value = "";
        corsPassword.placeholder = "";
        corsMode.value = "vrs";
        corsFrame.value = "ETRF2000@2005.0";
        corsEpoch.value = "";
        corsTls.checked = false;
        corsEnabled.checked = true;
        corsCrosscheck.checked = true;
        corsQuickstart.checked = false;
        onFrameChange();
        form.classList.add("d-none");
    }

    function onDelete(account) {
        if (!window.confirm("Delete CORS account " + account.name + "?")) {
            return;
        }

        fetch("/api/cors/accounts/" + account.id, {
            method: "DELETE",
            credentials: "same-origin",
            headers: { "Accept": "application/json" }
        }).then(function (response) {
            return response.text().then(function (text) {
                return { status: response.status, text: text };
            });
        }).then(function (result) {
            var data;
            try {
                data = JSON.parse(result.text);
            } catch (e) {
                data = null;
            }

            if (data && data.ok) {
                showMessage("Account deleted.", "success");
                loadAccounts();
            } else {
                var errText = "Request failed";
                if (data && data.error) {
                    errText = data.error;
                }
                showMessage(errText, "danger");
            }
        }).catch(function () {
            showMessage("Request failed", "danger");
        });
    }

    function loadAccounts() {
        fetch("/api/cors/accounts", {
            credentials: "same-origin",
            headers: { "Accept": "application/json" }
        }).then(function (response) {
            return response.text().then(function (text) {
                return { status: response.status, text: text };
            });
        }).then(function (result) {
            var data;
            try {
                data = JSON.parse(result.text);
            } catch (e) {
                data = null;
            }

            if (!data) {
                showMessage("Session expired - reload the page", "danger");
                return;
            }

            if (!data.ok) {
                showMessage(data.error || "Could not load accounts", "danger");
                return;
            }

            renderAccounts(data.accounts);
        }).catch(function () {
            showMessage("Could not load accounts", "danger");
        });
    }

    function renderAccounts(accounts) {
        while (listEl.firstChild) {
            listEl.removeChild(listEl.firstChild);
        }

        if (!accounts || accounts.length === 0) {
            var p = document.createElement("p");
            p.className = "text-muted";
            p.textContent = "No CORS accounts yet.";
            listEl.appendChild(p);
            return;
        }

        for (var i = 0; i < accounts.length; i++) {
            var account = accounts[i];
            var row = document.createElement("div");
            row.className = "d-flex justify-content-between align-items-center py-2 border-bottom";

            var info = document.createElement("div");

            var nameSpan = document.createElement("span");
            nameSpan.className = "font-weight-bold";
            nameSpan.textContent = account.name;
            info.appendChild(nameSpan);

            var detailSpan = document.createElement("span");
            detailSpan.className = "ml-2";
            detailSpan.textContent = account.host + ":" + account.port + " / " + account.mountpoint;
            info.appendChild(detailSpan);

            var flags = [];
            if (!account.enabled) {
                flags.push("disabled");
            }
            if (account.use_for_crosscheck) {
                flags.push("cross-check");
            }
            if (account.use_for_quick_start) {
                flags.push("start position");
            }
            if (account.tls) {
                flags.push("TLS");
            }

            var meta = document.createElement("div");
            meta.className = "small text-muted";
            meta.textContent = account.mode + ", " + account.frame;
            if (account.epoch != null) {
                meta.textContent += " epoch " + account.epoch;
            }
            if (flags.length > 0) {
                meta.textContent += " (" + flags.join(", ") + ")";
            }
            info.appendChild(meta);

            row.appendChild(info);

            var buttons = document.createElement("div");

            var editBtn = document.createElement("button");
            editBtn.className = "btn btn-sm btn-outline-secondary mr-1";
            editBtn.textContent = "Edit";
            editBtn.addEventListener("click", (function (a) {
                return function () {
                    onEdit(a);
                };
            })(account));
            buttons.appendChild(editBtn);

            var computeBtn = document.createElement("button");
            computeBtn.className = "btn btn-sm btn-outline-primary mr-1";
            computeBtn.textContent = "Compute position";
            if (!account.enabled) {
                computeBtn.disabled = true;
                computeBtn.title = "Account is disabled";
            }
            computeBtn.addEventListener("click", (function (a) {
                return function () {
                    if (typeof window.corsJobStart === "function") {
                        window.corsJobStart(a);
                    }
                };
            })(account));
            buttons.appendChild(computeBtn);

            var delBtn = document.createElement("button");
            delBtn.className = "btn btn-sm btn-outline-danger";
            delBtn.textContent = "Delete";
            delBtn.addEventListener("click", (function (a) {
                return function () {
                    onDelete(a);
                };
            })(account));
            buttons.appendChild(delBtn);

            row.appendChild(buttons);
            listEl.appendChild(row);
        }
    }

    function showMessage(text, kind) {
        messageEl.textContent = text;
        messageEl.className = "alert";
        if (kind === "success") {
            messageEl.classList.add("alert-success");
        } else if (kind === "danger") {
            messageEl.classList.add("alert-danger");
        } else {
            messageEl.classList.add("alert-info");
        }
        messageEl.classList.remove("d-none");

        if (kind === "success") {
            setTimeout(function () {
                messageEl.classList.add("d-none");
            }, 8000);
        }
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", init);
    } else {
        init();
    }
})();
