
# LineageOS Build & Setup

These are my Nix instructions to build LineageOS from sources (using [`robotnix`](https://github.com/danielfullmer/robotnix)), including periodic remote builds, plus [a guide](./setup.md) to install the resulting LineageOS on the target device and set up and restore backups.

[`robotnix`](https://github.com/danielfullmer/robotnix) is a (large) set of Nix instructions for building Android (AOSP, GrapheneOS, LineageOS, ...) from source.
This repository [updates `robotnix`](./robotnix.patch) (which largely should be upstreamed), decouples updating of the [Android sources](./repo/) and [APK sources](./apks/) from updating `robotnix`'s base build instructions, and adds / further automates [scripts](./lib.nix) to update those source URLs and then build Android in hardened [systemd services](./module.nix.md).
The heavy lifting, compiling Android including its WebView, which takes several dozen CPU-core hours on ~2020 CPUs, is (optionally) [offloaded to a VPS worker](https://github.com/NiklasGollenstede/nix-wiplib/tree/master/lib/vps-worker.nix.md), which is temporarily spawned in a Hetzner data center (requires an account and API key there).
With that, each build costs 50ct to 1.50€ (depending on whether the browser and/or webview are (re)built), but can otherwise happen on a very low end (x64, e.g. some old Atom) server.


## Build Time + Cost Examples

* doing a full build (push-build-pull) incl. browser & webview on a `cx41`, takes about 100 minutes to ramp up the CPU to 100% (fetching sources and building tools), then builds for 36 hours on 4 Intel (some Xeon Skylake) vCPUs, then downloads about 5 - 10 minutes, costing 1.08€ (w/o VAT)
* doing a full build (push-build-pull) incl. webview (w/o browser) on a `cpx41`, fetches for about 75 minutes, then builds for 9.5 hours on 8 AMD (some EPYC) vCPUs (thereof 6h bromite & 3h lineageos), costing 0.54€ (w/o VAT)
* ...
* resource consumption of the local services, on an Intel Celeron (2016, 6W) with striped ZFS raidz (~RAID5) with SDD cache:
    ```
    lineage-update: 1h  6min  5.412s CPU time, received 11.1G IP, sent  176.5M IP
    lineage-keys:       1min 16.089s CPU time, received 58.5M IP, sent 1003.2K IP
    lineage-build:     20min 35.379s CPU time, received  3.5G IP, sent  954.9M IP
    lineage-sign:   2h 12min 51.722s CPU time, received 58.5M IP, sent  980.4K IP
    ```


## TODO

* [ ] Caching of the browser/webview (push-build-pull): explicitly pull, store and then push the `config.build.${browser}`?
* [ ] Run the periodic build at the same schedule as the official lineage builds? There seems to be some monthly upstream security patch date.
* [ ] Upstream patches to robotnix.
* verified boot / locked bootloader
    * https://forum.xda-developers.com/t/guide-re-locking-the-bootloader-on-the-oneplus-8t-with-a-self-signed-build-of-los-18-1.4259409/
        * OnePlus 8 uses "AVBv2"
    * `robotnix/modules/signing.nix`: `signing.avb = { enable = true; mode = "vbmeta_chained_v2"; }`?
        * The build needs to produce a `vbmeta` partition, plus optionally `vbmeta_system` and/or `vbmeta_vendor` (check that!).
        * Need to `fastboot flash avb_custom_key pkmd.bin` (and a `avb_pkmd.bin` is generated with the key).
    * What about signing/verification of the firmware partitions that aren't being flashed?
        * The `avb_custom_key` is in addition to the vendor key, but either key is only used to verify `vbmeta.img`, which then needs to verify *all* other partitions. If it does not include a partition, then that partition won't be verified?
        * `vbmeta` *can* delegate to external signing keys for individual partitions or for a set of them via an additional `vbmeta_*` partition.
            * Does the generated `vbmeta` do that?
    * After OEM locking, unlocking (in case it refuses to boot) is possible as long as "OEM unlocking" isn't disabled in Android's settings.
    * `BOARD_AVB_ROLLBACK_INDEX`
