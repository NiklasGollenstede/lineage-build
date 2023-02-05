dirname: inputs@{ self, nixpkgs, ...}: let lib = nixpkgs.lib // { inherit (inputs.wiplib.lib) wip; }; lin = rec {

    ## Updates the relevant repository manifests in »baseDir«/config/repo for all "lineageos" »systems« defined.
    update-repo = pkgs: systems: let
        lineage-systems = (lib.filter (_:_.config.flavor == "lineageos") (builtins.attrValues systems));
    in pkgs.writeShellScriptBin "lineage-update-repo" ''
        export PATH=${lib.makeBinPath (inputs.robotnix.devShell.x86_64-linux.nativeBuildInputs ++ [ pkgs.coreutils ])}
        export PYTHONPATH=${inputs.robotnix.devShell.x86_64-linux.PYTHONPATH}
        set -o pipefail -u ; set -x
        baseDir=$1

        oldDir="$baseDir"/config/repo ; newDir=$( ${pkgs.coreutils}/bin/mktemp -d ) || exit ; trap "rm -rf '$newDir'" EXIT

        TARGET_DIR=$newDir ${inputs.robotnix}/flavors/lineageos/update_device_metadata.py || exit

        declare -A updatedBranches=( ) ; declare -a vendor_devices=( )
        for device in ${lib.concatMapStringsSep " " (system: system.config.device) lineage-systems} ; do
            branch=$( ${pkgs.jq}/bin/jq -r .[\""$device"\"].branch $newDir/device-metadata.json ) || exit ; [[ $branch != null ]] || exit
            branch=lineage-19.1 # not ready yet for lineage 20
            vendor=$( ${pkgs.jq}/bin/jq -r .[\""$device"\"].vendor $newDir/device-metadata.json ) || exit ; [[ $vendor != null ]] || exit
            vendor_devices+=( "$vendor"_"$device" )
            if [[ ''${updatedBranches[$branch]:-} ]] ; then continue ; fi
            mkdir -p $newDir/"$branch" || exit
            ${inputs.robotnix}/scripts/mk_repo_file.py --cache-search-path $oldDir --out $newDir/"$branch"/repo.json --ref-type branch "https://github.com/LineageOS/android" $branch || exit
            updatedBranches[$branch]=1 || exit
        done

        TARGET_DIR=$newDir ${inputs.robotnix}/flavors/lineageos/update_device_dirs.py --branch "$branch" "''${vendor_devices[@]}" || exit

        date "+%s" >$newDir/buildDateTime
        ${pkgs.rsync}/bin/rsync --archive --chmod=D770,F660 $newDir/ $oldDir/
    '';

    ## Updates the download URLs and hashes of additional external resources in »baseDir«/config/apks.
    update-apks = pkgs: systems: let
        mapArch = arch: { x86_64 = "x64"; }.${arch} or arch;
    in pkgs.writeShellScriptBin "lineage-update-apks" ''
        set -o pipefail -u ; set -x
        baseDir=$1

        version=$( ${pkgs.curl}/bin/curl -sSL https://api.github.com/repos/bromite/bromite/releases/latest | ${pkgs.jq}/bin/jq -r .tag_name ) && [[ $version ]] || exit
        if [[ $( cat "$baseDir"/config/apks/bromite/version &>/dev/null ) == "$version" ]] ; then exit 0 ; fi

        oldDir="$baseDir"/config/apks/bromite ; newDir=$( ${pkgs.coreutils}/bin/mktemp -d ) || exit ; trap "rm -rf '$newDir'" EXIT

        printf %s "$version" >$newDir/version || exit
        hashes=$( ${pkgs.curl}/bin/curl -sSL https://github.com/bromite/bromite/releases/download/"$version"/brm_"$version".sha256.txt ) || exit
        for arch in ${lib.concatStringsSep " " (lib.unique (lib.mapAttrsToList (_: system: mapArch system.config.arch) systems))} ; do
            for apk in "$arch"_ChromePublic "$arch"_SystemWebView ; do
                hash=$( <<<"$hashes" ${pkgs.gnugrep}/bin/grep -oPe '^[0-9a-f]{64}(?=  '"$apk"'[.]apk$)' ) || exit
                echo '{"url":"https://github.com/bromite/bromite/releases/download/'"$version"'/'"$apk"'.apk","sha256":"'"$hash"'"}' >$newDir/"$apk".apk.json || exit
            done
        done
        tarUrl=https://github.com/bromite/bromite/archive/refs/tags/"$version".tar.gz
        tarHash=$( ${pkgs.curl}/bin/curl -sSL "$tarUrl" | ${pkgs.coreutils}/bin/sha256sum - -b | ${pkgs.coreutils}/bin/cut -d' ' -f1 ) || exit
        echo '{"url":"'"$tarUrl"'","sha256":"'"$tarHash"'"}' >$newDir/tar.gz.json || exit

        tmp=$( ${pkgs.coreutils}/bin/mktemp -d ) || exit ; trap "rm -rf '$tmp'" EXIT
        ( cd $tmp ; PATH=$PATH:$tmp/"$version"/depot_tools:${lib.makeBinPath [ pkgs.coreutils pkgs.bash pkgs.python3 pkgs.findutils pkgs.git pkgs.curl pkgs.nix-prefetch-git pkgs.nix ]} CACHE_DIR=$tmp ${inputs.robotnix}/apks/chromium/mk-vendor-file.py --target-os=android "$version" ) || exit
        mv $tmp/vendor-"$version".nix $newDir/vendor.nix

        ${pkgs.rsync}/bin/rsync --archive --chmod=D770,F660 $newDir/ $oldDir/
    '';
    # TODO: also update: f-droid, ...

    ## Ensures that the required signing keys for all »systems« exist in »baseDir«/keys and copies (only) the private keys to »baseDir«/config/keys (so that the build process has access to the key signatures).
    ensure-keys = pkgs: systems: let
    in pkgs.writeShellScriptBin "lineage-ensure-keys" ''
        set -o pipefail -u ; set -x
        baseDir=$1
        ${lib.concatStrings (lib.mapAttrsToList (device: system: ''
            mkdir -p "$baseDir"/keys/${device} || exit
            </dev/null ${system.config.build.generateKeysScript} "$baseDir"/keys/${device} || exit
            ${pkgs.rsync}/bin/rsync -v --archive --no-perms --no-owner --no-group --include-from=<( cd "$baseDir"/keys/${device}/ ; find . -perm -g=r -printf '%P\n' ) --exclude='*' "$baseDir"/keys/${device}/ "$baseDir"/config/keys/${device}/
        '') systems)}
    '';

    ## After preparation by the functions/scripts above, this performs the actual LinageOS builds -- or, in the case of »build-remote«, rather has them performed on a temporary VPS -- before they can be signed locally.
    #  Remote building requires a »HCLOUD_TOKEN«, either as environment variable, or stored in »"$baseDir"/keys/lineage-builder.api-token«.
    #  Note: With 8GiB of RAM (on the builder), the build fails with a `java.lang.OutOfMemoryError`. 8GiB with swap would probs work in principle, but Java apparently thinks it's smart to limit each process'es memory to some fraction of physical RAM.
    inherit (let build = remote: pkgs: systems: let
        builder = lib.wip.vps-worker rec {
            name = "lineage-builder";
            inherit pkgs inputs;
            serverType = "cpx41"; # "cpx51"; # "cx41" is the smallest on which this builds (8GB RAM is not enough)
            tokenCmd = ''cat "$baseDir"/keys/${name}.api-token'';
            #suppressCreateEmail = false;
            nixosConfig = { };
            #debug = true; ignoreKill = false;
        };
        nix = "PATH=${pkgs.openssh}/bin:$PATH ${pkgs.nix}/bin/nix --extra-experimental-features 'nix-command flakes'";
        ifRemote = lib.optionalString remote;
    in pkgs.writeShellScriptBin "lineage-build-remote" ''
        ${lib.wip.extractBashFunction (builtins.readFile lib.wip.setup-scripts.utils) "prepend_trap"}
        set -o pipefail -u ; set -x
        baseDir=$1

        ${ifRemote ''
            # Use the remote builder for the heavy lifting:
            baseDir=$baseDir forceVmBuild=1 ${builder.createScript} || exit ; prepend_trap "baseDir=$baseDir ${builder.killScript}" EXIT
            ${builder.remoteStore.testCmd} || exit
            ${pkgs.push-flake}/bin/push-flake ${builder.remoteStore.urlArg} ${self} || exit
        ''}

        buildDateTime=${builtins.readFile "${self}/repo/buildDateTime"}
        buildNumber=$( date -u -d @$buildDateTime +%Y%m%d%H )
        for device in ${lib.concatStringsSep " " (lib.attrNames systems)} ; do
            prevBuildNumber=$( [[ -e "$baseDir"/build/$device ]] && ( ${pkgs.coreutils}/bin/ls -1 "$baseDir"/build/$device | LC_ALL=C ${pkgs.coreutils}/bin/sort -r | ${pkgs.gnugrep}/bin/grep -Pom1 "^[\w-]+-target_files-\K\d+(?=[.]zip)" ) || true )
            if [[ $prevBuildNumber == "$buildNumber" ]] ; then echo "Build $buildNumber for buildDateTime=$buildDateTime already exists. Skipping" ; continue ; fi
            # TODO: instead, keep and compare $( ${nix} build ${self}#robotnixConfigurations.$device.timeless.releaseScript --no-link --json --dry-run 2>/dev/null )

            rm -rf "$baseDir"/build/$device.staging || exit ; mkdir -p -m 775 "$baseDir"/build/$device.staging || exit ; chown lineage-build:lineage-build "$baseDir"/build/$device.staging || true

            ${if !remote then ''
                ulimit -Sn "$( ulimit -Hn )"
                ${nix} build --out-link "$baseDir"/build/$device.staging/releaseScript ${self}#robotnixConfigurations.$device.releaseScript || exit
            '' else if true then ''
                # (push-build-pull): The disadvantage of this is that it won't even reuse unchanged runtime dependencies, since they are not pushed to the builder. On  the plus side, only the original sources and the actual build output will ever touch the issuer.
                result=$( ${builder.sshCmd} -- 'nix build --no-link --print-out-paths ${self}#robotnixConfigurations.'$device'.releaseScript' ) || exit
                ${nix} build ${inputs.nixpkgs}#hello --out-link "$baseDir"/build/$device.staging/releaseScript || exit ; ln -sfT $result "$baseDir"/build/$device.staging/releaseScript || exit # hack to (at least locally) prevent the copied result to be GCed
                ${nix} copy --no-check-sigs --from ${builder.remoteStore.urlArg} $result || exit
            '' else ''
                # (nix-remote): This should reuse runtime dependencies (which are copied to and from the issuer), but build dependencies are still lost with the worker (I think). Oddly enough, it also downloads some things from the caches to the issuer.
                ulimit -Sn "$( ulimit -Hn )" # "these 3090 derivations will be built", and Nix locally creates a lockfile for each of then (?)
                ${nix} build --out-link "$baseDir"/build/$device.staging/releaseScript ${lib.concatStringsSep " " builder.remoteStore.builderArgs} ${self}#robotnixConfigurations.$device.releaseScript || exit
            ''}
        done
    ''; in {
        build-remote = build true;
        build-local = build false;
    }) build-remote build-local;

    sign-build = pkgs: systems: let
    in pkgs.writeShellScriptBin "lineage-sign-build" ''
        set -o pipefail -u ; set -x
        baseDir=$1

        for dir in $( cd "$baseDir"/build ; echo *.staging ) ; do
            device=''${dir%.staging}
            ( cd "$baseDir"/build/$device.staging ; PATH=${pkgs.gawk}/bin:$PATH "$baseDir"/build/$device.staging/releaseScript "$baseDir"/keys/$device ) || exit # passing "$prevBuildNumber" as 2nd arg would build an incremental update, but lineage's updater does not use those
            ( shopt -s extglob ; eval 'chmod 644 "$baseDir"/build/$device.staging/!(releaseScript)' ) || exit
            rm -rf "$baseDir"/build/$device || exit ; mv "$baseDir"/build/$device.staging "$baseDir"/build/$device || exit
        done
    '';

}; in lib // { inherit lin; }
