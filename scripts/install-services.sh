#!/usr/bin/env bash
set -euo pipefail

# Systemd service installer for cex-zig

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
SYSTEMD_SRC="$DIR/systemd"
SYSTEMD_DEST="/etc/systemd/system"

RESTART=false
for arg in "$@"; do
  case "$arg" in
    --restart) RESTART=true ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

echo "==> Installing systemd service files"

for unit in "$SYSTEMD_SRC"/*.service; do
  [[ -f "$unit" ]] || continue
  name="$(basename "$unit")"
  echo "    COPY $name -> $SYSTEMD_DEST/$name"
  sudo cp "$unit" "$SYSTEMD_DEST/$name"
done

echo "==> Reloading systemd daemon"
sudo systemctl daemon-reload

echo "==> Enabling services"
sudo systemctl enable cex-engine.service
sudo systemctl enable cex-control.service
sudo systemctl enable cex-dry-run-monitor.service

if [[ "$RESTART" == true ]]; then
  echo "==> Restarting services"
  sudo systemctl restart cex-engine.service
  sudo systemctl restart cex-control.service
  sudo systemctl restart cex-dry-run-monitor.service
fi

echo "==> Service install complete."
