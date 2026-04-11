#!/bin/bash
# Ghost Engine: start - Sovereign Bridge (Unix)

echo -e "\n\033[0;36m[GHOST] Initializing Sovereign Bridge...\033[0m"

# 1. Check for Node.js
if ! command -v node &> /dev/null; then
    echo -e "\033[0;31m[ERROR] Node.js not found.\033[0m"
    exit 1
fi

# 2. Arch detection
ARCH_RAW=$(uname -m)
if [ "$ARCH_RAW" == "x86_64" ]; then
    ARCH="x86_64"
elif [ "$ARCH_RAW" == "arm64" ] || [ "$ARCH_RAW" == "aarch64" ]; then
    ARCH="arm64"
else
    ARCH=$ARCH_RAW
fi

PLATFORM="linux"
if [[ "$OSTYPE" == "darwin"* ]]; then
    PLATFORM="macos"
fi

BIN_PATH="../$ARCH/bin/ghost_pulse"

if [ ! -f "$BIN_PATH" ]; then
    echo -e "\033[0;33m[WARNING] Ghost Engine binary not found for $ARCH at: $BIN_PATH\033[0m"
    echo -e "\033[0;90m[INFO] Attempting to build engine via zig build...\033[0m"
    
    # Build from the Local Platform Silo
    PUSH_DIR=$(pwd)
    cd ..
    zig build -Doptimize=ReleaseFast
    cd "$PUSH_DIR"

    if [ ! -f "$BIN_PATH" ]; then
        echo -e "\033[0;31m[FATAL] Build failed.\033[0m"
        exit 1
    fi
fi

echo -e "\033[0;90m[INFO] Platform: $PLATFORM | Architecture: $ARCH\033[0m"
echo -e "\033[0;90m[INFO] Igniting Bridge Server...\033[0m"

# 3. Launch the Bridge Server
# We use a pattern to capture the LAUNCH_URL and open the browser
node server.js | while read line; do
    echo -e "\033[0;90m$line\033[0m"
    if [[ $line == *"LAUNCH_URL: "* ]]; then
        URL=$(echo $line | awk '{print $NF}')
        echo -e "\n\033[0;32m[SUCCESS] Sovereign UI online at $URL\033[0m"
        if command -v xdg-open &> /dev/null; then
            xdg-open "$URL"
        elif command -v open &> /dev/null; then
            open "$URL"
        fi
    fi
done
