#!/bin/sh
# Mosquito Tattoo - edit recipe (Decision 18, edit spec v1)
# Turns <job>/process.mp4 + <job>/reveal.mp4 (+ optional <job>/hook.txt) into <job>/edited.mp4
# No hook.txt, or an empty one = no text on the video (Decision 20).
# Usage (inside the n8n container):  sh /scripts/edit.sh /files/jobs/<job id>
# Every setting below can be overridden by an environment variable of the same name
# (Workflow 2's Settings node passes them in).
set -eu

JOB="${1:?usage: sh /scripts/edit.sh /files/jobs/<job id>}"

# ---- settings (defaults = Decision 18) ----
OUT_W="${OUT_W:-1080}"            # output width
OUT_H="${OUT_H:-1920}"            # output height
FPS="${FPS:-30}"                  # output frame rate
PROC_TARGET="${PROC_TARGET:-13}"  # seconds the process clip is sped up to fill
REVEAL_MAX="${REVEAL_MAX:-7}"     # max seconds of reveal, real speed
XFADE="${XFADE:-0.3}"             # crossfade process -> reveal, seconds
HOOK_SECS="${HOOK_SECS:-3}"       # hook on screen for the first N seconds
HOOK_SIZE="${HOOK_SIZE:-84}"      # hook font size (px)
HOOK_BORDER="${HOOK_BORDER:-7}"   # black outline thickness (px)
LOGO_PCT="${LOGO_PCT:-14}"        # logo width, % of video width
LOGO_OPACITY="${LOGO_OPACITY:-0.85}"
LOGO_MARGIN="${LOGO_MARGIN:-40}"  # gap from the edges (px)
MUSIC="${MUSIC:-/files/assets/music/track1.mp3}"
MUSIC_START="${MUSIC_START:-0}"   # skip this many seconds of the track (quiet intros)
FADE_IN="${FADE_IN:-0.5}"         # music fade in, seconds
FADE_OUT="${FADE_OUT:-1}"         # music fade out, seconds
FONT="${FONT:-/files/assets/fonts/Cairo-Black.ttf}"
LOGO="${LOGO:-/files/assets/logo.png}"

PROC="$JOB/process.mp4"
REVEAL="$JOB/reveal.mp4"
HOOK="$JOB/hook.txt"
OUT="$JOB/edited.mp4"

for f in "$PROC" "$REVEAL" "$MUSIC" "$FONT" "$LOGO"; do
  [ -f "$f" ] || { echo "MISSING: $f" >&2; exit 1; }
done

dur() { ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1"; }
calc() { awk "BEGIN { printf \"%.3f\", $1 }"; }

PD=$(dur "$PROC")
RD=$(dur "$REVEAL")
SPEED=$(calc "($PD/$PROC_TARGET > 1) ? $PD/$PROC_TARGET : 1")   # never slow down
PLEN=$(calc "$PD/$SPEED")
RLEN=$(calc "($RD < $REVEAL_MAX) ? $RD : $REVEAL_MAX")
TOTAL=$(calc "$PLEN + $RLEN - $XFADE")
OFFSET=$(calc "$PLEN - $XFADE")
FO_START=$(calc "$TOTAL - $FADE_OUT")
HOOK_FADE=$(calc "$HOOK_SECS - 0.3")
LOGO_W=$(awk "BEGIN { w=int($OUT_W*$LOGO_PCT/100); if (w%2) w++; print w }")

# hook text only if hook.txt exists and has visible characters
if [ -f "$HOOK" ] && grep -q '[^[:space:]]' "$HOOK"; then
  HOOK_NOTE="hook on"
  TEXT="[v0]drawtext=fontfile=${FONT}:textfile=${HOOK}:expansion=none:text_shaping=1:\
fontsize=${HOOK_SIZE}:fontcolor=white:borderw=${HOOK_BORDER}:bordercolor=black:\
line_spacing=14:text_align=C:x=(w-text_w)/2:y=(h/6)-(text_h/2):\
enable='lt(t,${HOOK_SECS})':alpha='if(lt(t,${HOOK_FADE}),1,max(0,(${HOOK_SECS}-t)/0.3))'[v1]"
else
  HOOK_NOTE="no hook"
  TEXT="[v0]null[v1]"
fi

FIT="scale=${OUT_W}:${OUT_H}:force_original_aspect_ratio=increase,crop=${OUT_W}:${OUT_H},setsar=1"

FILTER="\
[0:v]setpts=(PTS-STARTPTS)/${SPEED},fps=${FPS},trim=duration=${PLEN},setpts=PTS-STARTPTS,${FIT},format=yuv420p[p];\
[1:v]fps=${FPS},trim=duration=${RLEN},setpts=PTS-STARTPTS,${FIT},format=yuv420p[r];\
[p][r]xfade=transition=fade:duration=${XFADE}:offset=${OFFSET}[v0];\
${TEXT};\
[2:v]scale=${LOGO_W}:-1,format=rgba,colorchannelmixer=aa=${LOGO_OPACITY}[lg];\
[v1][lg]overlay=W-w-${LOGO_MARGIN}:H-h-${LOGO_MARGIN},format=yuv420p[v];\
[3:a]atrim=duration=${TOTAL},asetpts=PTS-STARTPTS,aresample=48000,\
afade=t=in:d=${FADE_IN},afade=t=out:st=${FO_START}:d=${FADE_OUT}[a]"

echo "process ${PD}s -> sped up x${SPEED} -> ${PLEN}s | reveal ${RD}s -> ${RLEN}s | total ${TOTAL}s | ${HOOK_NOTE}"

ffmpeg -hide_banner -loglevel warning -y \
  -i "$PROC" -i "$REVEAL" -i "$LOGO" \
  -stream_loop -1 -ss "$MUSIC_START" -i "$MUSIC" \
  -filter_complex "$FILTER" -map "[v]" -map "[a]" \
  -c:v libx264 -preset medium -crf 20 -profile:v high -pix_fmt yuv420p -r "$FPS" \
  -c:a aac -b:a 192k -movflags +faststart -t "$TOTAL" "$OUT"

echo "DONE: $OUT"
ffprobe -v error -show_entries format=duration,size:stream=codec_name,width,height,r_frame_rate -of compact "$OUT"
