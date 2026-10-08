#!/usr/bin/env bash
# =============================================================================
#  magento-security-patcher.sh  —  ZERO-1
#
#  One command to:
#    1. Detect the installed Magento version (bin/magento -V, falling back to
#       composer.lock / composer.json)
#    2. Discover monthly security patch bundles on repo.magento.com
#       (e.g. https://repo.magento.com/patch/2-4-7-p10-sep-2026.zip), plus any
#       explicit URLs in a list file
#    3. Download + unpack them, then apply every patch inside, strictly in
#       release-date order, transactionally per bundle
#    4. Alert (stderr / Slack-compatible webhook / email) if a bundle needs a
#       higher patch level than is installed, or if a patch will not apply
#
#  Re-runnable / cron-safe: already-applied bundles and patches are detected
#  and skipped, so each run just picks up whatever is new (e.g. next month).
#
#  Usage:   ./magento-security-patcher.sh [options]
#  Run with -h for options. Requires: bash 4+, GNU date, wget, unzip, patch, php
#
#  Exit codes: 0 ok / nothing to do, 1 error, 2 upgrade required,
#              3 patch conflict (bundle rolled back)
# =============================================================================
# Everything runs inside main(), which is only called on the last line. When the
# script is piped (curl ... | bash) this means a truncated download runs nothing,
# and no command inside can read the rest of the script from stdin.
main() {
set -Eeuo pipefail
export LC_ALL=C

# ---------------------------------------------------------------- defaults ---
MAGENTO_ROOT="${MAGENTO_ROOT:-$(pwd)}"
# Space-separated list of base locations probed for <ver>-p<N>-<mon>-<yyyy>.zip
PATCH_BASE_URLS="${PATCH_BASE_URLS:-https://repo.magento.com/patch https://repo.magento.com/patch/auth}"
URL_LIST="${URL_LIST:-}"                  # optional local file: one zip URL per line
# Central list of known bundles, maintained in the GitHub repo and fetched on every run.
# Only repo.magento.com URLs are accepted from it.
KNOWN_LIST_URL="${KNOWN_LIST_URL-https://raw.githubusercontent.com/zero1limited/magento-security-patcher/master/patches.txt}"
LOOKBACK_MONTHS="${LOOKBACK_MONTHS:-6}"   # discovery window when no history
LOOKAHEAD_MONTHS="${LOOKAHEAD_MONTHS:-1}" # also probe next month(s)
P_AHEAD="${P_AHEAD:-3}"                   # probe up to N patch levels above installed
STATE_DIR="${STATE_DIR:-}"                # default: $MAGENTO_ROOT/var/security-patches
ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"        # Slack/Teams-style incoming webhook
ALERT_EMAIL="${ALERT_EMAIL:-}"            # needs a working `mail` command
DRY_RUN=0
CACHE_FLUSH=1
DI_COMPILE=0

usage() {
  cat <<EOF
Usage: magento-security-patcher.sh [options]
       curl -fsSL <raw-url> | bash -s -- [options]

  -r, --root DIR          Magento root (default: current directory)
  -l, --list FILE         Local file of extra patch zip URLs (one per line, # comments ok)
      --known-list URL    Central list of known bundles (default: patches.txt in the GitHub repo)
      --no-known-list     Don't fetch the central list
  -b, --base-url URL      Base URL to probe (repeatable; default repo.magento.com/patch)
      --lookback N        Months to look back when no history exists (default $LOOKBACK_MONTHS)
      --lookahead N       Months ahead of today to probe (default $LOOKAHEAD_MONTHS)
  -n, --dry-run           Download and test patches, change nothing
      --no-cache-flush    Skip bin/magento cache:flush after applying
      --compile           Run bin/magento setup:di:compile after applying
      --webhook URL       Post alerts to this webhook
      --email ADDR        Email alerts to this address
  -h, --help              Show this help

Credentials for repo.magento.com are read from (first found):
  \$MAGENTO_REPO_USER / \$MAGENTO_REPO_PASS, <root>/auth.json,
  \$COMPOSER_HOME/auth.json, ~/.config/composer/auth.json, ~/.composer/auth.json
They are only ever sent to repo.magento.com.
EOF
}

CLI_BASES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--root)        MAGENTO_ROOT="$2"; shift 2 ;;
    -l|--list)        URL_LIST="$2"; shift 2 ;;
    --known-list)     KNOWN_LIST_URL="$2"; shift 2 ;;
    --no-known-list)  KNOWN_LIST_URL=""; shift ;;
    -b|--base-url)    CLI_BASES+=("${2%/}"); shift 2 ;;
    --lookback)       LOOKBACK_MONTHS="$2"; shift 2 ;;
    --lookahead)      LOOKAHEAD_MONTHS="$2"; shift 2 ;;
    -n|--dry-run)     DRY_RUN=1; shift ;;
    --no-cache-flush) CACHE_FLUSH=0; shift ;;
    --compile)        DI_COMPILE=1; shift ;;
    --webhook)        ALERT_WEBHOOK="$2"; shift 2 ;;
    --email)          ALERT_EMAIL="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done
[[ ${#CLI_BASES[@]} -gt 0 ]] && PATCH_BASE_URLS="${CLI_BASES[*]}"

MAGENTO_ROOT="$(cd "$MAGENTO_ROOT" && pwd)"
STATE_DIR="${STATE_DIR:-$MAGENTO_ROOT/var/security-patches}"
DL_DIR="$STATE_DIR/downloads"
EX_DIR="$STATE_DIR/extracted"
APPLIED_LOG="$STATE_DIR/applied.log"
RUN_LOG="$STATE_DIR/run.log"
mkdir -p "$DL_DIR" "$EX_DIR"
touch "$APPLIED_LOG"

# ----------------------------------------------------------------- logging ---
if [[ -t 2 ]]; then C_R=$'\e[31m'; C_Y=$'\e[33m'; C_G=$'\e[32m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else C_R=; C_Y=; C_G=; C_B=; C_0=; fi

log()  { printf '%s [%-5s] %s\n' "$(date '+%F %T %Z')" "$1" "$2" >>"$RUN_LOG"
         local c=; case "$1" in ERROR|ALERT) c=$C_R;; WARN) c=$C_Y;; OK) c=$C_G;; esac
         printf '%s[%s]%s %s\n' "$c" "$1" "$C_0" "$2" >&2; }
info() { log INFO "$*"; }
warn() { log WARN "$*"; }
ok()   { log OK "$*"; }
die()  { log ERROR "$*"; exit 1; }

json_str() { php -r 'echo json_encode($argv[1]);' "$1"; }

alert() {   # alert "<subject>" "<body>"
  log ALERT "$1 — $2"
  local host; host="$(hostname 2>/dev/null || echo unknown)"
  local text="[Magento patcher @ $host:$MAGENTO_ROOT] $1: $2"
  if [[ -n $ALERT_WEBHOOK ]]; then
    wget -q -O /dev/null --header='Content-Type: application/json' \
      --post-data="{\"text\":$(json_str "$text")}" "$ALERT_WEBHOOK" \
      || warn "Webhook alert failed"
  fi
  if [[ -n $ALERT_EMAIL ]]; then
    if command -v mail >/dev/null; then
      printf '%s\n' "$text" | mail -s "Magento patcher: $1 ($host)" "$ALERT_EMAIL" || warn "Email alert failed"
    else warn "ALERT_EMAIL set but no 'mail' command available"; fi
  fi
}

# ------------------------------------------------------------ preflight -----
for bin in wget unzip patch php date sha256sum; do
  command -v "$bin" >/dev/null || die "Required command not found: $bin"
done
date -d '2000-01-01 +1 month' +%Y-%m >/dev/null 2>&1 || die "GNU date is required"
[[ -f "$MAGENTO_ROOT/composer.json" ]] || die "No composer.json in $MAGENTO_ROOT — is this a Magento root?"

if command -v flock >/dev/null; then
  exec 9>"$STATE_DIR/.lock"
  flock -n 9 || die "Another patcher run is in progress (lock: $STATE_DIR/.lock)"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
trap 'log ERROR "Unexpected failure at line $LINENO"' ERR

info "${C_B}Magento security patcher${C_0} — root: $MAGENTO_ROOT$([[ $DRY_RUN == 1 ]] && echo '  (DRY RUN)')"

# ------------------------------------------------------ version detection ---
php_json() {  # php_json <file> <php-expr using $j>
  php -r '$j=json_decode(@file_get_contents($argv[1]),true); if(!is_array($j)) exit(0); '"$2" "$1" 2>/dev/null || true
}

V_CLI=""
if [[ -f "$MAGENTO_ROOT/bin/magento" ]]; then
  V_CLI="$( (cd "$MAGENTO_ROOT" && php bin/magento -V --no-ansi 2>/dev/null) \
           | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+(-p[0-9]+(\.[0-9]+)?)?' | head -1 || true)"
fi
V_LOCK=""
[[ -f "$MAGENTO_ROOT/composer.lock" ]] && V_LOCK="$(php_json "$MAGENTO_ROOT/composer.lock" \
  'foreach(($j["packages"]??[]) as $p){ if(preg_match("#^magento/product-(community|enterprise)-edition$#",$p["name"])){ echo $p["version"]; break; } }')"
V_JSON="$(php_json "$MAGENTO_ROOT/composer.json" \
  'echo $j["require"]["magento/product-enterprise-edition"] ?? $j["require"]["magento/product-community-edition"] ?? "";')"
V_JSON="${V_JSON#[=^~v]}"

INSTALLED="${V_CLI:-${V_LOCK:-$V_JSON}}"
[[ -n $INSTALLED ]] || die "Could not detect Magento version (bin/magento -V, composer.lock and composer.json all failed)"
info "Detected Magento $INSTALLED  (bin/magento: ${V_CLI:-n/a} | composer.lock: ${V_LOCK:-n/a} | composer.json: ${V_JSON:-n/a})"
if [[ -n $V_JSON && $V_JSON =~ ^[0-9] && $V_JSON != "$INSTALLED" ]]; then
  warn "composer.json requires $V_JSON but $INSTALLED is installed — has a composer update been left unfinished?"
fi

[[ $INSTALLED =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-p([0-9]+)(\.[0-9]+)?)?$ ]] \
  || die "Unrecognised version string: $INSTALLED"
BASE="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
PLEVEL="${BASH_REMATCH[5]:-0}"
BASE_DASH="${BASE//./-}"
info "Version line $BASE, patch level p$PLEVEL — looking for bundles named ${BASE_DASH}-p<N>-<mon>-<yyyy>.zip"

# ------------------------------------------------------------ credentials ---
REPO_HOST="repo.magento.com"
CRED_RC=""
load_creds() {
  local u="${MAGENTO_REPO_USER:-}" p="${MAGENTO_REPO_PASS:-}" f
  if [[ -z $u || -z $p ]]; then
    for f in "$MAGENTO_ROOT/auth.json" "${COMPOSER_HOME:-/nonexistent}/auth.json" \
             "$HOME/.config/composer/auth.json" "$HOME/.composer/auth.json"; do
      [[ -f $f ]] || continue
      u="$(php_json "$f" 'echo $j["http-basic"]["repo.magento.com"]["username"] ?? "";')"
      p="$(php_json "$f" 'echo $j["http-basic"]["repo.magento.com"]["password"] ?? "";')"
      [[ -n $u && -n $p ]] && { info "Using repo.magento.com keys from $f"; break; }
    done
  fi
  if [[ -n $u && -n $p ]]; then
    CRED_RC="$TMP_DIR/wgetrc"; ( umask 077; printf 'http_user = %s\nhttp_password = %s\nauth_no_challenge = on\n' "$u" "$p" >"$CRED_RC" )
  else
    warn "No repo.magento.com credentials found — requests to $REPO_HOST will be anonymous"
  fi
}
load_creds

url_host() { local h="${1#*://}"; h="${h%%/*}"; echo "${h##*@}"; }
fetch() {   # fetch <url> <wget args...>  — only attaches creds for repo.magento.com
  local url="$1"; shift
  if [[ -n $CRED_RC && "$(url_host "$url")" == "$REPO_HOST" ]]; then
    WGETRC="$CRED_RC" wget "$@" "$url"
  else
    wget "$@" "$url"
  fi
}
http_status() {  # prints final HTTP status code for a URL (HEAD-style probe)
  fetch "$1" --spider -S -T 20 -t 2 2>&1 | awk '/^ *HTTP\//{c=$2} END{print c+0}' || true
}

# ------------------------------------------------------------ date helpers --
mon_num() { case "$1" in jan) echo 01;; feb) echo 02;; mar) echo 03;; apr) echo 04;; may) echo 05;; jun) echo 06;;
                         jul) echo 07;; aug) echo 08;; sep) echo 09;; oct) echo 10;; nov) echo 11;; dec) echo 12;; *) return 1;; esac; }
month_add() { date -d "$1-01 $2 month" +%Y-%m; }          # month_add 2026-09 +1
pretty_ym() { date -d "${1:0:4}-${1:4:2}-01" '+%b %Y'; }   # 202609 -> Sep 2026

BUNDLE_RE='^([0-9]+-[0-9]+-[0-9]+)(-p([0-9]+))?-([a-z]{3})-([0-9]{4})\.zip$'
CANDIDATES="$TMP_DIR/candidates"; : >"$CANDIDATES"
add_candidate() {  # add_candidate <url>  → "YYYYMM PLEVEL URL NAME" if it matches our version line
  local url="$1" name; name="$(basename "${url%%\?*}")"
  if [[ ! ${name,,} =~ $BUNDLE_RE ]]; then warn "Ignoring $name — doesn't match <ver>-p<N>-<mon>-<yyyy>.zip"; return 0; fi
  local ver="${BASH_REMATCH[1]}" p="${BASH_REMATCH[3]:-0}" mon="${BASH_REMATCH[4]}" yr="${BASH_REMATCH[5]}" mm
  mm="$(mon_num "$mon")" || { warn "Ignoring $name — bad month '$mon'"; return 0; }
  if [[ $ver != "$BASE_DASH" ]]; then info "Skipping $name — for $ver, this site is $BASE_DASH"; return 0; fi
  echo "$yr$mm $p $url ${name,,}" >>"$CANDIDATES"
}

# ------------------------------------------------- 1. URL lists -------------
read_url_list() {  # read_url_list <file> <repo_only 0|1>
  local line
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%%#*}"; line="$(echo "$line" | xargs)"; [[ -z $line ]] && continue
    if [[ $2 == 1 && ! $line =~ ^https://$REPO_HOST/ ]]; then
      warn "Ignoring $line from the central list — only https://$REPO_HOST/ URLs are allowed there"; continue
    fi
    add_candidate "$line"
  done <"$1"
}
if [[ -n $KNOWN_LIST_URL ]]; then
  if fetch "$KNOWN_LIST_URL" -q -T 20 -t 2 -O "$TMP_DIR/known.txt"; then
    info "Reading central list of known bundles from $KNOWN_LIST_URL"
    read_url_list "$TMP_DIR/known.txt" 1
  else
    warn "Couldn't fetch the central list ($KNOWN_LIST_URL) — continuing with discovery only"
  fi
fi
if [[ -n $URL_LIST ]]; then
  [[ -f $URL_LIST ]] || die "URL list not found: $URL_LIST"
  info "Reading extra bundle URLs from $URL_LIST"
  read_url_list "$URL_LIST" 0
fi

# ------------------------------------------------- 2. auto-discovery --------
NOW_YM="$(date +%Y-%m)"
LAST_YM="$(awk -F'|' -v b="$BASE" '$2 ~ "^"b"(-p|$)" {print $3}' "$APPLIED_LOG" | sort | tail -1)"
if [[ -n $LAST_YM ]]; then
  START_YM="$(month_add "${LAST_YM:0:4}-${LAST_YM:4:2}" +1)"
  info "Last applied bundle for $BASE: $(pretty_ym "$LAST_YM") — probing from $(date -d "$START_YM-01" '+%b %Y')"
else
  START_YM="$(month_add "$NOW_YM" "-$LOOKBACK_MONTHS")"
  info "No history for $BASE — probing the last $LOOKBACK_MONTHS months"
fi
END_YM="$(month_add "$NOW_YM" "+$LOOKAHEAD_MONTHS")"

ym="$START_YM"
while [[ ! $ym > $END_YM ]]; do
  mon="$(date -d "$ym-01" +%b | tr 'A-Z' 'a-z')"; yr="${ym:0:4}"
  found=0
  for (( p = PLEVEL; p <= PLEVEL + P_AHEAD && found == 0; p++ )); do
    if (( p == 0 )); then names=("$BASE_DASH-$mon-$yr.zip" "$BASE_DASH-p0-$mon-$yr.zip")
    else names=("$BASE_DASH-p$p-$mon-$yr.zip"); fi
    for base in $PATCH_BASE_URLS; do
      for n in "${names[@]}"; do
        url="${base%/}/$n"; code="$(http_status "$url")"
        case "$code" in
          200) info "Found $url"; add_candidate "$url"; found=1; break 2 ;;
          401|403) alert "Authentication failed" "HTTP $code from $url — check repo.magento.com access keys"; exit 1 ;;
        esac
      done
    done
  done
  (( found )) || info "No bundle published for $(date -d "$ym-01" '+%b %Y') (checked p$PLEVEL–p$((PLEVEL + P_AHEAD)))"
  ym="$(month_add "$ym" +1)"
done

# ------------------------------------------- 3. choose one bundle per month --
declare -A EXACT=() HIGHER=() LOWER=()
while read -r ym p url name; do
  [[ -z ${ym:-} ]] && continue
  if   (( p == PLEVEL )); then EXACT[$ym]="$p $url $name"
  elif (( p >  PLEVEL )); then [[ -z ${HIGHER[$ym]:-} ]] && HIGHER[$ym]="$p $url $name"
  else LOWER[$ym]="$p $url $name"; fi
done < <(sort -u "$CANDIDATES" | sort -k1,1n -k2,2n)

MONTHS="$(printf '%s\n' "${!EXACT[@]}" "${!HIGHER[@]}" "${!LOWER[@]}" | grep -v '^$' | sort -un || true)"
if [[ -z $MONTHS ]]; then ok "No patch bundles found for $INSTALLED — nothing to do."; exit 0; fi

# --------------------------------------------------- patch application -----
select_patch_files() {  # select_patch_files <dir>  → prints patch files, sorted
  local dir="$1" f; local -a composer=() git=() generic=()
  while IFS= read -r -d '' f; do
    case "${f,,}" in
      *.composer.patch|*.composer.diff) composer+=("$f") ;;
      *.git.patch|*.git.diff)           git+=("$f") ;;
      *)                                generic+=("$f") ;;
    esac
  done < <(find "$dir" -type f \( -iname '*.patch' -o -iname '*.diff' \) ! -path '*/__MACOSX/*' -print0 | sort -z)
  # Adobe ships both flavours: composer-format (vendor/magento/...) and git-format (app/code/Magento/...)
  if [[ -d $MAGENTO_ROOT/vendor/magento && ${#composer[@]} -gt 0 ]]; then printf '%s\n' "${composer[@]}"
  elif [[ -d $MAGENTO_ROOT/app/code/Magento && ${#git[@]} -gt 0 ]]; then printf '%s\n' "${git[@]}"
  elif [[ ${#composer[@]} -gt 0 ]]; then printf '%s\n' "${composer[@]}"
  elif [[ ${#git[@]} -gt 0 ]]; then printf '%s\n' "${git[@]}"; fi
  [[ ${#generic[@]} -gt 0 ]] && printf '%s\n' "${generic[@]}"
  return 0
}

P() { patch -d "$MAGENTO_ROOT" -p1 -f --no-backup-if-mismatch "$@"; }

# --------------------------------------------------- applicability check ----
# Splits a unified diff into one file per target (sec/<n>.diff) and prints a
# manifest line per target: "<n>\t<old path>\t<new path>" (paths with the a/ b/
# prefix stripped, as -p1 does). Hunk line counts are tracked so content lines
# that happen to start with "--- " or "+++ " are never mistaken for headers.
PATCH_SPLIT_AWK='
function strip(p) { sub(/\t.*$/, "", p); gsub(/^"|"$/, "", p); if (p == "/dev/null") return p; sub(/^[^\/]*\//, "", p); return p }
function newsec() { n++; hasdiff = 0; hasold = 0 }
function out(l) { if (n > 0) print l > (dir "/" n ".diff") }
BEGIN { n = 0; inh = 0 }
{
  if (inh) {
    c = substr($0, 1, 1)
    if (c == " " || $0 == "") { ol--; nl-- } else if (c == "-") { ol-- } else if (c == "+") { nl-- } else if (c == "\\") { } else { inh = 0 }
    if (inh) { out($0); if (ol <= 0 && nl <= 0) inh = 0; next }
  }
  if ($0 ~ /^diff /) {
    newsec(); hasdiff = 1
    if ($0 ~ /^diff --git /) { g = $0; sub(/^diff --git /, "", g); i = index(g, " b/")
      if (i) { dgo[n] = strip(substr(g, 1, i - 1)); dgn[n] = strip(substr(g, i + 1)) } }
    out($0); next
  }
  if ($0 ~ /^--- /)  { if (!(hasdiff && !hasold)) newsec(); old[n] = strip(substr($0, 5)); hasold = 1; out($0); next }
  if ($0 ~ /^\+\+\+ /) { new[n] = strip(substr($0, 5)); out($0); next }
  if ($0 ~ /^@@ /) {
    h = $0; sub(/^@@ -/, "", h); split(h, parts, " ")
    split(parts[1], A, ","); ol = (A[2] == "" ? 1 : A[2] + 0)
    p2 = parts[2]; sub(/^\+/, "", p2); split(p2, B, ","); nl = (B[2] == "" ? 1 : B[2] + 0)
    inh = (ol > 0 || nl > 0); out($0); next
  }
  out($0)
}
END { for (i = 1; i <= n; i++) { o = old[i]; w = new[i]; if (o == "") o = dgo[i]; if (w == "") w = dgn[i]; print i "\t" o "\t" w } }'

pkg_root() {   # the installable unit a path belongs to
  local p="$1"; local -a c; IFS=/ read -r -a c <<<"$p"
  case "$p" in
    vendor/*/*/*)        echo "vendor/${c[1]}/${c[2]}" ;;
    app/code/*/*/*)      echo "app/code/${c[2]}/${c[3]}" ;;
    app/design/*/*/*/*)  echo "app/design/${c[2]}/${c[3]}/${c[4]}" ;;
    */*)                 echo "${p%/*}" ;;
    *)                   echo "." ;;
  esac
}
pkg_label() {  # vendor/magento/module-company -> magento/module-company
  case "$1" in vendor/*) echo "${1#vendor/}" ;; app/code/*) local r="${1#app/code/}"; echo "${r/\//_}" ;; *) echo "$1" ;; esac
}

# assess_patch <patch file> <work dir>
# Sets: AP_STATUS (ok|partial|na|missing), AP_FILE (patch to apply: original or
# filtered), AP_TOTAL, AP_OK, AP_NA_PKGS, AP_MISSING (newline-separated details)
assess_patch() {
  local f="$1" work="$2" idx old new target root
  local -a keep=() ; local -A na_pkgs=()
  rm -rf "$work"; mkdir -p "$work/sec"
  AP_TOTAL=0; AP_OK=0; AP_MISSING=""; AP_NA_PKGS=""; AP_FILE="$f"
  while IFS=$'\t' read -r idx old new; do
    [[ -z $idx ]] && continue
    AP_TOTAL=$((AP_TOTAL + 1))
    target="$old"; [[ $old == /dev/null || -z $old ]] && target="$new"
    if [[ -z $target || $target == /dev/null || $target == /* || /$target/ == */../* ]]; then
      AP_MISSING+="unsafe or unreadable path in header: '${old:-?}' -> '${new:-?}'"$'\n'; continue
    fi
    root="$(pkg_root "$target")"
    if [[ $old == /dev/null ]]; then                       # patch creates a new file
      if [[ -e $MAGENTO_ROOT/$target || -d $MAGENTO_ROOT/$root ]]; then keep+=("$idx"); else na_pkgs[$(pkg_label "$root")]=1; fi
    elif [[ -e $MAGENTO_ROOT/$target ]]; then              # modifies / deletes an existing file
      keep+=("$idx")
    elif [[ -d $MAGENTO_ROOT/$root ]]; then                # package installed but file missing: real problem
      AP_MISSING+="$target (package $(pkg_label "$root") is installed but this file is missing)"$'\n'
    else
      na_pkgs[$(pkg_label "$root")]=1
    fi
  done < <(awk -v dir="$work/sec" "$PATCH_SPLIT_AWK" "$f")
  AP_OK=${#keep[@]}
  AP_NA_PKGS="$(printf '%s\n' "${!na_pkgs[@]}" | grep -v '^$' | sort | paste -sd, - | sed 's/,/, /g')"
  if (( AP_TOTAL == 0 )); then AP_STATUS=missing; AP_MISSING+="no file headers (--- / +++) found"$'\n'
  elif [[ -n $AP_MISSING ]]; then AP_STATUS=missing
  elif (( AP_OK == 0 )); then AP_STATUS=na
  elif (( AP_OK < AP_TOTAL )); then
    AP_STATUS=partial; AP_FILE="$work/applicable.patch"
    for idx in "${keep[@]}"; do cat "$work/sec/$idx.diff"; done >"$AP_FILE"
  else AP_STATUS=ok; fi
}

apply_bundle() {  # apply_bundle <name> <dir>  — all-or-nothing
  local name="$1" dir="$2" f out n=0; local -a files=() done_files=()
  mapfile -t files < <(select_patch_files "$dir")
  if [[ ${#files[@]} -eq 0 ]]; then alert "Empty bundle" "$name contains no .patch/.diff files"; return 3; fi
  info "$name: ${#files[@]} patch file(s)"
  APPLIED_COUNT=0; SKIPPED_COUNT=0; NA_COUNT=0
  rollback() {
    if (( ${#done_files[@]} )); then
      warn "  Rolling back ${#done_files[@]} patch(es) already applied from $name"
      for (( i=${#done_files[@]}-1; i>=0; i-- )); do P -R -s <"${done_files[$i]}" || warn "  rollback failed: ${done_files[$i]}"; done
    fi
  }
  for f in "${files[@]}"; do
    local rel="${f#"$dir"/}"; n=$((n + 1))
    assess_patch "$f" "$TMP_DIR/assess/$n"
    case "$AP_STATUS" in
      na)
        info "  - $rel: NOT APPLICABLE — targets packages not installed here: $AP_NA_PKGS"
        NA_COUNT=$((NA_COUNT + 1)); continue ;;
      missing)
        log ERROR "  x $rel: targets files that should exist but don't:"
        printf '%s' "$AP_MISSING" | sed 's/^/      /' | tee -a "$RUN_LOG" >&2
        rollback
        alert "Patch target missing" "$rel in $name targets files missing from installed packages (wrong version, or files removed/overridden?). Bundle rolled back; later bundles NOT applied."
        return 3 ;;
      partial)
        info "  ! $rel: $AP_OK of $AP_TOTAL files apply; skipping the rest — not installed here: $AP_NA_PKGS" ;;
    esac
    if P -R --dry-run -s <"$AP_FILE" >/dev/null 2>&1; then
      info "  = $rel (already applied)"; SKIPPED_COUNT=$((SKIPPED_COUNT + 1)); continue
    fi
    if ! out="$(P --dry-run <"$AP_FILE" 2>&1)"; then
      log ERROR "  x $rel will not apply cleanly:"; printf '%s\n' "$out" | sed 's/^/      /' | tee -a "$RUN_LOG" >&2
      rollback
      alert "Patch conflict" "$rel in $name does not apply to $INSTALLED (core files modified, or a vendor override?). Bundle rolled back; later bundles NOT applied."
      return 3
    fi
    if (( DRY_RUN )); then info "  ~ $rel (would apply)"; else
      P -s <"$AP_FILE"; info "  + $rel"
      cp "$AP_FILE" "$TMP_DIR/assess/$n.applied"; done_files+=("$TMP_DIR/assess/$n.applied"); fi
    APPLIED_COUNT=$((APPLIED_COUNT + 1))
  done
  return 0
}

SUMMARY=(); ANY_APPLIED=0; RC=0
for ym in $MONTHS; do
  REL="$(pretty_ym "$ym")"
  if [[ -n ${EXACT[$ym]:-} ]]; then
    read -r p url name <<<"${EXACT[$ym]}"
  elif [[ -n ${HIGHER[$ym]:-} ]]; then
    read -r p url name <<<"${HIGHER[$ym]}"
    alert "Upgrade required" "The $REL security bundle ($name) requires Magento $BASE-p$p; this site is on $INSTALLED. Upgrade to $BASE-p$p first — this and any later bundles have NOT been applied."
    SUMMARY+=("BLOCKED  $REL  $name  — needs $BASE-p$p (installed $INSTALLED)")
    RC=2; break
  else
    read -r p url name <<<"${LOWER[$ym]}"
    warn "Skipping $name ($REL) — targets $BASE-p$p, installed is $INSTALLED (fixes should already be included)"
    SUMMARY+=("SKIPPED  $REL  $name  — targets older p$p"); continue
  fi

  if prev="$(awk -F'|' -v n="$name" '$1==n {print $5}' "$APPLIED_LOG" | tail -1)" && [[ -n $prev ]]; then
    info "$name ($REL) already recorded as applied on $prev"; continue
  fi

  zip="$DL_DIR/$name"; dir="$EX_DIR/${name%.zip}"
  if [[ ! -s $zip ]]; then
    info "Downloading $url"
    fetch "$url" -q -T 60 -t 3 -O "$zip.part" || { rm -f "$zip.part"; alert "Download failed" "$url"; RC=1; break; }
    mv "$zip.part" "$zip"
  fi
  unzip -tqq "$zip" >/dev/null 2>&1 || { rm -f "$zip"; alert "Corrupt download" "$name failed zip integrity check (deleted; will retry next run)"; RC=1; break; }
  rm -rf "$dir"; mkdir -p "$dir"; unzip -qq -o "$zip" -d "$dir"
  SHA="$(sha256sum "$zip" | cut -d' ' -f1)"

  info "${C_B}Applying $REL security bundle${C_0} — $name (for $BASE-p$p)"
  if apply_bundle "$name" "$dir"; then
    STAMP="$(date '+%F %T %Z')"
    if (( DRY_RUN )); then
      SUMMARY+=("DRY-RUN  $REL  $name  — $APPLIED_COUNT would apply, $SKIPPED_COUNT already present, $NA_COUNT not applicable")
    else
      echo "$name|$BASE-p$p|$ym|$REL|$STAMP|$SHA|$APPLIED_COUNT/$SKIPPED_COUNT/$NA_COUNT" >>"$APPLIED_LOG"
      SUMMARY+=("APPLIED  $REL  $name  — released $REL, applied $STAMP ($APPLIED_COUNT new, $SKIPPED_COUNT already present, $NA_COUNT not applicable)")
      (( APPLIED_COUNT > 0 )) && ANY_APPLIED=1
      ok "$REL bundle applied ($name)"
    fi
  else
    RC=$?; SUMMARY+=("FAILED   $REL  $name  — rolled back; later months not attempted"); break
  fi
done

# ------------------------------------------------------- post-apply --------
if (( ANY_APPLIED )); then
  cd "$MAGENTO_ROOT"
  if (( DI_COMPILE )); then info "Running setup:di:compile"; php bin/magento setup:di:compile --no-ansi || warn "di:compile failed"; fi
  if (( CACHE_FLUSH )); then info "Flushing cache"; php bin/magento cache:flush --no-ansi >/dev/null || warn "cache:flush failed"; fi
  MODE="$(php bin/magento deploy:mode:show --no-ansi 2>/dev/null | grep -Eo 'production|developer|default' | head -1 || true)"
  [[ $MODE == production && $DI_COMPILE == 0 ]] && warn "Site is in production mode — if patches touched PHP classes/DI or frontend assets, run setup:di:compile and setup:static-content:deploy"
  warn "Patches under vendor/ are overwritten by 'composer install' — re-run this script after any composer install/update"
fi

echo >&2
printf '%s\n' "${C_B}Summary for $MAGENTO_ROOT (Magento $INSTALLED)${C_0}" >&2
if (( ${#SUMMARY[@]} )); then printf '  %s\n' "${SUMMARY[@]}" | tee -a "$RUN_LOG" >&2
else printf '  %s\n' "Everything up to date — no new bundles." >&2; fi
echo "  History: $APPLIED_LOG   Log: $RUN_LOG" >&2
exit "$RC"
}

main "$@" </dev/null
