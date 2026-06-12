# Reference images for the snapshot harness (#342 / ADR-0025)

This directory holds the committed reference PNGs that the image-snapshot layer
(`DrawnInstrumentSnapshotTests`) compares against. `swift-snapshot-testing` writes
them, one subfolder per test suite, when the suite runs in **record mode**.

## The references are NOT recorded yet — by design

ADR-0025 (capstone, hard prerequisite) requires references to be recorded on the
**CI-pinned toolchain (Xcode 26.3)**, never on a developer machine. Local Xcode is
26.5; a reference baked on a skewed toolchain encodes the wrong font rasterisation
and sub-pixel colour, poisoning every later instrument slice. So the tests are wired
but parked: the image suite is gated OFF by default (`APEX_SNAPSHOT_TESTS` unset), and
until the references exist, enabling the gate fails with "missing reference" — the
correct "not yet ratified" signal.

## How to record the references (HUMAN / CI step, on Xcode 26.3)

A CI "record mode" job that selects Xcode 26.3 (the same pin as `ci.yml`'s test job)
and runs the snapshot suite with **both** env vars set:

```bash
xcodebuild test \
  -project ProjectApex.xcodeproj \
  -scheme ProjectApex \
  -only-testing:ProjectApexTests/DrawnInstrumentSnapshotTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' \
  APEX_SNAPSHOT_TESTS=1 \
  APEX_RECORD_SNAPSHOTS=1
```

- `APEX_SNAPSHOT_TESTS=1` un-gates the suite.
- `APEX_RECORD_SNAPSHOTS=1` flips record mode → writes the PNGs here, and (per
  `swift-snapshot-testing`'s contract) **fails the run**. That always-fail is the CI
  guard that record mode is never left on in the compare job.

The job then commits the generated `DrawnInstrumentSnapshotTests/*.png`. The compare
job (and any later instrument slice) sets only `APEX_SNAPSHOT_TESTS=1` — never the
record flag — so it compares against these committed references and fails on a diff.

Before recording, the ungated `SnapshotHarnessPreconditionTests.fontPrecondition`
must be green (both embedded faces resolve by PostScript name) — otherwise the
references silently encode San Francisco.
