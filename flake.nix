{
  description = "Ptyxis, rebuilt from source with wezterm-like key handling";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      # VTE does not implement OSC 52 (clipboard), so build it with a patch
      # that adds the handler and link ptyxis against the patched VTE.
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [
            (final: prev: {
              vte-gtk4 = prev.vte-gtk4.overrideAttrs (old: {
                patches = (old.patches or [ ]) ++ [ ./nix/vte-osc52.patch ];
              });
            })
          ];
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          ptyxis = pkgs.ptyxis.overrideAttrs (old: {
            src = self;
          });
        in
        {
          inherit ptyxis;
          default = ptyxis;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.ptyxis ];
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
