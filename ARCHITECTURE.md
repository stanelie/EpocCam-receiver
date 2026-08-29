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

The streamer **re-advertises whenever its IP changes** (via `onLinkPropertiesChanged`, which — unlike `onAvailable` — fires on a same-network Wi-Fi roam), through a single **debounced re-registration** (this also replaced a per-disconnect mDNS "bounce" that was thrashing the responder).

**The streamer serves mDNS with JmDNS, not `android.net.nsd.NsdManager`.** The system daemon was measured registering this same service in **2 s, 73 s and 109 s** on one phone with identical code — and while it is unregistered, the phone is simply undiscoverable, so the app looks broken. It also cannot be safely forced, which is worth recording because both workarounds are tempting and both are wrong:

- *Retrying on a timer keyed to `onServiceRegistered`* fails, because that callback does not reliably fire even when the record demonstrably **is** on the wire (confirmed with `dns-sd -B` while the callback had never arrived). The retry then tears down a perfectly good advertisement.
- *Rapid re-registration wedges the daemon outright.* Roughly 29 register/unregister cycles left the phone advertising nothing at all until Wi-Fi was toggled to restart `mdnsd`.

JmDNS runs in-process, so registration is observable and controllable. It must be given the interface address explicitly (`JmDNS.create(InetAddress, name)`) — letting it choose can bind it to a virtual or secondary interface the viewer isn't on — and all of `create` / `registerService` / `close` block on network I/O, so they run on a dedicated single thread. It also **requires the `MulticastLock`** already held for the ARP fix above. Measured after the switch: **~0.4 s to register, across six consecutive rapid restarts** (386–414 ms), the exact pattern that produced the 73 s and 109 s cases.

## Viewer: identity, connection pool, resilience

**Slot key priority:** advertised `id` → peer **MAC** (from an EUI-64 IPv6 link-local, else the host's ARP table for IPv4 / NDP table for IPv6 — the NDP lookup recovers a stable MAC even for an iPhone's *rotating privacy* IPv6 address) → IP. The original iPhone (which advertises no `id`) still works via MAC + hostname resolution. The `deviceKey → slot` map is persisted so a phone keeps its slot across restarts.

**Connection pool (≤2), one connection per phone.** The streamer serves only one viewer socket, so the viewer must never open two connections to the same phone. mDNS is the single source of truth. (An earlier "last-known-host" fast-start probe was removed — it raced mDNS, opened a second socket to the same phone, and the dedup then dropped the wrong one, producing "connected but no video / phone says not connected".)

**Stale-IP self-heal.** The viewer prefers the advertised `ip`, but if that won't connect it falls back to the mDNS **hostname** (which the phone's mdnsd keeps current) — so a stale advertised IP after a roam recovers on its own.

**Stall watchdog.** An abrupt network drop leaves a half-open TCP that would otherwise pin a pool slot forever. Any live connection delivering no frames for ~6 s is dropped and reconnected.

**Fast constant retry, no backoff (important for live use).** Retries run every ~1 s with no exponential delay, and the connect timeout is 2 s. On a dedicated AP with a handful of known phones, a fast reconnect matters far more than being polite to an absent one. A phone that keeps failing is deprioritised purely by *ordering* — `connectMoreIfPossible` sorts fewest-failures-first — so it can never starve a reachable phone from a free slot, yet is still retried on every cycle rather than being parked for up to 20 s.

**Forced re-query while a slot is empty.** `NWBrowser` has no "query now" API: a long-running browser relies on the phone's unsolicited announcements plus its own exponentially-backed-off re-queries. That combination is how a phone powered on *after* the viewer could go unnoticed for ~30 s. While any slot is unfilled the browser is torn down and restarted every 5 s, forcing a fresh active query. This is deliberately stateless — it works on a cold start days later, with no cached "recently seen" list to rely on.

Together these dominate reconnect time. Measured, restarting the streamer with the viewer already running: **~0.5 s** from app launch to live video, versus ~59 s before (27 s of which was Android NSD re-registering, 32 s the Mac's browser not re-querying). Note the viewer now reconnects *before* mDNS registration even completes — the retry loop reaches the phone's listening socket first, so slow NSD no longer gates anything.

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

## Stabilization: OIS free, EIS needs the video-encode flag

**Optical (OIS) is always on** where the camera has it, with no toggle: it moves a lens element, so there is no crop and nothing is buffered. Previously `LENS_OPTICAL_STABILIZATION_MODE` was never set at all, leaving it to whatever `TEMPLATE_RECORD` defaulted to on each HAL.

**Electronic (EIS) is a per-camera toggle**, persisted per slot and re-applied on connect like the resolution choice. It crops, which is the only reason it isn't simply on.

Confirmed against the hardware — and note capability is *reported by the phone*, never assumed by the viewer, so the menu disables itself on a camera that can't do it:

| Device | Back camera | OIS | EIS |
| --- | --- | --- | --- |
| Galaxy S7 | main | yes | **no** |
| Pixel 5 | main | yes | yes |

### The trap: the HAL accepts EIS and silently ignores it

`CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE` reports `1` when we request `1` — whether or not stabilization is actually happening. On the Pixel it reported enabled while producing **no crop and no smoothing**. Requesting it is not evidence it is working; the visible tell is the crop.

The cause: **the HAL only applies EIS to a stream whose buffer usage includes `USAGE_VIDEO_ENCODE`.** Our `ImageReader` was created with `USAGE_GPU_SAMPLED_IMAGE` alone, so EIS had no video stream to act on.

### Why this looked like an unavoidable tradeoff, and wasn't

`USAGE_VIDEO_ENCODE` is the same flag implicated in the ~500 ms Qualcomm stall documented above, so the obvious reading was that EIS and low latency are mutually exclusive on these devices. Measured, they are not — the two are separable:

- the **latency bug** belongs to `MediaCodec.createInputSurface()` specifically;
- **EIS** keys on the *usage flag* of the camera's output stream.

So adding `USAGE_VIDEO_ENCODE` to the `ImageReader`, while still feeding the encoder through `ImageWriter` rather than its input surface, gives EIS **and** keeps latency low. Measured on a Pixel 5:

| Path | EIS works | Camera→encoder latency |
| --- | --- | --- |
| ImageReader, `GPU_SAMPLED` only | no | ~100 ms |
| Direct encoder input surface | yes | ~490 ms |
| **ImageReader + `VIDEO_ENCODE`** | **yes** | **~85 ms** |

EIS itself costs no measurable latency on any path (100.5 ms mean across off/on/off on the fast path) — the penalty was always the capture path, never the stabilization.

`CameraEncoder` logs what the HAL actually applied (`APPLIED: videoStab=… ois=…`, rate-limited), which is what separated "the HAL refused" from "the HAL accepted and did nothing".

## Viewer: NDI output (optional, alongside Syphon)

Syphon is the primary output and is always on: `publishPixelBuffer` binds the decoded frame's IOSurface directly as a GL texture — zero-copy, nothing re-encoded. NDI exists only for consumers that can't speak Syphon, and is off by default.

**It runs on a per-slot queue and is issued last**, so Syphon and the preview can never wait on it, with a semaphore bounding it to one frame in flight — a slow send drops the new frame rather than queuing a backlog, which costs less latency than working through stale frames.

**Send asynchronously.** This is load-bearing and was learned the hard way: switching to the synchronous send (on safety grounds, see below) added **~1 s of lag versus Syphon**. The SDK pipelines colour conversion, compression and network send across its own threads and explicitly recommends async for BGRA; sending synchronously serialises all of that inline. The buffer is retained until the next send, which the SDK documents as the synchronizing event.

**Recreate the senders when the frame format changes.** A receiver that has negotiated BGRA does not renegotiate on a live sender — it sits on the last frame it understood. Teardown runs on each slot's own queue and therefore completes *after* the call returns, so the recreate must wait on a `DispatchGroup` (plus a short settle) rather than run immediately; otherwise new senders are created under names the old ones still hold.

### H.264 passthrough: built, measured, and not worth it

The phone already sends H.264, so forwarding it to NDI skips the decode→SpeedHQ→decode round trip entirely. This is implemented and selectable (`Output ▸ NDI encoding`), gated behind `USE_NDI_ADVANCED=1 ./build.sh`.

**Measured result: no perceptible latency difference from SpeedHQ.** Compared in Millumin against Syphon, the phone's own native NDI sender, and this bridge — all displayed effectively together. So the round trip was never the bottleneck, and the passthrough does not justify what it costs.

What it costs is the **NDI Advanced SDK**, whose development licence silently stops delivering the stream after **30 minutes** on desktop (5 minutes on mobile): the sender keeps reporting success while receivers get nothing. That's why it is a build switch rather than only a menu item — linking the Advanced library unconditionally would put that cliff under the working SpeedHQ path too. The default build uses the base SDK and has no limit. No attempt is made to work around the gate; a commercial licence is the fix if it is ever needed.

Implementation details, confirmed against the SDK's own `NDIlib_Send_H264` example rather than inferred: Annex-B framing (already what the phone sends), a 44-byte `NDIlib_compressed_packet_t` prefix, SPS/PPS as `extra_data` on keyframes only, and a scatter-gather send so nothing is concatenated. The passthrough send stays synchronous — it does no encoding, so there is nothing to pipeline.

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
