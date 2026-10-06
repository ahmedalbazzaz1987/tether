#!/bin/bash
# Builds the universal release zip for GitHub (build/Tether-macOS.zip) and installs it.
cd "$(dirname "$0")/mac"
{ echo "=== release build $(date) ==="; ./build.sh --release --install; echo "=== exit code: $? ==="; } 2>&1 | tee ../build.log
