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

Running it again is safe and quick, because applied patches are recorded and skipped. When Adobe adds a new month to the registry, the next run picks it up automatically.

## Dry run

`-n` downloads and verifies every patch, then applies the whole chain to a **scratch copy** of the affected files. Each chained patch (Jul → Aug → Sep) is tested against the result of the one before it, exactly as a real run would apply it. Nothing in the Magento install changes, and webhook/email alerts are logged but not sent. The only writes are to `var/security-patches/` (downloads, `run.log`, lock file).

## Options

| Option | Description |
|---|---|
| `-r, --root DIR` | Magento root (default: current directory) |
| `--registry URL\|FILE` | Patch registry (default: `https://repo.magento.com/patch/patch-registry.json`) |
| `-n, --dry-run` | Download, verify and test every patch against a scratch copy; change nothing |
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
| 3 | A patch failed: conflict, missing target file, download/auth failure, or sha256 mismatch |

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

- **Requirements:** bash 4+, GNU `date`, `wget`, `patch`, `php`, `awk` and `sha256sum` (or `shasum`). That covers any standard Linux Magento host.
- **`composer install` removes the patches.** Anything applied under `vendor/` is overwritten by `composer install` or `composer update`, so run the patcher again afterwards.
- **Production mode:** run `setup:di:compile` (or use `--compile`) and `setup:static-content:deploy` after patching if the patches touched PHP classes or frontend assets.
- **Adobe's status tool:** the July 2026 patches install Adobe's own checker at `vendor/bin/patch-status`. It reads the same registry, so you can run it afterwards to cross-check what this script applied.
- **Concurrent runs:** a lock file stops two runs from overlapping.
