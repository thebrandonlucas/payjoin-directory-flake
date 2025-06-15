{
  description = "Payjoin Directory with Prometheus and Grafana";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane = {
      url = "github:ipetkov/crane/v0.20.2";
    };
    payjoin = {
      url = "github:payjoin/rust-payjoin";
      flake = false; # Source-only flake
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, crane, payjoin }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };
        # Initialize crane with Rust toolchain
        craneLib = (crane.mkLib pkgs).overrideToolchain pkgs.rust-bin.stable.latest.default;
        # Source for payjoin-directory crate
        src = craneLib.cleanCargoSource payjoin;
        # Common arguments for workspace
        commonArgs = {
          inherit src;
          strictDeps = true;
          pname = "payjoin-directory"; # Avoid workspace Cargo.toml warnings
          version = "0.1.0"; # Adjust based on crates/payjoin-directory/Cargo.toml
          cargoLock = "${payjoin}/Cargo-recent.lock"; # Use workspace Cargo.lock
          buildInputs = with pkgs; [ openssl pkg-config ];
          nativeBuildInputs = with pkgs; [ rust-bin.stable.latest.default ];
        };
        # Build dependencies
        cargoArtifacts = craneLib.buildDepsOnly (commonArgs // {
          cargoExtraArgs = "--locked -p payjoin-directory";
        });
        # Build payjoin-directory crate
        payjoin-directory = craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;
          cargoExtraArgs = "--locked -p payjoin-directory";
          cargoToml = "${payjoin}/crates/payjoin-directory/Cargo.toml";
          doCheck = false; # Skip tests for faster build
        });
      in {
        packages.default = payjoin-directory;
        devShells.default = craneLib.devShell {
          inputsFrom = [ payjoin-directory ];
          packages = with pkgs; [
            prometheus
            grafana
            prometheus-node-exporter
          ];
          shellHook = ''
            # Create writable directory for Grafana
            GRAFANA_DATA_DIR="/tmp/grafana-data"
            mkdir -p "$GRAFANA_DATA_DIR/data" "$GRAFANA_DATA_DIR/log"
            chmod -R u+w "$GRAFANA_DATA_DIR"

            # Start node-exporter
            if [[ -x "${pkgs.prometheus-node-exporter}/bin/node_exporter" ]]; then
              echo "Starting node_exporter..."
              ${pkgs.prometheus-node-exporter}/bin/node_exporter --web.listen-address=:9100 >> /tmp/node_exporter.log 2>&1 &
              NODE_EXPORTER_PID=$!
              # Wait for node_exporter to be up
              for i in {1..10}; do
                if curl -s http://localhost:9100/metrics > /dev/null; then
                  echo "node_exporter is up"
                  break
                fi
                echo "Waiting for node_exporter (attempt $i/10)..."
                sleep 1
              done
              if ! kill -0 $NODE_EXPORTER_PID 2>/dev/null; then
                echo "ERROR: node_exporter failed to start. Check /tmp/node_exporter.log for details."
                cat /tmp/node_exporter.log
                exit 1
              fi
            else
              echo "ERROR: node_exporter binary not found or not executable at ${pkgs.prometheus-node-exporter}/bin/node_exporter"
              exit 1
            fi

            # Start Prometheus
            ${pkgs.prometheus}/bin/prometheus --config.file=${pkgs.writeTextFile {
              name = "prometheus.yml";
              text = ''
                global:
                  scrape_interval: 15s
                scrape_configs:
                  - job_name: 'payjoin-directory'
                    static_configs:
                      - targets: ['0.0.0.0:8080']
                  - job_name: 'node_exporter'
                    static_configs:
                      - targets: ['localhost:9100']
              '';
            }} --web.listen-address=:9001 &
            PROMETHEUS_PID=$!

            # Start Grafana with writable data directory
            ${pkgs.grafana}/bin/grafana-server -homepath ${pkgs.grafana}/share/grafana -config ${pkgs.writeTextFile {
              name = "grafana.ini";
              text = ''
                [server]
                http_addr = 0.0.0.0
                http_port = 3001
                [auth]
                admin_user = admin
                admin_password = admin
                [paths]
                data = /tmp/grafana-data/data
                logs = /tmp/grafana-data/log
                [datasources]
                [datasources.prometheus]
                type = prometheus
                name = Prometheus
                url = http://localhost:9001
                access = proxy
                isDefault = true
              '';
            }} &
            GRAFANA_PID=$!

            # Start payjoin-directory
            ${payjoin-directory}/bin/payjoin-directory &
            PAYJOIN_PID=$!

            echo "Services started:"
            echo " - Payjoin Directory at http://localhost:8080"
            echo " - Prometheus at http://localhost:9001"
            echo " - Grafana at http://localhost:3001 (login: admin/admin)"

            # Wait for services to be up (simple health check)
            sleep 5
            if ! curl -s http://localhost:9001/-/healthy > /dev/null; then
              echo "WARNING: Prometheus may not be running correctly"
            fi
            if ! curl -s http://localhost:3001/api/health > /dev/null; then
              echo "WARNING: Grafana may not be running correctly"
            fi
            if ! curl -s http://localhost:8080/health > /dev/null; then
              echo "WARNING: Payjoin-directory may not be running correctly"
            fi

            # Clean up on exit
            trap "kill $NODE_EXPORTER_PID $PROMETHEUS_PID $GRAFANA_PID $PAYJOIN_PID 2>/dev/null" EXIT
            wait
          '';
        };
      }
    );
}
