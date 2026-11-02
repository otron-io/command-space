#!/bin/zsh
# Rebuild README media from the real SwiftUI views. Requires ffmpeg; no screen recording.
# Optional argument: a directory for intermediate captures (otherwise mktemp uses TMPDIR).
set -euo pipefail
REPO="${0:A:h:h}"
CAPTURE="${1:-$(mktemp -d)}"
OUT="$REPO/docs/media"
command -v ffmpeg >/dev/null
mkdir -p "$CAPTURE" "$OUT"
swift build --package-path "$REPO"
"$REPO/.build/debug/CommandSpace" --capture-readme "$CAPTURE"

# One global palette per animation keeps gradients and text consistent between frames.
PALETTE='split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle'
ffmpeg -hide_banner -loglevel error -y -framerate 20 -i "$CAPTURE/logo-frames/%04d.png" \
  -filter_complex "$PALETTE" -loop 0 "$OUT/command-space.gif"
ffmpeg -hide_banner -loglevel error -y -framerate 15 -i "$CAPTURE/panel-frames/%04d.png" \
  -filter_complex "crop=960:440:0:0,$PALETTE" -loop 0 "$OUT/in-action.gif"
cp "$CAPTURE/command-space.png" "$OUT/command-space.png"
for name in app-search conversions calculator instant-actions screen-intelligence image-paste; do
  ffmpeg -hide_banner -loglevel error -y -i "$CAPTURE/$name.png" -vf 'crop=960:440:0:0' \
    -frames:v 1 -update 1 -compression_level 9 "$OUT/$name.png"
done
echo "README media written to $OUT; intermediate frames kept at $CAPTURE"
