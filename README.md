<p align="center">
  <img src="Resources/AppIcon.png" alt="Tempra app icon" width="128" height="128">
</p>

# Tempra

**Keep background apps from taking over your Mac.**

Tempra is a free, open-source macOS menu bar app that limits or pauses
background apps and processes to reduce CPU use and save power. Set a rule for
an app, and Tempra applies its process-control action after the app leaves the
foreground and its windows are no longer meaningfully visible. Tempra restores
the app when you return to it or make one of its windows visible again.

## Features

### Control background apps

- Limit an app from 1% of one logical CPU core up to the Mac's total logical CPU
  capacity. In Tempra, 100% equals one logical CPU core.
- Pause an app in the background and resume it in the foreground.
- Lower an app's CPU priority, with or without a CPU limit. This action requires
  Tempra's optional administrator helper.
- Apply a rule only when an app is hidden or after a set delay.
- Wait while an app plays audio before applying its rule.
- Hide or quit an app after a set period in the background.
- Manage supported user-owned background services and processes that require
  administrator access.
- Disable a rule, resume one app temporarily, or pause all management for 15
  minutes, 1 hour, or 4 hours.
- Adjust saved CPU limits and delays with management profiles. Select a profile
  manually, or activate one by power source and user inactivity.

### See what your Mac is doing

- View total CPU use and separate values for performance and efficiency cores.
- Check current CPU use and the rolling one-minute average for each app.
- Inspect an app's resident memory, subprocesses, active protections, running
  time, and persistent CPU history.
- Review system and per-app CPU history for the last 5 minutes, 1 hour, or 24
  hours. Tempra stores up to 24 hours of graph history.
- Read the CPU temperature through AppleSMC without root access.
- Record up to seven days of rule activity, time limited, time paused, and
  intervention counts.
- Receive optional in-app high-CPU alerts with quick actions. These alerts do
  not require notification permission.
- Search and sort running apps, include background and system processes when
  needed, or detach the monitor from the menu bar.
- Export a JSON diagnostic report with the current rules, process state, recent
  activity, and process-control measurements.

When its panels are closed, Tempra keeps only the sampling required for the
menu-bar CPU value, automatic profiles, and active rules. Enable **Continuous
Monitoring** to keep CPU history and high-CPU alerts active in the background.

## How rules work

1. Open Tempra from the menu bar.
2. Select a running app.
3. Choose a CPU limit, pause action, lower CPU priority, or idle action.
4. Set the start delay and the conditions for the rule.

Tempra saves each rule automatically by bundle identifier. For apps with more
than one subprocess, Tempra keeps audio-producing and newly discovered
subprocesses out of CPU-limit pulses. When possible, it also leaves
latency-sensitive network work and critical file activity running while it
limits other subprocesses.

Open an app's activity details to view its CPU history and subprocesses. You can
also bring the app to the foreground, hide it, quit it, relaunch it, or end a
temporary resume when the action is available.

Tempra restores controlled processes when you return to an app, make one of its
windows visible, disable its rule, pause or turn off management, or quit Tempra
normally.

## Safety

Tempra manages ordinary apps and supported user-owned background services. Its
optional administrator helper can lower CPU priority and control supported
processes that the app cannot manage directly. Tempra shows an explicit error
if the helper is unavailable. It does not replace the requested action with a
weaker one.

Tempra keeps SoundSource audio components and protected macOS processes in
monitor-only mode. Protected processes include WindowServer, Finder, Dock,
SystemUIServer, loginwindow, and WindowManager. Tempra does not stop, lower the
priority of, or terminate these processes.

Before Tempra stops a process, an independent watchdog records its process ID
and start time. The watchdog resumes only the matching process if Tempra exits
unexpectedly. The administrator helper also sets automatic-resume deadlines for
privileged CPU-limit pulses. Tempra blocks a normal quit and shows an error if
it cannot restore every managed process.

Tempra validates saved rules, preferences, history, and management records
before it starts process management. If saved data is invalid, Tempra preserves
the stored bytes, shows an error, and stops startup. If a later save fails,
Tempra shows an error and does not treat the failed write as successful.

## Requirements

- macOS 14.2 or later
- Swift 5.10 or later
- An Apple Development or Developer ID Application signing identity for the app
  bundle and its administrator helper

## Build from source

Run this command from the repository root:

```sh
./script/build_and_run.sh
```

The script makes an optimized release build, adds the watchdog and administrator
helper, signs every executable with an Apple code-signing identity, creates
`dist/Tempra.app`, and opens the app. It selects the first available Apple
Development or Developer ID Application identity. Set `CODE_SIGN_IDENTITY` to
select a different identity:

```sh
CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./script/build_and_run.sh
```

Use a different mode when necessary:

```sh
./script/build_and_run.sh --build-only  # Build without opening the app
./script/build_and_run.sh --debug       # Build a debug version and open LLDB
./script/build_and_run.sh --logs        # Open the app and stream its logs
./script/build_and_run.sh --telemetry   # Open the app and stream its telemetry
./script/build_and_run.sh --verify      # Build, open, and check that Tempra runs
```

Run the test suite with:

```sh
swift test
```

## Build a release DMG

A release DMG requires a `Developer ID Application` identity and validated
notarization credentials. An Apple Development identity is not sufficient for
distribution.

1. Install the `Developer ID Application` identity in the login Keychain.
2. Store the notarization credentials in a Keychain profile:

   ```sh
   xcrun notarytool store-credentials Tempra-notary
   ```

3. Build, notarize, staple, and verify the DMG:

   ```sh
   CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
   NOTARYTOOL_PROFILE="Tempra-notary" \
   ./script/package_release_dmg.sh
   ```

4. If the matching GitHub release exists, add `--upload` to attach the DMG:

   ```sh
   CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
   NOTARYTOOL_PROFILE="Tempra-notary" \
   ./script/package_release_dmg.sh --upload
   ```

The script stops if Developer ID signing, notarization, stapling, Gatekeeper
assessment, or GitHub authentication fails.

If an Apple Developer Program membership is not available, you can create an
explicitly labeled, unnotarized DMG with an Apple Development identity:

```sh
./script/package_release_dmg.sh --unnotarized --upload
```

The file name includes `unnotarized`. macOS can warn users or block the app
because Apple did not notarize it. The script does not use this mode unless you
specify `--unnotarized`.

## License

Tempra is available under the [GNU General Public License v3.0](LICENSE).
See [Third-Party Notices](THIRD_PARTY_NOTICES.md) for sensor implementation
acknowledgements.
