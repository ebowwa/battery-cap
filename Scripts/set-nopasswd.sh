#!/bin/bash
# set-nopasswd.sh - one-shot: install NOPASSWD for the invoking user.
# Run via:  sudo bash ~/set-nopasswd.sh
# Idempotent: re-running just overwrites with the same content.
set -e

USER_NAME="${SUDO_USER:-$(whoami)}"
FILE="/etc/sudoers.d/${USER_NAME}-nopasswd"

echo "${USER_NAME} ALL=(ALL) NOPASSWD: ALL" > "$FILE"
chmod 0440 "$FILE"
visudo -cf "$FILE"

echo ""
echo "NOPASSWD installed for ${USER_NAME} at ${FILE}"
echo "Verify: ssh i5 'sudo -n true && echo OK'"
