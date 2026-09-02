# Plan 004: Add a native iOS companion with Home Screen and Lock Screen widgets

> **Executor instructions**: Follow this plan in order. Phase 0 is a device gate
> that must run on a real iPhone; it cannot be completed in the simulator or in
> CI, and its third item decides which transport the widget leans on. If a gate
> fails, stop and record the evidence in the decision log. Do not ship a widget
> that renders invented numbers, do not present a stale reading as current, and
> do not disable App Transport Security globally to reach the Mac.
>
> **Drift check (run first)**:
> `git diff --stat 03df85b..HEAD -- Package.swift apps/macos-native/Sources apps/pwa/public apps/pwa/src plans`
> If any listed path has changed, compare the current behavior described below
> with the live code and update this plan before implementation.

## Status

- **Priority**: P2
- **Effort**: L (new platform, new build lane, one shared contract)
- **Risk**: MEDIUM (widget refresh budget and Local Network privacy inside an
  app extension are outside this project's control; the encrypted relay
  fallback keeps a failure in either one from leaving the widget blank)
- **Depends on**: none in code; Phase 0 depends on hardware
- **Category**: feature
- **Planned at**: commit `03df85b`, 2026-09-01

## Feasibility verdict

**Feasible.** Three constraints shape the design; none of them blocks it.

1. **Daily use needs a paid Apple Developer Program membership ($99/yr);
   development and validation do not.** A free Personal Team can build, install,
   and test the app and its widget on a tethered iPhone. What it cannot do is
   keep them alive: a Personal Team signature expires after **7 days**, after
   which the app stops launching and its widget dies on the Home Screen until it
   is reinstalled from Xcode. That is the real cost of staying free — not any
   single capability. (Push Notifications do require the paid program, but this
   plan does not use them.)
   Whether **App Groups** is available to a Personal Team is *not asserted here*
   in either direction: reports conflict and the answer has moved between Xcode
   releases. Phase 0 measures it on the target machine, which is cheaper than
   any argument about it. If it turns out to be unavailable, the paid membership
   becomes a hard precondition rather than a convenience, because the app and
   the widget cannot otherwise share one cached snapshot.
2. **Widgets are not live.** WidgetKit reloads on a system budget (Apple
   documents roughly 40–70 timeline reloads per day for an installed widget), so
   ~15 minutes is the realistic floor. That is acceptable against a Mac that
   only refreshes every 5 minutes itself (`UsageStore.refreshInterval = 300`),
   and Phase 4 makes the cadence visible instead of hiding it: the widget always
   shows how old its reading is and when it next expects to check.
3. **Two transports, local network first.** The LAN path is the freshest and
   involves no third party, so it leads. The encrypted ntfy relay the Mac
   already publishes to is the fallback, so the widget still has something true
   to show when the phone is on cellular or away from home. Neither transport
   invents data: both carry the same snapshot the Mac measured, and when both
   are silent the widget shows the last reading's true age plus the offline
   message.

Everything else is already in place: the pairing secret, the 12-word phrase, the
QR code, the local `/snapshot` endpoint, and the encrypted relay publisher all
exist and are protocol-defined rather than PWA-specific.

## Decision

Add a **native SwiftUI iOS app plus a WidgetKit extension** under `apps/ios`,
built with XcodeGen exactly like the macOS app, sharing `MetriaCore` by source
reference. The app pairs by scanning **the QR code the Mac already generates**,
then reads usage over two transports, in order:

- **Local network (primary)**: `GET http://<mac-ip>:<port>/snapshot` with the
  pairing header, the same request the PWA makes today
  (`apps/pwa/public/app.js:159-174`).
- **Encrypted relay (fallback)**: poll the ntfy topic derived from the pairing
  secret and decrypt with AES-GCM, the same payload the Mac publishes today
  (`apps/macos-native/Sources/Metria/MetriaApp.swift:136-168`).

The app and the widget share one snapshot cache in an **App Group** container
and read the pairing secret from a shared Keychain access group. Whichever
process fetches successfully writes the cache and reloads the widget timelines.

The macOS app changes in exactly two small ways: the pairing link gains a
`local=` parameter so one QR code carries both the hosted PWA URL and the LAN
address, and `LocalPWAServer` advertises `_metria._tcp` over Bonjour so the
phone survives a DHCP address change without re-pairing.

Do **not** replace the PWA in this plan. The README already lists native mobile
apps as the intended replacement, but the PWA is the only Android story and must
keep working byte-for-byte against the same endpoints.

## Why this matters

The PWA cannot put anything on the Lock Screen or the Home Screen. On iOS a PWA
gets no widgets, no reliable background refresh, and Web Push only inside its
own installed window. A quota you have to open an app to read is a quota you
check too late. The widget is the actual product here; the app around it exists
to pair, to hold the permission grants, and to give the widget a place to cache.

## Verified current state

1. The pairing secret is 16 bytes in the macOS Keychain, rendered as a QR code
   and a 12-word BIP-39-style phrase; HKDF derives the ntfy topic and the
   AES-256 key from it (`apps/macos-native/Sources/MetriaCore/PairingSecret.swift`).
2. The QR code encodes `<pwaBaseURL>/#s=<secret-base64url>&server=<ntfy>`
   (`MetriaApp.swift:112-115`). `pwaBaseURL` is the custom HTTPS PWA URL when set
   — the default — and falls back to the local server's `http://<ip>:<port>`
   only when that setting is cleared (`MetriaApp.swift:1234-1240`). **So today's
   QR code does not carry the LAN address in the default configuration.**
3. `LocalPWAServer` serves the bundled PWA files and one `GET /snapshot` that
   requires header `X-Metria-Secret` to equal the base64url master secret
   (`LocalPWAServer.swift:104-118`). It is plain HTTP, port 8973 by default,
   trying successive ports on failure, bound to the primary IPv4 address of
   `en0` (`LocalNetwork.swift:5-27`). It does not advertise Bonjour.
4. The snapshot JSON is `{ updatedAt, providers: [{ name, percent, resetDate }] }`
   with ISO-8601 dates, produced by a `private struct MetriaSnapshot`
   (`MetriaApp.swift:10-19`) and pushed to both the local server and ntfy
   whenever it changes (`MetriaApp.swift:1201-1214`).
5. `MetriaCore` imports only Combine, Foundation, CryptoKit, and Security — no
   AppKit — so it compiles for iOS unchanged. The root `Package.swift` builds
   the `Metria` executable from `path: "."` with an explicit `exclude` list,
   which a new `apps/ios` directory would break unless it is excluded.

## Phase 0 — Device gate (blocking, cannot be skipped)

Run on a real iPhone (iOS 17+) using a throwaway Xcode project, **first with the
signing team actually intended for daily use**. Record every answer, and the
team type, in the decision log.

1. **App Groups**: create `group.com.metria.shared` and confirm the app and a
   widget extension can both read and write a file in the shared container.
   Record explicitly whether this worked under a free Personal Team, since that
   answer decides whether the paid membership is a convenience or a
   precondition.
2. **Keychain sharing**: confirm the widget extension can read a Keychain item
   written by the app through a shared access group.
3. **Local Network privacy — the decisive question.** With
   `NSLocalNetworkUsageDescription` set and the prompt already accepted in the
   app, confirm whether a `URLSession` request from **inside the widget
   extension** to `http://<mac-ip>:8973/snapshot` succeeds, and whether an
   `NWBrowser` for `_metria._tcp` resolves there. The permission prompt can only
   be presented by a foreground app, so if the grant does not extend to the
   extension the request fails silently.
   - **If it extends**: the widget runs the full chain itself on every timeline
     reload — LAN first, relay second. This is the design the plan assumes.
   - **If it does not**: the widget must never attempt a local fetch (it would
     only burn its execution time failing silently). The app owns the LAN
     transport, foreground and `BGAppRefreshTask`, and the widget refreshes
     itself over the relay only, which needs no local-network grant. Build
     Phase 4 to the answer rather than around it.
4. **ATS**: confirm `NSAppTransportSecurity.NSAllowsLocalNetworking = YES`
   permits the plain-HTTP LAN request without disabling ATS globally, in both
   the app and the extension Info.plist.
5. **Refresh budget**: install a widget whose timeline requests
   `.after(15 * 60)` and log every `getTimeline` call for 24 hours. Record the
   observed reload count — Phase 4's countdown copy depends on it being roughly
   what was requested.
6. **Signature lifetime**: note the provisioning profile's expiry date, so the
   7-day reinstall cycle is a recorded fact rather than a surprise.
- **Gate**: items 1, 2, and 4 must pass, and item 3 must have a recorded answer.

## Phase 1 — Share the snapshot contract and open the build lane

- Move the snapshot model out of `MetriaApp.swift` into `MetriaCore` as a public
  `UsageSnapshot: Codable` with the identical field names, ISO-8601 date
  strategy, and JSON output. The macOS app encodes it; iOS decodes it; the PWA
  must keep parsing it unchanged. Additive optional fields only — never rename
  or retype `name`, `percent`, `resetDate`, or `updatedAt`.
- Add `"apps/ios"` to the `exclude` list of the `Metria` executable target in
  `Package.swift` (per AGENTS.md, the manifest is explicit and must be updated).
- Add `apps/ios/project.yml` (XcodeGen), mirroring `apps/macos-native/project.yml`:
  - `MetriaCore` — framework, platform iOS, sources
    `../macos-native/Sources/MetriaCore` (source reuse, not a copy).
  - `MetriaMobileKit` — framework, the shared client code (transport, cache,
    formatting) used by both the app and the widget.
  - `MetriaMobile` — application, `com.metria.ios`, deployment target iOS 17.0,
    Swift 5.9, App Group and Keychain-sharing entitlements,
    `NSCameraUsageDescription`, `NSLocalNetworkUsageDescription`,
    `NSBonjourServices: ["_metria._tcp"]`, `NSAllowsLocalNetworking`.
  - `MetriaWidgets` — app extension, `com.metria.ios.widgets`, same App Group,
    Keychain group, and ATS/Bonjour keys, embedded in the app.
  - A postbuild copy of `Assets/*.png` for the provider logos, matching the
    macOS target's script.
- **Gate**: `swift build` still passes from the repository root, and
  `xcodegen generate --spec apps/ios/project.yml` followed by an unsigned
  simulator build of all targets succeeds.

## Phase 2 — Make the Mac pairable by a native client

Small, additive, and safe for the existing PWA.

- **Carry the LAN address in the pairing link.** Extend
  `PairingManager.pairingLink` to append `&local=<http://ip:port>` whenever
  `localPWAServer.baseURL` exists, independent of `customPWAURL`, and refresh
  the QR image on every `onURLChange`. The PWA ignores unknown fragment
  parameters (`parsePairingParams` reads only `s` and `server`), so one QR code
  now serves both clients.
- **Advertise Bonjour.** Give the `NWListener` an `NWListener.Service(name:
  "Metria", type: "_metria._tcp")` so the iPhone can re-resolve the Mac after a
  DHCP change instead of demanding a re-scan. The Mac's Info.plist already
  declares `NSLocalNetworkUsageDescription`.
- **Derive the local token instead of shipping the master secret** (hardening,
  do it in this phase or explicitly defer it): add
  `PairingSecret.localToken(from:)` using HKDF info `metria-local-token-v1`, and
  have `/snapshot` accept either the derived token or the legacy base64url
  secret so the deployed PWA keeps working. The iOS client sends only the
  derived token. Rationale: the header travels in plaintext over the LAN today,
  and the master secret it currently carries also unlocks the ntfy stream
  permanently, while a derived token does not.
- **Gate**: `swift build` passes; the existing PWA still pairs and still loads
  `/snapshot` from a browser on the same Wi-Fi.

## Phase 3 — The iOS app

- **Pairing**: `AVCaptureSession` + `AVCaptureMetadataOutput` (`.qr`) — no
  third-party scanner. Parse the fragment into `{ secret, ntfyServer, localURL }`
  with the same rules as `parsePairingParams` (which already reads `server` for
  the relay), reject anything else, and keep the 12-word
  phrase as a manual fallback path (`PairingSecret.secret(from:)` already
  validates the checksum). Store the secret in the shared Keychain group with
  `kSecAttrAccessibleAfterFirstUnlock`; the widget must still tolerate a nil
  read and fall through to its unpaired state rather than crash.
- **Transport** (`SnapshotSource`, in `MetriaMobileKit`, used by both processes):
  1. `LocalSnapshotSource` — resolve the Bonjour service, fall back to the
     pinned `localURL` from pairing, `GET /snapshot` with the token header,
     3-second timeout.
  2. `RelaySnapshotSource` — `GET <ntfy>/<topic>/json?poll=1&since=10m`, decrypt
     each line's `message` with AES-GCM (IV(12) ‖ ciphertext ‖ tag(16), exactly
     `decryptSnapshot` in `apps/pwa/public/pairing.js`), keep the newest that
     decrypts, ignore anything that does not — a failed decrypt is either the
     wrong key or forged noise on a guessed topic.
  3. `SharedSnapshotCache` — atomic JSON write into the App Group container,
     storing the snapshot, the time of the fetch, and which transport answered.
  Run them in order but keep the newest `updatedAt`, not merely the first
  answer: a relay message can be newer than a stale local read.
  Every successful fetch calls `WidgetCenter.shared.reloadAllTimelines()`.
- **UI**: one screen matching the PWA's card list — logo, provider name,
  percentage in the existing color thresholds (85 red / 65 orange / 40 yellow /
  else green), progress bar, reset date, "Updated <time>" footer, and a
  connection chip reading Local / Relay / Offline. Settings holds re-pair,
  forget pairing, the local server address, and the ntfy server field.
- **Background**: register one `BGAppRefreshTask` that fetches and reloads widget
  timelines. Treat it as opportunistic; never present it as a guarantee. It
  carries the LAN transport for the widget if Phase 0 item 3 came back negative.
- **Gate**: on device, scanning the Mac's QR code pairs and shows live
  percentages on Wi-Fi; leaving the network flips the chip to Offline while the
  last reading stays on screen with its age.

## Phase 4 — The widgets

Built to Phase 0 item 3's measured answer.

- **Families**: `.systemSmall` (highest-usage provider as a ring gauge),
  `.systemMedium` (up to four providers as rows), `.accessoryCircular` (Lock
  Screen gauge of the highest provider), `.accessoryRectangular` (two lines:
  providers and percentages), `.accessoryInline` (one line). Choose the displayed
  provider with an `AppIntentConfiguration`, so one widget can be pinned to
  Claude and another to Cursor.
- **Freshness display — required, not decoration.** WidgetKit's auto-updating
  date text (`Text(_:style:)` with `.relative`, and
  `Text(timerInterval:countsDown:)`) re-renders on screen **without consuming a
  timeline reload**, so both of these tick live and cost nothing against the
  budget:
  - **Last update**: `Text(snapshot.updatedAt, style: .relative)` — "3 min ago",
    counting up on its own. Use the Mac's `updatedAt` (when the reading was
    true), not the fetch time (when the phone happened to ask).
  - **Next check**: `Text(timerInterval: now...nextReloadDate, countsDown: true)`
    against the same date the timeline requested. Label it as an expectation
    ("next check") and never as a promise — the system may reload late, in which
    case the timer sits at `0:00`, which is itself the correct signal that the
    refresh is overdue.
  - Provider reset dates can use `.relative` for free too ("resets in 3d").
  - Space is tight on `.accessoryInline` and `.accessoryCircular`: show the
    percentage there and keep both timers to the medium, small, and rectangular
    families.
- **Timeline**: `getTimeline` reads the shared cache, fetches when Phase 0
  permits it, and returns one entry with
  `.after(Date().addingTimeInterval(15 * 60))` — the same date the countdown
  targets. Add an interactive refresh `Button(intent:)` (iOS 17) so a tap can
  re-fetch on demand.
- **Offline state**: when the newest snapshot is older than 20 minutes and
  neither transport answers, render the mascot plus one line drawn deterministically from the
  snapshot's age, so it does not flicker between reloads. All strings en-US
  (AGENTS.md), short enough for `.accessoryRectangular`:
  - "Your Mac is asleep. Your quota is not."
  - "No signal from the Mac. Assume you spent it all."
  - "Last seen 3h ago. Living dangerously."
  - "Offline. The tokens are burning unsupervised."
  The joke never replaces the age — the relative timestamp stays on screen and
  keeps counting. A funny widget that hides staleness is a broken widget.
- **Not paired state**: a plain "Open Metria to scan the QR code on your Mac"
  with a deep link, never a joke.
- **Gate**: on device, all five families render paired, stale, and unpaired
  states correctly; the relative timestamp and the countdown both advance while
  the screen is on with no timeline reload; force-quitting the app does not blank
  the widget; the 24-hour reload count matches Phase 0's measurement.

## Phase 5 — CI, release, and documentation

- `.github/workflows/ios-ci.yml`: on pull requests touching `apps/ios`,
  `Assets`, or `apps/macos-native/Sources/MetriaCore`, run `xcodegen generate`
  and an unsigned `xcodebuild -destination "generic/platform=iOS Simulator"`
  build of all targets. No signing secrets in CI.
- Release: TestFlight upload is a separate, credentialed workflow; do not add it
  until a paid team exists. Until then the iOS app is source-only, and the
  README must say so rather than implying a download — including the 7-day
  reinstall cycle that a free Personal Team build imposes.
- README: add an "iOS app" section under Mobile, stating the pairing flow, that
  usage only appears while the Mac is awake on the same Wi-Fi, the widget refresh
  cadence, and that the PWA remains the Android path. Update the "To do" entry
  once the app exists.
- AGENTS.md: add a line for the iOS lane (XcodeGen spec location, shared
  `MetriaCore` by source reference, verification command).

## Risks

1. **Local Network permission does not reach the widget extension.** Measured
   before any product code (Phase 0 item 3). Mitigation: the fallback is already
   part of the design — the app keeps the LAN transport and the widget refreshes
   over the relay, which needs no local-network grant.
2. **Widget refresh budget disappoints.** Mitigation: the widget states its own
   staleness and next check, both for free, plus the interactive refresh button.
3. **Free-team signature expiry.** The app and widget stop working every 7 days
   until reinstalled from Xcode. Mitigation: none technical — it is the reason to
   buy the membership, and the README must say so plainly.
4. **App Groups unavailable on the tier in use.** Then the app and widget cannot
   share a cache and the design does not stand. Measured in Phase 0 item 1.
5. **DHCP moves the Mac.** Mitigation: Bonjour resolution in Phase 2, pinned
   address only as a fallback.
6. **Plaintext HTTP on the LAN.** Anyone on the same network can read the
   snapshot and replay the header. Mitigation: derived local token in Phase 2, so
   a captured header is not the master secret; the content is usage percentages,
   and a self-signed TLS LAN server would be worse than the problem it solves.
7. **Contract drift between three clients.** The PWA, the widget, and the app all
   parse one JSON. Mitigation: one `UsageSnapshot` in `MetriaCore`, additive
   changes only, and the PWA re-checked in Phase 2's gate.
8. **Scope creep into an iOS provider implementation.** Out of scope forever: the
   phone has no Claude/Codex/Cursor credentials and must never be asked for them.
   It displays what the Mac measured.

## Alternatives considered and rejected

- **LAN-only, dropping the relay.** Rejected: a widget that is blank whenever
  the phone leaves the house is not worth the Home Screen slot, and the relay
  payload is already end-to-end encrypted with a key the relay operator does not
  hold.
- **Relay-only, dropping the LAN path.** Rejected: the local path is the
  freshest and involves no third party at all.
- **APNs push to beat the refresh budget.** Out of scope here, and not free to
  add later: it needs the paid membership, an APNs key held by the Cloudflare
  Worker, and a Mac-side publisher that does not exist — nothing in this
  repository ever calls the Worker's `/api/usage`
  (`apps/pwa/src/worker.js:130-140`), so the PWA's own "mobile alerts" today
  only deliver the welcome push sent at subscribe time. Revisit only if Phase 4
  measures the budget as unacceptable, and do not downgrade the end-to-end
  encryption to get there: that endpoint currently takes the plaintext secret
  and the plaintext snapshot, unlike the ntfy path.
- **Keeping only the PWA and waiting for iOS to allow web widgets.** Rejected:
  there is no such API, and the README already commits to native mobile apps.
- **React Native / Flutter / Capacitor.** Rejected: the entire deliverable is a
  WidgetKit extension in SwiftUI, which every wrapper reimplements natively
  anyway, and `MetriaCore` is already Swift.
- **A second QR code just for the LAN address.** Rejected: one `local=`
  parameter on the existing link is invisible to the PWA and costs one line.
- **Embedding the PWA in a `WKWebView` shell.** Rejected: same screen, worse
  performance, and still no widgets — widgets cannot render web content.
- **Moving `MetriaCore` to a top-level `packages/` directory** for the shared
  target. Reasonable, but rejected for now as churn across `Package.swift`,
  `project.yml`, AGENTS.md, and CI paths; the iOS project references the existing
  path directly. Revisit if a third consumer appears.
- **Copying `PairingSecret.swift` into the iOS target.** Rejected: a duplicated
  key-derivation routine is exactly the drift that silently breaks pairing.

## Verification

```sh
swift build                                          # required repository verification (AGENTS.md)
xcodegen generate --spec apps/ios/project.yml
xcodebuild -project apps/ios/MetriaMobile.xcodeproj -scheme MetriaMobile \
  -configuration Release -destination "generic/platform=iOS Simulator" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Manual checks with the Mac app running:

1. Scan the Settings → Phone QR code: the app pairs and shows the same numbers as
   the Mac dashboard within one refresh interval.
2. The existing PWA still pairs and still updates from the same QR code.
3. Add each widget family; each shows real percentages with a live "updated N
   minutes ago" and a live countdown to the next check.
4. Leave the Wi-Fi network: the chip flips to Relay and the numbers survive on
   cellular; re-joining returns it to Local.
5. Quit the Mac app: the widget keeps the last reading, its age keeps counting,
   and after 20 minutes the offline line appears alongside it. Airplane mode
   does the same with both transports down.
6. Regenerate the pairing on the Mac: the phone stops updating and prompts to
   re-pair rather than showing stale numbers as current.

## Open questions for the product owner

1. Paid membership: buy it up front, or run on a free team through Phase 4 and
   accept the 7-day reinstall cycle during development? Phase 0 item 1 may force
   the answer.
2. Android: out of scope here, but the same transport and the same
   `UsageSnapshot` contract would carry a Kotlin client and Glance widgets later.

## Decision log

- **Transport scope set 2026-09-01** (product owner): local network first, with
  the existing encrypted ntfy relay reinstated as the fallback so the widget
  survives cellular and a sleeping Wi-Fi link. (An earlier revision of this plan
  cut the relay; that cut was reversed the same day.) APNs push remains out of
  scope — see "Alternatives" for what it would cost.
- **Phase 0 item 1 answered 2026-09-01 on a free Personal Team.** With
  "Automatically manage signing" and a Personal Team, Xcode provisioned
  `group.com.metria.shared` for both `MetriaMobile` (`com.metria.ios.app`) and
  `MetriaWidgets`, and the project built for an iPhone destination. **App Groups
  is therefore available without the paid membership here**, which makes the
  Apple Developer Program a convenience — the 7-day signature — rather than a
  precondition. Items 2 through 5 remain unmeasured: a successful build proves
  entitlement provisioning, not that the widget extension can read a Keychain
  item the app wrote, reach the LAN, or hold its reload budget. Item 2 deserves
  particular attention because `PairingStore` omits `kSecAttrAccessGroup` and
  relies on both targets declaring the same first entitled group
  (`apps/ios/Sources/MetriaMobileKit/AppGroup.swift:5-10`); Xcode's Signing &
  Capabilities pane showed App Groups and Background Modes but no Keychain
  Sharing row, so confirm the entitlement reached the profile.
- *(Remaining Phase 0 results go here before any product code is written.)*
