#!/bin/sh
# Key frames and speech of a video, for Claude to read (skill `video`): prints the folder they're in.
# Frames: the first one and each scene change (at most 20, 1280 px wide); too few changes (a static screen
# recording) → 8 evenly spaced. Speech: whisper-cli with the medium model, when the video has sound and both exist.
set -e
in="$1"
[ -f "$in" ] || { echo "no such file: $in" >&2; exit 1; }
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
out="${TMPDIR:-/tmp}/meepo-video-$(date +%s)-$$"
mkdir -p "$out/frames"
scale="scale='min(1280,iw)':-2"
ffmpeg -hide_banner -loglevel info -i "$in" -vf "select='eq(n\,0)+gt(scene\,0.25)',$scale,showinfo" -fps_mode vfr -frames:v 20 -q:v 3 \
  "$out/frames/%02d.jpg" 2> "$out/showinfo.txt" || true
count=$(ls "$out/frames" | wc -l | tr -d ' ')
if [ "$count" -lt 4 ]; then
  rm -f "$out/frames/"*.jpg
  duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$in")
  rate=$(awk -v d="$duration" 'BEGIN { if (d <= 0) d = 8; printf "%.6f", 8 / d }')
  ffmpeg -hide_banner -loglevel info -i "$in" -vf "fps=$rate,$scale,showinfo" -frames:v 8 -q:v 3 "$out/frames/%02d.jpg" 2> "$out/showinfo.txt"
fi
grep -o 'pts_time:[0-9.]*' "$out/showinfo.txt" | cut -d: -f2 | awk '{ printf "%02d.jpg %.1fs\n", NR, $1 }' > "$out/frames.txt"
model="$HOME/.cache/whisper/ggml-medium.bin"
if command -v whisper-cli >/dev/null && [ -f "$model" ] && ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$in" | grep -q .; then
  ffmpeg -v error -i "$in" -ar 16000 -ac 1 -c:a pcm_s16le "$out/audio.wav"
  whisper-cli -m "$model" -f "$out/audio.wav" -l auto -np 2>/dev/null | grep -v '^\s*$' > "$out/transcript.txt" || true
  [ -s "$out/transcript.txt" ] || rm -f "$out/transcript.txt"
  rm -f "$out/audio.wav"
fi
rm -f "$out/showinfo.txt"
echo "$out"
