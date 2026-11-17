# onramp

Bootstraps a Mac at enrollment from an [InstallApplications](https://github.com/macadmins/installapplications)-style `bootstrap.json`.

**Status:** pre-alpha. It builds an installer package and runs end to end, but the package isn't signed yet, which an MDM needs to install it (see [Building the package](#building-the-package)).

## Requirements

- macOS 14 or later
- Swift 6.1 or later (Xcode 16.4 or later), the oldest toolchain CI checks

## Build and test

```bash
swift build
swift test
```

## Building the package

```bash
pkg/build.sh
```

This writes `build/onramp-<version>.pkg`, a distribution package with a universal binary for Apple silicon and Intel. It installs:
- `/Library/onramp/onramp`
- `/Library/LaunchDaemons/io.github.popaprozac.onramp.daemon.plist`, which sends the daemon's output to `/var/log/onramp/onramp.log`
- a postinstall script that creates `/var/log/onramp` and loads the daemon. On a reinstall it reloads the daemon, which carries on from its saved progress.

Everything is installed as root:wheel. The package isn't signed yet. That's fine for `sudo installer -pkg … -target /`, but an MDM's InstallEnterpriseApplication needs a package signed with a Developer ID Installer certificate.

On Macs where macOS tags built files with `com.apple.provenance`, `pkgbuild` prints `write: Permission denied` a few times. That's harmless: the package installs no stray `._` files.

## Deploying

Send the package and two profiles from your MDM, in any order. The daemon waits for its profile if the package arrives first.
- `examples/onramp-config.mobileconfig` sets onramp's [configuration](#configuration). Replace its `JSONURL`, and its `PayloadUUID`s with your own.
- `examples/onramp-background-items.mobileconfig` marks onramp's LaunchDaemon as managed, so users don't get a "Background Items Added" notice for it during enrollment.

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

This checks the file first, as `validate` does, and stops if there are errors. Then it goes through every phase and prints what would happen to each item. It doesn't download, install or run anything, and it doesn't need root. Without a path, it uses the bootstrap the profile points at.

- Package receipts are read from this Mac with `pkgutil`, so a package skipped because of its receipt really would be skipped here.
- Every preflight script is assumed to exit non-zero, so all phases are shown. `--skip-preflight` leaves preflight out.

## Phases

Phases run in order: `preflight`, `setupassistant`, then `userland`. Within a phase, items run in file order.

- **preflight:** if a `rootscript` here exits 0, the Mac is already set up and nothing else runs. Any other exit status, or a script that can't be started, means carry on.
- **package:** skipped if the receipt for `packageid` is at or above `version`, compared the way munki's LooseVersion does it. A package with no receipt is installed. `required: true` installs it regardless of the receipt.
- **rootscript:** runs as root.
- **userscript:** runs as the logged-in user. It's skipped in `setupassistant`, because no user is logged in yet.
- **`donotwait`:** starts a script and moves on without waiting for it. It's ignored in `preflight`.
- **`skip_if`:** `x86_64`/`intel` skips the item on Intel Macs, and `arm64`/`apple_silicon` skips it on Apple silicon. onramp applies it to every item type; upstream only applies it to packages.
- **Downloads:** an item with a `url` is downloaded to `file`, unless `file` already matches `hash`.
  - There are `1 + retries` attempts, `retrywait` seconds apart. With no network, an attempt waits for one instead of failing.
  - The file is checked against `hash` before it's moved into place, so a failed download never leaves a partial file at `file`.
  - Downloaded scripts are made executable (mode 0755).

`fail_policy` is an onramp addition. It decides whether a failed item stops the run:

| `fail_policy` | Stops the run when |
|---|---|
| `failable_execution` (default) | a download or package install fails; a script may fail |
| `failure_is_not_an_option` | anything fails |
| `failable` | never |

Upstream ignores failed package installs.

`wait_for_desktop` is also an onramp addition, for userland items only, and defaults to `true`.
- Normally userland waits until the user's desktop is ready (see [How the daemon runs](#how-the-daemon-runs)).
- Items at the **start** of `userland` with `"wait_for_desktop": false` run as soon as the user is logged in, even while the per-user Setup Assistant screens are still up. Then onramp waits for the desktop and runs the rest.
- On an item after one that waits, the key has no effect, and `validate` warns about it.

The use case is a full-screen dialog that should already cover the desktop when Setup Assistant closes. For example, swiftDialog installed in `setupassistant`, then started first in `userland` with `--blurscreen`, `donotwait` and `"wait_for_desktop": false`. In testing on macOS 27.2.1, swiftDialog started this way stayed behind Setup Assistant, which remained on top and clickable, and was already up when Setup Assistant closed. Test other apps the same way before relying on them: an app that draws above Setup Assistant would stop the user finishing it. `run --dry-run` shows where the waits fall.

## Configuration

The daemon reads the `io.github.popaprozac.onramp` preferences domain, normally from a configuration profile. A profile's values win over any others.

| Key | Type | Meaning |
|---|---|---|
| `JSONURL` | string | Where to download `bootstrap.json`. Must be `https`, because the bootstrap decides what runs as root. |
| `Bootstrap` | dictionary | The bootstrap itself, with the same keys and values as `bootstrap.json`. Use this or `JSONURL`, not both. |
| `Headers` | dictionary of strings | Extra request headers, such as `Authorization`. They're sent only to `JSONURL`'s scheme, host and port, and dropped on a redirect to anywhere else. Upstream sends them to every URL. |
| `MaxAttempts` | integer, at least 1 | How many failed attempts before onramp gives up. Default 3. |

Until `JSONURL` or `Bootstrap` is set, the daemon waits and checks again every 15 seconds. MDMs often install the package before the profile arrives, so this doesn't count as a failure. A profile that's present but invalid does count.

## How the daemon runs

1. **preflight** and **setupassistant** run as soon as the daemon starts, which is normally while Setup Assistant is still on screen.
2. Userland files are downloaded next, before anyone logs in.
3. **userland** waits for someone to log in. Leading items with `"wait_for_desktop": false` start then. After that it waits for the user's desktop, meaning the per-user Setup Assistant screens closed and Dock and Finder running, and runs the rest.
   - It waits as long as Setup Assistant is open.
   - Without Setup Assistant, it carries on after 2 minutes if Dock or Finder never appears.
4. At the end it records the result and uninstalls itself (below).

Other rules:
- **Saved progress.** `/Library/onramp/state.plist` records which phases have finished. A restart or shutdown *between* phases, such as while waiting for someone to log in, costs nothing, and finished phases aren't run again.
- **Attempts.** A phase that fails, or one cut off part-way by a crash, restart or power loss, counts as a failed attempt. launchd starts the daemon again, which carries on from that phase. At `MaxAttempts` onramp gives up.
- **Cached bootstrap.** A downloaded bootstrap is saved as `/Library/onramp/bootstrap.json`, readable only by root, and restarts use it without the network, as upstream does.
- **Root-only files.** Before onramp installs or runs anything as root, it resolves symlinks and requires the file and every directory above it to be owned by root and not writable by group or others. So files in `/tmp` or `/Users/Shared` are refused. Upstream has no such check.
- **Userscripts** run as the logged-in user inside their GUI session (`launchctl asuser`, then `sudo -u`), so they can open windows.
- **Logging.** The daemon writes one timestamped line per step to standard output.

When it finishes it writes these keys to `/Library/Preferences/io.github.popaprozac.onramp.plist` for the MDM to read. Keys a result doesn't set are cleared, so nothing from an earlier run lingers.

| Key | Value |
|---|---|
| `Result` | `completed`, `already_provisioned`, `completed_with_failures` (every phase ran, but items whose `fail_policy` let them fail did fail) or `failed` |
| `Error` | what failed, naming the phase and item; several are separated by `; ` |
| `FailedAttempts` | how many attempts failed |
| `FinishedAt` | date |
| `Version` | onramp's version |

Then it removes its LaunchDaemon plist and unloads itself last. The log in `/var/log/onramp` is kept.
- **After `completed` or `already_provisioned`**, it also removes `/Library/onramp`.
- **After anything else**, it removes only its state and cached bootstrap, and keeps `/Library/onramp/onramp` so IT can rerun setup.

## Rerunning setup (IT)

```bash
sudo /Library/onramp/onramp run [path/to/bootstrap.json] [--skip-preflight]
```

For when setup didn't finish, without reimaging: from a Self Service or Munki script, or in Terminal at the user's desktop.
- **Bootstrap:** without a path, it fetches the bootstrap the profile points at, fresh, never the daemon's cached copy.
- **The daemon:** if onramp's daemon is still loaded, `run` stops it first, so the two never run at once.
- **The run:** every phase runs in the foreground, with one timestamped line per item. Userscripts run as the logged-in user, and preflight saying "already provisioned" stops the run, as in the daemon. `--skip-preflight` runs setupassistant and userland anyway.
- **Afterwards:** `run` writes the same status keys as the daemon.
  - On `completed` or `already_provisioned`, it removes onramp the same way and exits 0.
  - On anything else it exits 1 and changes nothing. A daemon it stopped comes back at the next boot and carries on from its own saved progress.

## Identifiers

These are fixed because MDM profiles and launchd plists reference them:

| Purpose | Value |
|---|---|
| Bundle ID / managed-preferences domain | `io.github.popaprozac.onramp` |
| LaunchDaemon label | `io.github.popaprozac.onramp.daemon` |

onramp installs no LaunchAgent. It runs userland in the user's session from the daemon.

## License

Apache-2.0. See [LICENSE](LICENSE).
