#!/usr/bin/env bash
set -e

ENGINE_USER="cex-engine"
ENGINE_GROUP="cex-engine"
APP_DIR="/opt/cex-zig"
NOLOGIN_SHELL="$(command -v nologin || true)"
if [ -z "$NOLOGIN_SHELL" ]; then
  NOLOGIN_SHELL="/usr/sbin/nologin"
fi

echo "--- Installing Zig 0.15.2 ---"
curl -fsSL https://bun.sh/install | bash
export PATH="$HOME/.bun/bin:$PATH"
tar xf zig-linux-x86_64-0.15.2.tar.xz
sudo mv zig-linux-x86_64-0.15.2 /usr/local/zig
sudo ln -sf /usr/local/zig/zig /usr/local/bin/zig
zig version

echo "--- Installing Bun ---"
curl -fsSL https://bun.sh/install | bash
export PATH="$HOME/.bun/bin:$PATH"
bun --version

echo "--- Installing OS Deps ---"
if [ -f /etc/debian_version ]; then
  sudo apt-get update
  sudo apt-get install -y build-essential libsqlite3-dev
elif [ -f /etc/redhat-release ]; then
  sudo dnf groupinstall -y "Development Tools"
  sudo dnf install -y sqlite-devel
fi

echo "--- Creating unprivileged service account ---"
if ! getent group "$ENGINE_GROUP" >/dev/null; then
  sudo groupadd --system "$ENGINE_GROUP"
fi

if ! id -u "$ENGINE_USER" >/dev/null 2>&1; then
  sudo useradd \
    --system \
    --gid "$ENGINE_GROUP" \
    --home-dir /nonexistent \
    --shell "$NOLOGIN_SHELL" \
    --comment "CEX engine service user" \
    "$ENGINE_USER"
fi

# Enforce non-login shell even if account already exists.
sudo usermod --shell "$NOLOGIN_SHELL" "$ENGINE_USER"

if [ -d "$APP_DIR" ]; then
  echo "--- Fixing ownership for $APP_DIR ---"
  sudo chown -R "$ENGINE_USER:$ENGINE_GROUP" "$APP_DIR"
else
  echo "--- Skipping ownership fix: $APP_DIR does not exist yet ---"
fi

echo "--- Setup Complete ---"
