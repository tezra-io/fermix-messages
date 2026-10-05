# Live checks

What `swift test` cannot prove: anything that needs the real Messages app, real TCC, the
real login keychain or a second device. These are Spike 0 (design Appendix C, S1–S15) in
short form, run by the owner on the Fermix Mac against a `dev_local` build. Record each
result in the design doc's §22. Every message sent is generated for the check, to a test
account or to the owner's own devices; no existing conversation is read for a fixture.

## Setup

```sh
DEV_LOCAL=~/projects/fermix-dev-local          # [fermix_core.plugins] dev_local
APP="$DEV_LOCAL/imessage_helper/bin/macos-universal/Fermix Messages.app"
BIN="$APP/Contents/MacOS/fermix-messages"
H=~/.fermix-dev                                # the dev FERMIX_HOME
OWNER=+15551234567                             # your handle
TEST=test-account@icloud.com                   # the dedicated/test account's handle

cd ~/projects/fermix-messages
swift build -c release
scripts/build_app.sh .build/release/fermix-messages "$(dirname "$APP")" 0.1.0-dev \
  "Developer ID Application: Sujeeth Shetty (54A57TH9BJ)"
"$BIN" --version
```

Stop the engine's iMessage channel (or the dev daemon) first, so it does not hold a
second `serve` session on the same home.

One `serve` session you can type into (requests to a FIFO, the wire to `wire.log`, the
log to `helper.log`):

```sh
rm -f "$H/fm.in"; mkfifo "$H/fm.in"
("$BIN" serve --home "$H" < "$H/fm.in" > "$H/wire.log" 2> "$H/helper.log" &)
exec 3> "$H/fm.in"
req() { printf '%s\n' "$1" >&3; }
req '{"id":1,"method":"initialize","params":{"protocol_version":1,"client":"live-check"}}'
tail -f "$H/wire.log"            # in a second terminal; helper.log for the log
# end the session: req '{"id":99,"method":"shutdown"}'; exec 3>&-
```

The one-shot commands the engine calls:

```sh
"$BIN" probe      --home "$H"
"$BIN" grant      --home "$H" --service automation|full_disk_access
"$BIN" policy-get --home "$H"
"$BIN" policy-set --home "$H" --owner "$OWNER" [--handle GUEST]...     # needs Full Disk Access
```

## Checks

| ID | Check | Commands | Pass |
|---|---|---|---|
| S1 | Full Disk Access row | `"$BIN" grant --home "$H" --service full_disk_access` (bundle revealed in Finder, then the pane opens in front of it); drag the app in if it is not listed; `"$BIN" probe --home "$H"`. Then move the bundle to another version directory, rebuild nothing, probe again | `full_disk_access: granted`, `db: readable`; the row reads "Fermix Messages" with the icon; the grant survives the move |
| S2 | Automation prompt, three launchers | `"$BIN" grant --home "$H" --service automation` from (a) the app-managed agent (the app's Grant button), (b) a user LaunchAgent, (c) an SSH session | (a)(b) show "Fermix Messages wants access to control Messages" once, then `automation: granted`; (c) no dialog, `automation` stays `denied`/`not_determined`; the Automation row is keyed to `io.tezra.fermix.messages` |
| S3 | Own account (stage 6 gate) | message yourself from the phone; `"$BIN" probe` (read `self_aliases`); `"$BIN" policy-set --home "$H" --owner "$OWNER"` | until the own posture is supported: `{"error": {"kind": "owner_is_this_mac", …}}`, no dialog, `policy-get` unchanged. Once it is: the prompt arrives as one `message` with `sender.is_me: true`, `sender.service: "iMessage"`; the reply is `recorded` and reaches the phone **with a notification** |
| S4 | Send verification and ghost rows | `req '{"id":10,"method":"send.text","params":{"to":"'$TEST'","text":"S4 check","idempotency_key":"s4-1"}}'`; then a nonsense target added to the policy (`policy-set … --handle +15550000000`) | the first is `recorded` within 8 s with a `guid`; the nonsense target is `uncertain` (a ghost row or none) and the ledger row's `detail` names which; `recorded` happens before `date_delivered` is set |
| S5 | `attributedBody` decoding | send 40 generated messages of each kind (plain, emoji, a link, a mention) from the phone to `$TEST`; `req '{"id":11,"method":"messages.after","params":{"since_rowid":<before>,"limit":256}}'` | ≥ 99 % have `text` set and `decode_error: null` (any `typedstream_*` class is a fixture to capture) |
| S6 | Attachments both ways | inbound: a photo (HEIC) and a voice memo, then `attachment.fetch` with `convert: true`; outbound: copy a JPEG and a PDF into `$H/imessage/outbox/<uuid>/` and `send.file`; also `ln -s /etc/hosts "$H/imessage/outbox/x/hosts"` and `send.file` it | JPEG and `m4a` land under `$H/imessage/inbox/<guid>/`; both outbound files are `recorded`; the symlink is `path_refused` |
| S7 | GUID forms, participant lookup | with an SMS chat and no iMessage chat for a handle in the policy, `send.text` to it; read `helper.log` (`send_dispatched mode=…`) | the first send goes `participant_text`, later ones `chat_text` to the iMessage chat; the SMS chat is never the target |
| S8 | Sleep/wake, WAL rotation | `watch.subscribe`, sleep the Mac 10 min, wake, send 30 generated messages | every message arrives once, in order (the 1 s poll covers dropped kqueue events) |
| S9 | macOS 26 | repeat S4 and S7 on a macOS 26 Mac, or record "verified on 27 only" | recorded |
| S10 | Policy item ACL | `ACCOUNT="policy:$(printf %s "$(cd "$H" && pwd -P)" | shasum -a 256 | cut -c1-16)"`; from a `fermix ask` shell command: `security find-generic-password -s io.tezra.fermix.messages -a "$ACCOUNT" -w`; then bump the version (rebuild with `0.1.1-dev`) and `"$BIN" policy-get --home "$H"`; then an ad-hoc build (`build_app.sh … ""`) and `policy-get` | the shell read raises the keychain dialog (deny it); the signed helper reads silently across the bump; the ad-hoc build prompts |
| S11 | Self aliases | `"$BIN" probe --home "$H"` on the own account (phone and email aliases signed in); `policy-set --owner` with each alias, then with a friend's handle | `self_aliases` is exactly the account's aliases; each alias gives `owner_is_this_mac`; the friend's handle is derived `dedicated_account` (the dialog shows) |
| S12 | Watcher before response | own posture (once supported, see S3), `watch.subscribe`, then 50 `send.text` to `$OWNER` in a loop (distinct keys) | zero `message` notifications for those sends (each is `recorded`) |
| S13 | Restart during an uncertain send | `send.text`, then `pkill -9 -f "fermix-messages serve"` between the AppleScript and the verification (watch `helper.log` for `send_dispatched`); start `serve` again and `initialize` | a `send.reconciled` for that key, `recorded` or `uncertain`; no duplicate send; no echo; the same key replayed returns that word and sends nothing |
| S14 | Overflow beyond the bound | `watch.subscribe` with `buffer_limit: 16`; stop reading the wire (`kill -STOP` the `tail`, or start `serve` with `> >(sleep 120; cat >> "$H/wire.log")`); send 300 generated messages; resume; page with `messages.after` from the last acknowledged row until `has_more` is false; subscribe again from there | one `watch.overflow`; every message delivered exactly once, in order, across the wire and the pages |
| S15 | Setup from zero | a fresh home (`H=$(mktemp -d)`), no grants: `initialize`, `probe`, `grant` succeed; `policy-set` answers `permission_denied {full_disk_access}` until that grant lands (the posture is derived from chat.db); `messages.after`, `watch.subscribe`, `send.text` answer `permission_denied {full_disk_access}` / `policy_absent` until each grant and the confirmation land | Connected is reached through the control plane alone |

Helper-specific checks to run alongside:

- **Self-disclaim.** Only S1 and S2 prove it (CI runs `--version` through it but cannot
  see TCC): the prompt and both Privacy rows name "Fermix Messages", never the launcher
  (Terminal, the Fermix app). A disclaim that cannot happen exits 70, 71 or 72 with
  `FATAL disclaim` on stderr and runs nothing.
- **Consent dialog.** `policy-set` with a new guest shows one alert naming every handle
  ("Allow Fermix to exchange iMessages with +1 555 123 4567 and …?") and the derived posture
  ("Fermix will answer messages that +1 555 123 4567 sends to this Mac's account.");
  Approve → `{"confirmed_at": …, "posture": "dedicated_account"}`; Cancel → `{"error": {"kind": "policy_refused", …}}`;
  the same `policy-set` again returns at once with no dialog. Unanswered for 170 s it is
  `policy_refused`.
- **Owner signed in on this Mac.** On a freshly signed-in account (no chats yet) confirm
  the account's own address as `--owner` (derived `dedicated_account`: no aliases yet), then
  `watch.subscribe` and message yourself from the phone: one `policy.state
  {state: "owner_is_this_mac"}`, no `message`, and `send.text` to `$OWNER` answers
  `owner_is_this_mac` until a new `policy-set` writes a new item.
- **Sign-in probe.** With Automation granted, `signed_in` is `true`; sign Messages out and
  it reads `false`.
- **Rows without a chat join.** During S8, `grep row_without_chat_skipped "$H/helper.log"`
  should be empty or rare; frequent hits mean the 5 s join hold delays live messages.
- **Logs.** `helper.log` never carries a message body, and every handle in it is redacted.
