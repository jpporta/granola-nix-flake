{
  description = "Nix flake for Granola on Linux (macOS identity wrapper)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    granola-src = {
      url = "github:bindusara-reddy/granola-linux-macos";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      granola-src,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        fhsDeps = with pkgs; [
          # Build tools & runtime utilities
          coreutils
          bash
          gnused
          gnutar
          gawk
          findutils
          which
          nodejs_24
          python3
          gcc
          gnumake
          _7zz
          curl
          jq
          file
          pulseaudio
          desktop-file-utils
          xdg-utils

          # Electron & UI dependencies
          alsa-lib
          at-spi2-atk
          at-spi2-core
          cairo
          cups
          dbus
          expat
          fontconfig
          freetype
          gdk-pixbuf
          glib
          gtk3
          libgbm
          libdrm
          libGL
          libnotify
          libsecret
          libx11
          libxcomposite
          libxcursor
          libxdamage
          libxext
          libxfixes
          libxi
          libxrandr
          libxrender
          libxtst
          libxcb
          libxshmfence
          libxkbcommon
          nspr
          nss
          pango
          systemd
        ];

        fhs = pkgs.buildFHSEnv {
          name = "granola-fhs";
          targetPkgs = pkgs: fhsDeps;
          runScript = "bash";
        };

        knownDmgUrl = "https://dr2v7l5emb758.cloudfront.net/7.469.1/Granola-7.469.1-mac-universal.dmg";

        launcherScript = pkgs.writeShellScriptBin "granola" ''
          set -euo pipefail

          DATA_DIR="''${XDG_DATA_HOME:-$HOME/.local/share}/granola-linux-macos"
          BUILD_DIR="$DATA_DIR/build/granola"
          CACHE_DIR="$DATA_DIR/.cache"
          SRC_DIR="$DATA_DIR/src"
          APPLICATIONS_DIR="''${XDG_DATA_HOME:-$HOME/.local/share}/applications"
          DESKTOP_FILE="$APPLICATIONS_DIR/granola-linux-macos.desktop"

          build_granola() {
            echo "==> Setting up Granola Linux builder in $DATA_DIR"
            mkdir -p "$DATA_DIR" "$CACHE_DIR"
            rm -rf "$SRC_DIR"
            cp -r --no-preserve=mode "${granola-src}" "$SRC_DIR"
            chmod -R u+rwX "$SRC_DIR"
            chmod +x "$SRC_DIR/build.sh" "$SRC_DIR/desktop.sh" "$SRC_DIR"/scripts/* 2>/dev/null || true

            DMG_PATH="$CACHE_DIR/Granola-7.469.1.dmg"
            if [ ! -f "$DMG_PATH" ]; then
              echo "==> Downloading verified Granola macOS installer (v7.469.1)..."
              ${pkgs.curl}/bin/curl -L --fail --output "$DMG_PATH" "${knownDmgUrl}"
            fi

            echo "==> Building Granola..."
            ${fhs}/bin/granola-fhs -c "cd '$SRC_DIR' && ./build.sh --cache-dir '$CACHE_DIR' --output '$BUILD_DIR' '$DMG_PATH'"
            install_desktop
          }

          install_desktop() {
            echo "==> Installing desktop entry and registering granola:// protocol handler..."
            mkdir -p "$APPLICATIONS_DIR"
            cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Granola
Comment=Granola AI meeting notes and recorder
Exec=$out/bin/granola %U
Icon=$BUILD_DIR/granola-app-icon.png
Terminal=false
Categories=Office;
Keywords=meeting;notes;transcription;
StartupNotify=true
StartupWMClass=granola
MimeType=x-scheme-handler/granola;
X-Granola-Linux-MacOS-Identity=true
EOF
            chmod 0644 "$DESKTOP_FILE"
            if command -v update-desktop-database >/dev/null 2>&1; then
              update-desktop-database "$APPLICATIONS_DIR" 2>/dev/null || true
            fi
            if command -v xdg-mime >/dev/null 2>&1; then
              xdg-mime default "$(basename "$DESKTOP_FILE")" x-scheme-handler/granola 2>/dev/null || true
            fi
            echo "==> Desktop entry installed: $DESKTOP_FILE"
          }

          case "''${1:-}" in
            --build|build)
              build_granola
              exit 0
              ;;
            --install-desktop|install-desktop)
              install_desktop
              exit 0
              ;;
          esac

          if [ ! -x "$BUILD_DIR/run-granola" ]; then
            echo "==> Granola build not found. Building now..."
            build_granola
          else
            # Ensure desktop file is up to date with correct wrapper path
            if [ ! -f "$DESKTOP_FILE" ] || ! grep -q "x-scheme-handler/granola" "$DESKTOP_FILE" 2>/dev/null; then
              install_desktop
            fi
          fi

          exec ${fhs}/bin/granola-fhs -c "exec '$BUILD_DIR/run-granola' \"\$@\"" -- "$@"
        '';

        granolaPkg = pkgs.stdenv.mkDerivation {
          pname = "granola";
          version = "7.469.1";
          src = ./.;
          dontUnpack = true;

          installPhase = ''
            mkdir -p $out/bin
            cp ${launcherScript}/bin/granola $out/bin/granola
            substituteInPlace $out/bin/granola --replace '$out' "$out"
          '';
        };
      in
      {
        packages = {
          default = granolaPkg;
          granola = granolaPkg;
          fhs = fhs;
        };

        apps = {
          default = {
            type = "app";
            program = "${granolaPkg}/bin/granola";
          };
          build = {
            type = "app";
            program = "${pkgs.writeShellScript "granola-build" "exec ${granolaPkg}/bin/granola --build"}";
          };
          install-desktop = {
            type = "app";
            program = "${pkgs.writeShellScript "granola-install-desktop" "exec ${granolaPkg}/bin/granola --install-desktop"}";
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            fhs
            granolaPkg
          ] ++ fhsDeps;
          shellHook = ''
            echo "Granola development & runner shell loaded."
            echo "Run 'granola' to start Granola or 'granola --build' to rebuild."
          '';
        };
      }
    );
}
