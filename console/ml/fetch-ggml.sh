#!/bin/sh
# Fetches ggml, the tensor engine under console/ml, at the commit the console is built and
# tested against. One job: put ggml at console/ml/ggml. Re-running it moves it to the pin.
set -eu
PIN=7840aaba1989c6deeefede1d77d5aaf8f52b947e
here=$(cd "$(dirname "$0")" && pwd)
if [ ! -d "$here/ggml/.git" ]; then
  git clone --quiet https://github.com/ggml-org/ggml.git "$here/ggml"
fi
git -C "$here/ggml" fetch --quiet --depth 1 origin "$PIN" 2>/dev/null || git -C "$here/ggml" fetch --quiet origin
git -C "$here/ggml" checkout --quiet "$PIN"
echo "ggml at $PIN"
