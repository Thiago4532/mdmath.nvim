{
  description = "mdmath.nvim - LaTeX math equation renderer for Neovim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        nodeDeps = pkgs.buildNpmPackage {
          pname = "mdmath-js";
          version = "1.0.0";
          src = ./mdmath-js;
          npmDepsHash = "sha256-yUyLKZQGIibS/9nHWnh0yvtZqza3qEpN9UNqRaNK53Y=";
          dontNpmBuild = true;
          installPhase = ''
            mkdir -p "$out"
            cp -r . "$out/"
            chmod +x "$out/src/processor.js"
          '';
        };

        plugin = pkgs.vimUtils.buildVimPlugin {
          pname = "mdmath.nvim";
          version = "1.0.0";
          src = pkgs.lib.cleanSource ./.;

          doCheck = false; # Disable require checks

          postPatch = ''
            # Replace mdmath-js with pre-built version
            rm -rf mdmath-js
            cp -r ${nodeDeps} mdmath-js
            chmod -R u+w mdmath-js

            # Create a wrapper for processor.js with proper PATH
            mv mdmath-js/src/processor.js mdmath-js/src/processor-unwrapped.js
            cat > mdmath-js/src/processor.js << EOF
            #!/usr/bin/env node
            process.env.PATH = "${
              pkgs.lib.makeBinPath [
                pkgs.librsvg
                pkgs.imagemagick
                pkgs.nodejs
              ]
            }" + ":" + (process.env.PATH || "");
            import('./processor-unwrapped.js');
            EOF
            chmod +x mdmath-js/src/processor.js
          '';

          # Runtime dependencies available to the plugin
          propagatedBuildInputs = with pkgs; [
            nodejs
            imagemagick
            librsvg
          ];
        };

        # Test Neovim with plugin pre-configured
        testNvim = pkgs.neovim.override {
          configure = {
            customRC = ''
              lua << EOF
              require('mdmath').setup()
            '';
            packages.mdmath = {
              start = [
                plugin
                (pkgs.vimPlugins.nvim-treesitter.withPlugins (p: [
                  p.markdown
                  p.markdown_inline
                ]))
              ];
            };
          };
        };
      in
      {
        packages.default = plugin;
        packages.mdmath-nvim = plugin;
        packages.test-nvim = testNvim;
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            nodejs
            npm
            imagemagick
            librsvg
          ];
        };
      }
    );
}
