#!/bin/bash
cd "$(dirname "$0")/mac"
{ echo "=== build started $(date) ==="; ./build.sh --install; echo "=== exit code: $? ==="; } 2>&1 | tee ../build.log
