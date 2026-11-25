#!/usr/bin/env bash
# PIA (pia.jp) ticket availability watcher — read-only stock check.
# Usage: bash pia-check.sh [--watch SECONDS] [--toast] [--run CMD] [--quiet] [--pfcd 001]
#   --watch N   one full pass over every target every N seconds (min 15); default = single pass
#   --toast     pop a Windows toast when stock changes to available / low
#   --run CMD   shell command fired on that change (env PIA_SUMMARY holds status)
#   --quiet     only print state changes
#   --pfcd 001  force performance codes instead of auto-discovering them from each event page
# Targets: TARGETS="eventCd/rlsCd,eventCd/rlsCd"  (default: the two NHKSO releases below)
# Exit code: 0 tickets found / 1 all sold out / 2 fetch or parse problem
# Process spawns cost ~0.15 s each on MSYS, so the per-cycle path is kept fork-free
# outside the two requests per target: everything else uses shell builtins.
set -uo pipefail

TARGETS="${TARGETS:-2618278/007,2618278/008}"
LANG_CD="${LANG_CD:-eng}"
PFCDS="${PFCDS:-}"
CACHE_TTL=600            # seconds an event page's performance list is reused before re-fetching
WATCH=0
TOAST=0
RUN_CMD="${RUN_CMD:-}"
QUIET=0
STATE_DIR="${STATE_DIR:-$(dirname "$(readlink -f "$0")")/pia-state}"

BASE="https://sell.pia.jp/inbound"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch)     WATCH="${2:?--watch needs seconds}"; shift 2 ;;
    --pfcd)      PFCDS="${2:?--pfcd needs a code}"; shift 2 ;;
    --toast)     TOAST=1; shift ;;
    --run)       RUN_CMD="${2:?--run needs a command}"; shift 2 ;;
    --quiet)     QUIET=1; shift ;;
    -h|--help)   sed -n '3,11p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ ! "$WATCH" =~ ^[0-9]+$ ]] || { [[ "$WATCH" != "0" ]] && (( WATCH < 15 )); }; then
  echo "--watch must be 0 or >= 15 seconds" >&2; exit 2
fi

mkdir -p "$STATE_DIR"
LOG="$STATE_DIR/history.log"
SNAP="$STATE_DIR/last-snapshot.tsv"
JAR=""                    # set per target: each event keeps its own server-side session
TMP="$(mktemp -d)"
declare -A CACHE_AT       # target -> $SECONDS of its last event-page fetch
trap 'rm -rf "$TMP"' EXIT

# ---------------- fetch ----------------
get() { # get <url> <outfile> [referer] ; echoes http code, one retry
  local url="$1" out="$2" ref="${3:-}" code try=0
  local -a hdr=(-A "$UA" -H "Accept-Language: en,ja;q=0.8")
  [[ -n "$ref" ]] && hdr+=(-H "Referer: $ref")
  [[ "$url" == */util/* ]] && hdr+=(-H "X-Requested-With: XMLHttpRequest")
  while :; do
    code=$(curl -sS -m 15 -b "$JAR" -c "$JAR" "${hdr[@]}" \
                -o "$out" -w '%{http_code}' "$url" 2>>"$STATE_DIR/curl.err") || code=000
    [[ "$code" == "200" && -s "$out" ]] && break
    (( try >= 1 )) && break
    try=$((try+1)); sleep 3
  done
  echo "$code"
}

# ---------------- parsing (one perl process each) ----------------
discover() { # discover < event-page.html  ->  pfcd<TAB>date label
  perl -0777 -ne '
    my ($sel) = $_ =~ /(<select[^>]*name="insPerformCode".*?<\/select>)/s;
    $sel = "" unless $sel;
    while ($sel =~ /<option\s+value="(\d+)"[^>]*>\s*(.*?)\s*<\/option>/gs) {
      my ($v, $t) = ($1, $2);
      $t =~ s/<[^>]*>//g; $t =~ s/&nbsp;/ /g; $t =~ s/&amp;/&/g; $t =~ s/\s+/ /g;
      print "$v\t$t\n";
    }
  '
}

parse_stock() { # parse_stock <file> -> ssk<TAB>label<TAB>status
  perl -0777 -ne '
    while ($_ =~ /<img\s+src="[^"]*zaiko_(\w+)\.png".{0,800}?<input\s+type="radio"\s+name="insStockSK"([^>]*?)value="(\d+)"[^>]*\/>\s*([^<]*)/gs) {
      my ($mark, $attrs, $ssk, $label) = ($1, $2, $3, $4);
      my %m = (maru => "AVAILABLE", sankaku => "FEW", batsu => "SOLDOUT");
      my $st = $m{$mark} // "UNKNOWN($mark)";
      $st = "SOLDOUT" if $st eq "AVAILABLE" && $attrs =~ /\bdisabled\b/;
      $label =~ s/&nbsp;/ /g; $label =~ s/&amp;/&/g; $label =~ s/^\s+|\s+$//g;
      $label = "(unnamed)" if $label eq "";
      print "$ssk\t$label\t$st\n";
    }
  ' "$1"
}

# ---------------- checking ----------------
PERF_OK=0
check_performance() { # check_performance <tgt> <pfcd> <date> <page-url> ; prints rows, sets PERF_OK
  local tgt="$1" pfcd="$2" when="$3" page="$4" code rows ssk label st
  PERF_OK=0
  code=$(get "$BASE/util/selectPerform.php?pfcd=$pfcd" "$TMP/sp.html" "$page")
  if [[ "$code" != "200" ]]; then
    printf '%s|%s|%s|-|-|ERROR(HTTP %s)\n' "$tgt" "$when" "$pfcd" "$code"; return
  fi
  rows=$(parse_stock "$TMP/sp.html")
  if [[ -z "$rows" ]]; then
    printf '%s|%s|%s|-|-|ERROR(no seat rows parsed)\n' "$tgt" "$when" "$pfcd"; return
  fi
  while IFS=$'\t' read -r ssk label st; do
    [[ -z "$ssk" ]] && continue
    printf '%s|%s|%s|%s|%s|%s\n' "$tgt" "$when" "$pfcd" "$ssk" "$label" "$st"
    PERF_OK=1
  done <<< "$rows"
}

seat_rows() { # seat_rows <tgt> <page-url> <list-file> -> rows; rc 1 when no valid row at all
  local tgt="$1" page="$2" list="$3" pfcd when ok=0
  while IFS=$'\t' read -r pfcd when; do
    [[ -z "$pfcd" ]] && continue
    check_performance "$tgt" "$pfcd" "${when:-unknown}" "$page" > "$TMP/perf.txt"
    (( PERF_OK == 1 )) && ok=1
    printf '%s\n' "$(< "$TMP/perf.txt")"
  done < "$list"
  (( ok == 1 ))
}

check_target() { # check_target <eventCd> <rlsCd> -> rows
  local ev="$1" rls="$2" tgt="$1/$2" page cache code rows
  page="$BASE/selectTicket.php?eventCd=$ev&rlsCd=$rls&langCd=$LANG_CD"
  cache="$STATE_DIR/pfcd-$ev-$rls.tsv"
  # selectPerform.php carries no eventCd: the server reads the event from the session,
  # so every target keeps its own cookie jar or one event's page would hijack the other's.
  JAR="$STATE_DIR/jar-$ev-$rls.txt"

  if [[ -z "$PFCDS" && -s "$cache" && -n "${CACHE_AT[$tgt]:-}" ]] \
     && (( SECONDS - CACHE_AT[$tgt] < CACHE_TTL )); then
    rows=$(seat_rows "$tgt" "$page" "$cache") && { printf '%s\n' "$rows"; return 0; }
    # session most likely expired: fall through and rebuild it
  fi

  code=$(get "$page" "$TMP/page.html")
  if [[ "$code" != "200" ]]; then
    printf '%s|-|-|-|-|ERROR(HTTP %s on event page)\n' "$tgt" "$code"; return 0
  fi
  CACHE_AT[$tgt]=$SECONDS

  if [[ -n "$PFCDS" ]]; then
    tr ',;' '\n\n' <<< "$PFCDS" | sed '/^$/d;s/^0*//' \
      | while read -r p; do printf '%03d\t(manual)\n' "$p"; done > "$cache"
  else
    discover < "$TMP/page.html" > "$cache"
  fi
  if ! [[ -s "$cache" ]]; then
    printf '%s|-|-|-|-|ERROR(no performances in event page)\n' "$tgt"; return 0
  fi

  seat_rows "$tgt" "$page" "$cache"
}

collect() { # writes $TMP/rows.txt
  : > "$TMP/rows.txt"
  local t
  for t in ${TARGETS//,/ }; do
    [[ "$t" == */* ]] && check_target "${t%%/*}" "${t##*/}" >> "$TMP/rows.txt"
  done
}

# ---------------- reporting ----------------
NOTIFY_PS1="$STATE_DIR/notify.ps1"
write_notify_script() {
  cat > "$NOTIFY_PS1" <<'PS1'
$t = $env:PIA_TOAST_TITLE
$b = $env:PIA_TOAST_BODY
$links = @()
if ($env:PIA_LINKS) { $links = @($env:PIA_LINKS -split ';' | Where-Object { $_ }) }
# Best-effort native toast too (leaves a trace in the notification centre).
try {
  [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
  [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
  $esc = { param($s) ($s -replace '&','&amp;') -replace '<','&lt;' -replace '>','&gt;' }
  $x = New-Object Windows.Data.Xml.Dom.XmlDocument
  $x.LoadXml("<toast><visual><binding template=""ToastGeneric""><text>$(& $esc $t)</text><text>$(& $esc $b)</text></binding></visual></toast>")
  [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("pia-check").Show($x)
} catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = $t
$form.Size = New-Object System.Drawing.Size(640, 340)
$form.StartPosition = 'CenterScreen'
$form.TopMost = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(176, 0, 32)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.ShowInTaskbar = $true

$lbl = New-Object System.Windows.Forms.Label
$lbl.Text = $b
$lbl.Font = New-Object System.Drawing.Font('Microsoft YaHei', 14, [System.Drawing.FontStyle]::Bold)
$lbl.ForeColor = [System.Drawing.Color]::White
$lbl.Dock = 'Top'
$lbl.Height = 180
$lbl.Padding = New-Object System.Windows.Forms.Padding(14)
$form.Controls.Add($lbl)

$panel = New-Object System.Windows.Forms.FlowLayoutPanel
$panel.Dock = 'Bottom'
$panel.Height = 120
$panel.Padding = New-Object System.Windows.Forms.Padding(10)
$form.Controls.Add($panel)

foreach ($u in $links) {
  $tag = if ($u -match 'rlsCd=(\d+)') { $Matches[1] } else { 'page' }
  $btn = New-Object System.Windows.Forms.Button
  $btn.Text = "Open $tag ticket page"
  $btn.Width = 190; $btn.Height = 60
  $btn.Font = New-Object System.Drawing.Font('Microsoft YaHei', 11, [System.Drawing.FontStyle]::Bold)
  $btn.Tag = $u
  $btn.Add_Click({ param($s, $e) Start-Process $s.Tag; $form.Close() })
  $panel.Controls.Add($btn)
}
$dismiss = New-Object System.Windows.Forms.Button
$dismiss.Text = 'Dismiss (stop alarm)'
$dismiss.Width = 190; $dismiss.Height = 60
$dismiss.Font = New-Object System.Drawing.Font('Microsoft YaHei', 11, [System.Drawing.FontStyle]::Bold)
$dismiss.Add_Click({ $form.Close() })
$panel.Controls.Add($dismiss)

$script:opened = $false
$alarm = New-Object System.Windows.Forms.Timer
$alarm.Interval = 1200
$alarm.Add_Tick({
  try { [console]::beep(1000, 220); [console]::beep(1400, 220) }
  catch { try { [System.Media.SystemSounds]::Exclamation.Play() } catch {} }
  $form.TopMost = $true
  $form.Activate()
})
$auto = New-Object System.Windows.Forms.Timer
$auto.Interval = 15000
$auto.Add_Tick({
  if (-not $script:opened) {
    $script:opened = $true
    foreach ($u in $links) { Start-Process $u }
  }
})
$life = New-Object System.Windows.Forms.Timer
$life.Interval = 600000
$life.Add_Tick({ $form.Close() })

$form.Add_Shown({ $alarm.Start(); $auto.Start(); $life.Start(); $form.Activate() })
$form.Add_FormClosed({ $alarm.Stop(); $auto.Stop(); $life.Stop() })
[System.Windows.Forms.Application]::Run($form)
PS1
}

notify_windows() { # notify_windows <title> <body>  (links come from ALERT_LINKS)
  command -v powershell.exe >/dev/null 2>&1 || return
  write_notify_script
  PIA_TOAST_TITLE="$1" PIA_TOAST_BODY="$2" PIA_LINKS="${ALERT_LINKS:-}" \
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$NOTIFY_PS1" 2>/dev/null || echo "$NOTIFY_PS1")" \
    >>"$STATE_DIR/notify.err" 2>&1 &
}

run_once() {
  collect
  local rows; rows=$(< "$TMP/rows.txt")
  if [[ -z "$rows" ]]; then
    printf -v ts '%(%F %T)T' -1
    echo "[$ts] ERROR: no data returned" | tee -a "$LOG" >&2; return 2
  fi
  printf -v ts '%(%F %T)T' -1

  # One awk pass: state changes against the previous snapshot, plus the new snapshot.
  local changes="" snap="" line
  local -A seen_tgts=()
  ALERT_LINKS=""
  while IFS= read -r line; do
    case "$line" in
      CHANGE:*) IFS='|' read -r tgt _ _ when label st <<< "${line#CHANGE:}"
                changes+="$tgt  $when / $label -> $st"$'\n'
                if [[ -z "${seen_tgts[$tgt]:-}" ]]; then
                  seen_tgts[$tgt]=1
                  ALERT_LINKS+="$BASE/selectTicket.php?eventCd=${tgt%%/*}&rlsCd=${tgt##*/}&langCd=$LANG_CD;"
                fi ;;
      SNAP:*)   snap+="${line#SNAP:}"$'\n' ;;
    esac
  done < <(awk -F'\t' -v prevfile="$SNAP" '
      BEGIN { while ((getline l < prevfile) > 0) { split(l, p, "\t"); prev[p[1]] = p[2] } }
      {
        n = split($0, a, "|"); key = a[1] "|" a[3] "|" a[4]
        if ((a[6] == "AVAILABLE" || a[6] == "FEW") && prev[key] != a[6])
          print "CHANGE:" key "|" a[2] "|" a[5] "|" a[6]
        print "SNAP:" key "\t" a[6]
      }' "$TMP/rows.txt")

  local n_a=0 n_f=0 n_e=0 r
  while IFS= read -r r; do
    case "$r" in
      *'|AVAILABLE') (( n_a++ )) ;;
      *'|FEW')       (( n_f++ )) ;;
      *'|ERROR'*)    (( n_e++ )) ;;
    esac
  done <<< "$rows"

  local summary
  if   (( n_e > 0 && n_a + n_f == 0 )); then summary="CHECK FAILED ($n_e error rows) - page changed or blocked, not necessarily sold out"
  elif (( n_a + n_f > 0 ));              then summary="TICKETS AVAILABLE: $n_a sellable, $n_f low-stock"
  else                                      summary="all sold out ($n_e errors)"
  fi

  if (( QUIET == 0 )); then
    echo "[$ts] targets: ${TARGETS//,/  }"
    awk -F'|' '{
      icon = ($6=="AVAILABLE") ? "[O]" : ($6=="FEW") ? "[~]" : ($6=="SOLDOUT") ? "[X]" : "[!]"
      printf "    %s %-12s pfcd %-4s %-3s %-9s %s\n", icon, $1, $3, $4, $5, $2
    }' "$TMP/rows.txt"
    echo "    => $summary"
  fi

  printf '%s\n' "${rows//|/$'\t'}" >> "$LOG"
  printf '@\t%s\t%s\n' "$ts" "$summary" >> "$LOG"
  printf '%s' "$snap" > "$SNAP"

  if [[ -n "$changes" ]]; then
    echo ""
    echo "  *** STATE CHANGE ***"
    printf '%s\n' "$changes" | sed '/^$/d; s/^/      /'
    printf '\a'
    local msg="${changes//$'\n'/ }"
    (( TOAST == 1 )) && notify_windows "PIA tickets" "${msg:0:200}"
    [[ -n "$RUN_CMD" ]] && PIA_SUMMARY="$summary" PIA_LINKS="${ALERT_LINKS%;}" bash -c "$RUN_CMD"
  fi

  (( n_e > 0 )) && return 2
  (( n_a + n_f > 0 )) && return 0
  return 1
}

if [[ $WATCH -eq 0 ]]; then
  run_once; exit $?
fi

LOCK="$STATE_DIR/lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  opid=$(cat "$LOCK/pid" 2>/dev/null)
  if [[ -n "$opid" ]] && kill -0 "$opid" 2>/dev/null; then
    echo "another watcher is already running (pid $opid). Close its window first." >&2
    exit 2
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK"
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK" "$TMP"' EXIT

echo "watching ${TARGETS//,/ + } every ${WATCH}s  (close this window to stop)   state: $STATE_DIR"
while :; do
  t0=${EPOCHREALTIME//./}                       # microseconds, no fork
  run_once
  nap=$(( WATCH * 1000000 - (${EPOCHREALTIME//./} - t0) ))
  (( nap < 3000000 )) && nap=3000000            # a slow pass still gets a 3 s breather
  sleep "$(printf '%d.%06d' $(( nap / 1000000 )) $(( nap % 1000000 )))"
done
