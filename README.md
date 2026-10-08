# magento-security-patcher

Applies Adobe's monthly Magento security patch bundles with one command. It finds the bundles, downloads them, checks they match the installed version and applies them in release-date order.

Maintained by [ZERO-1](https://www.zero1.co.uk).

## Quick start

Run from the Magento root:

```bash
curl -fsSL https://raw.githubusercontent.com/zero1limited/magento-security-patcher/master/patcher.sh | bash
```

Pass options after `bash -s --`:

```bash
# Dry run: download and test-apply only, change nothing
curl -fsSL https://raw.githubusercontent.com/zero1limited/magento-security-patcher/master/patcher.sh | bash -s -- -n

# Point at a different Magento root
curl -fsSL https://raw.githubusercontent.com/zero1limited/magento-security-patcher/master/patcher.sh | bash -s -- -r /var/www/magento
```

Always keep the `-f` in `curl -fsSL`. Without it, a 404 or GitHub error page gets passed to bash and run as commands.

## What it does

1. **Detects the installed version** from `php bin/magento -V`. If that fails it falls back to `composer.lock`, then `composer.json`.
2. **Finds the bundles** in two ways:
   - It reads the [list of known bundles](patches.txt) in this repo on every run.
   - It checks `https://repo.magento.com/patch/` and `https://repo.magento.com/patch/auth/` for files named like `2-4-7-p10-sep-2026.zip`, for every month from the last bundle it applied up to next month (the last 6 months on the first run). That's how next month's bundle gets picked up automatically, even before it's added to the list.
3. **Applies them in date order.** Each bundle is unpacked and all of its `.patch`/`.diff` files are applied with `patch -p1` from the Magento root. Where Adobe ships both a composer-format and a git-format version of a patch, it picks the one that matches how Magento is installed.
4. **Checks every patch applies to this site.** Before applying anything, it reads the `---`/`+++` file headers in each patch and checks each target file against the install:
   - **Target exists:** the change is applied.
   - **Whole package not installed** (for example a B2B patch for `magento/module-company` on a CE site): reported as **Not Applicable** and skipped. If only some files in a patch are N/A, the rest of that patch is still applied.
   - **Package installed but the file is missing:** treated as an error, because it means the version doesn't match or core files have been removed or overridden. An alert is raised and the bundle is rolled back.
5. **Rolls back on failure.** If any patch in a bundle won't apply cleanly, the patches already applied from that bundle are undone, an alert is raised, and no later bundles are attempted.
6. **Stops if the site needs upgrading.** If a bundle needs a higher patch level than is installed (for example the bundle is for `2.4.7-p10` and the site is on `2.4.7-p9`), it raises an alert saying which version to upgrade to and applies nothing from that point on.
7. **Records what it did.** It flushes the cache and writes each bundle's release month and the time it was applied to `var/security-patches/applied.log`.

Running it again is safe. Bundles and patches that are already in place are detected and skipped, including ones applied by hand.

## Options

| Option | Description |
|---|---|
| `-r, --root DIR` | Magento root (default: current directory) |
| `-l, --list FILE` | Local file of extra bundle zip URLs to apply, one per line (`#` comments allowed) |
| `--known-list URL` | Central list of known bundles (default: `patches.txt` in this repo) |
| `--no-known-list` | Don't fetch the central list |
| `-b, --base-url URL` | Location to look for bundles in (can be repeated; default `https://repo.magento.com/patch` and `https://repo.magento.com/patch/auth`) |
| `--lookback N` | Months to look back when there's no history yet (default 6) |
| `--lookahead N` | Months ahead of today to check (default 1) |
| `-n, --dry-run` | Download and test-apply only, change nothing |
| `--no-cache-flush` | Don't run `cache:flush` afterwards |
| `--compile` | Run `setup:di:compile` after applying |
| `--webhook URL` | Send alerts to a Slack-style incoming webhook |
| `--email ADDR` | Email alerts (needs a working `mail` command) |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success, or nothing to do |
| 1 | Error (download, auth, environment) |
| 2 | Upgrade required before the next bundle can be applied |
| 3 | A patch wouldn't apply cleanly, or targets a file missing from an installed package; that bundle was rolled back |

## Adding new bundles

When Adobe publishes a new month's bundles, add their URLs to [`patches.txt`](patches.txt) and push. Every site picks them up on its next run, and the order of lines in the file doesn't matter because bundles are always applied by release date.

Only `https://repo.magento.com/` URLs are accepted from this file, so a bad edit can't point sites at a zip hosted anywhere else.

## Credentials

repo.magento.com access keys are read from the first of these that exists:

1. `$MAGENTO_REPO_USER` / `$MAGENTO_REPO_PASS`
2. `<magento root>/auth.json`
3. `$COMPOSER_HOME/auth.json`, `~/.config/composer/auth.json`, `~/.composer/auth.json`

The keys are only ever sent to `repo.magento.com`.

## Running on a schedule

Point cron at a **tagged release**, not `master`. Otherwise every push to `master` runs as-is on client servers.

```cron
# 06:00 daily: picks up a new bundle as soon as Adobe publishes it
0 6 * * * cd /var/www/magento && bash <(curl -fsSL https://raw.githubusercontent.com/zero1limited/magento-security-patcher/v1.0.0/patcher.sh) --webhook https://hooks.slack.com/services/XXX >> /var/log/magento-patcher.log 2>&1
```

## Notes

- **Requirements:** bash 4+, GNU `date`, `wget`, `unzip`, `patch` and `php`. That covers any standard Linux Magento host; macOS's built-in `date` won't work.
- **`composer install` removes the patches.** Anything applied under `vendor/` is overwritten by `composer install` or `composer update`, so run the patcher again afterwards.
- **Production mode:** run `setup:di:compile` (or use `--compile`) and `setup:static-content:deploy` after patching if the patches touched PHP classes or frontend assets.
- **Concurrent runs:** a lock file stops two runs from overlapping.
