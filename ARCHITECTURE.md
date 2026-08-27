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

**ARP warm-up before dialing.** A phone that just joined Wi-Fi has no ARP entry on the Mac yet — mDNS discovery itself doesn't create one, since multicast replies don't require the Mac to ARP the sender. `NWConnection`'s TCP SYN to a cold ARP entry can stall for many seconds (well past the connect timeout below), even though a plain `ping`/`nc` to the same IP resolves ARP immediately and unblocks it. This is why "add a second phone while a first is already connected" used to work only after relaunching the viewer: the first phone's IP was ARP-warm from its own traffic, the second one's wasn't, and nothing on the Mac had ever talked to it. Every dial now fires a background `ping` in parallel (`Browser.swift`, `primeARP`) purely to force that ARP resolution; the dial itself never waits on it.

Two things about `primeARP` are load-bearing and easy to regress:

- **Prime the advertised IP, not the endpoint being dialled.** The stale-IP fallback below dials the mDNS *hostname*, which is a `.service(...)` endpoint carrying no address to ping — so a `primeARP(dialTarget)` silently no-ops there. That's the worst possible place to skip it: the pool switches to the hostname after the *first* failure and stays there, so a struggling phone spends nearly all its retries unprimed. Observed on a Galaxy S7: ~5.5 minutes of 4-second timeouts before it happened to connect, with only the very first attempt ever primed.
- **One short ping isn't enough.** A Wi-Fi radio in power save needs a few packets to wake — a cold S7 answered at ~60 ms/packet only after several, versus ~3 ms warm. `-c 3 -t 3`; note macOS reserves `-i` below 1 s for root, so the default interval stands.

`primeARP` logs each attempt (`priming ARP for <ip>` / `ARP prime skipped`), which is the fastest way to confirm it is actually firing on the fallback path.

## Streamer: encoding reliability

- **Automatic keyframes.** The encoder emits an IDR every ~1 second, so a viewer joins or recovers from loss within a second (rather than waiting on an on-demand keyframe request).
- **Encoder self-heal.** If no keyframe flows for a few seconds while a viewer is connected, a watchdog recreates the MediaCodec on a background thread (single-flighted and rate-limited). This is the backstop for a *wedged* codec — one that keeps emitting P-frames but stops producing keyframes even when asked. Periodic keyframes alone can't fix that, because a stuck codec ignores keyframe requests.
- **Note:** at HD, 1-second keyframes are large. If Wi-Fi contention causes hitching, widen the keyframe interval at HD.

## Streamer: camera→encoder latency on Qualcomm devices (Pixel)

*(The capture path this section describes is vendor-specific in **both** directions — Qualcomm needs it, Exynos breaks on it. See "This path is Qualcomm-only" below before touching the gate.)*

Feeding the camera straight into `MediaCodec.createInputSurface()` is the documented, "recommended" zero-copy capture path, and it's what the encoder used originally. On Qualcomm-based phones (confirmed on a Pixel 5; Samsung's S6/S7, which this app is normally run on, don't have the latency problem) that input surface's `HardwareBuffer` usage flag (`USAGE_VIDEO_ENCODE`) puts the driver into a mode that holds back ~500ms–1s of frames before the encoder ever sees them — independent of bitrate, profile, `KEY_LATENCY`, VBR vs CBR, or any other `MediaFormat`/`CaptureRequest` tuning. This is a known, Google-acknowledged platform issue closed **"Won't Fix (Obsolete)"** without a fix: https://issuetracker.google.com/issues/254027327.

**Diagnosis approach that actually worked:** don't guess at encoder config — measure. Every encoded frame's `presentationTimeUs` is the camera's own capture timestamp, propagated untouched through the Surface into the encoder; diffing it against wall clock when the encoder emits that frame (`CameraEncoder.kt`'s `PIPE LATENCY` log, every ~2s) measures exactly how long a frame sat in the camera→encoder pipe, isolating that from anything downstream (network send, decode). Four different encoder/capture-request changes were tried and measured this way; none moved a suspiciously stable ~500ms figure at all — which is itself what pointed at a fixed driver-level pipeline depth rather than a tunable software parameter.

**Fix:** route frames through `ImageReader` → `ImageWriter.queueInputImage()` instead of feeding the camera directly into the encoder's input surface. This sidesteps the `USAGE_VIDEO_ENCODE` flag while staying a zero-copy GPU buffer handoff (no CPU frame copy) — confirmed by the same bug report. Measured result on the Pixel 5: ~500ms → ~90–100ms.

**This path is Qualcomm-only — do not widen that gate.** It was first gated on API level alone (`SDK_INT >= Q`, since `ImageWriter.newInstance(surface, maxImages, format)` and `ImageReader.newInstance(..., usage)` need API 29), on the assumption that "new enough Android" was a safe proxy for "affected device". It isn't: a Samsung **Exynos** S6 also runs API 29, took the path, and **encoded a solid green frame** to the viewer — while the phone's *own on-screen preview stayed perfectly correct*, which is what makes this confusing to diagnose (it looks like a receiver/decoder bug, but the corruption is already in the encoded stream). The gate is now `SDK_INT >= Q && isQualcomm`, where `isQualcomm` checks `Build.HARDWARE` starting with `qcom` plus `Build.SOC_MANUFACTURER` (itself API 31+, so read only when available — a bare reference would crash the app's API 23 minimum). Everything else keeps the direct-Surface path, which those devices were already using with no latency problem. If setup throws, it also falls back to direct-Surface.

The general lesson: this is a **vendor driver** workaround, so it must be gated on the vendor. An OS-version gate is not a proxy for a hardware quirk — the two phones in use here (a Qualcomm Pixel 5 and an Exynos S6) happen to share an API level while needing opposite capture paths.

## Building

- **Receiver:** `./build.sh` — compiles a universal (Apple Silicon + Intel) app with `swiftc`. New Swift source files must be added to the `SWIFT_SRCS` list in `build.sh`. Runs on macOS 11+. The build is unsigned, so first launch on another Mac needs right-click ▸ Open.
- **Streamer:** a normal Android Studio / Gradle debug build (`:app:assembleDebug`) produces `epoccam-streamer.apk`. Requires the Android SDK and a JDK (Android Studio's bundled JBR works). The debug APK is debug-signed — a phone that already has a differently-signed copy must uninstall it before installing.

## Troubleshooting "a phone won't connect"

1. **Same subnet?** mDNS is link-local. If the Mac and the phone end up on different subnets (e.g. the Mac loses one of two network interfaces), they can't discover each other even though both are "online". Check that the Mac has an address on the phone's subnet.
2. **Discovered but the connect just hangs** (`log stream --predicate 'process == "EpocCamViewer"'` shows `connecting to ...` then nothing — no `ready`, no `failed` — until the app's own connect timeout fires and it backs off): a cold ARP entry, most often the first time a *new* phone appears while another is already connected and ARP-warm. The viewer now primes ARP itself before every dial (see above), so this should self-heal; if it still happens, a manual `ping -c 3 <ip>` or `nc -zv <ip> 5054` from the Mac while it's stuck will unblock it immediately, which confirms the diagnosis.
3. **Reachable but not discovered at all** (ping / `nc <ip> 5054` succeed, but nothing shows up in the browser): a stale mDNS cache. Flush it with `sudo killall -HUP mDNSResponder`, and restart the viewer to clear any wedged in-memory pool state. (Rebooting the *phone* does not fix viewer-side state.)
4. **Connects but no video:** the encoder is producing frames but no keyframes (wedged codec). Restart the streamer app; the self-heal watchdog also covers this.
5. **High latency to a "local" IP** (e.g. hundreds of ms) usually means the phone is on the wrong Wi-Fi and being routed indirectly — put both devices on the same LAN.
6. **High latency on one specific phone, others fine** (e.g. steady ~1s only on some Android phones): check the phone's own on-screen camera preview first — if *that* already lags, the delay is upstream of the network entirely (camera/encoder pipeline on the phone, see "Streamer: camera→encoder latency on Qualcomm devices" above), not a receiver or Wi-Fi issue.
7. **Green (or otherwise corrupt) image in the viewer, while the phone's own preview looks correct:** the phone is on a capture path its GPU/driver doesn't support. Check logcat for `capture path: hardware=… isQualcomm=…` — a non-Qualcomm device must **not** log `using ImageReader/ImageWriter path`. Same rule of thumb as #6: compare against the phone's own preview first, because "viewer is wrong, phone is right" means the corruption is already baked into the encoded stream and is a *streamer*-side problem, not a decoder or network one.

## Compatibility

The original iPhone EpocCam transmitter still works with this receiver: it advertises no `id`/`ip` TXT, so the viewer resolves it by hostname and keys its slot by MAC — exactly the fallback paths above.
