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
2. **Finds the bundles** on `https://repo.magento.com/patch/`, named like `2-4-7-p10-sep-2026.zip`. It checks every month from the last bundle it applied up to next month (the last 6 months on the first run). That's how next month's bundle gets picked up automatically.
3. **Applies them in date order.** Each bundle is unpacked and all of its `.patch`/`.diff` files are applied with `patch -p1` from the Magento root. Where Adobe ships both a composer-format and a git-format version of a patch, it picks the one that matches how Magento is installed.
4. **Rolls back on failure.** If any patch in a bundle won't apply cleanly, the patches already applied from that bundle are undone, an alert is raised, and no later bundles are attempted.
5. **Stops if the site needs upgrading.** If a bundle needs a higher patch level than is installed (for example the bundle is for `2.4.7-p10` and the site is on `2.4.7-p9`), it raises an alert saying which version to upgrade to and applies nothing from that point on.
6. **Records what it did.** It flushes the cache and writes each bundle's release month and the time it was applied to `var/security-patches/applied.log`.

Running it again is safe. Bundles and patches that are already in place are detected and skipped, including ones applied by hand.

## Options

| Option | Description |
|---|---|
| `-r, --root DIR` | Magento root (default: current directory) |
| `-l, --list FILE` | File of extra bundle zip URLs to apply, one per line (`#` comments allowed) |
| `-b, --base-url URL` | Location to look for bundles in (can be repeated; default `https://repo.magento.com/patch`) |
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
| 3 | A patch wouldn't apply cleanly; that bundle was rolled back |

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
