#!/bin/bash
# 수동으로 한 번 빌드하고 설치합니다. (자동화가 켜져 있으면 쓸 일이 없습니다.)
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
mkdir -p "$ROOT_DIR/Products"
"$ROOT_DIR/Scripts/build-and-install.sh" 2>&1 | tee "$ROOT_DIR/Products/last-build.log"
printf '\n아무 키나 누르면 창이 닫힙니다...'
read -r -n 1 -s
printf '\n'
