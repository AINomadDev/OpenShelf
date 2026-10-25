#!/bin/bash
set -euo pipefail
engine="$1"
remote="$2"
backend="$3"
if [ -n "${4:-}" ]; then export RCLONE_CONFIG="$4"; fi
printf '\nOpenShelf · Connect your storage\n\n'
if [ "$backend" = drive ]; then
  printf 'Google Drive opens a browser for sign-in.\nUse your own Google OAuth client ID when prompted.\nGuide: https://rclone.org/drive/#making-your-own-client-id\n\n'
elif [ "$backend" = iclouddrive ]; then
  printf 'iCloud Drive is experimental and uses Apple web sign-in.\nEnter your Apple ID password only in this Terminal, followed by 2FA.\nApp-specific passwords are not supported. Keep service set to drive.\nGuide: https://rclone.org/iclouddrive/\n\n'
fi
if [ "$backend" = iclouddrive ] && [ -n "${4:-}" ]; then
  "$engine" config create "$remote" "$backend" --all --no-output
elif "$engine" listremotes | /usr/bin/grep -Fxq "$remote:"; then
  "$engine" config reconnect "$remote:"
else
  "$engine" config create "$remote" "$backend" --all --no-output
fi
printf '\nConnection saved. Return to OpenShelf and click Open drive.\n'
