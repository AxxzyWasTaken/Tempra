# Security policy

Tempra stops, throttles, and deprioritizes processes it does not own, and it installs an
administrator helper to reach the ones it cannot touch otherwise. That is a lot of power for a
menu bar app, so a bug in those paths is worth reporting.

## Supported versions

Only the latest release gets fixes. There are no support branches, and older releases stay as
they are.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Anything older | No, upgrade first |

Tempra does not auto-update, because the builds are not notarized and there is no signed update
feed. A security fix reaches you when you download the new DMG from the
[releases page](https://github.com/AxxzyWasTaken/Tempra/releases/latest), and not before.

## Reporting a vulnerability

[Open a private security advisory](https://github.com/AxxzyWasTaken/Tempra/security/advisories/new).
Only you and the maintainer can see it until a fix ships.

Do not open a public issue for a vulnerability, and do not post details anywhere else before the
fix is out.

Include:

- The macOS version, the Mac, and the Tempra version or commit.
- Whether the administrator helper was installed.
- Steps to reproduce, from a clean install if you can manage it.
- What the attacker walks away with. Running code, root, stopping a process they should not be
  able to stop, reading something that is not theirs.

Expect a first reply within a week. If the report holds up, you get a note when the fix ships,
and the advisory and the release notes credit you unless you would rather stay anonymous.

## What counts

In scope:

- An unprivileged process gaining root through the administrator helper or its XPC interface.
- The helper or the guardian acting on a process the caller has no right to control.
- A process left stopped or deprioritized after Tempra quits, crashes, or gets killed. A stuck
  process is a broken machine.
- A rule or a signal reaching a protected system process.
- Code execution through saved preferences, a profile, or a downloaded update.
- Another user's process details leaking to an unprivileged caller.

Out of scope:

- Tempra doing what you configured it to do, including pausing an app that then loses unsaved
  work.
- The Gatekeeper warning on first launch. That is the missing notarization, and the README
  covers it.
- The administrator password prompt when installing the helper.
- Anything that needs an attacker who already has root, or physical access to an unlocked Mac.
- Scanner output with no working reproduction.

## While you are testing

Use your own machine and your own processes. Do not go after anyone else's Mac, and do not use a
real bug to reach data that is not yours.
