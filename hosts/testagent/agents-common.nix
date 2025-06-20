# SPDX-FileCopyrightText: 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{
  pkgs,
  inputs,
  lib,
  self,
  config,
  ...
}:
let
  # Vendored in, as brainstem isn't suitable for nixpkgs packaging upstream:
  # https://github.com/NixOS/nixpkgs/pull/313643
  brainstem = pkgs.callPackage ../../pkgs/brainstem { };

  connect-script = pkgs.writeShellApplication {
    name = "connect";
    text = # sh
      ''
        url="''${1%/}"  # Remove trailing slash

        if [[ ! $url =~ ^https?://[^/]+$ ]]; then
          echo "ERROR: The URL should start with https and not have any subpath"
          exit 1
        fi

        if [[ ! -f /var/lib/jenkins/jenkins.env ]]; then
          # create the file with correct permissions
          sudo install -o jenkins -g jenkins -m 600 /dev/null /var/lib/jenkins/jenkins.env
        fi

        # add this controller to known hosts
        sudo -u jenkins ssh-keygen -R "''${url#*//}" 2>/dev/null || true
        sudo -u jenkins ssh -o StrictHostKeyChecking=no -i ${config.sops.secrets.ssh_host_ed25519_key.path} "${config.networking.hostName}@''${url#*//}" exit

        echo "CONTROLLER=$url" | sudo tee /var/lib/jenkins/jenkins.env
        sudo systemctl restart start-agents.service

        echo "Connected agents to the controller"
      '';
  };

  disconnect-script = pkgs.writeShellApplication {
    name = "disconnect";
    text = # sh
      ''
        sudo systemctl stop start-agents.service
        echo "CONTROLLER=" | sudo tee /var/lib/jenkins/jenkins.env

        echo "Disconnected agents from the controller"
      '';
  };
in
{
  imports =
    [
      ./agent.nix
      inputs.sops-nix.nixosModules.sops
      inputs.disko.nixosModules.disko
      self.nixosModules.service-monitoring
    ]
    ++ (with self.nixosModules; [
      common
      service-openssh
    ]);

  sops.secrets =
    let
      credential = {
        sopsFile = ./credentials.yaml;
        owner = "jenkins";
      };
    in
    {
      dut-pass = credential;
      plug-login = credential;
      plug-pass = credential;
      switch-token = credential;
      switch-secret = credential;
      wifi-ssid = credential;
      wifi-password = credential;
      pi-login = credential;
      pi-pass = credential;
      # used for ssh connections
      ssh_host_ed25519_key.owner = "jenkins";
    };

  networking.useDHCP = true;

  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  hardware = {
    enableRedistributableFirmware = true;
    cpu.intel.updateMicrocode = true;
  };

  services.udev.packages = [
    brainstem
    pkgs.usbsdmux
  ];

  # packages available in all user sessions
  environment.systemPackages =
    [
      brainstem
      connect-script
      disconnect-script
      self.packages.${pkgs.system}.policy-checker
    ]
    ++ (with inputs.robot-framework.packages.${pkgs.system}; [
      ghaf-robot
      KMTronic
    ])
    ++ (with pkgs; [
      minicom
      usbsdmux
      grafana-loki
      (python3.withPackages (ps: with ps; [ pyserial ]))
    ]);

  # This server is only exposed to the internal network
  # fail2ban only causes issues here
  services.fail2ban.enable = lib.mkForce false;

  services.monitoring = {
    metrics.enable = true;
    logs.enable = false;
  };

  systemd.services.push-testagent-metrics = {
    description = "Push testagent metrics to Prometheus Pushgateway";
    serviceConfig = {
      Type = "oneshot";
    };
    path = [ pkgs.curl ];
    script = ''
      password=$(cat ${config.sops.secrets.metrics_password.path})
      metrics=$(curl -s http://127.0.0.1:${toString config.services.prometheus.exporters.node.port}/metrics)
      echo "$metrics" | curl -u logger:$password --data-binary @- https://monitoring.vedenemo.dev/push/metrics/job/${config.networking.hostName}
    '';
  };

  systemd.timers.push-testagent-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1min";
    };
  };

  environment.etc."jenkins/provenance-trust-policy.json".source =
    ../../slsa/provenance-trust-policy.json;
}
