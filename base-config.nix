
## Non-device-specific »robotnixConfiguration«-module base configuration:

dirname: inputs: { config, pkgs, lib, ... }: let inherit (inputs.self) lib; in let
    mapArch = arch: { x86_64 = "x64"; }.${arch} or arch;
in {
    flavor = "lineageos";
    variant = "user"; # I.e. not a debug build. With this, it could bake sense to lock the bootloader.

    source.lineage.repoDir = lib.mkIf (builtins.pathExists "${dirname}/repo") "${dirname}/repo";
    buildDateTime = lib.mkIf (builtins.pathExists "${dirname}/repo") (lib.toInt (builtins.readFile "${dirname}/repo/buildDateTime"));

    microg.enable = true;
    apps.seedvault.enable = true; # (I think this is ignored b/c lineageos already includes seedvault)
    apps.fdroid.enable = true;

    signing.enable = true;
    signing.avb = { enable = true; mode = "vbmeta_chained_v2"; }; # (this neither prevents building nor installing, but what would happen when re-locking the bootloader?)
    signing.keyStorePath = "${dirname}/keys/${config.device}";

    apps.updater.enable = true;

    # Switch from Chrome to Bromite (but only build the webview from source; get the browser as prebuilt apk or manually later):
    apps.bromite.enable  = false; webview.bromite.enable  = true;  webview.bromite.availableByDefault  = true;  webview.bromite.isFallback  = true;
    apps.chromium.enable = false; webview.chromium.enable = false; webview.chromium.availableByDefault = false; webview.chromium.isFallback = false;

    # Use prebuilt browser APKs (cuz building the browser takes longer than building the rest of the system):
    apps.prebuilt.bromite.apk = lib.mkForce (pkgs.fetchurl (lib.importJSON "${dirname}/apks/bromite/${mapArch config.arch}_ChromePublic.apk.json")); apps.prebuilt.bromite.enable = true;
    #webview.bromite.apk       = lib.mkForce (pkgs.fetchurl (lib.importJSON "${dirname}/apks/bromite/${mapArch config.arch}_SystemWebView.apk.json")); # this does not properly enable/register the webview in the system
    #build.bromite = null; apps.prebuilt.bromiteTrichromeLibrary.apk = null; # (make sure not to build from source)

    # Update Bromite (the base version that the source-built browser and the webview inherit from):
    _module.args.apks = lib.mkForce (let
        apks = import "${inputs.robotnix}/apks" { pkgs = pkgs; };
    in apks // { bromite = (apks.bromite.override {
        version = builtins.readFile "${dirname}/apks/bromite/version";
        depsPath = "${dirname}/apks/bromite/vendor.nix";
    }).overrideAttrs (old: {
        bromite_src = pkgs.runCommand "bromite_src" { } ''mkdir -p $out ; tar -C $out --strip-components=1 -xzf ${pkgs.fetchurl (lib.importJSON "${dirname}/apks/bromite/tar.gz.json")}'';
    }); });

    # Enable system-wide domain-based ad blocking:
    hosts = pkgs.fetchurl { # 2022-10-27
        url = "https://raw.githubusercontent.com/StevenBlack/hosts/3.11.26/hosts";
        sha256 = "sha256-0P13OWbv1BWoE4PMzmblr2mr9mvccnbTIWsN6yz8elw=";
    };

    # For Play-Store apps, f-droid requires a special mirror-repo (which needs to be self-hosted).
    # With this (not sure it's required inAndroid 12+) Aurora Store works perfectly well (but it does not periodically/automatically search for or trigger updates; set an alarm to remember doing it manually!).
    apps.prebuilt.AuroraServices = {
        packageName = "com.aurora.services";
        apk = pkgs.fetchurl {
            url = "https://gitlab.com/AuroraOSS/AuroraServices/uploads/c22e95975571e9db143567690777a56e/AuroraServices_v1.1.1.apk";
            sha256 = "sha256-8D83aPGVWQfsMTrkl8/ZK09vWO4cAbazi9C2oqmlBZM=";
        };
        privileged = true; privappPermissions = [ "INSTALL_PACKAGES" "DELETE_PACKAGES" ];
    };

    # (lineage 20 claims to have a decent camera app)
    /* apps.prebuilt.GCam = {
        apk = pkgs.fetchurl {
            url = "https://1-dontsharethislink.celsoazevedo.com/file/filesc/GCam8.2.204_Greatness.220901.2136Release_Snap.apk";
            curlOpts = "--referer https://www.celsoazevedo.com/files/android/google-camera/dev-greatness/f/dl14/";
            sha256 = "cb70109c7c1607eb7a495bed576d1dac86dc5c738a85611bbaff81ab267ece39";
        };
        usesOptionalLibraries = [ "com.google.android.gestureservice" "com.google.android.camera2" "com.google.android.camera.experimental2015" "com.google.android.camera.experimental2016" "com.google.android.camera.experimental2017" "com.google.android.camera.experimental2018" "com.google.android.camera.experimental2019" "com.google.android.camera.experimental2020" "com.google.android.camera.experimental2020_midyear" "com.google.android.camera.experimental2021" "com.google.android.wearable" ];
    }; */
    # When preinstalled, the app won't start, so install it manually.
    # (The config .xml?)
    apps.prebuilt.GCamPhotosPreview = {
        apk = pkgs.fetchurl {
            url = "https://release.calyxinstitute.org/GCamPhotosPreview-1.apk";
            sha256 = "sha256-MtOwJK+x1lQbf/hk76PENyQ8a6GKuJ3kHXEtwUnIlCM=";
        };
    };

}
