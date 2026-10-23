"""Run a command in its own process group and kill the whole group on timeout or error.

When subprocess.run() times out it only kills the direct child process. If that
child has spawned its own children (e.g. pdp3 starting many programs and downloads),
those grandchildren become orphans and keep running. By starting the command in a
new session (its own process group) we can kill the entire group, ensuring no
orphan processes survive.

POSIX only. Standard library only. No logging side effects.
"""

import os
import signal
import subprocess
import time


def run_in_process_group(args, *, timeout, cwd=None, env=None, text=True,
                         capture_output=True, kill_grace_seconds=5.0):
    """Run a command in its own process group; kill the group on timeout or error.

    Args:
        args: Command and arguments (list or string).
        timeout: Seconds to wait before killing the group.
        cwd: Working directory for the command.
        env: Environment variables for the command.
        text: If True, decode stdout/stderr as text.
        capture_output: If True, capture stdout and stderr.
        kill_grace_seconds: Seconds to wait after SIGTERM before sending SIGKILL.

    Returns:
        subprocess.CompletedProcess with the command's return code and output.

    Raises:
        subprocess.TimeoutExpired: If the command times out (after killing the group).
        Any other exception raised by the command or during cleanup.
    """
    proc = subprocess.Popen(
        args,
        cwd=cwd,
        env=env,
        text=text,
        stdout=subprocess.PIPE if capture_output else None,
        stderr=subprocess.PIPE if capture_output else None,
        start_new_session=True,
    )

    try:
        stdout, stderr = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as first:
        _kill_group(proc.pid, kill_grace_seconds)
        stdout = None
        stderr = None
        try:
            stdout, stderr = proc.communicate()
        except (subprocess.TimeoutExpired, OSError):
            pass
        if stdout is None:
            stdout = first.output
        if stderr is None:
            stderr = first.stderr
        raise subprocess.TimeoutExpired(
            args, timeout, output=stdout, stderr=stderr
        ) from None
    except BaseException:
        _kill_group(proc.pid, kill_grace_seconds)
        raise
    else:
        _kill_group(proc.pid, kill_grace_seconds)

    return subprocess.CompletedProcess(args, proc.returncode, stdout, stderr)


def _kill_group(pgid, grace):
    """Kill an entire process group, escalating from SIGTERM to SIGKILL.

    Args:
        pgid: Process group ID (same as the child's PID when started with
              start_new_session=True).
        grace: Seconds to wait after SIGTERM before sending SIGKILL.
    """
    try:
        os.killpg(pgid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return

    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.1)

    try:
        os.killpg(pgid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
