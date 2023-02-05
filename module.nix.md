/*

# Periodic LineageOS Builds

When integrated in a NixOS configuration and enabled, this module periodically does (a more secure equivalent of) building and calling the `ci` output of this flake, and also serves the latest result of doing so.

`domain` has to point to this host (and should match that defined in [`./flake.nix`](./flake.nix)). Using a host name that only resolves in ones home network may also work well enough, and could potentially also avoid issues with publicly publishing the builds.

`baseDir` has to exist with the following sub dirs:
* `keys/` contains the (private and public) signature keys for each configured build, and should be backed up but kept confidential. For remote builds, this also has to contain the `lineage-builder.api-token`.
* `config/` contains a copy of this repo. Before building, the `ci` service updates the (public) `keys`, (linage/android) `repo`, and `apk` (urls) directories (think of them as lock files) in this copy of the repo, which then contains all the information necessary to (re-)create (but not sign) the LinageOS build(s). It can be synced to and from there using the [`./sync.sh`](./sync.sh) script, or it can be managed directly by GIT. The repo, including the updated `keys`/`repo`/`apks` dirs, should be backed up for provenance, but _can_ be published.
* `build/` contains the latest result of each configured build, from where it is served with `nginx` for OTA device updates. This should probably be kept across reboots, but does not need to be backed up.

With the module enabled (to define the users), this should establish/restore the correct file permissions (`cd $baseDir`, then):
* `chown -R  lineage-keys:lineage-keys $( shopt -s extglob ; eval 'echo ./keys/!(*.*)' )`
* `chown -R lineage-build:lineage-build ./{config/,build/,keys/lineage-builder.api-token}`
* `chown     lineage-keys:lineage-build ./keys`
* `chmod -R +770                        ./config/`
* `chmod    0775                        ./build{,/*}`


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: args@{ config, pkgs, lib, utils, ... }: let inherit (inputs.self) lib; in let
    cfg = config.services.lineage-build;
in {

    options = { services.lineage-build = {
        enable = lib.mkEnableOption (lib.mdDoc ''automatic periodic updating and rebuilding of LineageOS and serving of the result'');
        domain = lib.mkOption { type = lib.types.nullOr lib.types.str; default = "lineage.${config.networking.domain}"; };
        baseDir = lib.mkOption { type = lib.types.path; default = "/app/lineage-build"; };
        buildRemote = lib.mkOption { description = ''Whether to perform the computation-intensive parts of the build of a VPS worker instead of locally. This requires a `HCLOUD_TOKEN` in `''${baseDir}/keys/lineage-builder.api-token`.''; type = lib.types.bool; default = true; };
        createUsers = lib.mkEnableOption ''automatic creation of the `lineage-build` and `lineage-keys` users'' // {default = true; example = false; };
    }; };

    config = let

        mkService = verb: next: service: service // {
            restartIfChanged = false; # don't abort this during (automatic or manual) system upgrade, but keep it running
            script = ''
                set -x
                HOME=$( ${pkgs.coreutils}/bin/mktemp -d ) || exit ; trap "rm -rf '$HOME'" EXIT
                ${pkgs.nix}/bin/nix --extra-experimental-features 'nix-command flakes' run ${lib.escapeShellArg cfg.baseDir}/config#${verb} -- ${lib.escapeShellArg cfg.baseDir}
            '';
            serviceConfig = {
                Type = "oneshot";
                PrivateUsers = true;
                ProtectSystem = "strict";
                MemoryDenyWriteExecute = true;
                PrivateDevices = true;
                ProtectKernelTunables = true;
                ProtectControlGroups = true;
                ProtectHome = true;
                SystemCallFilter = "@system-service";
                SystemCallErrorNumber = "EPERM";
                NoNewPrivileges = true; RestrictSUIDSGID = true;
            } // service.serviceConfig // {
                ReadWritePaths = (service.serviceConfig.ReadWritePaths or [ ]) ++ [ "/tmp" ];
                ExecStartPost = (service.serviceConfig.ExecStartPost or [ ]) ++ lib.optional (next != null) ''+-/run/current-system/sw/bin/systemctl start --no-block ${next}.service'';
            };
        };

    in lib.mkIf cfg.enable ({

        services.nginx.virtualHosts = lib.mkIf (cfg.domain != null) { ${cfg.domain} = {
            locations."/android/".alias = "${cfg.baseDir}/build/";
        }; };

        systemd.services = {
            lineage-update = mkService "update-deps" "lineage-keys" {
                startAt = "Tue *-*-* 02:05:00";
                serviceConfig.User = lib.mkDefault "lineage-build";
                serviceConfig.ReadWritePaths = [
                    "${utils.escapeSystemdExecArg cfg.baseDir}/config/apks"
                    "${utils.escapeSystemdExecArg cfg.baseDir}/config/repo"
                ];
            };
            lineage-keys = mkService "ensure-keys" "lineage-build" {
                serviceConfig.User = lib.mkDefault "lineage-keys";
                serviceConfig.ReadWritePaths = [
                    "${utils.escapeSystemdExecArg cfg.baseDir}/config/keys"
                    "${utils.escapeSystemdExecArg cfg.baseDir}/keys"
                ];
                serviceConfig.ExecStartPost = [
                    ''+${pkgs.coreutils}/bin/chown -R lineage-build:lineage-build ${utils.escapeSystemdExecArg cfg.baseDir}/config/keys/''
                    ''+${pkgs.coreutils}/bin/chmod -R g+r,g-w,o-rwx               ${utils.escapeSystemdExecArg cfg.baseDir}/config/keys/''
                ];
            };
            lineage-build = mkService (if cfg.buildRemote then "build-remote" else "build-local") "lineage-sign" {
                serviceConfig.User = lib.mkDefault (if cfg.buildRemote then "root" else "lineage-build");
                serviceConfig.ReadWritePaths = [
                    "${utils.escapeSystemdExecArg cfg.baseDir}/build"
                ];
                serviceConfig.PrivateDevices = !cfg.buildRemote; # need /dev/kvm
                serviceConfig.PrivateUsers = !cfg.buildRemote; # doesn't work for root
                #serviceConfig.SupplementaryGroups = [ "nix-trusted" ]; # TODO: try this instead of root
            };
            lineage-sign = mkService "sign-build" null {
                serviceConfig.User = lib.mkDefault "lineage-keys";
                serviceConfig.ReadWritePaths = [
                    "${utils.escapeSystemdExecArg cfg.baseDir}/build"
                ];
                serviceConfig.MemoryDenyWriteExecute = false; # java -.-
            };
        };

        users.users = lib.mkIf cfg.createUsers {
            lineage-build = { isSystemUser = true; group = "lineage-build"; }; # owns the sources
            lineage-keys = { isSystemUser = true; group = "lineage-keys"; extraGroups = [ "lineage-build" ]; }; # owns the keys
        };
        users.groups = lib.mkIf cfg.createUsers {
            lineage-build = { };
            lineage-keys = { };
            #nix-trusted = { };
        };
        #nix.settings.trusted-users = [ "@nix-trusted" ]

    });
}
