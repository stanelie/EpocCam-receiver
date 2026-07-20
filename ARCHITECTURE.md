# EpocCam dual-camera — architecture & design notes

This system pairs two repos, reverse-engineered from the original iPhone EpocCam protocol (and kept wire-compatible with it):

- **EpocCam-streamer** (Android/Kotlin) — the TCP *server*. Captures the camera, encodes H.264, and serves the stream to one viewer at a time. Advertises itself over mDNS (`_epoccam._tcp`, port 5054).
- **EpocCam-receiver** (macOS/Swift) — the "EpocCam Viewer", the TCP *client*. Discovers phones, connects out, decodes, and publishes each feed to a **Syphon** server for use in Millumin / other Syphon clients.

**Dual camera:** the receiver accepts two concurrent streamers and publishes them as two distinct Syphon sources, **"EpocCam A"** and **"EpocCam B"**. All slot assignment and the A/B swap are done **entirely on the viewer side** — the phones need no UI for it, because the operator typically has no physical access to the remote phones. (A phone-side A/B button was prototyped and rejected for that reason.)

Receiver window: a two-pane view (A left, B right), a per-camera **Resolution** submenu, and **Cameras ▸ Swap A ↔ B** (⌘S), which flips the two feeds and persists the choice.

## mDNS identity & discovery (the crux)

Two problems had to be solved before two phones could be told apart:

1. **Identity vs discovery are different problems.** A phone's MAC uniquely identifies it, but you only learn it *after* connecting — so it can't help you *discover* or *address* a phone. Discovery needs a unique, addressable mDNS identity up front.
2. **Every phone originally advertised the same mDNS identity.** A fixed service instance name plus Android's generic `Android.local` hostname means two phones publish an identical service — Bonjour collapses them and the viewer only ever sees/reaches one.

**Fix (invisible, no phone UI):** each streamer advertises a stable per-install UUID three ways:

- a **unique instance name** `mobile-<id8>` so both phones are discoverable;
- a TXT record **`id`** — the viewer's stable slot key (survives IP changes, MAC randomization, and reboots);
- a TXT record **`ip`** — the phone's current IPv4, so the viewer dials the exact phone and sidesteps the shared `Android.local` hostname.

The streamer **re-advertises whenever its IP changes** (via `onLinkPropertiesChanged`, which — unlike `onAvailable` — fires on a same-network Wi-Fi roam), through a single **debounced re-registration** (this also replaced a per-disconnect mDNS "bounce" that was thrashing Android's NSD).

## Viewer: identity, connection pool, resilience

**Slot key priority:** advertised `id` → peer **MAC** (from an EUI-64 IPv6 link-local, else the host's ARP table for IPv4 / NDP table for IPv6 — the NDP lookup recovers a stable MAC even for an iPhone's *rotating privacy* IPv6 address) → IP. The original iPhone (which advertises no `id`) still works via MAC + hostname resolution. The `deviceKey → slot` map is persisted so a phone keeps its slot across restarts.

**Connection pool (≤2), one connection per phone.** The streamer serves only one viewer socket, so the viewer must never open two connections to the same phone. mDNS is the single source of truth. (An earlier "last-known-host" fast-start probe was removed — it raced mDNS, opened a second socket to the same phone, and the dedup then dropped the wrong one, producing "connected but no video / phone says not connected".)

**Stale-IP self-heal.** The viewer prefers the advertised `ip`, but if that won't connect it falls back to the mDNS **hostname** (which the phone's mdnsd keeps current) — so a stale advertised IP after a roam recovers on its own.

**Stall watchdog.** An abrupt network drop leaves a half-open TCP that would otherwise pin a pool slot forever. Any live connection delivering no frames for ~6 s is dropped and reconnected.

**No slot-hogging (important for live use).** A phone that keeps failing to connect — e.g. a test device introduced during setup that then disconnects — is backed off with a growing delay (2 → 5 → 10 → 20 s). The pool skips backed-off services and tries fewest-failures-first, so a reachable phone always wins a free slot. The backoff resets the instant the phone re-advertises (a returning or roamed phone reconnects immediately).

## Streamer: encoding reliability

- **Automatic keyframes.** The encoder emits an IDR every ~1 second, so a viewer joins or recovers from loss within a second (rather than waiting on an on-demand keyframe request).
- **Encoder self-heal.** If no keyframe flows for a few seconds while a viewer is connected, a watchdog recreates the MediaCodec on a background thread (single-flighted and rate-limited). This is the backstop for a *wedged* codec — one that keeps emitting P-frames but stops producing keyframes even when asked. Periodic keyframes alone can't fix that, because a stuck codec ignores keyframe requests.
- **Note:** at HD, 1-second keyframes are large. If Wi-Fi contention causes hitching, widen the keyframe interval at HD.

## Building

- **Receiver:** `./build.sh` — compiles a universal (Apple Silicon + Intel) app with `swiftc`. New Swift source files must be added to the `SWIFT_SRCS` list in `build.sh`. Runs on macOS 11+. The build is unsigned, so first launch on another Mac needs right-click ▸ Open.
- **Streamer:** a normal Android Studio / Gradle debug build (`:app:assembleDebug`) produces `epoccam-streamer.apk`. Requires the Android SDK and a JDK (Android Studio's bundled JBR works). The debug APK is debug-signed — a phone that already has a differently-signed copy must uninstall it before installing.

## Troubleshooting "a phone won't connect"

1. **Same subnet?** mDNS is link-local. If the Mac and the phone end up on different subnets (e.g. the Mac loses one of two network interfaces), they can't discover each other even though both are "online". Check that the Mac has an address on the phone's subnet.
2. **Reachable but not discovered** (ping / `nc <ip> 5054` succeed, but nothing shows up): a stale mDNS cache. Flush it with `sudo killall -HUP mDNSResponder`, and restart the viewer to clear any wedged in-memory pool state. (Rebooting the *phone* does not fix viewer-side state.)
3. **Connects but no video:** the encoder is producing frames but no keyframes (wedged codec). Restart the streamer app; the self-heal watchdog also covers this.
4. **High latency to a "local" IP** (e.g. hundreds of ms) usually means the phone is on the wrong Wi-Fi and being routed indirectly — put both devices on the same LAN.

## Compatibility

The original iPhone EpocCam transmitter still works with this receiver: it advertises no `id`/`ip` TXT, so the viewer resolves it by hostname and keys its slot by MAC — exactly the fallback paths above.
