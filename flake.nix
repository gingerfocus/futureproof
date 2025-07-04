{
  inputs.nixpkgs.url = "nixpkgs-unstable"; # "nixpkgs";

  outputs = { self, nixpkgs }: let
    lib = nixpkgs.lib;
    systems = ["aarch64-linux" "x86_64-linux"];
    eachSystem = f:
      lib.foldAttrs lib.mergeAttrs {}
      (map (s: lib.mapAttrs (_: v: {${s} = v;}) (f s)) systems);
  in
    eachSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
      };
      # neon = self.packages."${system}";
    in {
      devShells.default = pkgs.mkShell {
        packages = with pkgs; [
          zon2nix

          pkg-config
          freetype
          glfw
          shaderc

          wayland
          wayland-scanner
          wayland-protocols
          libxkbcommon

          # Development
          alejandra
          zig
        ];
      };

      formatter = pkgs.alejandra;

      packages = {
        # default = neon.neomacs;
        # neomacs = pkgs.callPackage ./nix/neomacs.nix {};
        # zss = pkgs.callPackage ./nix/zss.nix {};
      };
    });
}
