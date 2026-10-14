#!/usr/bin/env bash
# 打开讲解版波形： bash teach/view.sh [名字，默认 teach_alu]
NAME="${1:-teach_alu}"
DIR="$(cd "$(dirname "$0")" && pwd)/wave"
cd "$DIR" || exit 1
exec gtkwave "$NAME.gtkw"
