# onramp

Bootstraps a Mac at enrollment from an [InstallApplications](https://github.com/macadmins/installapplications)-style `bootstrap.json`.

**Status:** pre-alpha. It can check a `bootstrap.json` and show what a run would do, but cannot install anything yet.

## Requirements

- macOS 14 or later
- Swift 6.0 or later (Xcode 16+)

## Build and test

```bash
swift build
swift test
```

## Checking a bootstrap.json

```bash
swift run onramp validate path/to/bootstrap.json
```

`validate` reads the upstream InstallApplications format: `preflight`, `setupassistant` and `userland` arrays of `package`, `rootscript` and `userscript` items. Unknown keys are ignored, and missing `retries`/`retrywait` default to 3 and 5. It exits non-zero if the file has any errors.

Errors:

- the file isn't valid JSON, or a required key (`name`, `file`, `type`) is missing
- `type`, `skip_if` or `fail_policy` has an unsupported value
- `file` isn't an absolute path, or `name` is empty
- `url` isn't http(s), or `url` is set without a `hash`
- `hash` isn't a 64-character SHA-256 hex digest (either case)
- a `package` is missing `url`, `packageid` or `version`
- a `preflight` item isn't a `rootscript`
- `retries` or `retrywait` is negative

Warnings (it still exits 0):

- a plain `http` URL
- `donotwait` on a package, or `required` on a script
- a `userscript` in `setupassistant`, or `donotwait` on a `preflight` item
- a bootstrap with no items

## Dry run

```bash
swift run onramp run --dry-run path/to/bootstrap.json
```

This checks the file first, as `validate` does, and stops if there are errors. Then it goes through every phase and prints what would happen to each item. It doesn't download, install or run anything, and it doesn't need root.

- Package receipts are read from this Mac with `pkgutil`, so a package skipped because of its receipt really would be skipped here.
- Every preflight script is assumed to exit non-zero, so all phases are shown.

`run` without `--dry-run` isn't supported yet.

## Phases

Phases run in order: `preflight`, `setupassistant`, then `userland`. Within a phase, items run in file order.

- **preflight:** if a `rootscript` here exits 0, the Mac is already set up and nothing else runs. Any other exit status, or a script that can't be started, means carry on.
- **package:** skipped if the receipt for `packageid` is at or above `version`, compared the way munki's LooseVersion does it. A package with no receipt is installed. `required: true` installs it regardless of the receipt.
- **rootscript:** runs as root.
- **userscript:** runs as the logged-in user. It's skipped in `setupassistant`, because no user is logged in yet.
- **`donotwait`:** starts a script and moves on without waiting for it. It's ignored in `preflight`.
- **`skip_if`:** `x86_64`/`intel` skips the item on Intel Macs, and `arm64`/`apple_silicon` skips it on Apple silicon. onramp applies it to every item type; upstream only applies it to packages.
- **Downloads:** an item with a `url` is downloaded to `file`, unless `file` already matches `hash`.
  - There are `1 + retries` attempts, `retrywait` seconds apart.
  - The file is checked against `hash` before it's moved into place, so a failed download never leaves a partial file at `file`.
  - Downloaded scripts are made executable (mode 0755).

`fail_policy` is an onramp addition. It decides whether a failed item stops the run:

| `fail_policy` | Stops the run when |
|---|---|
| `failable_execution` (default) | a download or package install fails; a script may fail |
| `failure_is_not_an_option` | anything fails |
| `failable` | never |

Upstream ignores failed package installs.

## Identifiers

These are fixed because MDM profiles and launchd plists reference them:

| Purpose | Value |
|---|---|
| Bundle ID / managed-preferences domain | `io.github.popaprozac.onramp` |
| LaunchDaemon label | `io.github.popaprozac.onramp.daemon` |
| LaunchAgent label | `io.github.popaprozac.onramp.agent` |
| XPC Mach service | `io.github.popaprozac.onramp.xpc` |

## License

Apache-2.0. See [LICENSE](LICENSE).
