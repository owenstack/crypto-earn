#!/usr/bin/env bash

set -euo pipefail


# Dependency check and install
echo "Checking for required system libraries..."
MISSING_DEPS=()

# Check for sqlite3
if ! ldconfig -p | grep -q libsqlite3; then
	MISSING_DEPS+=(sqlite3)
fi

# Check for secp256k1
if ! ldconfig -p | grep -q libsecp256k1; then
	MISSING_DEPS+=(secp256k1)
fi

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
	echo "Missing dependencies: ${MISSING_DEPS[*]}"
	if [ -f /etc/debian_version ]; then
		sudo apt-get update
		for dep in "${MISSING_DEPS[@]}"; do
			case $dep in
				sqlite3)
					sudo apt-get install -y libsqlite3-dev
					;;
				secp256k1)
					# secp256k1 is not always in apt repos, so build from source if needed
					if ! apt-cache show libsecp256k1-dev >/dev/null 2>&1; then
						echo "libsecp256k1-dev not found in apt, building from source..."
						git clone https://github.com/bitcoin-core/secp256k1.git || true
						cd secp256k1
						./autogen.sh
						./configure
						make
						sudo make install
						cd ..
						rm -rf secp256k1
					else
						sudo apt-get install -y libsecp256k1-dev
					fi
					;;
			esac
		done
	elif [ -f /etc/redhat-release ]; then
		sudo dnf install -y sqlite-devel
		# Add secp256k1 build for RedHat/CentOS if needed
		if ! ldconfig -p | grep -q libsecp256k1; then
			git clone https://github.com/bitcoin-core/secp256k1.git || true
			cd secp256k1
			./autogen.sh
			./configure
			make
			sudo make install
			cd ..
			rm -rf secp256k1
		fi
	else
		echo "Unsupported OS. Please install sqlite3 and secp256k1 manually."
		exit 1
	fi
else
	echo "All required dependencies are present."
fi


echo "Building Zig engine..."
cd "$DIR/zig"
zig build -Doptimize=ReleaseFast

echo "Building TS control plane..."
cd "$DIR/ts"
bun install
bun run build

echo "Build complete."
