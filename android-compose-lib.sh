#!/usr/bin/env bash
# Video compositing arithmetic for multi-device recordings. Pure functions:
# they read device geometry from the arrays below, print a filter graph, and
# touch no device, no file and no clock. That is what makes the filter graph
# testable without ffmpeg, and it is why the geometry lives here instead of in
# android-demo.sh next to the segment pump.
#
# android-demo.sh sets, before sourcing this file:
#   DEVICE_COUNT      1 or 2
#   SCREEN_W_BY_DEV   indexed array of per-device pixel widths
#   SCREEN_H_BY_DEV   indexed array of per-device pixel heights
#   COMPOSE_HEIGHT    pane height for the composite, default 1080

# Pane width for one device at a common height. h264 with yuv420p needs even
# dimensions, and an odd pane width makes the encoder round silently, so round
# up here rather than discovering it as a one-pixel asymmetry between panes.
pane_width_for() {  # pane_width_for <screen_w> <screen_h> <height>
  awk -v sw="$1" -v sh="$2" -v h="$3" 'BEGIN {
    w = (sh > 0) ? (sw * h / sh) : h
    w = int(w)
    if (w % 2) w++
    if (w < 2) w = 2
    printf "%d", w
  }'
}

# Sets COMPOSE_W and COMPOSE_H for the whole composite. Every pane is the same
# height because hstack requires it; the output width is the sum of the pane
# widths. Two 1080x2400 phones at 1080 give 972x1080, which is a near-square
# frame: that is the honest consequence of putting two portrait screens side by
# side, and COMPOSE_HEIGHT is the knob for it.
build_compose_geometry() {  # build_compose_geometry <height>
  local h="$1" d i w=0
  h=$(( h - (h % 2) ))
  [ "$h" -ge 16 ] || h=16
  for ((d = 1; d <= DEVICE_COUNT; d++)); do
    i=$((d - 1))
    w=$(( w + $(pane_width_for "${SCREEN_W_BY_DEV[$i]}" "${SCREEN_H_BY_DEV[$i]}" "$h") ))
  done
  COMPOSE_W="$w"
  COMPOSE_H="$h"
}

# Prints the -filter_complex string for SEGMENT_COUNT segments.
#
# One device keeps the historical graph exactly: a plain temporal concat, no
# scaling, no hstack. Two devices get each segment's panes normalized to a
# common height, rebased, and joined with hstack, then the composites are
# concat in segment order.
#
# ffmpeg's -filter_complex is a list of chains separated by semicolons, and a
# label only names a chain's output: it never starts the next one. Every chain
# appended below therefore carries its own leading semicolon, but not the first,
# so the one-device branch above stays byte for byte what it always was.
#
# hstack needs no explicit padding for a pane that runs out early: it is
# framesync-based with repeatlast=1, so the last frame of the shorter input is
# held while the longer one finishes. Verified locally, 5s hstacked with 3s
# gives 5.000s with the shorter pane's final color still showing at t=4s. That
# is also the behavior we want: a device with nothing to show should idle
# visibly rather than vanish from the frame.
build_concat_filter() {  # build_concat_filter <segment_count>
  local seg_count="$1" s d i idx chain="" join pane_w h sep=""

  if [ "${DEVICE_COUNT:-1}" -le 1 ]; then
    for ((s = 0; s < seg_count; s++)); do
      chain="${chain}[${s}:v]"
    done
    chain="${chain}concat=n=${seg_count}:v=1:a=0[outvraw]"
    printf '%s;[outvraw]fps=30,format=yuv420p[outv]' "$chain"
    return 0
  fi

  build_compose_geometry "${COMPOSE_HEIGHT:-1080}"
  h="$COMPOSE_H"

  for ((s = 0; s < seg_count; s++)); do
    for ((d = 1; d <= DEVICE_COUNT; d++)); do
      i=$((d - 1))
      idx=$((s * DEVICE_COUNT + i))
      pane_w="$(pane_width_for "${SCREEN_W_BY_DEV[$i]}" "${SCREEN_H_BY_DEV[$i]}" "$h")"
      chain="${chain}${sep}[${idx}:v]scale=${pane_w}:${h}:force_original_aspect_ratio=decrease,pad=${pane_w}:${h}:(ow-iw)/2:(oh-ih)/2,setsar=1,setpts=PTS-STARTPTS,fps=30[s${s}d${d}]"
      sep=";"
    done
    join=""
    for ((d = 1; d <= DEVICE_COUNT; d++)); do
      join="${join}[s${s}d${d}]"
    done
    chain="${chain}${sep}${join}hstack=inputs=${DEVICE_COUNT}[s${s}h]"
    sep=";"
  done

  join=""
  for ((s = 0; s < seg_count; s++)); do
    join="${join}[s${s}h]"
  done
  chain="${chain}${sep}${join}concat=n=${seg_count}:v=1:a=0[outvraw]"
  printf '%s;[outvraw]fps=30,format=yuv420p[outv]' "$chain"
}
