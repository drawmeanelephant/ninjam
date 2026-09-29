#!/usr/bin/env python3
"""
Run a command fully detached from the calling shell.

The lab takes 10+ minutes per scenario, which is longer than a single
tool invocation, and both `nohup ... &` and `launchctl submit` proved
unreliable here: the first is reaped with the shell's process group, and
the second restarts the job when it exits, which wipes results that have
already been written.

Double-forking sidesteps both. The first fork returns immediately to the
caller; the child calls setsid() to get a new session and process group,
so a kill aimed at the caller's group cannot reach it. The second fork
orphans it to init. Output goes to the log file given by --log.

Usage:  run_detached.py --log FILE -- COMMAND [ARGS...]
"""

import os
import sys


def main(argv):
    if "--log" not in argv:
        sys.stderr.write(__doc__)
        return 2
    log = argv[argv.index("--log") + 1]
    argv = argv[argv.index("--log") + 2:]
    if not argv or argv[0] != "--":
        sys.stderr.write("expected: run_detached.py --log FILE -- COMMAND ...\n")
        return 2

    cmd = argv[1:]
    if os.fork() > 0:
        # first child: hand off to the grandchild and wait for the
        # immediate child to exit, which is as soon as it has forked.
        os.wait()
        return 0

    os.setsid()
    if os.fork() > 0:
        os._exit(0)

    # grandchild: reparented to init, own session, immune to the caller's
    # process-group teardown.
    fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    os.dup2(fd, 1)
    os.dup2(fd, 2)
    devnull = os.open(os.devnull, os.O_RDONLY)
    os.dup2(devnull, 0)
    os.close(fd)
    if devnull > 2:
        os.close(devnull)

    os.execvp(cmd[0], cmd)
    os._exit(127)  # exec failed


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
