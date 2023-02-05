{ description = (
    "Building LinageOS using robotnix, about as self-contained in a flake as possible. With periodic remote builds."
); inputs = {

    nixpkgs = { url = "github:NixOS/nixpkgs/nixos-22.11"; };
    wiplib = { url = "github:NiklasGollenstede/nix-wiplib"; inputs.nixpkgs.follows = "nixpkgs"; };
    #robotnix = { url = "github:danielfullmer/robotnix"; inputs.nixpkgs.follows = "nixpkgs"; };
    robotnix = { url = "github:danielfullmer/robotnix"; inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-22.05"; inputs.nixpkgsUnstable.url = "github:NixOS/nixpkgs/nixos-21.11"; };

}; outputs = inputs@{ wiplib, ... }: let patches = rec {

    robotnix = [
        ./robotnix.patch
    ];

}; in inputs.wiplib.lib.wip.patchFlakeInputsAndImportRepo inputs patches ./. (inputs@{ self, nixpkgs, ... }: repo@{ lib, ... }: let

    domain = "lineage.niklasg.de"; # see ./module.nix.md

    robotnixConfigurations = lib.wip.mapMergeUnique ({ device, }: { "${device}" = let
        mkSystem = override: inputs.robotnix.lib.robotnixSystem { imports = [
            override (
                (lib.wip.importWrapped inputs "${self}/base-config.nix").module
            ) ({ config, ... }: {
                inherit device; androidVersion = 12;
                apps.updater.url = "https://${domain}/android/${config.device}/";
            })
        ]; _file = "${self}/flake.nix#robotnixConfigurations"; };
    in (mkSystem { }) // { timeless = mkSystem {
        buildDateTime = lib.mkForce 0;
    }; }; }) [
        { device = "instantnoodle"; }
    ];

in [
    repo { inherit robotnixConfigurations; }
    { nixosModules.default = (lib.wip.importWrapped inputs "${self}/module.nix.md").module; }

    (lib.wip.forEachSystem [ "aarch64-linux" "x86_64-linux" ] (localSystem: let
        pkgs = lib.wip.importPkgs inputs { system = localSystem; };
        nix = "PATH=${pkgs.openssh}/bin:$PATH ${pkgs.nix}/bin/nix --extra-experimental-features 'nix-command flakes'";
    in {
        packages = {

            update-repo  = lib.lin.update-repo  pkgs robotnixConfigurations;
            update-apks  = lib.lin.update-apks  pkgs robotnixConfigurations;
            ensure-keys  = lib.lin.ensure-keys  pkgs robotnixConfigurations;
            build-remote = lib.lin.build-remote pkgs robotnixConfigurations;
            build-local  = lib.lin.build-local  pkgs robotnixConfigurations;
            sign-build   = lib.lin.sign-build   pkgs robotnixConfigurations;

            # This should be called periodically (by enabling ./modules.nix.md (or a cron job)):
            ci = pkgs.writeShellScriptBin "ci" ''
                set -x
                : ''${1:?must be set to the »baseDir«, as explained in »${self}/module.nix.md«}
                ${nix} run "$1"/config#update-repo  -- "$1" || exit
                ${nix} run "$1"/config#update-apks  -- "$1" || exit
                ${nix} run "$1"/config#ensure-keys  -- "$1" || exit
                ${nix} run "$1"/config#build-remote -- "$1" || exit
            '';
            update-deps = pkgs.writeShellScriptBin "lineage-update-deps" ''
                set -x
                ${lib.lin.update-repo pkgs robotnixConfigurations}/bin/lineage-update-repo "$1" || exit
                ${lib.lin.update-apks pkgs robotnixConfigurations}/bin/lineage-update-apks "$1" || exit
            '';

            inherit (pkgs) push-flake;

            builder-shell = let
                name = "lineage-builder-dev";
            in pkgs.writeShellScriptBin "shell-${name}-wrapper" ''{
                tokenFile=$( realpath ../keys/${name}.api-token )
            } ; source ${(lib.wip.vps-worker rec {
                inherit name pkgs inputs; serverType = "cx41";
                tokenCmd = ''cat "$tokenFile"/keys/${name}.api-token'';
            }).shell}'';
        };

        # For [the device setup](./setup.md):
        devShells = lib.mapAttrs (device: system: pkgs.mkShell {
            name = device;
            nativeBuildInputs = [
                pkgs.android-tools # »adb« »fastboot«
                pkgs.unzip # (duh)
            ];
            shellHook = ''
                buildDateTime=${builtins.readFile "${self}/repo/buildDateTime"}
                buildNumber=$( date -u -d @$buildDateTime +%Y%m%d%H )
                device=${system.config.device}
                PS1=''${PS1/\\$/\\[\\e[93m\\](${device})\\[\\e[97m\\]\\$}
                cd ../build/${device} || true
            '';
        }) robotnixConfigurations;
    }))
]); }
