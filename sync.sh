#!/bin/bash
# Regenera macos/integration = upstream/main + patches.txt, y compila y prueba en macOS.
#
# Uso: .macos/sync.sh [--continue] [--no-build] [--no-test] [--push] [--jobs N]
#   --continue  tras resolver un conflicto y hacer `git commit`: sigue sin resetear la rama.
#   --no-build  solo merges.          --no-test  compila pero no corre ctest.
#   --push      sube macos/integration a origin (force) si todo terminó bien.
set -euo pipefail

UPSTREAM_REPO=boykopovar/AnyPS5
BRANCH=macos/integration

TOOLS="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TOOLS/.." && pwd)"
GIT_DIR_COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
LOGS="$TOOLS/logs"
STAMP="$(date +%Y%m%d-%H%M%S)"
JOBS="$(sysctl -n hw.ncpu)"

CONTINUE=0 BUILD=1 TEST=1 PUSH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --continue) CONTINUE=1 ;;
        --no-build) BUILD=0; TEST=0 ;;
        --no-test) TEST=0 ;;
        --push) PUSH=1 ;;
        --jobs) JOBS="$2"; shift ;;
        -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
        *) echo "Opción desconocida: $1" >&2; exit 64 ;;
    esac
    shift
done

mkdir -p "$LOGS"
SUMMARY="$LOGS/sync-$STAMP.txt"
say() { echo "$*" | tee -a "$SUMMARY"; }
g() { git -C "$ROOT" "$@"; }

if [ -n "$(g status --porcelain --untracked-files=no)" ] && [ $CONTINUE -eq 0 ]; then
    echo "Hay cambios sin commitear en $ROOT; guárdalos o descártalos antes de sincronizar." >&2
    exit 1
fi
if g rev-parse -q --verify MERGE_HEAD >/dev/null; then
    echo "Hay un merge a medias: resuelve los conflictos, haz 'git commit' y corre con --continue." >&2
    exit 1
fi

# rerere guarda las resoluciones en .git/rr-cache; se copian a .macos para que viajen con el fork.
mkdir -p "$TOOLS/rr-cache" "$GIT_DIR_COMMON/rr-cache"
rsync -a "$TOOLS/rr-cache/" "$GIT_DIR_COMMON/rr-cache/"

g fetch --quiet upstream main
UPSTREAM_SHA="$(g rev-parse --short upstream/main)"
say "upstream/main = $UPSTREAM_SHA ($(g log -1 --format=%ci upstream/main))"

if [ $CONTINUE -eq 0 ]; then
    if g rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null; then
        g update-ref "refs/macos/previous-integration" "refs/heads/$BRANCH"
    fi
    g switch --quiet -C "$BRANCH" upstream/main
else
    [ "$(g branch --show-current)" = "$BRANCH" ] || { echo "--continue requiere estar en $BRANCH" >&2; exit 1; }
fi

APPLIED="" SKIPPED="" STALE=""
while read -r kind name _; do
    case "$kind" in ''|\#*) continue ;; esac
    case "$kind" in
        pr)
            info="$(gh pr view "$name" -R "$UPSTREAM_REPO" --json state,title --jq '.state + "\t" + .title')"
            state="${info%%$'\t'*}" title="${info#*$'\t'}"
            if [ "$state" = MERGED ]; then STALE="$STALE #$name"; continue; fi
            if [ "$state" != OPEN ]; then SKIPPED="$SKIPPED #$name($state)"; continue; fi
            ref="refs/macos/pr/$name"
            g fetch --quiet upstream "+refs/pull/$name/head:$ref"
            label="#$name $title"
            ;;
        branch)
            ref="refs/heads/$name"
            g rev-parse -q --verify "$ref" >/dev/null || { echo "No existe la rama $name" >&2; exit 1; }
            label="$name"
            ;;
        *) echo "Entrada inválida en patches.txt: $kind $name" >&2; exit 1 ;;
    esac

    if g merge-base --is-ancestor "$ref" HEAD; then
        APPLIED="$APPLIED
  = $label"
        continue
    fi
    if ! out="$(g merge --quiet --no-ff --no-edit -m "macos: merge $label" "$ref" 2>&1)"; then
        conflicts="$(g diff --name-only --diff-filter=U)"
        if [ -z "$conflicts" ] && g rev-parse -q --verify MERGE_HEAD >/dev/null; then
            g commit --quiet --no-edit
            label="$label (conflicto resuelto por rerere)"
        else
            say "CONFLICTO al aplicar $label:"
            say "${conflicts:-$out}"
            say "Resuelve, 'git add' + 'git commit', y vuelve a correr: .macos/sync.sh --continue"
            exit 2
        fi
    fi
    APPLIED="$APPLIED
  + $label"
done < "$TOOLS/patches.txt"

rsync -a "$GIT_DIR_COMMON/rr-cache/" "$TOOLS/rr-cache/"

say "Aplicados:$APPLIED"
[ -z "$SKIPPED" ] || say "Saltados (no abiertos):$SKIPPED"
[ -z "$STALE" ] || say "Ya mergeados en upstream, quítalos de patches.txt:$STALE"

STATUS=0
if [ $BUILD -eq 1 ]; then
    g submodule update --init --recursive --depth 1 --jobs 8 >"$LOGS/submodules-$STAMP.log" 2>&1 \
        || g submodule update --init --recursive --jobs 8 >>"$LOGS/submodules-$STAMP.log" 2>&1
    if [ ! -f "$ROOT/build/build.ninja" ]; then
        cmake -S "$ROOT" -B "$ROOT/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON \
            >"$LOGS/configure-$STAMP.log" 2>&1 || { say "Falló la configuración: $LOGS/configure-$STAMP.log"; exit 3; }
    fi
    BUILD_LOG="$LOGS/build-$STAMP.log"
    if cmake --build "$ROOT/build" --parallel "$JOBS" -- -k 0 >"$BUILD_LOG" 2>&1 \
        && cmake --build "$ROOT/build" --target libs --parallel "$JOBS" >>"$BUILD_LOG" 2>&1; then
        say "Build OK"
    else
        STATUS=3
        say "Build con errores ($BUILD_LOG): $(grep -c '^FAILED' "$BUILD_LOG") objetos, $(grep -c ' error:' "$BUILD_LOG") errores"
        say "Por librería:"
        grep '^FAILED' "$BUILD_LOG" | sed -E 's#.*prx/([^/]+)/.*#\1#; s#.*CMakeFiles/([^/.]+)\.dir.*#\1#' \
            | sort | uniq -c | sort -rn | tee -a "$SUMMARY" || true
        say "Errores más frecuentes:"
        grep ' error:' "$BUILD_LOG" | sed -E 's/.* error: //' | sort | uniq -c | sort -rn | head -15 | tee -a "$SUMMARY" || true
        TEST=0
    fi
fi

if [ $TEST -eq 1 ]; then
    TEST_LOG="$LOGS/ctest-$STAMP.log"
    if ctest --test-dir "$ROOT/build" --output-on-failure -j "$JOBS" >"$TEST_LOG" 2>&1; then
        say "ctest: $(grep -E 'tests passed' "$TEST_LOG")"
    else
        STATUS=4
        say "ctest: $(grep -E 'tests passed|tests failed' "$TEST_LOG" | tail -1)"
        sed -n '/The following tests FAILED/,$p' "$TEST_LOG" | tee -a "$SUMMARY"
    fi
fi

if [ $PUSH -eq 1 ] && [ $STATUS -eq 0 ]; then
    g push --force origin "$BRANCH"
fi
say "Resumen: $SUMMARY"
exit $STATUS
