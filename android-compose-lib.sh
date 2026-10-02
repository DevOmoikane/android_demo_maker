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

# One device unless the caller says otherwise. The driver always sets
# DEVICE_COUNT before sourcing this file, but the suite and any other caller may
# not, and an unbound variable is a worse answer than the one-device default.
device_count() { printf '%s' "${DEVICE_COUNT:-1}"; }

# The -i slot a (segment, device) pair occupies. compose_input_order below is
# this function's inverse, and build_concat_filter labels its panes with it, so
# the order the inputs are added in and the index each pane reads are the same
# fact stated twice rather than two independent opinions that happen to agree.
compose_input_index() {  # compose_input_index <segment> <device>
  printf '%s' "$(( $1 * $(device_count) + ($2 - 1) ))"
}

# Prints one "<segment> <device>" line per input, in the order the -i flags must
# be added: segment-major, every device inside its segment. The caller turns each
# line into a path, because the path depends on its work directory and the
# library has no business knowing one.
#
# The loops are driven by the index from compose_input_index and divided back
# out, so this enumerates exactly the slots that function names. Deriving the
# pair from the index rather than nesting two loops over segment and device is
# the point: a nested pair of loops is where a device-major order creeps in, and
# nothing in the graph would show it. ffmpeg accepts any pairing and renders a
# plausible frame, so a mismatch is invisible to anyone watching the output.
compose_input_order() {  # compose_input_order <segment_count>
  local seg_count="$1" dc n idx
  dc="$(device_count)"
  n=$(( seg_count * dc ))
  for ((idx = 0; idx < n; idx++)); do
    printf '%s %s\n' "$(( idx / dc ))" "$(( (idx % dc) + 1 ))"
  done
}

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
# side. The shape comes from the devices, not from COMPOSE_HEIGHT: a pane is as
# wide as its screen's aspect ratio makes it at that height, so every height
# keeps the same shape and only the resolution moves (488x540, 972x1080 and
# 1296x1440 are the same 0.9 frame at 540, 1080 and 1440).
build_compose_geometry() {  # build_compose_geometry <height>
  local h="$1" d i w=0
  h=$(( h - (h % 2) ))
  [ "$h" -ge 16 ] || h=16
  # One device is not composited: it passes through unscaled, so the output is
  # the device's own screen size, not a pane of it. The driver reads these to
  # report the output size, so they have to be right on this path too.
  if [ "$(device_count)" -le 1 ]; then
    COMPOSE_W="${SCREEN_W_BY_DEV[0]}"
    COMPOSE_H="${SCREEN_H_BY_DEV[0]}"
    return 0
  fi
  for ((d = 1; d <= $(device_count); d++)); do
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
#
# The input indices come from compose_input_index, which is the same arithmetic
# compose_input_order uses to hand the driver its -i list, so a pane cannot read
# a different recording than the one filed under that index.
build_concat_filter() {  # build_concat_filter <segment_count>
  local seg_count="$1" s d i idx chain="" join pane_w h sep="" dc

  dc="$(device_count)"

  if [ "$dc" -le 1 ]; then
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
    for ((d = 1; d <= dc; d++)); do
      i=$((d - 1))
      idx="$(compose_input_index "$s" "$d")"
      pane_w="$(pane_width_for "${SCREEN_W_BY_DEV[$i]}" "${SCREEN_H_BY_DEV[$i]}" "$h")"
      chain="${chain}${sep}[${idx}:v]scale=${pane_w}:${h}:force_original_aspect_ratio=decrease,pad=${pane_w}:${h}:(ow-iw)/2:(oh-ih)/2,setsar=1,setpts=PTS-STARTPTS,fps=30[s${s}d${d}]"
      sep=";"
    done
    join=""
    for ((d = 1; d <= dc; d++)); do
      join="${join}[s${s}d${d}]"
    done
    chain="${chain}${sep}${join}hstack=inputs=${dc}[s${s}h]"
    sep=";"
  done

  join=""
  for ((s = 0; s < seg_count; s++)); do
    join="${join}[s${s}h]"
  done
  chain="${chain}${sep}${join}concat=n=${seg_count}:v=1:a=0[outvraw]"
  printf '%s;[outvraw]fps=30,format=yuv420p[outv]' "$chain"
}
