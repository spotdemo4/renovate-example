{
  description = "Renovate with Nix support";

  inputs = {
    systems.url = "systems";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    utils = {
      url = "github:numtide/flake-utils";
      inputs.systems.follows = "systems";
    };
    nur = {
      url = "github:nix-community/NUR";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nur-pinned = {
      url = "github:nix-community/NUR/1c365e600afe6787c0861e4fd8609d598c5e416c";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    nixpkgs,
    utils,
    nur,
    ...
  }:
    utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [nur.overlays.default];
      };

      patched-renovate = pkgs.stdenv.mkDerivation (finalAttrs: {
        pname = "renovate";
        version = "41.45.0";

        src = pkgs.fetchFromGitHub {
          owner = "renovatebot";
          repo = "renovate";
          tag = finalAttrs.version;
          hash = "sha256-0kwgK89ZqOXP/tzrbPQGG+EbJgUY3YGsGrMGSoP2i34=";
        };

        patches = [
          (pkgs.fetchpatch {
            url = "https://github.com/renovatebot/renovate/compare/main...spotdemo4:renovate:nix.diff";
            hash = "sha256-k5TGfap8+s426he3H98CvPl9hdLi/19KfWAeaBMgn3U=";
          })
        ];

        postPatch = ''
          substituteInPlace package.json \
            --replace-fail "0.0.0-semantic-release" "${finalAttrs.version}"
        '';

        nativeBuildInputs = with pkgs;
          [
            makeWrapper
            nodejs
            pnpm_10.configHook
            python3
            yq-go
          ]
          ++ lib.optional stdenv.hostPlatform.isDarwin xcbuild;

        pnpmDeps = pkgs.pnpm_10.fetchDeps {
          inherit (finalAttrs) pname version src;
          fetcherVersion = 2;
          hash = "sha256-zbirZPJe4ldNYk0T1wllUSTSPL935rLAM8dxlDPTzBc=";
        };

        env.COREPACK_ENABLE_STRICT = 0;

        buildPhase =
          ''
            runHook preBuild

            # relax nodejs version
            yq '.engines.node = "${pkgs.nodejs.version}"' -i package.json

            pnpm build
            pnpm install --offline --prod --ignore-scripts
          ''
          # The optional dependency re2 is not built by pnpm and needs to be built manually.
          # If re2 is not built, you will get an annoying warning when you run renovate.
          + ''
            pushd node_modules/.pnpm/re2*/node_modules/re2

            mkdir -p $HOME/.node-gyp/${pkgs.nodejs.version}
            echo 9 > $HOME/.node-gyp/${pkgs.nodejs.version}/installVersion
            ln -sfv ${pkgs.nodejs}/include $HOME/.node-gyp/${pkgs.nodejs.version}
            export npm_config_nodedir=${pkgs.nodejs}
            npm run rebuild

            popd

            runHook postBuild
          '';

        # TODO: replace with `pnpm deploy`
        # now it fails to build with ERR_PNPM_NO_OFFLINE_META
        # see https://github.com/pnpm/pnpm/issues/5315
        installPhase = ''
          runHook preInstall

          mkdir -p $out/{bin,lib/node_modules/renovate}
          cp -r dist node_modules package.json renovate-schema.json $out/lib/node_modules/renovate

          makeWrapper "${pkgs.lib.getExe pkgs.nodejs}" "$out/bin/renovate" \
            --add-flags "$out/lib/node_modules/renovate/dist/renovate.js"
          makeWrapper "${pkgs.lib.getExe pkgs.nodejs}" "$out/bin/renovate-config-validator" \
            --add-flags "$out/lib/node_modules/renovate/dist/config-validator.js"

          runHook postInstall
        '';

        meta = {
          description = "Cross-platform dependency automation, with patches for nix";
          homepage = "https://github.com/renovatebot/renovate";
          changelog = "https://github.com/renovatebot/renovate/releases/tag/${finalAttrs.version}";
          license = pkgs.lib.licenses.agpl3Only;
          mainProgram = "renovate";
          platforms = pkgs.nodejs.meta.platforms;
        };
      });
    in {
      devShells.default = pkgs.mkShell {
        packages = [
          patched-renovate
        ];
      };

      formatter = pkgs.alejandra;

      packages.default = patched-renovate;
    });
}
