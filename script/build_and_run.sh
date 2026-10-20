#!/bin/zsh
# Explicit developer run. build_app.py itself never starts or installs the app.
set -euo pipefail
task_root="${0:A:h:h}"
# Both editions monitor the same global keyboard. Do not start a second engine
# beside an existing switcher, including an already-running MacSwitcher build.
if /usr/bin/pgrep -x RuSwitcher >/dev/null; then
  print -u2 "Quit the running switcher before starting this development build."
  exit 2
fi
for task_argument in "$@"; do
  case "$task_argument" in
    --output|--output=*) print -u2 "Use build_app.py directly for a custom output path."; exit 2 ;;
  esac
done
/usr/bin/python3 "$task_root/script/build_app.py" "$@"
/usr/bin/open "$task_root/.сборки/MacSwitcher.app"
