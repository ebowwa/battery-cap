#!/bin/bash
# run-validation-via-dialog.sh
# Zero-typing path: pops a GUI dialog on the Air for the i5 sudo password,
# then drives SSH via expect to feed it. Password never goes through argv
# or persists in shell history.

set -e

I5_PASS=$(osascript -e 'text returned of (display dialog "Enter i5 sudo password (user: i5-8gb):" default answer "" with hidden answer with title "battery-cap validation")' 2>/dev/null) || { echo "Dialog cancelled"; exit 130; }

if [ -z "$I5_PASS" ]; then
  echo "Empty password; aborting"
  exit 1
fi

export I5_PASS
expect <<'EOF'
set timeout 120
log_user 1
set pass_count 0
spawn ssh -t i5 sudo bash ~/validate.sh
expect {
  -re {[Pp]assword[:]} {
    incr pass_count
    if {$pass_count > 1} {
      puts "\nWrong password (sudo prompted twice); aborting to avoid lockout"
      exit 1
    }
    send "$env(I5_PASS)\r"
    exp_continue
  }
  eof
}
EOF

unset I5_PASS
