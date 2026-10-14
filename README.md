# magento-security-patcher

Brings a Magento / Adobe Commerce install up to date with Adobe's isolated security patches in one command. Adobe's official [patch registry](https://repo.magento.com/patch/patch-registry.json) drives what gets applied, so nothing is guessed. Each patch is checked against what's actually installed, applied in the order its `requires` chain demands, and verified against the registry's sha256 before anything is touched.

Maintained by [ZERO-1](https://www.zero1.co.uk).

## Quick start

Run from the Magento root:

```bash
curl -fsSL https://raw.githubusercontent.com/zero1limited/magento-security-patcher/master/patcher.sh | bash
```

Pass options after `bash -s --`:

```bash
# Dry run: download, verify and test every patch; change nothing
curl -fsSL https://raw.githubusercontent.com/zero1limited/magento-security-patcher/master/patcher.sh | bash -s -- -n

# Real run with Slack alerts
curl -fsSL https://raw.githubusercontent.com/zero1limited/magento-security-patcher/master/patcher.sh | bash -s -- --webhook https://hooks.slack.com/services/T000/B000/XXXX

# Webhook from an environment variable (keeps it out of shell history); note it goes on the bash side of the pipe
curl -fsSL https://raw.githubusercontent.com/zero1limited/magento-security-patcher/master/patcher.sh | ALERT_WEBHOOK=https://hooks.slack.com/services/T000/B000/XXXX bash
```

Always keep the `-f` in `curl -fsSL`. Without it, a 404 or GitHub error page gets passed to bash and run as commands.

## How it works

1. **Reads the registry** from `https://repo.magento.com/patch/patch-registry.json`. Every download URL comes from the registry (`patch_base_url` + `file_name`); nothing is guessed or constructed. The script refuses a registry with no `patch_base_url`, or one that isn't on `https://repo.magento.com/`, and only accepts `.diff`/`.patch` files.
2. **Detects what's installed, per area.** The registry splits patches by area:
   - **CE** uses the Magento version, from `bin/magento -V`, falling back to `composer.lock` / `composer.json`.
   - **Every other area** (EE, B2B, PageBuilder, Inventory, …) uses the version of its composer package. It reads `vendor/composer/installed.json` first because that's what's actually on disk, then `composer.lock`. For example, B2B uses the version of `magento/extension-b2b`, such as `1.5.3`.
3. **Selects the patches** whose `area` is installed and whose `applies_to` includes that area's exact installed version.
4. **Resolves `requires`.** Every prerequisite must be in the plan or already applied. If one can't be met (not in the registry, or for a different version), the patch is **blocked**, along with anything that depends on it.
5. **Orders the patches** topologically on `requires`, with ties broken by `released` date. For example, Sep requires Aug, which requires Jul, and the standalone `VULN-*` hotfixes slot in by date.
6. **Downloads and verifies each `.diff`** from exactly the URL the registry gives. For patches with `entitlements` (extended-support versions), repo.magento.com redirects to its authenticated location and your keys go along with the request. Every file's **sha256 must match the registry** or it's deleted and not applied.
7. **Checks the patch targets.** Every `---`/`+++` target is checked against the install:
   - **Target exists:** the change is applied.
   - **Whole package not installed:** reported as **Not Applicable** and skipped. If only some files in a patch are N/A, the rest of that patch is still applied.
   - **Package installed but the file is missing:** treated as a failure.
8. **Applies each patch with the same strictness as Adobe's own `vendor/bin/patch-status` tool:** `patch -p1 --fuzz=0 --batch --forward`. A patch that's already applied is detected and recorded rather than re-applied. If a patch fails, nothing from it is applied, the patches that depend on it are skipped, and unrelated patches still go ahead.
9. **Reports and alerts:**
   - If newer patches exist for a higher patch level on your release line (e.g. you're on `2.4.7-p9` and patches exist for `2.4.7-p10`), it raises an **upgrade alert**.
   - If no registry patch applies to your version at all, it raises an **unsupported-version alert**.
   - Everything applied is written to `var/security-patches/applied.log`.

Running it again is safe. **Every run checks the actual files; it never trusts the history.** `vendor/` is often rebuilt by `composer install` or a deploy while `var/` survives, so a patch recorded in `applied.log` is still checked against the code. If its changes have gone, it's re-applied and reported as `RE-APPLIED`. Checks are done file by file and are chain-aware: a file changed by July and then again by August counts as in place for July when August's change sits on top of it. A patch that's half in place (e.g. its `vendor/` files reverted but its `lib/` or `pub/` files still patched) only has its missing files applied. When Adobe adds a new month to the registry, the next run picks it up automatically.

## Dry run

`-n` downloads and verifies every patch, then applies the whole chain to a **scratch copy** of the affected files. Each chained patch (Jul → Aug → Sep) is tested against the result of the one before it, exactly as a real run would apply it. Nothing in the Magento install changes, and webhook/email alerts are logged but not sent. The only writes are to `var/security-patches/` (downloads, `run.log`, lock file).

## Check

`--check` reports the patch status of an install without changing anything. It ignores `applied.log` entirely, so the verdict comes from the files alone. That makes it the right tool for auditing a site, including patches applied some other way, e.g. by composer-patches.

```bash
curl -fsSL https://raw.githubusercontent.com/zero1limited/magento-security-patcher/master/patcher.sh | bash -s -- --check
```

Every registry patch that applies to the install gets one of these verdicts:

| Verdict | Meaning |
|---|---|
| `APPLIED` | Definitely applied: every file's change is exactly in place |
| `MISSING` | Definitely not applied: none of the changes are in place, and every one applies cleanly |
| `PARTIAL` | Some files' changes are in place and the rest apply cleanly (typically after `vendor/` was rebuilt but `lib/` or `pub/` weren't). The row says how many of each. |
| `N/A` | Targets packages that aren't installed |
| `UNKNOWN` | Can't be determined: a target file matches neither the patched nor the unpatched code (edited locally, or a different version of the fix), the download failed, or it depends on a patch that's `UNKNOWN` |

How the verdicts are decided:

- **File by file, at fuzz 0:** a change only counts as present or absent if it matches exactly.
- **In chain order:** August is judged as it would sit on top of July, so a chain where only some months are applied is reported correctly.
- **`APPLIED` and `MISSING` are only given when they're certain.** Anything ambiguous is `UNKNOWN`.

Exit codes for `--check`: `0` everything applicable is applied, `4` something is missing or partial, `3` something is unknown, `2` upgrade required or unsupported version.

## Reset

`--reset` starts from a clean slate. Use it straight after rebuilding `vendor/` (e.g. `rm -rf vendor && composer install`) when you want the whole patch chain applied from scratch and recorded fresh.

```bash
curl -fsSL https://raw.githubusercontent.com/zero1limited/magento-security-patcher/master/patcher.sh | bash -s -- --reset
```

- **History:** `var/security-patches/applied.log` is moved to `applied.log.<timestamp>.bak` and a new, empty history is started. The backup is kept so nothing is lost.
- **Applying:** every applicable patch is applied from the beginning of its chain, and the run is recorded as `APPLIED`, not `RE-APPLIED`.
- **If `vendor/` isn't actually clean:** the files are still checked, so nothing is applied twice and nothing breaks. Any patch found already fully or partly in place is listed in a `NOT-CLEAN` warning, so you know the baseline wasn't what you expected.
- **With `-n`:** `--reset -n` shows what a reset run would do without touching the history or any files.

## Options

| Option | Description |
|---|---|
| `-r, --root DIR` | Magento root (default: current directory) |
| `--registry URL\|FILE` | Patch registry (default: `https://repo.magento.com/patch/patch-registry.json`) |
| `-n, --dry-run` | Download, verify and test every patch against a scratch copy; change nothing |
| `--check` | Report only: which patches are definitely applied, missing or partial; changes nothing. See [Check](#check) |
| `--reset` | Start from a clean history and expect a clean (unpatched) `vendor/`; see [Reset](#reset) |
| `--no-cache-flush` | Don't run `cache:flush` afterwards |
| `--compile` | Run `setup:di:compile` after applying |
| `--webhook URL` | Send alerts to a Slack-style incoming webhook (not sent on dry runs) |
| `--email ADDR` | Email alerts (needs a working `mail` command; not sent on dry runs) |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Up to date, or everything applicable was applied |
| 1 | Error (registry unavailable, environment problem) |
| 2 | Newer patches need a version upgrade, or the version is unsupported |
| 3 | A patch failed: conflict, missing target file, download/auth failure, or sha256 mismatch (with `--check`: status unknown for at least one patch) |
| 4 | `--check` only: at least one patch is missing or partially applied |

### What reaches Slack / email

Only problems are sent: upgrade required, unsupported version, a patch failed or wouldn't apply cleanly, a sha256 mismatch, a download or authentication failure, or the registry being unavailable or rejected. Successful runs aren't posted; the summary goes to the terminal and `var/security-patches/run.log`.

## Credentials

Most patches are public. Patches with `entitlements` in the registry (currently the extended-support 2.4.4–2.4.6 and older B2B lines) need repo.magento.com keys with the matching entitlement, read from the first of these that exists:

1. `$MAGENTO_REPO_USER` / `$MAGENTO_REPO_PASS`
2. `<magento root>/auth.json`
3. `$COMPOSER_HOME/auth.json`, `~/.config/composer/auth.json`, `~/.composer/auth.json`

The keys are only ever sent to `repo.magento.com`.

## Running on a schedule

Point cron at a **tagged release**, not `master`. Otherwise every push to `master` runs as-is on client servers.

```cron
# 06:00 daily: picks up new registry patches as soon as Adobe publishes them
0 6 * * * cd /var/www/magento && bash <(curl -fsSL https://raw.githubusercontent.com/zero1limited/magento-security-patcher/v2.0.0/patcher.sh) --webhook https://hooks.slack.com/services/XXX >> /var/log/magento-patcher.log 2>&1
```

On instances built without `var/` (e.g. fresh development replicas), there's no history, so every applicable patch is evaluated from scratch against what's actually installed. Run the patcher **after** `composer install`, which would otherwise wipe patched files under `vendor/`, and before `setup:upgrade` / `setup:di:compile`.

## Notes

- **Requirements:** bash 4.2+ (works on older shared hosting such as CentOS/CloudLinux 7), GNU `date`, `wget`, `patch`, `php`, `awk` and `sha256sum` (or `shasum`). That covers any standard Linux Magento host.
- **`composer install` removes the patches.** Anything applied under `vendor/` is overwritten by `composer install` or `composer update`, so run the patcher again afterwards.
- **Production mode:** run `setup:di:compile` (or use `--compile`) and `setup:static-content:deploy` after patching if the patches touched PHP classes or frontend assets.
- **Adobe's status tool:** the July 2026 patches install Adobe's own checker at `vendor/bin/patch-status`. It reads the same registry, so you can run it afterwards to cross-check what this script applied.
- **Concurrent runs:** a lock file stops two runs from overlapping.
