#!/bin/sh
# Fetches miniaudio, the one-file audio library under the microphone and the speaker, at
# the release the console is built and tested against. One job: put miniaudio.h at
# console/ml/miniaudio/miniaudio.h. Re-running it replaces the file with the pinned one.
set -eu
TAG=0.11.25
SHA=ac7af4de748b7e26b777f37e01cee313a308a7296a3eb080e2906b320cc55c89
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$here/miniaudio"
out="$here/miniaudio/miniaudio.h"
curl -sSfL -o "$out.part" "https://raw.githubusercontent.com/mackron/miniaudio/$TAG/miniaudio.h"
got=$( (shasum -a 256 "$out.part" 2>/dev/null || sha256sum "$out.part") | cut -d' ' -f1)
if [ "$got" != "$SHA" ]; then
  rm -f "$out.part"; echo "miniaudio.h at $TAG is $got, not the pinned $SHA" >&2; exit 1
fi
mv "$out.part" "$out"
echo "miniaudio at $TAG"
