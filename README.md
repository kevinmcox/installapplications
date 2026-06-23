# InstallApplications Zsh (IAZ)

![InstallApplications icon](/icon/installapplications.png?raw=true)

InstallApplications is an alternative to tools like [PlanB](https://github.com/google/macops-planb) where you can dynamically download packages for use with `InstallApplication`. This is useful for ADE bootstraps, allowing you to have a significantly reduced initial package that can easily be updated without repackaging your initial package.

## IAZ

Version 3 of InstallApplications is a Zsh rewrite of the python original with the primary goal of removing the need for the embedded python. The result is a 99.9% reduction in package size to only 25 KB.

The second goal was to maintain backwards compatiblity with the JSON configuration so it will work as a drop-in replacment in most scenarios.

There are a couple tradeoffs noted below, but these do not matter for my use case. This fork is published here in hopes it might be useful to others as well.

## Requirements

**macOS 15 Sequoia or later.** v3.0+ depends on `/usr/bin/jq`, which Apple began shipping in macOS 15. Earlier macOS releases do not include `jq` and the bootstrap will fail with `"/usr/bin/jq is required but not present!"`.

If you need to deploy to macOS 14 or earlier, stick with InstallApplications 2.x (the Python-based release).

## Shell implementation

As of v3.0, InstallApplications is a single `zsh` script with no embedded Python framework. It relies only on tools that ship with macOS:

- `/bin/zsh` — script interpreter
- `/usr/bin/curl` — HTTPS downloads (with optional basic auth and follow-redirects)
- `/usr/bin/jq` — JSON parsing (**macOS 15+ only**; see [Requirements](#requirements))
- `/usr/bin/shasum` — SHA256 hash validation
- `/usr/bin/plutil`, `/usr/sbin/pkgutil`, `/usr/sbin/installer` — package handling
- `/usr/bin/logger` — Console.app / unified logging visibility

This drops the package size back down to a handful of kilobytes, removing the ~35 MB Python framework that previous releases bundled.

### Migrating from 2.x

If you are upgrading from a 2.x release:

- Any `rootscript` or `userscript` items in your `bootstrap.json` that were pinned to the embedded Python (`#!/Library/installapplications/Python.framework/Versions/Current/bin/python3`) will no longer work. Three migration paths:
    - **Rewrite the script in shell** (`#!/bin/zsh` or `#!/bin/bash`). Best for simple bootstrap-time logic — no runtime to ship, and both shells are always present on macOS. This is what InstallApplications itself does now.
    - **Install a Python runtime as one of the FIRST items in your bootstrap.json**, before any item that needs Python. Build a relocatable Python (e.g. via [relocatable-python](https://github.com/gregneagle/relocatable-python)), wrap it in a pkg, and place that pkg early in the `setupassistant` stage. Later items can then shebang against the installed framework's path.
    - **Use a compiled binary or different language.** Swift, Go, Rust, anything pre-compiled in a pkg works.

    Note: `/usr/bin/python3` is **not** a viable target on a freshly-ADE'd Mac — it's a stub that prompts the user to install Xcode Command Line Tools the first time it's invoked, which doesn't work non-interactively during SetupAssistant. Admins also can't pre-install Python out of band, because InstallApplications is literally the first thing running on the Mac.
- The Python `middleware` extensibility hook has been removed. URL/header rewriting is no longer supported in-process; pre-sign your URLs server-side or use the existing `--headers` flag.

#### Bug fixes you may notice in logs

v3.0 fixes three latent bugs in the Python implementation that affected logging and error handling. Most users won't have noticed them in normal operation, but the logs you collect post-upgrade will look slightly different:

- **Package installer output now appears in the daemon log.** In 2.x, the Python 2→3 conversion silently broke `installpackage`'s output capture (a bytes-vs-string mismatch swallowed by a bare `except: pass`). Packages installed correctly, but the InstallApplications daemon log contained no `installer:` lines whatsoever. v3.0 captures and forwards `installer -verbose` output line-by-line, so expect dozens of new lines per package install.
- **Script-spawn failures no longer crash the run.** When `subprocess.Popen` raised `OSError` (missing interpreter, bad perms, etc.), the 2.x error handler crashed itself by calling `.decode()` on the exception object. v3.0 just logs the exit code and continues.
- **Non-UTF-8 script output no longer crashes the run.** A script emitting non-UTF-8 bytes used to trigger `UnicodeDecodeError` in 2.x's `out.decode('utf-8')` calls, aborting the bootstrap. v3.0 captures bytes verbatim via shell command substitution; worst case the line looks garbled in the log.

## MDMs that support Custom DEP

- AirWatch
- FileWave (please contact them for instructions)
- MicroMDM
- SimpleMDM
- Mosyle
- Jamf School
- [Fleet](https://fleetdm.com/docs/using-fleet/mdm-macos-setup-experience#bootstrap-package)

### A note about other MDMs

While other MDMs could _technically_ install this tool, the mechanism greatly differs. Other MDMs currently use `InstallApplication` API to install their binary. From here, you could then install this tool.

Unfortunately, by doing this, you lose many of the features of `InstallApplications`, the primary one being speed.

Example: Jamf Pro

Jamf Pro would install the `jamf` binary first, rather than InstallApplications. An admin would need to scope a policy through the console in order to install this tool and it cannot be 100% validated that InstallApplications will be installed during the SetupAssistant process.

## How this process works:

During an ADE SetupAssistant workflow (with a supported MDM), the following will happen:

1. MDM will send a push request utilizing `InstallApplication` to inform the device of a package installation.
2. InstallApplications (this tool) will install and load its LaunchDaemon.
3. InstallApplications (this tool) will install and load its LaunchAgent if in the proper context (installed outside of SetupAssistant).
4. InstallApplications will begin to install your setupassistant packages (if configured) during the SetupAssistant.
5. If userland packages are configured, InstallApplications will wait until the user is in their active session before installing.
6. InstallApplications will gracefully exit and kill its process.

## Stages

There are currently three stages:
#### preflight ####

This stage is designed to only work with a **single rootscript**. This stage is useful for running InstallApplications on previously deployed machines or if you simply want to re-run it.

If the preflight script exits 0, InstallApplications will cleanup/remove itself, bypassing the setupassistant and userland stages.

If the preflight script exits 1 or higher, InstallApplications will continue with the bootstrap process.
#### setupassistant ####

- Packages/rootscripts that should be prioritized for download/installation _and_ can be installed during SetupAssistant, where no user session is present.

#### userland ####

- Packages/rootscripts/userscripts that should be prioritized for download/installation but may need to be installed in the user's context. This could be your UI tooling that informs the user that an ADE workflow is being used. This stage will wait for a user session before installing.

By utilizing setupassistant/userland, you can have **almost instant UI notifications** for your users.

## Notes

- InstallApplications will only begin installing userland when a user session has been started. This is to reduce the likelihood of your packages attempting to start UI elements during SetupAssistant.

### Signing
You will **NEED** to sign this package for use with ADE/MDM. To acquire a signing certificate, join the [Apple Developers Program](https://developer.apple.com).

Open the `build-info.json` file and specify your signing certificate.

```json
"signing_info": {
    "identity": "Mac Installer: Erik Gomez (XXXXXXXXXXX)",
    "timestamp": true
},
```

Note that you cannot use a `Mac Developer:` signing identity as that is used for application signing and not package signing. Attempting to use this will result in the following error:

`An installer signing identity (not an application signing identity) is required for signing flat-style products.`

### Downloading and running scripts

InstallApplications can handle downloading and running scripts. Please see below for how to specify the json structure.

For user scripts, you **must** set the folder path to the `userscripts` sub folder. This is due to the folder having world-wide permissions, allowing the LaunchAgent/User to delete the scripts when finished.

```json
"file": "/Library/installapplications/userscripts/userland_exampleuserscript.sh",
```

## Installing InstallApplications to another folder.

If you need to install IAs to another folder, you can modify the munki-pkg `payload`, but you will also need to modify the launchdaemon plist's `iapath` argument.

```xml
<string>--iapath</string>
<string>/Library/installapplications</string>
```

### Configuring LaunchAgent/LaunchDaemon for your json

Simply specify a url to your json file in the LaunchDaemon plist, located in the payload/Library/LaunchDaemons folder in the root of the project.

```xml
<string>--jsonurl</string>
<string>https://domain.tld</string>
```

NOTE: If you alter the name of the LaunchAgent/LaunchDaemon or the Label, you will also need to enable the arguments `--laidentifier` and `--ldidentifier` in the LaunchDaemon plist, and update the `launch_agent_plist_name` and `launch_daemon_plist_name` variables in both the `preinstall` and `postinstall` scripts.

```xml
<string>--laidentifier</string>
<string>com.example.installapplications</string>
<string>--ldidentifier</string>
<string>com.example.installapplications</string>
```

#### Optional Reboot

If after installing all of your packages, you want to force a reboot, simply uncomment the flag in the launchdaemon plist.

```xml
<string>--reboot</string>
```

#### Optional Skip Bootstrap.json validation

If you would like to pre-package your bootstrap.json file into your package and not download it, simply uncomment the flag in the launchdaemon plist.

```xml
<string>--skip-validation</string>
```

#### Basic Auth
Currently, Basic Authentication is only supported by using `--headers` flag.

The authentication should be passed as a base64 encoded `username:password`, prefixed with `Basic `.

Generate the value with:

```bash
echo -n 'username:password' | base64
```

In the LaunchDaemon add the resulting string, prefixed with `Basic `:

```xml
<string>--headers</string>
<string>Basic dXNlcm5hbWU6cGFzc3dvcmQ=</string>
```

#### Follow HTTP Redirects

If your webserver needs to redirect InstallApplictions to fetch content from another URL, pass `--follow-redirects` in your LaunchDaemon. Useful for situations where content may be stored on a CDN or object storage.

```xml
<string>--follow-redirects</string>
```

### DEPNotify

As of InstallApplications v2.0.2, the built in support for DEPNotify has been removed.

Big Sur makes this code less stable. If you would like an example on how to launch DEPNotify with a user script, please see [depnotify_user_launcher.py](https://github.com/erikng/installapplicationsdemo/blob/master/installapplications/scripts/user/depnotify_user_launcher.py) at the installapplications demo GitHub.

### Logging

All events are written to `/var/log/installapplications/installapplications.log` (root context) and `/var/log/installapplications/installapplications.user.log` (user context), and are also forwarded to macOS unified logging via `logger`. Open Console.app and search for `InstallApplications` to view all events.

Per-item runtime durations are written to `/var/log/installapplications/ia_item_runtimes.plist` as a nested dict `{stage: {item_name: seconds}}`, updated after each item completes.

### Building a package

This repository is built with [munkipkg](https://github.com/munki/munki-pkg):

```bash
munkipkg .
```

**Requires munkipkg from `main` after [PR #81](https://github.com/munki/munki-pkg/pull/81) (merged 2026-06-09).** That PR hardcoded `hostArchitectures="arm64,x86_64"` into munkipkg's Distribution template. Without it, the pkg munkipkg produces is treated as Intel-only by macOS Installer (and the `installer` CLI) and demands Rosetta on Apple Silicon — even though InstallApplications is arch-agnostic shell code. munki-pkg has no tagged releases, so update your local copy by pulling from main.

Configure your signing identity in `build-info.json` (see [Signing](#signing) above) and `munkipkg` will sign the pkg as part of the build. Output lands in `build/InstallApplications-<version>.pkg`.

### SHA256 hashes

Each package must have a SHA256 hash stored in the JSON. You can easily create hashes with the following command:

`/usr/bin/shasum -a 256 /path/to/pkg`

This guarantees that the package you place on the web for download is the package that gets installed by InstallApplication. If the hash does not match, InstallApplication will attempt to re-download and re-check.

### JSON Structure

The JSON structure is quite simple. You supply the following:

- filepath (default `/Library/installapplications`; configurable via the `--iapath` LaunchDaemon flag)
- url (any domain, but it should ideally be https://)
- hash (SHA256)
- name (define a name for the package, for debug logging and DEPNotify)
- version of package (to check package receipts)
- package id (to check for package receipts)
- type of item (currently `rootscript`, `package` or `userscript`)
- skip_if criteria to skip a pkg (currently `x86_64`, `intel`, `arm64` or `apple_silicon`)
- retries is the number of times an item is retried to download (defaults to 3 if not set)
- retrywait is the number of seconds to wait before attempting a retry to download (defaults to 5 if not set)

The following is an example JSON:

```json
{
  "preflight": [
    {
      "donotwait": false,
      "file": "/Library/installapplications/preflight_script.sh",
      "hash": "sha256 hash",
      "name": "Example Preflight Script",
      "type": "rootscript",
      "url": "https://domain.tld/preflight_script.sh",
      "retries": 5,
      "retrywait": 10
    }
  ],
  "setupassistant": [
    {
      "file": "/Library/installapplications/setupassistant.pkg",
      "url": "https://domain.tld/setupassistant.pkg",
      "packageid": "com.package.setupassistant",
      "version": "1.0",
      "hash": "sha256 hash",
      "name": "setupassistant Package Name",
      "type": "package",
      "retries": 5,
      "retrywait": 10
    }
  ],
  "userland": [
    {
      "file": "/Library/installapplications/userland.pkg",
      "url": "https://domain.tld/userland.pkg",
      "packageid": "com.package.userland",
      "version": "1.0",
      "hash": "sha256 hash",
      "name": "Userland Package Name",
      "skip_if": "x86_64",
      "type": "package",
      "retries": 5,
      "retrywait": 10
    },
    {
      "file": "/Library/installapplications/userland_examplerootscript.sh",
      "hash": "sha256 hash",
      "name": "Example Script",
      "type": "rootscript",
      "url": "https://domain.tld/userland_examplerootscript.sh"
    },
    {
      "file": "/Library/installapplications/userscripts/userland_exampleuserscript.sh",
      "hash": "sha256 hash",
      "name": "Example Script",
      "type": "userscript",
      "url": "https://domain.tld/userland_exampleuserscript.sh"
    }
  ]
}
```

URLs should not be subject to redirection, or there may be unintended behavior. Please link directly to the URI of the package.

You may have more than one package and script in each stage. Packages and scripts will be deployed in the order listed.

### Creating your JSON

Using `generatejson.py` you can automatically generate the json with the file, hash, and name keys populated (you'll need to upload the packages to a server and update the url keys).

You can pass an unlimited amount of `--item` arguments, each one with the following meta-variables. Please note that currently _all_ of these meta-variables are **required**:

* item-name - required, sets the display name that will show in DEPNotify
* item-path - required, path on the local disk to the item you want to include
* item-stage - required, defaults to userland if not specified
* item-type - required, generatejson will detect package vs script. Scripts default to rootscript, so pass "userscript" to this variable if your item is a userscript.
* item-url - required, if --base-url is set generatejson will auto-generate the URL as base-url/stage/item-file-name. You can override this automatic generation by passing a URL to the item here.
* script-do-not-wait - required, only applies to userscript and rootscript item-types. Defaults to false.
* retries - optional, integer value that defaults to 3 if not specified
* retrywait - optional, integer value that defaults to 5 if not specified

Run the tool:

```
python generatejson.py --base-url https://github.com --output ~/Desktop \
--item \
item-name='preflight' \
item-path='/localpath/preflight.py' \
item-stage='preflight' \
item-type='rootscript' \
item-url='https://github.com/preflight/preflight.py' \
script-do-not-wait=False \
--item \
item-name='setupassistant package' \
item-path='/localpath/package.pkg' \
item-stage='setupassistant' \
item-type='package' \
item-url='https://github.com/setupassistant/package.pkg' \
script-do-not-wait=False \
retries=5 \
retrywait=10 \
--item \
item-name='userland user script' \
item-path='/localpath/userscript.py' \
item-stage='userland' \
item-type='userscript' \
item-url='https://github.com/userland/userscript.py' \
script-do-not-wait=True \
```

The bootstrap.json will be saved in the directory specified with `--output`.
