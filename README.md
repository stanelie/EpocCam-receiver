# EpocCam-receiver — moved

**This repository is archived. Development continues at
[stanelie/ExMachino](https://github.com/stanelie/ExMachino).**

This code now lives there under [`viewer/`](https://github.com/stanelie/ExMachino/tree/main/viewer),
with its full history intact.

## Why

The Android sender and the macOS receiver talk over a custom wire protocol that changes with
almost every feature, so they are only meaningful as a matched pair. Keeping them in separate
repositories meant a protocol change had to land as two commits in two places, and separate
version numbers actively misled — "streamer 2.4.1" and "receiver 2.6.0" said nothing about
whether they worked together. They are now one repository sharing one version, released
together.

## Releases

The final release here is **v2.6.0**, which pairs with streamer v2.4.1. Both remain
downloadable, but new releases are published at
[ExMachino](https://github.com/stanelie/ExMachino/releases) and contain **both** apps —
install them as a pair.
