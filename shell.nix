{ pkgs ? import <nixpkgs> { overlays = [ (import (fetchTarball "https://github.com/oxalica/rust-overlay/archive/master.tar.gz")) ]; } }:
let
  payjoin-directory = (import ./flake.nix { inherit pkgs; }).packages.${pkgs.system}.default;
in
pkgs.mkShell {
  buildInputs = with pkgs; [
    payjoin-directory
    prometheus
    grafana
    node-exporter
  ];
  shellHook = ''
    # Start node-exporter
    ${pkgs.node-exporter}/bin/node-exporter --web.listen-address=:9100 &
    NODE_EXPORTER_PID=$!
    # Start Prometheus
    ${pkgs.prometheus}/bin/prometheus --config.file=${./prometheus.yml} --web.listen-address=:9001 &
    PROMETHEUS_PID=$!
    # Start Grafana
    ${pkgs.grafana}/bin/grafana-server -homepath ${pkgs.grafana}/share/grafana -config ${pkgs.writeFileFromString ''
      [server]
      http_addr = 0.0.0.0
      http_port = 3001
      [auth]
      admin_user = admin
      admin_password = admin
      [datasources]
      [datasources.prometheus]
      type = prometheus
      name = Prometheus
      url = http://localhost:9001
      access = proxy
      isDefault = true
    ''} &
    GRAFANA_PID=$!
    # Start payjoin-directory
    ${payjoin-directory}/bin/payjoin-directory &
    PAYJOIN_PID=$!
    echo "Services started:"
    echo " - Payjoin Directory at http://localhost:8080"
    echo " - Prometheus at http://localhost:9001"
    echo " - Grafana at http://localhost:3001 (login: admin/admin)"
    # Clean up on exit
    trap "kill $NODE_EXPORTER_PID $PROMETHEUS_PID $GRAFANA_PID $PAYJOIN_PID 2>/dev/null" EXIT
    wait
  '';
}
