#!/usr/bin/env bash
# Web interface in the foreground - the entry point for the Windows launcher.
#
# It exists for one reason: it takes NO arguments and its path has NO spaces.
# PowerShell's Start-Process joins the argument array with spaces and quotes
# nothing, so a composed command arrived at bash torn apart at the first space,
# with the rest landing in $0/$1. A single space-free path removes that trap.
export DSH_WEB_FOREGROUND=1
# Through `bash` rather than directly: the executable bit on start-web.sh may
# not survive a fresh clone, and the launch would fail with Permission denied.
exec bash "$HOME/Harness_AI/scripts/start-web.sh" "$HOME/Harness_AI"
