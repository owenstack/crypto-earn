#!/usr/bin/env bash
set -euo pipefail

ENGINE_USER="cex-engine"
ENGINE_GROUP="cex-engine"
APP_DIR="/opt/cex-zig"
NOLOGIN_SHELL="$(command -v nologin || true)"
if [ -z "$NOLOGIN_SHELL" ]; then
  NOLOGIN_SHELL="/usr/sbin/nologin"
fi

echo "--- Installing Zig 0.15.2 ---"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)
    ZIG_ARCH="x86_64"
    ZIG_SHA256="02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239"
    ;;
  aarch64)
    ZIG_ARCH="aarch64"
    ZIG_SHA256="958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f"
    ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
ZIG_TARBALL="zig-${ZIG_ARCH}-linux-0.15.2.tar.xz"
ZIG_URL="https://ziglang.org/download/0.15.2/${ZIG_TARBALL}"

if ! curl -fsSL "$ZIG_URL" -o "$ZIG_TARBALL"; then
  echo "ERROR: Failed to download Zig from $ZIG_URL" >&2
  exit 1
fi

echo "${ZIG_SHA256}  ${ZIG_TARBALL}" | sha256sum --check || {
  echo "ERROR: Zig tarball checksum mismatch. Aborting." >&2
  rm -f "${ZIG_TARBALL}"
  exit 1
}

tar xf "$ZIG_TARBALL"
sudo rm -rf /usr/local/zig
sudo mv "zig-${ZIG_ARCH}-linux-0.15.2" /usr/local/zig
sudo ln -sf /usr/local/zig/zig /usr/local/bin/zig
rm -f "$ZIG_TARBALL"

echo "--- Installing Bun ---"
curl -fsSL https://bun.sh/install | bash
export PATH="$HOME/.bun/bin:$PATH"

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

echo "--- Verifying prerequisites ---"
fail=0
for cmd in zig bun sqlite3; do
  if command -v "$cmd" &>/dev/null; then
    echo "    OK   $cmd ($(command -v "$cmd"))"
  else
    echo "    FAIL $cmd not found" >&2
    fail=1
  fi
done
if [ "$fail" -ne 0 ]; then
  echo "ERROR: One or more prerequisites are missing. Check output above." >&2
  exit 1
fi

echo "--- Setup Complete ---"
