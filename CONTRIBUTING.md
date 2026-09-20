# Contributing to Tempra

## Build and test

```sh
swift build                          # about 3 seconds incremental
swift test                           # the full suite, about 400 tests
swift test --filter <SuiteName>      # one suite while you iterate
swift test --build-system native     # the layout older toolchains and CI use
```

Run the full bare suite before opening a pull request. Do not pipe it through
`tail`; that hides the exit code.

CI runs `swift build --configuration release` and `swift test` under both
SwiftPM build systems (`native` and `swiftbuild`). Swift 6.4 and later default
to `swiftbuild` and place products in `.build/out/Products/Debug`; older
toolchains default to `native` and use `.build/<triple>/debug`. A test that
builds a product path from a literal layout passes on one and fails on the
other forever, so never hardcode a `.build/...` path. If a test needs a built
sibling executable, ask the dynamic linker where the test bundle lives with
`dladdr(#dsohandle, ...)` and walk up past the `.xctest` bundle. `Bundle.main`
is a toolchain binary inside Xcode.app during `swift test` and is useless here.
`swift build --show-bin-path` prints the layout the current toolchain chose.

## Targets

| Target | Role |
|---|---|
| `Tempra` | The menu bar app: AppKit entry point, SwiftUI views, `AppStore` |
| `TempraPrivilegedHelper` | Root XPC helper for processes owned by other users |
| `TempraWatchdog` | The launchd process guardian that restores paused processes if the app dies |
| `TempraSafety` | Shared XPC protocols, the priority controller, and the protected-process policy |

The test target imports `TempraPrivilegedHelper` and `TempraWatchdog` directly,
so root-helper logic is unit-testable without privileges.

## Writing tests

- Swift Testing (`@Suite`, `@Test`, `#expect`). Fakes live per test file and are
  private. Reuse the existing shapes rather than inventing a new fake for a
  protocol that already has one.
- Never let the real clock decide an interval a test asserts on. Services take
  an injected clock (`ProcessControlClock.now`, `SuspensionExpirationClock.now`,
  `MonitoringCoordinator.now`). When you assert a measured gap, advance the
  injected clock by hand. When you assert a debounce window, use a window far
  longer than any runner could outlive and cover the production default with a
  separate assertion on the stored property.
- Poll with a local `eventually { }` helper, not `Task.sleep`.
- A `ManagedApp` that should be paused in a test needs `launchedAt` in the past
  (older than the rule delay), `isHidden: true`,
  `windowVisibility: .hiddenOrMinimized`, real `processIdentities`, and an
  enabled rule with `action: .pause`.
- `AppStore` tests use a fresh `UserDefaults(suiteName:)` per test, pass
  `startsMonitoring: false`, and always `await store.shutdown()` at the end.
- `LifecycleFailureMessageTests` and `ApplicationTerminationTests` assert exact
  user-facing strings. When you change wording, update both.

## Known flake

`ProcessGuardianTests` "The lease timer restores a stopped process without
another request" can race under full-suite load. It passes alone and on re-run.
Re-run before investigating. If the same test fails in every CI run it is not
this flake; treat it as a deterministic environment difference.

## Invariants worth knowing before you touch process control

- Every operation answers with four disjoint sets: applied, stale, failed,
  unchanged. Never fail a whole batch because some identities are unactionable;
  put them in `unchanged`.
- The guardian journal has two independent sets, stopped and backgrounded.
  `disarm` releases only the stopped set. Do not simplify it to recover
  everything.
- Add new rule invariants to `SystemProcessRulePolicy.normalized()`, not to
  another call site.
- After any `await` in `ProcessController`, re-check `workIsCurrent` before
  mutating the ownership maps.

## Commits

Conventional Commits with a scope, past-tense subject, bullet body. Version
lives only in `script/build_and_run.sh` (`APP_VERSION`, `APP_BUILD`); the
release script reads it from there.
