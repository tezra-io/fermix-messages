# fermix-messages

The signed iMessage helper that Fermix's `imessage` channel spawns. Design of record:
`docs/design/MILESTONE_54_IMESSAGE_CHANNEL.md` in `tezra-io/fermix` (§5, §6, §7, §8, §9
are this repo's contract). Swift 5.10+, SwiftPM only (no Xcode project), macOS 14+.

## Rules
- The bundle id `io.tezra.fermix.messages` and the display name "Fermix Messages" are
  permanent TCC keys. Never change them.
- The helper is the principal for Full Disk Access and Automation; it self-disclaims at
  the top of `main()` and never runs undisclaimed. No fallback path.
- The recipient policy lives only in the helper's own keychain item (ACL = this code);
  every data-plane call is checked against the stored item, never against a request.
- `attributedBody` is parsed structurally with bounds. `NSUnarchiver` and
  `NSKeyedUnarchiver` are forbidden on that blob. No code from GPL projects.
- Dispositions are `recorded`, `uncertain`, `failed`; `uncertain` is never retried.
- One mutation lane; the ledger row is fsynced before `osascript` runs.
- Logs redact handles. No message body ever reaches stderr.
- Gates: `swift build -c release`, `scripts/swift_test.sh` (plain `swift test` under
  Xcode; Command Line Tools need the wrapper's framework and macro-plugin paths),
  `scripts/build_app.sh` with the Developer ID identity (the entitlement check inside it
  must pass). What needs the real Messages app or TCC is in `LIVE_CHECK.md`.
- Code rules mirror the engine's AGENTS.md: linear flow, bounded loops, small functions,
  own every resource, fail loud, no fallbacks, zero warnings.
