#!/bin/bash
# Keep-awake needs `pmset disablesleep`, which needs root. This installs /etc/sudoers.d/claude-touchbar
# so the app may run exactly those two commands without a password. Asks for an admin password once.
set -euo pipefail

RULE="/etc/sudoers.d/claude-touchbar"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
echo "$(id -un) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1" > "$TMP"
visudo -cf "$TMP" >/dev/null

CMD="/usr/bin/install -o root -g wheel -m 0440 '$TMP' '$RULE'"
if [ -t 0 ]; then
    sudo sh -c "$CMD"
else
    # no terminal to type a password into: use the GUI prompt
    osascript -e "do shell script \"$CMD\" with administrator privileges"
fi

sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null
echo "installed $RULE"
