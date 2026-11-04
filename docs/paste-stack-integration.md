# Paste Stack integrations

Copy offers two ways to request a batch. Both validate 1 to 100 nonempty text
items, with at most 1 MiB of UTF-8 text in total, and keep duplicate items. On
acceptance, Copy replaces the stack with temporary entries, selects FIFO order,
and activates the stack. A rejected or invalid request leaves the stack alone.
Replacing a nonempty stack always needs confirmation.

## System actions

The Add Text to Paste Stack App Intent exposes the operation to Shortcuts and
other system experiences. The system does not provide this action with a
verified originating app, so Copy asks for confirmation on every request and
never remembers its source. The confirmation defaults to Cancel, shows a
separate, pageable preview of each item, and follows the secret-masking and
screen-sharing settings. An item beyond the secret scanner's limit remains
hidden until explicitly revealed.

## Direct app-to-app requests

The signed app advertises `CopyPasteStackProtocolVersion` 1 in its Info.plist.
This lets another app detect a compatible installation without sending an
Apple event or triggering macOS Automation permission. It is an advertisement,
not proof of the running recipient: a client must verify Copy's signing
identity and the reply to a payload-free handshake before sending private text.

Copy handles Apple events in class `CpSt`: `ping` returns a versioned
capability reply without modifying the stack; `batc` accepts a UTF-8 JSON
object containing `version: 1`, an `items` array, and `expiresAt` as Unix
seconds. The expiry can be at most 300 seconds from receipt. Copy checks it
again after any consent prompt, before changing the stack or remembering a
caller. Replies contain version 1 and a status, never stack contents. Requests have a 6,295,552-byte encoded
limit before decoding, followed by the item and UTF-8 limits above.

The App Intent and Apple events both use Copy's stack validation and consent
flow. They are separate interfaces because an App Intent invoked through a
system experience cannot establish the identity of the originating app. An
Apple event supplies a read-only actual-sender audit token; Copy resolves its
code identity from that token, never from a name or path in the request.

## Access levels

A verified signed caller can be authorized once and remembered by its bundle
identifier, signing identifier, and certificate fingerprint. Copy still asks
before replacing existing entries. A caller whose identity or signing cannot
be verified is offered one-time approval only; Copy never remembers it
implicitly.

Settings, Permissions lists authorized apps and lets the user forget them. It
also lets a developer explicitly add an unsafe exception for an app bundle's
canonical path and identifier. This exception ignores its signing certificate:
a process able to replace that app inherits its access. It is never created
automatically and is intended only for apps the user is developing. The
operating system's Automation permission is separate and can be revoked in
System Settings.

## Opt-in and signing requirements

External requests are disabled by default. Enable them under Settings > Permissions. The setting and remembered callers are protected by an app-specific data-protection Keychain access group. If Keychain access is unavailable, requests fail closed. A non-authoritative preference avoids accessing the Keychain while disabled; changing that preference alone cannot authorize requests. Requests use noninteractive Keychain reads, so they do not trigger Keychain authorization dialogs. Enabling access can require Keychain authorization depending on macOS and Keychain state. No previously stored unprotected approval is migrated.

A Developer ID provisioning profile must authorize the app identifier and Keychain access group for `com.tarikbc.Copy`. Install the profile locally and set `COPY_PROVISIONING_PROFILE` to its UUID before running `Scripts/release.sh`. CI requires the profile encoded as the `COPY_PROVISIONING_PROFILE_BASE64` secret. The release script preserves entitlements when re-signing the application. Verify the exported, notarized build with the actual Developer ID profile, including opt-in, remembered caller, revocation, and disabled requests on macOS 14 before release. Unsigned or ad-hoc builds cannot validate this Keychain boundary.
