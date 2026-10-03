# fermix-messages

The iMessage helper for [Fermix](https://github.com/tezra-io/fermix): a signed, notarized
`LSUIElement` app bundle (`io.tezra.fermix.messages`) that reads `~/Library/Messages/chat.db`
read-only, sends through Messages.app, and keeps the recipient policy the owner confirmed
in its own keychain item. The engine talks to it over NDJSON on stdio
(`fermix-messages serve --home DIR`); the control plane also runs as one-shot commands
that print one JSON object: `probe`, `grant --service automation|full_disk_access`,
`policy-get`, `policy-set --posture P --owner H [--handle H]...`.

The design is `docs/design/MILESTONE_54_IMESSAGE_CHANNEL.md` in the engine repo. The
helper holds the two macOS grants (Full Disk Access, Automation → Messages) so the
engine never has to.

```sh
swift build -c release
scripts/build_app.sh .build/release/fermix-messages dist 0.1.0 "Developer ID Application: …"
scripts/swift_test.sh
```

Protocol version and the engine's sha256 pin move together: a wire change bumps
`protocol_version` here and the pin in the engine's `FermixCore.IMessage.HelperInstaller`
in the same release walk.
