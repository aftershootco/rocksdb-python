# {
#   # Build Pyo3 package
#   inputs = {
#     nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
#     flake-utils.url = "github:numtide/flake-utils";
#     rust-overlay = {
#       url = "github:oxalica/rust-overlay";
#       inputs.nixpkgs.follows = "nixpkgs";
#     };
#     crane = {
#       url = "github:ipetkov/crane";
#       inputs.nixpkgs.follows = "nixpkgs";
#     };
#   };
#
#   outputs = inputs:
#     inputs.flake-utils.lib.eachDefaultSystem (system: let
#       pkgs = import inputs.nixpkgs {
#         inherit system;
#         overlays = [inputs.rust-overlay.overlays.default];
#       };
#       lib = pkgs.lib;
#
#       # Get a custom rust toolchain
#       customRustToolchain = pkgs.rust-bin.stable."1.77.0".default;
#       craneLib =
#         (inputs.crane.mkLib pkgs).overrideToolchain customRustToolchain;
#
#       projectName =
#         (craneLib.crateNameFromCargoToml {cargoToml = ./Cargo.toml;}).pname;
#       projectVersion =
#         (craneLib.crateNameFromCargoToml {
#           cargoToml = ./Cargo.toml;
#         })
#         .version;
#
#       pythonVersion = pkgs.python311;
#       wheelTail = "cp310-cp310-manylinux_2_34_x86_64"; # Change if pythonVersion changes
#       wheelName = "${projectName}-${projectVersion}-${wheelTail}.whl";
#
#       crateCfg = {
#         src = craneLib.cleanCargoSource (craneLib.path ./.);
#         nativeBuildInputs = [pythonVersion];
#       };
#
#       # Build the library, then re-use the target dir to generate the wheel file with maturin
#       crateWheel =
#         (craneLib.buildPackage (crateCfg
#           // {
#             pname = projectName;
#             version = projectVersion;
#             # cargoArtifacts = crateArtifacts;
#           }))
#         .overrideAttrs (old: {
#           LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
#           nativeBuildInputs = old.nativeBuildInputs ++ [pkgs.maturin];
#           buildPhase =
#             old.buildPhase
#             + ''
#               maturin build --offline --target-dir ./target
#             '';
#           installPhase =
#             old.installPhase
#             + ''
#               cp target/wheels/${wheelName} $out/
#             '';
#         });
#     in rec {
#       packages = rec {
#         default = crateWheel; # The wheel itself
#
#         # A python version with the library installed
#         pythonEnv =
#           pythonVersion.withPackages
#           (ps: [(lib.pythonPackage ps)] ++ (with ps; [ipython]));
#       };
#
#       lib = {
#         # To use in other builds with the "withPackages" call
#         pythonPackage = ps:
#           ps.buildPythonPackage rec {
#             pname = projectName;
#             format = "wheel";
#             version = projectVersion;
#             src = "${crateWheel}/${wheelName}";
#             doCheck = false;
#             pythonImportsCheck = [projectName];
#           };
#       };
#
#       devShells = rec {
#         rust = pkgs.mkShell {
#           name = "rust-env";
#           src = ./.;
#           nativeBuildInputs = with pkgs; [pkg-config rust-analyzer maturin];
#           LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
#         };
#         python = pkgs.mkShell {
#           name = "python-env";
#           src = ./.;
#           nativeBuildInputs = [packages.pythonEnv];
#         };
#         default = rust;
#       };
#
#       apps = rec {
#         ipython = {
#           type = "app";
#           program = "${packages.pythonEnv}/bin/ipython";
#         };
#         default = ipython;
#       };
#     });
# }
{
  description = "Build a cargo project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-analyzer-src.follows = "";
    };

    flake-utils.url = "github:numtide/flake-utils";

    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    crane,
    fenix,
    flake-utils,
    advisory-db,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      inherit (pkgs) lib;

      craneLib = crane.lib.${system};

      src = craneLib.cleanCargoSource (craneLib.path ./.);
      # mkPkgconfigPath = pkgs: builtins.concatStringsSep ":" (map (pkg: "${pkg.dev}/lib/pkgconfig") pkgs);

      # Common arguments can be set here to avoid repeating them later
      commonArgs = {
        inherit src;
        strictDeps = true;

        buildInputs =
          [
            # Add additional build inputs here
          ]
          ++ lib.optionals pkgs.stdenv.isDarwin [
            # Additional darwin specific inputs can be set here
            pkgs.libiconv
          ];
        nativeBuildInputs = with pkgs; [
          git
          maturin
          python3
          # pkg-config
        ];
        # ++ lib.optionals stdenv.isDarwin
        # (with pkgs.darwin.apple_sdk.frameworks; [Carbon CoreFoundation CoreServices Security]);
        LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
        # VIRTUAL_ENV = "${pkgs.python3}";

        # PKG_CONFIG_PATH = mkPkgconfigPath (with pkgs; [openssl.dev]);
      };

      craneLibLLvmTools =
        craneLib.overrideToolchain
        (fenix.packages.${system}.complete.withComponents [
          "cargo"
          "llvm-tools"
          "rustc"
        ]);

      # Build *just* the cargo dependencies, so we can reuse
      # all of that work (e.g. via cachix) when running in CI
      cargoArtifacts = craneLib.buildDepsOnly commonArgs;

      # Build the actual crate itself, reusing the dependency
      # artifacts from above.
      pyrocksdb =
        (craneLib.buildPackage
          (commonArgs
            // {
              inherit cargoArtifacts;
            }))
        .overrideAttrs (prev: {
          buildPhase =
            prev.buildPhase
            + ''
              maturin build --release -- --features
            '';
          installPhase = ''
            cp -r target/wheels/* $out/
          '';
        });
    in {
      checks = {
        # Build the crate as part of `nix flake check` for convenience
        inherit pyrocksdb;

        # Run clippy (and deny all warnings) on the crate source,
        # again, resuing the dependency artifacts from above.
        #
        # Note that this is done as a separate derivation so that
        # we can block the CI if there are issues here, but not
        # prevent downstream consumers from building our crate by itself.
        pyrocksdb-clippy = craneLib.cargoClippy (commonArgs
          // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          });

        pyrocksdb-doc = craneLib.cargoDoc (commonArgs
          // {
            inherit cargoArtifacts;
          });

        # Check formatting
        pyrocksdb-fmt = craneLib.cargoFmt {
          inherit src;
        };

        # Audit dependencies
        pyrocksdb-audit = craneLib.cargoAudit {
          inherit src advisory-db;
        };

        # Audit licenses
        pyrocksdb-deny = craneLib.cargoDeny {
          inherit src;
        };

        # Run tests with cargo-nextest
        # Consider setting `doCheck = false` on `pyrocksdb` if you do not want
        # the tests to run twice
        pyrocksdb-nextest = craneLib.cargoNextest (commonArgs
          // {
            inherit cargoArtifacts;
            partitions = 1;
            partitionType = "count";
          });
      };

      packages =
        {
          default = pyrocksdb;
        }
        // lib.optionalAttrs (!pkgs.stdenv.isDarwin) {
          pyrocksdb-llvm-coverage = craneLibLLvmTools.cargoLlvmCov (commonArgs
            // {
              inherit cargoArtifacts;
            });
        };

      apps.default = flake-utils.lib.mkApp {
        drv = pyrocksdb;
      };

      devShells.default = craneLib.devShell ({
          checks = self.checks.${system};

          packages = [
            pkgs.maturin
          ];
        }
        // commonArgs);
    });
}
