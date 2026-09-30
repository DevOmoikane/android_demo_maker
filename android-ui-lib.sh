# Shared adb/uiautomator driving primitives for driving an Android app's UI
# over adb. Sourced by android-demo.sh (narrated recording) and
# android-spec-test.sh (fast unattended assertions) so both drive the UI the
# exact same way and only diverge in what they do with the result (record+
# narrate vs assert+report). assert_signed_in() is an app-specific convenience
# checking common bottom-nav destinations; redefine it per app as needed.
#
# Callers must define, before sourcing this file:
#   ADB()               function/alias: adb -s "$SERIAL" "$@"
#   WORKDIR             scratch dir (this file writes $WORKDIR/dump.xml)
#   SCREEN_W, SCREEN_H  device pixel dimensions (only find_and_tap_after_scrolling needs them)

# Dumps the live hierarchy fresh before every lookup - this is not a hot loop, so the
# ~300ms dump cost per lookup is a non-issue and it's the only way to stay correct as
# screens actually change between steps.
dump_ui() {
  ADB shell uiautomator dump /sdcard/_android_demo_dump.xml >/dev/null 2>&1 || true
  ADB pull /sdcard/_android_demo_dump.xml "$WORKDIR/dump.xml" >/dev/null 2>&1 || true
}

# center_from_bounds "[x1,y1][x2,y2]" -> "cx cy"
center_from_bounds() {
  local nums
  nums="$(printf '%s' "$1" | grep -o '[0-9]\+')"
  # shellcheck disable=SC2206
  local arr=($nums)
  echo "$(( (arr[0] + arr[2]) / 2 )) $(( (arr[1] + arr[3]) / 2 ))"
}

# uiautomator's XML dump is not reliably one-node-per-line, so a match on
# "text=..." piped into a separate "bounds=..." grep can pick up a DIFFERENT
# element's bounds (commonly the root layout's, since it sorts first). Every
# lookup below keeps text/desc and bounds in one grep -o pattern scoped by
# [^>]*, which cannot cross into the next tag's '>' - that keeps the match
# inside a single element regardless of how the dump is laid out on disk.

# poll_bounds <extractor-fn> <args...> - calls extractor-fn (which dumps the
# UI and echoes bounds, or nothing) up to POLL_MAX_ATTEMPTS times (default 25),
# POLL_INTERVAL_SECONDS apart (default 0.8s, so ~20s total). A step right after
# a screen transition can fire before network-backed content finishes loading
# - this covers that race instead of every caller needing its own guess at
# settle time. Override the two env vars (unset them again after) for a call
# site that genuinely needs to outlast a slow real backend call, e.g. a live
# AI agent reply that can take tens of seconds - don't just raise the default,
# every ordinary find-and-tap lookup would then wait needlessly long to fail.
poll_bounds() {
  local fn="$1" bounds attempt max="${POLL_MAX_ATTEMPTS:-25}" interval="${POLL_INTERVAL_SECONDS:-0.8}"
  shift
  for attempt in $(seq 1 "$max"); do
    bounds="$("$fn" "$@")"
    [ -n "$bounds" ] && { printf '%s' "$bounds"; return 0; }
    sleep "$interval"
  done
  return 0
}

_bounds_for_text() {
  local text="$1" nth="${2:-1}"
  dump_ui
  grep -o "text=\"${text}\"[^>]*bounds=\"[^\"]*\"" "$WORKDIR/dump.xml" | sed -n "${nth}p" | grep -o 'bounds="[^"]*"' || true
}

_bounds_for_contains() {
  local sub="$1" nth="${2:-1}" match val match_count=0 bounds=""
  dump_ui
  while IFS= read -r match; do
    val="$(printf '%s' "$match" | sed -n 's/^text="\([^"]*\)".*/\1/p')"
    case "$val" in
      *"$sub"*)
        match_count=$((match_count + 1))
        if [ "$match_count" -eq "$nth" ]; then
          bounds="$(printf '%s' "$match" | grep -o 'bounds="[^"]*"')"
          break
        fi
        ;;
    esac
  done < <(grep -o 'text="[^"]*"[^>]*bounds="[^"]*"' "$WORKDIR/dump.xml" || true)
  printf '%s' "$bounds"
}

_bounds_for_desc() {
  local desc="$1" nth="${2:-1}"
  dump_ui
  grep -o "content-desc=\"${desc}\"[^>]*bounds=\"[^\"]*\"" "$WORKDIR/dump.xml" | sed -n "${nth}p" | grep -o 'bounds="[^"]*"' || true
}

# Substring match on content-desc, same shape as _bounds_for_contains but for desc -
# needed for e.g. "Companion said: ..." where the suffix (the reply text) isn't known
# ahead of time.
_bounds_for_desc_contains() {
  local sub="$1" nth="${2:-1}" match val match_count=0 bounds=""
  dump_ui
  while IFS= read -r match; do
    val="$(printf '%s' "$match" | sed -n 's/^content-desc="\([^"]*\)".*/\1/p')"
    case "$val" in
      *"$sub"*)
        match_count=$((match_count + 1))
        if [ "$match_count" -eq "$nth" ]; then
          bounds="$(printf '%s' "$match" | grep -o 'bounds="[^"]*"')"
          break
        fi
        ;;
    esac
  done < <(grep -o 'content-desc="[^"]*"[^>]*bounds="[^"]*"' "$WORKDIR/dump.xml" || true)
  printf '%s' "$bounds"
}

# find_and_tap_after_scrolling <substring> <max_swipes> [nth] - swipes up
# repeatedly (up to max_swipes) until the given text is found, then taps it.
# For feed-style screens where accumulated content pushes a target an
# unpredictable distance below the fold.
find_and_tap_after_scrolling() {
  local sub="$1" max="${2:-6}" nth="${3:-1}" bounds cx y1 y2 i
  cx=$(( SCREEN_W / 2 )); y1=$(( SCREEN_H * 70 / 100 )); y2=$(( SCREEN_H * 30 / 100 ))
  for i in $(seq 1 "$max"); do
    bounds="$(_bounds_for_contains "$sub" "$nth")"
    [ -n "$bounds" ] && break
    ADB shell input swipe "$cx" "$y1" "$cx" "$y2" 400
    sleep 0.6
  done
  [ -n "$bounds" ] || { echo "ERROR: no element with text containing \"$sub\" (nth=$nth) found after scrolling" >&2; return 1; }
  ADB shell input tap $(center_from_bounds "$bounds")
}

# tap_until_gone <tap-text> <watch-for-text> [max_attempts] [interval_seconds]
# - taps tap-text repeatedly, re-dumping and waiting interval_seconds between
# attempts, until watch-for-text is no longer present on screen (meaning the
# app moved on). For a real-world event with unpredictable latency (an email
# arriving) that no fixed pre-tap buffer can reliably cover.
tap_until_gone() {
  local tap_text="$1" watch_text="$2" max="${3:-15}" interval="${4:-3}" i bounds
  for i in $(seq 1 "$max"); do
    dump_ui
    grep -qF "text=\"${watch_text}\"" "$WORKDIR/dump.xml" || return 0
    bounds="$(grep -o "text=\"${tap_text}\"[^>]*bounds=\"[^\"]*\"" "$WORKDIR/dump.xml" | head -1 | grep -o 'bounds="[^"]*"')"
    [ -n "$bounds" ] && ADB shell input tap $(center_from_bounds "$bounds")
    sleep "$interval"
  done
  dump_ui
  if grep -qF "text=\"${watch_text}\"" "$WORKDIR/dump.xml"; then
    echo "ERROR: still on screen with \"$watch_text\" after $max attempts tapping \"$tap_text\"" >&2
    return 1
  fi
  return 0
}

# wait_gone <watch-for-text> [max_attempts] [interval_seconds] - same wait as
# tap_until_gone but without tapping anything in between. For a reply that
# arrives on its own once the backend responds (e.g. AI Chat's "Companion is
# thinking" indicator) rather than needing a repeated tap to progress.
wait_gone() {
  local watch_text="$1" max="${2:-20}" interval="${3:-3}" i
  for i in $(seq 1 "$max"); do
    dump_ui
    grep -qF "text=\"${watch_text}\"" "$WORKDIR/dump.xml" || return 0
    sleep "$interval"
  done
  dump_ui
  if grep -qF "text=\"${watch_text}\"" "$WORKDIR/dump.xml"; then
    echo "ERROR: still on screen with \"$watch_text\" after $max attempts (${interval}s apart)" >&2
    return 1
  fi
  return 0
}

# find_and_tap_text <exact text> [nth]
find_and_tap_text() {
  local text="$1" nth="${2:-1}" bounds
  bounds="$(poll_bounds _bounds_for_text "$text" "$nth")"
  [ -n "$bounds" ] || { echo "ERROR: no element with text=\"$text\" (nth=$nth) found on screen" >&2; return 1; }
  ADB shell input tap $(center_from_bounds "$bounds")
}

# find_and_tap_contains <substring> [nth]
find_and_tap_contains() {
  local sub="$1" nth="${2:-1}" bounds
  bounds="$(poll_bounds _bounds_for_contains "$sub" "$nth")"
  [ -n "$bounds" ] || { echo "ERROR: no element with text containing \"$sub\" (nth=$nth) found on screen" >&2; return 1; }
  ADB shell input tap $(center_from_bounds "$bounds")
}

# find_and_tap_left_of_contains <substring> <offset_x> [nth] - for controls (like
# a checkbox) that sit to the left of a text label with no text/desc of their
# own. Anchoring on the label's own bounds instead of a hardcoded coordinate
# means the tap still lands correctly if the label's position shifts.
find_and_tap_left_of_contains() {
  local sub="$1" offset_x="$2" nth="${3:-1}" bounds nums x1 y1 y2
  bounds="$(poll_bounds _bounds_for_contains "$sub" "$nth")"
  [ -n "$bounds" ] || { echo "ERROR: no element with text containing \"$sub\" (nth=$nth) found on screen" >&2; return 1; }
  nums="$(printf '%s' "$bounds" | grep -o '[0-9]\+')"
  # shellcheck disable=SC2206
  local arr=($nums)
  x1="${arr[0]}"; y1="${arr[1]}"; y2="${arr[3]}"
  ADB shell input tap $(( x1 - offset_x )) $(( (y1 + y2) / 2 ))
}

# find_and_swipe_up_from_contains <substring> <delta_y> [nth] - scrolls a
# clipped scroll container by swiping up starting from a text label's own
# position, so the swipe still lands inside the scrollable area even if the
# form's layout shifts.
find_and_swipe_up_from_contains() {
  find_and_swipe_direction "$1" up "${2:-500}" "${3:-1}"
}

# find_and_swipe_direction <substring> <direction> <delta> [nth] - swipe
# starting at a matched element's own center, moving delta pixels in
# direction (up/down/left/right). Anchoring on the element instead of raw
# screen coordinates keeps the gesture inside the right container (an inner
# pager vs the outer feed, say) even if the layout shifts.
find_and_swipe_direction() {
  local sub="$1" dir="$2" delta="$3" nth="${4:-1}" bounds nums x1 y1 x2 y2 cx cy ex ey
  case "$dir" in
    up|down|left|right) ;;
    *) echo "ERROR: invalid swipe_element direction '$dir' (expected up, down, left, or right)" >&2; return 2 ;;
  esac
  bounds="$(poll_bounds _bounds_for_contains "$sub" "$nth")"
  [ -n "$bounds" ] || { echo "ERROR: no element with text containing \"$sub\" (nth=$nth) found on screen to swipe from" >&2; return 1; }
  nums="$(printf '%s' "$bounds" | grep -o '[0-9]\+')"
  # shellcheck disable=SC2206
  local arr=($nums)
  x1="${arr[0]}"; y1="${arr[1]}"; x2="${arr[2]}"; y2="${arr[3]}"
  cx=$(( (x1 + x2) / 2 )); cy=$(( (y1 + y2) / 2 ))
  case "$dir" in
    up)    ex="$cx";             ey=$(( cy - delta )) ;;
    down)  ex="$cx";             ey=$(( cy + delta )) ;;
    left)  ex=$(( cx - delta )); ey="$cy" ;;
    right) ex=$(( cx + delta )); ey="$cy" ;;
  esac
  ADB shell input swipe "$cx" "$cy" "$ex" "$ey" 300
}

# find_and_long_press <mode> <value> [nth] [duration_ms] - press-and-hold on
# an element located by mode: text (exact), contains (substring of text), or
# desc (exact content-desc). input(1) has no dedicated long-press command; a
# zero-distance swipe held longer than the framework's ~500ms long-click
# timeout is how a press-and-hold is expressed over adb.
find_and_long_press() {
  local mode="$1" value="$2" nth="${3:-1}" dur="${4:-1000}" bounds cx cy
  case "$mode" in
    text)     bounds="$(poll_bounds _bounds_for_text "$value" "$nth")" ;;
    contains) bounds="$(poll_bounds _bounds_for_contains "$value" "$nth")" ;;
    desc)     bounds="$(poll_bounds _bounds_for_desc "$value" "$nth")" ;;
  esac
  [ -n "$bounds" ] || { echo "ERROR: no element found for long_press (${mode}=\"${value}\", nth=$nth)" >&2; return 1; }
  read -r cx cy <<<"$(center_from_bounds "$bounds")"
  ADB shell input swipe "$cx" "$cy" "$cx" "$cy" "$dur"
}

# find_and_double_tap <mode> <value> [nth] - double-taps an element located by
# mode (text/contains/desc). Both taps are issued inside ONE on-device shell
# command; two separate adb invocations would leave a gap between taps wider
# than most apps' double-tap window.
find_and_double_tap() {
  local mode="$1" value="$2" nth="${3:-1}" bounds cx cy
  case "$mode" in
    text)     bounds="$(poll_bounds _bounds_for_text "$value" "$nth")" ;;
    contains) bounds="$(poll_bounds _bounds_for_contains "$value" "$nth")" ;;
    desc)     bounds="$(poll_bounds _bounds_for_desc "$value" "$nth")" ;;
  esac
  [ -n "$bounds" ] || { echo "ERROR: no element found for double_tap (${mode}=\"${value}\", nth=$nth)" >&2; return 1; }
  read -r cx cy <<<"$(center_from_bounds "$bounds")"
  ADB shell "input tap $cx $cy && input tap $cx $cy"
}

# find_and_drag <from-mode> <from-value> <from-nth> <to-mode> <to-value>
#               <to-nth> [duration_ms]
# Drags one element onto another: source located by from-mode (text/contains/
# desc), drop target by to-mode (same three, or "point" with to-value "X Y"
# for a raw coordinate drop zone like an unlabeled trash target).
find_and_drag() {
  local from_mode="$1" from_value="$2" from_nth="${3:-1}" \
        to_mode="$4" to_value="$5" to_nth="${6:-1}" dur="${7:-800}"
  local fbounds tbounds fx fy tx ty dnd_out dnd_ok=1
  case "$from_mode" in
    text)     fbounds="$(poll_bounds _bounds_for_text "$from_value" "$from_nth")" ;;
    contains) fbounds="$(poll_bounds _bounds_for_contains "$from_value" "$from_nth")" ;;
    desc)     fbounds="$(poll_bounds _bounds_for_desc "$from_value" "$from_nth")" ;;
  esac
  [ -n "$fbounds" ] || { echo "ERROR: no element found to drag (${from_mode}=\"${from_value}\", nth=$from_nth)" >&2; return 1; }
  read -r fx fy <<<"$(center_from_bounds "$fbounds")"
  case "$to_mode" in
    text)     tbounds="$(poll_bounds _bounds_for_text "$to_value" "$to_nth")" ;;
    contains) tbounds="$(poll_bounds _bounds_for_contains "$to_value" "$to_nth")" ;;
    desc)     tbounds="$(poll_bounds _bounds_for_desc "$to_value" "$to_nth")" ;;
    point)    tbounds="" ; tx="${to_value% *}"; ty="${to_value#* }" ;;
  esac
  if [ "$to_mode" != "point" ]; then
    [ -n "$tbounds" ] || { echo "ERROR: no drop target found (${to_mode}=\"${to_value}\", nth=$to_nth)" >&2; return 1; }
    read -r tx ty <<<"$(center_from_bounds "$tbounds")"
  fi
  # draganddrop (API 24+) sends real drag-start/drop events that some drag
  # targets require to accept the drop; fall back to a slow swipe where the
  # subcommand doesn't exist (older devices print a usage error).
  dnd_out="$(ADB shell input draganddrop "$fx" "$fy" "$tx" "$ty" "$dur" 2>&1)" || dnd_ok=0
  case "$dnd_out" in *usage:*|*Usage:*|*"unknown command"*) dnd_ok=0 ;; esac
  if [ "$dnd_ok" = 0 ]; then
    ADB shell input swipe "$fx" "$fy" "$tx" "$ty" "$dur"
  fi
}

# find_and_tap_desc <exact content-desc> [nth]
find_and_tap_desc() {
  local desc="$1" nth="${2:-1}" bounds
  bounds="$(poll_bounds _bounds_for_desc "$desc" "$nth")"
  [ -n "$bounds" ] || { echo "ERROR: no element with content-desc=\"$desc\" (nth=$nth) found on screen" >&2; return 1; }
  ADB shell input tap $(center_from_bounds "$bounds")
}

# find_and_tap_desc_contains <substring> [nth] - for a content-desc that includes
# a variable suffix (e.g. "Notifications, 20 unread" where the count changes),
# so an exact-match tap_desc can't reliably target it.
find_and_tap_desc_contains() {
  local sub="$1" nth="${2:-1}" bounds
  bounds="$(poll_bounds _bounds_for_desc_contains "$sub" "$nth")"
  [ -n "$bounds" ] || { echo "ERROR: no element with content-desc containing \"$sub\" (nth=$nth) found on screen" >&2; return 1; }
  ADB shell input tap $(center_from_bounds "$bounds")
}

# _checked_for_text/_checked_for_desc <exact text/desc> [nth] -> "true"/"false"
# (empty if not found). Reads the SAME node's own checked="..." attribute --
# correct for the common Compose pattern of a toggle row built with
# Modifier.semantics(mergeDescendants = true) { contentDescription = label },
# where the label and the Switch's checked state land on one merged node. A
# Switch left un-merged from its label needs a different selector, not this.
_checked_for_text() {
  local text="$1" nth="${2:-1}"
  dump_ui
  grep -o "text=\"${text}\"[^>]*checked=\"[^\"]*\"" "$WORKDIR/dump.xml" | sed -n "${nth}p" | sed -n 's/.*checked="\([^"]*\)".*/\1/p'
}

_checked_for_desc() {
  local desc="$1" nth="${2:-1}"
  dump_ui
  grep -o "content-desc=\"${desc}\"[^>]*checked=\"[^\"]*\"" "$WORKDIR/dump.xml" | sed -n "${nth}p" | sed -n 's/.*checked="\([^"]*\)".*/\1/p'
}

assert_signed_in() {
  dump_ui
  if grep -qF 'content-desc="Settings"' "$WORKDIR/dump.xml" || grep -qF 'content-desc="Family"' "$WORKDIR/dump.xml"; then
    return 0
  fi
  echo "ERROR: app doesn't look signed in (no Home/Family/Settings nav found)." >&2
  return 1
}

# substitute_templates <raw> -> expands {{TIMESTAMP}} and {{ENV:NAME}} tokens.
# One {{TIMESTAMP}} per call (not per script run) so two typed fields in the
# same step never disagree, but repeat steps across a run still get fresh
# values. Errors out on an unset env var rather than typing the literal token
# into a form field.
substitute_templates() {
  local raw="$1" ts name value
  ts="$(date +%s)"
  raw="${raw//\{\{TIMESTAMP\}\}/$ts}"
  while [[ "$raw" =~ \{\{ENV:([A-Za-z_][A-Za-z0-9_]*)\}\} ]]; do
    name="${BASH_REMATCH[1]}"
    value="${!name:-}"
    [ -n "$value" ] || { echo "ERROR: {{ENV:${name}}} used but $name is not set/exported" >&2; return 1; }
    raw="${raw/\{\{ENV:${name}\}\}/$value}"
  done
  printf '%s' "$raw"
}

# maybe_type <step-json> - if the step has a "type" field, substitute
# templates and type it into whatever field the preceding tap just focused.
maybe_type() {
  local step="$1" raw value
  raw="$(jq -r '.type // empty' <<<"$step")"
  [ -n "$raw" ] || return 0
  value="$(substitute_templates "$raw")" || return 1
  # Compose takes a frame or two to move focus into the field the tap just hit,
  # and `input text` sent inside that window loses its first character
  # (observed on a Pixel 6 Pro: the login email field received "srael+..." for
  # "israel+...", so the whole scenario failed on a bogus login error). One
  # short settle here covers every caller (tap_text/tap_contains/tap_desc/tap_xy).
  sleep "${TYPE_FOCUS_SETTLE_SECONDS:-0.4}"
  ADB shell input text "$value"
}

# ---- exec / if: host-side scripting and branching --------------------------
# Ported from /Users/israel/dev/omoikane/android_demo_maker/android-demo.sh
# (bash parts only), which is the general, app-agnostic version of this same
# driving tool. Kept here, not duplicated per-caller script, so android-demo.sh
# and android-spec-test.sh branch identically.

# xml_unescape <s> - decodes the handful of entities uiautomator's XML dump
# actually produces (&amp; &lt; &gt; &quot; &apos;/&#39;) so if-step string
# compares see the text the user sees. &amp; must be decoded last so a
# literal "&amp;" typed on screen doesn't double-decode.
xml_unescape() {
  local s="$1" q="'"
  s="${s//&quot;/\"}"
  s="${s//&lt;/<}"
  s="${s//&gt;/>}"
  s="${s//&apos;/$q}"
  s="${s//&#39;/$q}"
  s="${s//&amp;/&}"
  printf '%s' "$s"
}

# find_text_value <sub> <nth> <mode> - scans one fresh UI dump for the nth
# element whose text attribute equals (mode=exact) or contains
# (mode=contains) sub. On success sets TEXT_VALUE (unescaped) and
# TEXT_BOUNDS and returns 0; returns 1 when there is no match this round.
TEXT_VALUE=""
TEXT_BOUNDS=""
find_text_value() {
  local sub="$1" nth="${2:-1}" mode="${3:-contains}"
  local match val match_count=0
  dump_ui
  while IFS= read -r match; do
    val="$(printf '%s' "$match" | sed -n 's/^text="\([^"]*\)".*/\1/p')"
    if [ "$mode" = "exact" ]; then
      [ "$val" = "$sub" ] || continue
    else
      case "$val" in *"$sub"*) ;; *) continue ;; esac
    fi
    match_count=$((match_count + 1))
    if [ "$match_count" -eq "$nth" ]; then
      TEXT_BOUNDS="$(printf '%s' "$match" | grep -o 'bounds="[^"]*"')" || true
      TEXT_VALUE="$(xml_unescape "$val")"
      return 0
    fi
  done < <(grep -o 'text="[^"]*"[^>]*bounds="[^"]*"' "$WORKDIR/dump.xml" || true)
  return 1
}

# screen_condition_met <if-step> - polls the live UI for up to
# timeout_seconds for the step's text (contains/exact), then applies any
# extra equals/matches constraints against the found element's full text.
# Returns 0 when the condition holds, 1 when it does not, 2 on a malformed
# step (missing text, bad mode).
screen_condition_met() {
  local step="$1" sub mode nth timeout deadline want
  sub="$(jq -r '.text // empty' <<<"$step")"
  [ -n "$sub" ] || { echo "ERROR: if/source=screen requires \"text\"" >&2; return 2; }
  mode="$(jq -r '.text_match // "contains"' <<<"$step")"
  case "$mode" in contains|exact) ;; *) echo "ERROR: invalid text_match '$mode' (expected contains or exact)" >&2; return 2 ;; esac
  nth="$(jq -r '.nth // 1' <<<"$step")"
  timeout="$(jq -r '.timeout_seconds // 8' <<<"$step")"
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    if find_text_value "$sub" "$nth" "$mode"; then
      want="$(jq -r '.equals // empty' <<<"$step")"
      if [ -n "$want" ] && [ "$TEXT_VALUE" != "$want" ]; then
        return 1
      fi
      want="$(jq -r '.matches // empty' <<<"$step")"
      if [ -n "$want" ]; then
        grep -Eq -- "$want" <<<"$TEXT_VALUE" || return 1
      fi
      echo "   (found \"$TEXT_VALUE\" on screen)"
      return 0
    fi
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.8
  done
}

# ---------------------------------------------------------------- device hygiene
#
# Auto-rotate belongs to whoever owns the device, not to a test run. `adb shell
# monkey -p <pkg> -c android.intent.category.LAUNCHER 1` turns it ON and never
# puts it back (monkey thaws rotation during its own setup), which is how it
# kept coming back on after a session. Confirmed on a Pixel 6 Pro, 2026-08-28:
# accelerometer_rotation 0 -> 1 on every monkey launch, unchanged by
# `am start -n`, `adb install`, `pm clear` and `uiautomator dump`. Nothing here
# launches with monkey; these two functions catch anything else that moves the
# setting.

AUTOROTATE_AT_START=""

# Reads the setting so autorotate_restore can put it back. No-op when the guard
# is turned off, or when the device answers something other than 0/1 (an
# emulator can).
autorotate_snapshot() {
  [ "${GUARD_AUTOROTATE:-true}" = "true" ] || return 0
  AUTOROTATE_AT_START="$(ADB shell settings get system accelerometer_rotation 2>/dev/null | tr -d '\r\n')"
  case "$AUTOROTATE_AT_START" in 0|1) ;; *) AUTOROTATE_AT_START="" ;; esac
}

# Puts the setting back if the run moved it, and says so: a silent restore
# would hide the next tool that starts flipping it.
autorotate_restore() {
  [ -n "$AUTOROTATE_AT_START" ] || return 0
  local now
  now="$(ADB shell settings get system accelerometer_rotation 2>/dev/null | tr -d '\r\n')"
  [ "$now" = "$AUTOROTATE_AT_START" ] && return 0
  ADB shell settings put system accelerometer_rotation "$AUTOROTATE_AT_START" >/dev/null 2>&1
  echo "==> auto-rotate had been changed during this run ($AUTOROTATE_AT_START -> $now); restored to $AUTOROTATE_AT_START" >&2
}

# True when the device is attached over USB. Radio toggles are refused
# otherwise: on wireless debugging, disabling wifi cuts adb's own transport and
# the device is left unreachable with its radios off.
device_is_usb() {
  adb devices -l | awk -v s="$SERIAL" '$1 == s' | grep -q ' usb:'
}

# do_exec_step <exec-step> - runs the step's external command synchronously
# and remembers its exit status + stdout in LAST_EXEC_STATUS /
# LAST_EXEC_OUTPUT for a following if step (source last_command). on_fail
# decides whether a non-zero status aborts the run ("stop", the default) or
# just logs ("continue"; the recorded status still reflects the failure).
# DEMO_SERIAL/DEMO_APP_ID/DEMO_ACTIVITY/DEMO_SCREEN_W/DEMO_SCREEN_H are
# exported by the caller script, not here, so the command sees them.
LAST_EXEC_STATUS=""
LAST_EXEC_OUTPUT=""
do_exec_step() {
  local step="$1" shell cmd status=0 out lines
  shell="$(jq -r '.shell // "bash"' <<<"$step")"
  case "$shell" in
    bash|sh|lambda) ;;
    *) echo "ERROR: invalid exec shell '$shell' (expected bash, sh, or lambda)" >&2; return 2 ;;
  esac
  cmd="$(jq -r '.command // empty' <<<"$step")"
  [ -n "$cmd" ] || { echo "ERROR: exec step is missing \"command\"" >&2; return 2; }
  cmd="$(substitute_templates "$cmd")" || return 2
  if [ "${GUARD_RADIO_TOGGLE_USB_ONLY:-true}" = "true" ] &&
     printf '%s' "$cmd" | grep -Eq 'svc +(wifi|data) +disable' &&
     ! device_is_usb; then
    echo "ERROR: this exec step turns a radio off, and $SERIAL is not on USB." >&2
    echo "       Over wireless debugging that kills adb's own transport mid-run and leaves" >&2
    echo "       the device offline with no way back in. Attach it by USB and re-run." >&2
    return 1
  fi
  echo "   \$ exec (${shell}): $(printf '%s' "$cmd" | head -1)"
  case "$shell" in
    bash)   out="$(printf '%s' "$cmd" | bash 2>&1)" || status=$? ;;
    sh)     out="$(printf '%s' "$cmd" | sh 2>&1)" || status=$? ;;
    lambda) out="$(jq -rn "$cmd" 2>&1)" || status=$? ;;
  esac
  LAST_EXEC_STATUS="$status"
  LAST_EXEC_OUTPUT="$out"
  if [ -n "$out" ]; then
    lines="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
    printf '%s\n' "$out" | head -5 | sed 's/^/     | /'
    [ "$lines" -gt 5 ] && echo "     | ... ($((lines - 5)) more lines)"
  fi
  echo "   => exit ${status}"
  if [ "$status" -ne 0 ]; then
    if [ "$(jq -r '.on_fail // "stop"' <<<"$step")" = "continue" ]; then
      echo "   (exec failed; continuing because on_fail=continue)" >&2
      return 0
    fi
    echo "ERROR: exec command failed with exit status ${status} (on_fail=stop)" >&2
    return 1
  fi
}

# eval_condition <if-step> - returns 0 when the condition holds (then-branch),
# 1 when it does not (else-branch), 2 on a malformed step.
eval_condition() {
  local step="$1" source expect want rc
  source="$(jq -r '.source // "last_command"' <<<"$step")"
  case "$source" in
    last_command)
      expect="$(jq -r '.expect // "success"' <<<"$step")"
      case "$expect" in
        success|fail) ;;
        *) echo "ERROR: invalid expect '$expect' (expected success or fail)" >&2; return 2 ;;
      esac
      if [ "$expect" = "success" ]; then
        [ "${LAST_EXEC_STATUS:-}" = "0" ] || return 1
      else
        # fail requires an exec to have actually run and failed
        if [ -z "${LAST_EXEC_STATUS:-}" ] || [ "$LAST_EXEC_STATUS" = "0" ]; then return 1; fi
      fi
      want="$(jq -r '.output_equals // empty' <<<"$step")"
      if [ -n "$want" ] && [ "$LAST_EXEC_OUTPUT" != "$want" ]; then return 1; fi
      want="$(jq -r '.output_matches // empty' <<<"$step")"
      if [ -n "$want" ] && ! grep -Eq -- "$want" <<<"$LAST_EXEC_OUTPUT"; then return 1; fi
      return 0
      ;;
    screen)
      rc=0
      screen_condition_met "$step" || rc=$?
      return "$rc"
      ;;
    *)
      echo "ERROR: invalid if source '$source' (expected last_command or screen)" >&2
      return 2
      ;;
  esac
}
