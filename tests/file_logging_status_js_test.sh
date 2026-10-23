#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${GM_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node not available"
    exit 0
fi

node - "$REPO" <<'JSEOF'
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const repo = process.argv[2];
let passed = 0;
let failed = 0;

function pass(msg) {
    console.log('PASS: ' + msg);
    passed++;
}

function fail(msg) {
    console.log('FAIL: ' + msg);
    failed++;
}

// Part 1: Test file_logging_status.js behaviour
const statusJsPath = path.join(repo, 'web_app', 'static', 'file_logging_status' + '.js');
let statusJs;
try {
    statusJs = fs.readFileSync(statusJsPath, 'utf8');
} catch (e) {
    fail('Could not read ' + statusJsPath + ': ' + e.message);
}

if (statusJs) {
    const warningEl = { className: '', textContent: '', style: { display: '' } };
    const sandbox = {
        window: {},
        document: {
            getElementById: function(id) {
                if (id === 'file_logging_warning') {
                    return warningEl;
                }
                return null;
            }
        },
        $: function(sel) {
            return {
                ready: function(fn) {
                    fn();
                }
            };
        },
        io: {
            connect: function() {
                return fakeSocket;
            }
        }
    };

    let fileLoggingHandler = null;
    const fakeSocket = {
        on: function(event, handler) {
            if (event === 'file_logging_status') {
                fileLoggingHandler = handler;
            }
        },
        emit: function() {}
    };

    try {
        vm.runInNewContext(statusJs, sandbox);
    } catch (e) {
        fail('Error running file_logging_status.js: ' + e.message);
    }

    if (!fileLoggingHandler) {
        fail('file_logging_status handler was not registered');
    } else {
        // Case A: survey running, logging active
        warningEl.className = '';
        warningEl.textContent = '';
        warningEl.style.display = '';
        sandbox.window.gmSurveyRunning = undefined;
        fileLoggingHandler(JSON.stringify({ survey_running: true, active: true }));
        if (warningEl.className === 'alert alert-info' &&
            warningEl.textContent.indexOf('Autosurvey') !== -1 &&
            warningEl.style.display === '' &&
            sandbox.window.gmSurveyRunning === true) {
            pass('Case A: survey running, logging active');
        } else {
            fail('Case A: survey running, logging active');
        }

        // Case B: survey running, logging not active
        warningEl.className = '';
        warningEl.textContent = '';
        warningEl.style.display = '';
        fileLoggingHandler(JSON.stringify({ survey_running: true, active: false }));
        if (warningEl.className === 'alert alert-danger' &&
            warningEl.textContent.indexOf('CRITICAL') !== -1 &&
            warningEl.style.display === '') {
            pass('Case B: survey running, logging not active');
        } else {
            fail('Case B: survey running, logging not active');
        }

        // Case C: no survey, logging active
        warningEl.className = '';
        warningEl.textContent = '';
        warningEl.style.display = '';
        sandbox.window.gmSurveyRunning = undefined;
        fileLoggingHandler(JSON.stringify({ survey_running: false, active: true }));
        if (warningEl.className === 'alert alert-warning' &&
            warningEl.textContent.indexOf('without a survey') !== -1 &&
            warningEl.style.display === '' &&
            sandbox.window.gmSurveyRunning === false) {
            pass('Case C: no survey, logging active');
        } else {
            fail('Case C: no survey, logging active');
        }

        // Case D: no survey, logging not active
        warningEl.className = '';
        warningEl.textContent = '';
        warningEl.style.display = '';
        fileLoggingHandler(JSON.stringify({ survey_running: false, active: false }));
        if (warningEl.style.display === 'none') {
            pass('Case D: no survey, logging not active');
        } else {
            fail('Case D: no survey, logging not active');
        }

        // Case E: older payload without survey_running
        warningEl.className = '';
        warningEl.textContent = '';
        warningEl.style.display = '';
        sandbox.window.gmSurveyRunning = undefined;
        fileLoggingHandler(JSON.stringify({ active: false, enabled: false }));
        if (warningEl.style.display === 'none' &&
            sandbox.window.gmSurveyRunning === false) {
            pass('Case E: older payload without survey_running');
        } else {
            fail('Case E: older payload without survey_running');
        }
    }
}

// Part 2: Source check of settings.js
const settingsJsPath = path.join(repo, 'web_app', 'static', 'settings' + '.js');
let settingsJs;
try {
    settingsJs = fs.readFileSync(settingsJsPath, 'utf8');
} catch (e) {
    fail('Could not read ' + settingsJsPath + ': ' + e.message);
}

if (settingsJs) {
    const surveyCheckIdx = settingsJs.indexOf('window.gmSurveyRunning !== true');
    const confirmIdx = settingsJs.indexOf('window.confirm(');
    const emitIdx = settingsJs.indexOf('socket.emit("services switch", {"name" : "file"');

    if (surveyCheckIdx !== -1 && confirmIdx !== -1 && emitIdx !== -1) {
        if (surveyCheckIdx < confirmIdx && confirmIdx < emitIdx) {
            pass('settings.js: survey check, confirm, and emit in correct order');
        } else {
            fail('settings.js: survey check, confirm, and emit not in correct order');
        }
    } else {
        fail('settings.js: missing required patterns');
    }
}

console.log('RESULT: ' + passed + ' passed, ' + failed + ' failed');
process.exit(failed);
JSEOF

exit $?
