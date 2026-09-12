#!/bin/sh
# Ships the console as one .love: the tree's Lua with console/main.lua and conf.lua at the
# archive's root, so `love build/malleable.love --agent a.feature --root D` opens to an
# agent. The ML models and the engine's native library stay on disk; a shipped console
# speaks only with console/ml beside it (console/main.lua says how it finds the tree).
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
out="$here/build"
mkdir -p "$out"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp "$here/console/main.lua" "$here/console/conf.lua" "$stage/"
mkdir -p "$stage/console/lib" "$stage/console/ml" "$stage/console/agents" "$stage/src/provider" "$stage/bin"
cp "$here"/console/lib/*.lua "$stage/console/lib/"
cp "$here"/console/ml/*.lua "$stage/console/ml/"
cp "$here"/console/agents/*.feature "$stage/console/agents/"
cp "$here"/src/*.lua "$stage/src/"
cp "$here"/src/provider/*.lua "$stage/src/provider/"
cp "$here"/bin/*.lua "$stage/bin/"
cp "$here/agent.lua" "$stage/"
rm -f "$out/malleable.love"
(cd "$stage" && zip -q -r "$out/malleable.love" .)
ls -l "$out/malleable.love"
