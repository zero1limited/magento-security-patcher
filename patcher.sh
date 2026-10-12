#!/usr/bin/env bash
# =============================================================================
#  patcher.sh  —  ZERO-1 Magento security patcher
#  https://github.com/zero1limited/magento-security-patcher
#
#  One command to bring a Magento / Adobe Commerce install up to date with
#  Adobe's isolated security patches, driven by the official registry:
#    https://repo.magento.com/patch/patch-registry.json
#
#    1. Detects the installed version of every registry "area" (CE core
#       version, plus EE / B2B / PageBuilder / ... from composer packages)
#    2. Selects every registry patch whose applies_to matches what's installed
#    3. Orders them by their "requires" chain (then release date) and refuses
#       any patch whose prerequisites can't be met
#    4. Downloads each .diff, verifies its sha256 against the registry, checks
#       every target file exists (reports Not Applicable otherwise), then
#       applies it — skipping anything already applied
#    5. Alerts (stderr / Slack-style webhook / email) when newer patches exist
#       for a higher patch level, or anything fails
#
#  Usage:  curl -fsSL <raw-url>/patcher.sh | bash -s -- [options]
#          ./patcher.sh [options]          (run with -h for options)
#  Needs:  bash 4+, GNU date, wget, patch, php, awk, sha256sum/shasum
#
#  Exit codes: 0 up to date, 1 error, 2 newer patches need a version upgrade,
#              3 a patch failed (conflict / missing file / download / hash)
# =============================================================================

# Everything runs inside main(), which is only called on the last line. When the
# script is piped (curl ... | bash) this means a truncated download runs nothing,
# and no command inside can read the rest of the script from stdin.
main() {
set -Eeuo pipefail
export LC_ALL=C

# ---------------------------------------------------------------- defaults ---
MAGENTO_ROOT="${MAGENTO_ROOT:-$(pwd)}"
REGISTRY="${REGISTRY:-https://repo.magento.com/patch/patch-registry.json}"  # URL or local file
STATE_DIR="${STATE_DIR:-}"                # default: $MAGENTO_ROOT/var/security-patches
ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"        # Slack/Teams-style incoming webhook
ALERT_EMAIL="${ALERT_EMAIL:-}"            # needs a working `mail` command
DRY_RUN=0
CACHE_FLUSH=1
DI_COMPILE=0

usage() {
  cat <<EOF
Usage: patcher.sh [options]
       curl -fsSL https://raw.githubusercontent.com/zero1limited/magento-security-patcher/master/patcher.sh | bash -s -- [options]

  -r, --root DIR          Magento root (default: current directory)
      --registry URL|FILE Patch registry (default: $REGISTRY)
  -n, --dry-run           Download, verify and test every patch against a scratch copy; change nothing
      --no-cache-flush    Skip bin/magento cache:flush after applying
      --compile           Run bin/magento setup:di:compile after applying
      --webhook URL       Post alerts to this webhook (not sent on dry runs)
      --email ADDR        Email alerts to this address (not sent on dry runs)
  -h, --help              Show this help

Credentials for repo.magento.com (only needed for patches with entitlements,
e.g. extended-support versions) are read from the first found of:
  \$MAGENTO_REPO_USER / \$MAGENTO_REPO_PASS, <root>/auth.json,
  \$COMPOSER_HOME/auth.json, ~/.config/composer/auth.json, ~/.composer/auth.json
They are only ever sent to repo.magento.com.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--root)        MAGENTO_ROOT="$2"; shift 2 ;;
    --registry)       REGISTRY="$2"; shift 2 ;;
    -n|--dry-run)     DRY_RUN=1; shift ;;
    --no-cache-flush) CACHE_FLUSH=0; shift ;;
    --compile)        DI_COMPILE=1; shift ;;
    --webhook)        ALERT_WEBHOOK="$2"; shift 2 ;;
    --email)          ALERT_EMAIL="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

MAGENTO_ROOT="$(cd "$MAGENTO_ROOT" && pwd)"
STATE_DIR="${STATE_DIR:-$MAGENTO_ROOT/var/security-patches}"
DL_DIR="$STATE_DIR/downloads"
APPLIED_LOG="$STATE_DIR/applied.log"
RUN_LOG="$STATE_DIR/run.log"
mkdir -p "$DL_DIR"
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
  if (( DRY_RUN )); then
    [[ -n $ALERT_WEBHOOK || -n $ALERT_EMAIL ]] && info "(dry run — alert not sent to webhook/email)"
    return 0
  fi
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
for bin in wget patch php awk date; do
  command -v "$bin" >/dev/null || die "Required command not found: $bin"
done
if command -v sha256sum >/dev/null; then sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null; then sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else die "Required command not found: sha256sum (or shasum)"; fi
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
  'foreach(($j["packages"]??[]) as $p){ if(preg_match("#^magento/product-(community|enterprise)-edition$#",$p["name"])){ echo ltrim($p["version"],"v"); break; } }')"
V_JSON="$(php_json "$MAGENTO_ROOT/composer.json" \
  'echo $j["require"]["magento/product-enterprise-edition"] ?? $j["require"]["magento/product-community-edition"] ?? "";')"
V_JSON="${V_JSON#[=^~v]}"

INSTALLED="${V_CLI:-${V_LOCK:-$V_JSON}}"
[[ -n $INSTALLED ]] || die "Could not detect Magento version (bin/magento -V, composer.lock and composer.json all failed)"
info "Detected Magento $INSTALLED  (bin/magento: ${V_CLI:-n/a} | composer.lock: ${V_LOCK:-n/a} | composer.json: ${V_JSON:-n/a})"
if [[ -n $V_JSON && $V_JSON =~ ^[0-9] && $V_JSON != "$INSTALLED" ]]; then
  warn "composer.json requires $V_JSON but $INSTALLED is installed — has a composer update been left unfinished?"
fi
[[ $INSTALLED =~ ^[0-9]+\.[0-9]+\.[0-9]+(-p[0-9]+(\.[0-9]+)?)?$ ]] || die "Unrecognised version string: $INSTALLED"

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
    info "No repo.magento.com keys found — fine for public patches; entitled (extended-support) patches will need them"
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
http_status() {  # final HTTP status for a URL
  fetch "$1" --spider -S -T 20 -t 2 2>&1 | awk '/^ *HTTP\//{c=$2} END{print c+0}' || true
}

# --------------------------------------------------------------- registry ---
REG_FILE="$TMP_DIR/registry.json"
if [[ -f $REGISTRY ]]; then
  cp "$REGISTRY" "$REG_FILE"; info "Using local registry $REGISTRY"
elif [[ $REGISTRY =~ ^https?:// ]]; then
  fetch "$REGISTRY" -q -T 30 -t 3 -O "$REG_FILE" || { alert "Registry unavailable" "Could not download $REGISTRY"; exit 1; }
  info "Fetched patch registry $REGISTRY"
else
  die "Registry not found: $REGISTRY"
fi

# The planner reads the registry + installed packages, and prints a TSV plan:
#   FATAL|WARN|INFO <msg>          BASE <patch_base_url>
#   AREA <area> <version|-> <source>
#   PLAN <id> <area> <ver> <file_name> <sha256> <released> <requires,..> <recorded sha|-> <cve count> <entitled 0|1>
#   SKIP <id> <area> <released> <reason>
#   UPGRADE <area> <installed> <newer version> <patch count> <latest released>
cat >"$TMP_DIR/plan.php" <<'PHP'
<?php
[, $regFile, $root, $ceVersion, $appliedLog] = $argv;
function out(...$f) { echo implode("\t", array_map(function ($x) { return str_replace(["\t", "\n", "\r"], ' ', (string)$x); }, $f)), "\n"; }
function pv($v) { return preg_match('/^(\d+\.\d+\.\d+)(?:-p(\d+))?/', (string)$v, $m) ? [$m[1], (int)($m[2] ?? 0)] : null; }

$reg = json_decode((string)@file_get_contents($regFile), true);
if (!is_array($reg) || !isset($reg['patches']) || !is_array($reg['patches'])) { out('FATAL', 'registry is not valid JSON or has no "patches" object'); exit(0); }
$schemaV = (string)($reg['_schema']['version'] ?? '?');
if (!preg_match('/^1\./', $schemaV)) out('WARN', "unexpected registry schema version $schemaV (this script understands 1.x)");
$base = rtrim((string)($reg['_schema']['patch_base_url'] ?? ''), '/');
if ($base === '') { out('FATAL', 'registry has no _schema.patch_base_url — refusing to guess where patches live'); exit(0); }
if (strpos($base . '/', 'https://repo.magento.com/') !== 0) { out('FATAL', "patch_base_url '$base' is not on https://repo.magento.com/ — refusing"); exit(0); }
out('BASE', $base);

// Installed packages: vendor/composer/installed.json (what's really there) first, then composer.lock
$installed = [];
foreach (["$root/vendor/composer/installed.json" => 'vendor/composer/installed.json', "$root/composer.lock" => 'composer.lock'] as $f => $src) {
    if (!is_file($f)) continue;
    $j = json_decode((string)file_get_contents($f), true);
    if (!is_array($j)) continue;
    $pk = isset($j['packages']) ? array_merge($j['packages'], $j['packages-dev'] ?? []) : (isset($j[0]) ? $j : []);
    foreach ($pk as $p) {
        if (!isset($p['name'], $p['version'])) continue;
        $n = strtolower($p['name']);
        if (!isset($installed[$n])) $installed[$n] = [ltrim($p['version'], 'vV'), $src];
    }
}

// Installed version per area
$areas = $reg['_areas'] ?? [];
$areaVer = [];
foreach ($areas as $area => $def) {
    if (($def['detection'] ?? '') === 'base_version') { $areaVer[$area] = $ceVersion; out('AREA', $area, $ceVersion, 'installed Magento version'); continue; }
    $pkg = strtolower((string)($def['composer_package'] ?? ''));
    if ($pkg !== '' && isset($installed[$pkg])) { $areaVer[$area] = $installed[$pkg][0]; out('AREA', $area, $installed[$pkg][0], "$pkg ({$installed[$pkg][1]})"); }
    else out('AREA', $area, '-', $pkg !== '' ? $pkg : 'no detection rule');
}

// Already recorded: R|id|area|ver|released|applied_at|sha256|result
$applied = [];
if (is_file($appliedLog)) foreach (file($appliedLog, FILE_IGNORE_NEW_LINES) as $l) {
    $c = explode('|', $l);
    if (count($c) >= 8 && $c[0] === 'R') $applied[$c[1]] = $c[6];
}

$P = $reg['patches'];
$cand = []; $bad = [];
foreach ($P as $id => $p) {
    $area = (string)($p['area'] ?? '');
    if (!isset($areas[$area])) continue;
    if (!isset($areaVer[$area]) || !in_array($areaVer[$area], (array)($p['applies_to'] ?? []), true)) continue;
    $fn = (string)($p['file_name'] ?? ''); $sha = strtolower((string)($p['sha256'] ?? ''));
    if (!preg_match('/^[A-Za-z0-9][A-Za-z0-9._-]*\.(diff|patch)$/', $fn)) { $bad[$id] = "unsupported file_name '$fn' in registry (expected a .diff or .patch)"; continue; }
    if (!preg_match('/^[0-9a-f]{64}$/', $sha)) { $bad[$id] = 'missing/invalid sha256 in registry'; continue; }
    $cand[$id] = $p;
}

// Prerequisites: each must be in the plan, already recorded, or it blocks (transitively)
do {
    $changed = false;
    foreach ($cand as $id => $p) {
        foreach ((array)($p['requires'] ?? []) as $r) {
            $why = null;
            if (isset($bad[$r])) $why = "requires $r, which can't be applied";
            elseif (isset($cand[$r]) || isset($applied[$r])) continue;
            elseif (!isset($P[$r])) $why = "requires $r, which is not in the registry";
            else $why = "requires $r, which does not apply to this install (" . ($P[$r]['area'] ?? '?') . ' ' . implode('/', (array)($P[$r]['applies_to'] ?? [])) . ')';
            $bad[$id] = $why; unset($cand[$id]); $changed = true; break;
        }
    }
} while ($changed);
foreach ($bad as $id => $why) out('SKIP', $id, $P[$id]['area'] ?? '?', $P[$id]['released'] ?? '?', $why);

// Topological order on "requires", ties broken by release date then id
$indeg = []; $kids = [];
foreach ($cand as $id => $p) { $indeg[$id] = 0; }
foreach ($cand as $id => $p) foreach ((array)($p['requires'] ?? []) as $r) if (isset($cand[$r])) { $indeg[$id]++; $kids[$r][] = $id; }
$key = function ($id) use ($cand) { return ($cand[$id]['released'] ?? '9999') . "\0" . $id; };
$ready = array_keys(array_filter($indeg, function ($d) { return $d === 0; }));
$order = [];
while ($ready) {
    usort($ready, function ($a, $b) use ($key) { return strcmp($key($a), $key($b)); });
    $id = array_shift($ready); $order[] = $id;
    foreach ($kids[$id] ?? [] as $k) if (--$indeg[$k] === 0) $ready[] = $k;
}
foreach ($cand as $id => $p) if (!in_array($id, $order, true)) out('SKIP', $id, $p['area'], $p['released'] ?? '?', 'dependency cycle in registry requires');
foreach ($order as $id) {
    $p = $cand[$id];
    out('PLAN', $id, $p['area'], $areaVer[$p['area']], $p['file_name'], strtolower($p['sha256']), $p['released'] ?? '?',
        implode(',', (array)($p['requires'] ?? [])) ?: '-', $applied[$id] ?? '-', count((array)($p['cves'] ?? [])), empty($p['entitlements']) ? 0 : 1);
}

// Newer patch levels on the same line (e.g. installed 2.4.7-p9, patches exist for 2.4.7-p10)
foreach ($areaVer as $area => $iv) {
    $mine = pv($iv); if (!$mine) continue;
    $newer = []; $latest = '';
    foreach ($P as $id => $p) {
        if (($p['area'] ?? '') !== $area || in_array($iv, (array)($p['applies_to'] ?? []), true)) continue;
        foreach ((array)($p['applies_to'] ?? []) as $v) {
            $t = pv($v);
            if ($t && $t[0] === $mine[0] && $t[1] > $mine[1]) { $newer[$v][] = $id; $latest = max($latest, (string)($p['released'] ?? '')); }
        }
    }
    if ($newer) {
        uksort($newer, function ($a, $b) { return pv($a)[1] <=> pv($b)[1]; });
        $keys = array_keys($newer); $top = end($keys);
        out('UPGRADE', $area, $iv, $top, count($newer[$top]), $latest);
    } elseif (($areas[$area]['detection'] ?? '') === 'base_version') {
        $any = false;
        foreach ($P as $p) if (in_array($iv, (array)($p['applies_to'] ?? []), true)) { $any = true; break; }
        if (!$any) out('UNSUPPORTED', $area, $iv);
    }
}
PHP
php "$TMP_DIR/plan.php" "$REG_FILE" "$MAGENTO_ROOT" "$INSTALLED" "$APPLIED_LOG" >"$TMP_DIR/plan.tsv" \
  || die "Registry planner failed (php error)"

BASE_URL=""; UNSUPPORTED=""; declare -a PLAN=() SKIPS=() UPGRADES=()
while IFS=$'\t' read -r kind a b c d e f g h i j; do
  case "$kind" in
    FATAL)   alert "Registry rejected" "$a"; exit 1 ;;
    WARN)    warn "$a" ;;
    BASE)    BASE_URL="$a" ;;
    AREA)    [[ $b != - ]] && info "  area $(printf '%-12s' "$a") $b  ($c)" ;;
    PLAN)    PLAN+=("$a"$'\t'"$b"$'\t'"$c"$'\t'"$d"$'\t'"$e"$'\t'"$f"$'\t'"$g"$'\t'"$h"$'\t'"$i"$'\t'"$j") ;;
    SKIP)    SKIPS+=("$a"$'\t'"$b"$'\t'"$c"$'\t'"$d") ;;
    UPGRADE) UPGRADES+=("$a"$'\t'"$b"$'\t'"$c"$'\t'"$d"$'\t'"$e") ;;
    UNSUPPORTED) UNSUPPORTED="$b" ;;
  esac
done <"$TMP_DIR/plan.tsv"
info "Registry: ${#PLAN[@]} patch(es) apply to this install, ${#SKIPS[@]} blocked"

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

# Dry runs apply everything for real to a scratch copy of just the files the
# patches touch, so chained patches (Sep requires Aug requires Jul) are each
# tested against the result of the previous one — exactly like a real run.
APPLY_ROOT="$MAGENTO_ROOT"; declare -A SHADOW=()
if (( DRY_RUN )); then APPLY_ROOT="$TMP_DIR/shadow"; mkdir -p "$APPLY_ROOT"; fi
t_exists() { if (( DRY_RUN )) && [[ -n ${SHADOW[$1]:-} ]]; then [[ -e $APPLY_ROOT/$1 ]]; else [[ -e $MAGENTO_ROOT/$1 ]]; fi; }
d_exists() { [[ -d $MAGENTO_ROOT/$1 || -d $APPLY_ROOT/$1 ]]; }
shadow_prepare() {  # copy targets into the scratch copy the first time they're touched
  (( DRY_RUN )) || return 0
  local t
  for t in "$@"; do
    [[ -n ${SHADOW[$t]:-} ]] && continue; SHADOW[$t]=1
    if [[ -e $MAGENTO_ROOT/$t ]]; then mkdir -p "$APPLY_ROOT/$(dirname "$t")"; cp -p "$MAGENTO_ROOT/$t" "$APPLY_ROOT/$t"; fi
  done
}

# assess_patch <patch file> <work dir>
# Sets: AP_STATUS (ok|partial|na|missing), AP_FILE (patch to apply: original or
# filtered), AP_TOTAL, AP_OK, AP_NA_PKGS, AP_MISSING, AP_TARGETS (kept targets)
assess_patch() {
  local f="$1" work="$2" idx old new target root
  local -a keep=(); local -A na_pkgs=()
  rm -rf "$work"; mkdir -p "$work/sec"
  AP_TOTAL=0; AP_OK=0; AP_MISSING=""; AP_NA_PKGS=""; AP_FILE="$f"; AP_TARGETS=()
  while IFS=$'\t' read -r idx old new; do
    [[ -z $idx ]] && continue
    AP_TOTAL=$((AP_TOTAL + 1))
    target="$old"; [[ $old == /dev/null || -z $old ]] && target="$new"
    if [[ -z $target || $target == /dev/null || $target == /* || /$target/ == */../* ]]; then
      AP_MISSING+="unsafe or unreadable path in header: '${old:-?}' -> '${new:-?}'"$'\n'; continue
    fi
    root="$(pkg_root "$target")"
    if [[ $old == /dev/null ]]; then                       # patch creates a new file
      if t_exists "$target" || d_exists "$root"; then keep+=("$idx"); AP_TARGETS+=("$target"); else na_pkgs[$(pkg_label "$root")]=1; fi
    elif t_exists "$target"; then                          # modifies / deletes an existing file
      keep+=("$idx"); AP_TARGETS+=("$target")
    elif d_exists "$root"; then                            # package installed but file missing: real problem
      AP_MISSING+="$target (package $(pkg_label "$root") is installed but this file is missing)"$'\n'
    else
      na_pkgs[$(pkg_label "$root")]=1
    fi
  done < <(awk -v dir="$work/sec" "$PATCH_SPLIT_AWK" "$f")
  AP_OK=${#keep[@]}
  AP_NA_PKGS="$(printf '%s\n' "${!na_pkgs[@]}" | grep -v '^$' | sort | paste -sd, - | sed 's/,/, /g' || true)"
  if (( AP_TOTAL == 0 )); then AP_STATUS=missing; AP_MISSING+="no file headers (--- / +++) found"$'\n'
  elif [[ -n $AP_MISSING ]]; then AP_STATUS=missing
  elif (( AP_OK == 0 )); then AP_STATUS=na
  elif (( AP_OK < AP_TOTAL )); then
    AP_STATUS=partial; AP_FILE="$work/applicable.patch"
    for idx in "${keep[@]}"; do cat "$work/sec/$idx.diff"; done >"$AP_FILE"
  else AP_STATUS=ok; fi
}

# Same strictness as Adobe's own vendor/bin/patch-status tool: no fuzz, never prompt
P() { patch -d "$APPLY_ROOT" -p1 --fuzz=0 --batch --forward --no-backup-if-mismatch "$@"; }

# apply_unit <id> <patch files...>  — all-or-nothing; sets UNIT_RESULT (applied|already|na) + counts
apply_unit() {
  local id="$1"; shift
  local f out n=0 rel; local -a done_files=()
  U_NEW=0; U_ALREADY=0; U_NA=0; U_NOTE=""
  rollback() {
    local i
    for (( i=${#done_files[@]}-1; i>=0; i-- )); do P -R -s <"${done_files[$i]}" || warn "  rollback failed: ${done_files[$i]}"; done
  }
  for f in "$@"; do
    rel="$(basename "$f")"; n=$((n + 1))
    assess_patch "$f" "$TMP_DIR/assess/$id/$n"
    case "$AP_STATUS" in
      na)
        info "    - $rel: NOT APPLICABLE — targets packages not installed here: $AP_NA_PKGS"
        U_NA=$((U_NA + 1)); U_NOTE="not installed: $AP_NA_PKGS"; continue ;;
      missing)
        log ERROR "    x $rel targets files that should exist but don't:"
        printf '%s' "$AP_MISSING" | sed 's/^/        /' | tee -a "$RUN_LOG" >&2
        rollback; U_NOTE="target file(s) missing from installed packages"; return 3 ;;
      partial)
        info "    ! $rel: $AP_OK of $AP_TOTAL files apply; skipping the rest — not installed here: $AP_NA_PKGS"
        U_NOTE="partly N/A: $AP_NA_PKGS" ;;
    esac
    shadow_prepare "${AP_TARGETS[@]}"
    if P -R --dry-run -s <"$AP_FILE" >/dev/null 2>&1; then
      info "    = $rel (already applied)"; U_ALREADY=$((U_ALREADY + 1)); continue
    fi
    if ! out="$(P --dry-run <"$AP_FILE" 2>&1)"; then
      log ERROR "    x $rel will not apply cleanly:"; printf '%s\n' "$out" | sed 's/^/        /' | tee -a "$RUN_LOG" >&2
      rollback; U_NOTE="does not apply cleanly (modified core files or a vendor override?)"; return 3
    fi
    P -s <"$AP_FILE"
    cp "$AP_FILE" "$TMP_DIR/assess/$id/$n.applied"; done_files+=("$TMP_DIR/assess/$id/$n.applied")
    if (( DRY_RUN )); then info "    ~ $rel (would apply)"; else info "    + $rel"; fi
    U_NEW=$((U_NEW + 1))
  done
  if   (( U_NEW > 0 )); then UNIT_RESULT=applied
  elif (( U_ALREADY > 0 )); then UNIT_RESULT=already
  else UNIT_RESULT=na; fi
  return 0
}

# ------------------------------------------------------------ apply plan ----
declare -A FAILED=()
SUMMARY=(); ANY_APPLIED=0; RC=0
row() { SUMMARY+=("$(printf '%-9s %s  %-28s %s' "$1" "$2" "$3" "$4")"); }

for line in "${SKIPS[@]}"; do
  IFS=$'\t' read -r id area rel why <<<"$line"
  FAILED[$id]=blocked; warn "Blocked: $id — $why"; row BLOCKED "$rel" "$id" "— $why"
done

for line in "${PLAN[@]}"; do
  IFS=$'\t' read -r id area ver file sha rel reqs recorded ncve entitled <<<"$line"
  label="$area $ver, $ncve CVE$([[ $ncve == 1 ]] || echo s)"
  info "${C_B}$id${C_0}  ($label, released $rel)"

  # prerequisites that failed earlier in this run block this patch too
  blocker=""
  if [[ $reqs != - ]]; then
    IFS=, read -r -a req_arr <<<"$reqs"
    for r in "${req_arr[@]}"; do [[ -n ${FAILED[$r]:-} ]] && { blocker="$r"; break; }; done
  fi
  if [[ -n $blocker ]]; then
    FAILED[$id]=blocked; warn "  Skipped — requires $blocker, which failed"; row SKIPPED "$rel" "$id" "— requires $blocker, which failed"; continue
  fi

  if [[ $recorded == "$sha" ]]; then
    info "  already recorded as applied"; continue
  elif [[ $recorded != - ]]; then
    warn "  registry sha256 changed since this patch was recorded — re-checking"
  fi

  # download + integrity
  dest="$DL_DIR/$file"
  url="$BASE_URL/$file"   # exactly as the registry says; the server redirects entitled patches itself
  if [[ ! -s $dest || "$(sha256 "$dest")" != "$sha" ]]; then
    rm -f "$dest" "$dest.part"
    if ! fetch "$url" -q -T 60 -t 3 -O "$dest.part"; then
      rm -f "$dest.part"; code="$(http_status "$url")"
      if [[ $code == 401 || $code == 403 ]]; then
        if [[ -n $CRED_RC ]]; then why="repo.magento.com keys were rejected — check they carry the required entitlement (HTTP $code)"
        else why="needs repo.magento.com keys with the required entitlement (HTTP $code)"; fi
      else why="download failed (HTTP ${code:-?})"; fi
      FAILED[$id]=download; alert "Patch download failed" "$id: $why — $url"; row FAILED "$rel" "$id" "— $why"; RC=3; continue
    fi
    mv "$dest.part" "$dest"
  fi
  got="$(sha256 "$dest")"
  if [[ $got != "$sha" ]]; then
    rm -f "$dest"; FAILED[$id]=hash
    alert "Integrity check failed" "$id: sha256 $got does not match the registry ($sha). File deleted, NOT applied."
    row FAILED "$rel" "$id" "— sha256 mismatch (not applied)"; RC=3; continue
  fi
  info "  sha256 verified"

  if apply_unit "$id" "$dest"; then
    stamp="$(date '+%F %T %Z')"
    case "$UNIT_RESULT" in
      applied) what="$([[ $DRY_RUN == 1 ]] && echo WOULD-APPLY || echo APPLIED)"; ANY_APPLIED=1 ;;
      already) what=ALREADY ;;
      na)      what=N/A ;;
    esac
    row "$what" "$rel" "$id" "($label)${U_NOTE:+ — $U_NOTE}"
    if (( ! DRY_RUN )); then
      echo "R|$id|$area|$ver|$rel|$stamp|$sha|$UNIT_RESULT" >>"$APPLIED_LOG"
      if [[ $UNIT_RESULT == applied ]]; then ok "  $id applied"; fi
    fi
  else
    FAILED[$id]=apply; RC=3
    alert "Patch failed" "$id ($label): $U_NOTE. Nothing from this patch was applied; patches that require it are skipped."
    row FAILED "$rel" "$id" "— $U_NOTE"
  fi
done

for line in "${UPGRADES[@]}"; do
  IFS=$'\t' read -r area cur newer count latest <<<"$line"
  alert "Upgrade required" "$area is on $cur, but $count newer security patch(es) up to $latest only apply to $newer. Upgrade $area to $newer to receive them."
  row UPGRADE "$latest" "$area $cur -> $newer" "— $count patch(es) need $newer"
  (( RC == 0 )) && RC=2
done

if [[ -n $UNSUPPORTED ]]; then
  alert "Unsupported version" "No patch in Adobe's registry applies to Magento $UNSUPPORTED — this release line is likely out of security support. Plan an upgrade to a supported version."
  row UNSUPPORTED "-" "Magento $UNSUPPORTED" "— no registry patches for this version"
  (( RC == 0 )) && RC=2
fi

# ------------------------------------------------------- post-apply --------
if (( ANY_APPLIED && ! DRY_RUN )); then
  cd "$MAGENTO_ROOT"
  if (( DI_COMPILE )); then info "Running setup:di:compile"; php bin/magento setup:di:compile --no-ansi || warn "di:compile failed"; fi
  if (( CACHE_FLUSH )); then info "Flushing cache"; php bin/magento cache:flush --no-ansi >/dev/null || warn "cache:flush failed"; fi
  MODE="$(php bin/magento deploy:mode:show --no-ansi 2>/dev/null | grep -Eo 'production|developer|default' | head -1 || true)"
  [[ $MODE == production && $DI_COMPILE == 0 ]] && warn "Site is in production mode — if patches touched PHP classes/DI or frontend assets, run setup:di:compile and setup:static-content:deploy"
  warn "Patches under vendor/ are overwritten by 'composer install' — re-run this script after any composer install/update"
fi

echo >&2
printf '%s\n' "${C_B}Summary for $MAGENTO_ROOT (Magento $INSTALLED)$([[ $DRY_RUN == 1 ]] && echo ' — DRY RUN, nothing changed')${C_0}" >&2
if (( ${#SUMMARY[@]} )); then printf '  %s\n' "${SUMMARY[@]}" | tee -a "$RUN_LOG" >&2
else printf '  %s\n' "Up to date — every registry patch for this install is already applied." >&2; fi
echo "  History: $APPLIED_LOG   Log: $RUN_LOG" >&2
exit "$RC"
}

main "$@" </dev/null
