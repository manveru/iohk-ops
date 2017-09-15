with (import ./../lib.nix);

globals: params:
{ config, pkgs, lib, options, ... }:
let
  cfg = config.services.cardano-node;
  name = "cardano-node";
  stateDir = "/var/lib/cardano-node/";
  cardano = (import ./../default.nix { dconfig = builtins.trace ("cardano: DCONFIG is: " + config.deployment.arguments.dconfig)
                                                 config.deployment.arguments.dconfig; }).cardano-sl-static;
  distributionParam = "(${toString cfg.genesisN},${toString cfg.totalMoneyAmount})";
  rnpDistributionParam = "(${toString cfg.genesisN},50000,${toString cfg.totalMoneyAmount},0.99)";
  smartGenIP = builtins.getEnv "SMART_GEN_IP";

  command = toString [
    cfg.executable
    (optionalString (cfg.publicIP != null) "--address ${cfg.publicIP}:${toString cfg.port}")
    "--listen ${cfg.privateIP}:${toString cfg.port}"
    # Profiling
    # NB. can trigger https://ghc.haskell.org/trac/ghc/ticket/7836
    # (it actually happened)
    #"+RTS -N -pa -hb -T -A6G -qg -RTS"
    # Event logging (cannot be used with profiling)
    #"+RTS -N -T -l -A6G -qg -RTS"
    "--no-ntp" # DEVOPS-160
    (optionalString cfg.stats "--stats")
    (optionalString (!cfg.productionMode) "--rebuild-db")
    (optionalString (!cfg.productionMode) "--spending-genesis ${toString cfg.nodeIndex}")
    (optionalString (!cfg.productionMode) "--vss-genesis ${toString cfg.nodeIndex}")
    (optionalString (cfg.distribution && !cfg.productionMode && cfg.richPoorDistr) (
       "--rich-poor-distr \"${rnpDistributionParam}\""))
    (optionalString (cfg.distribution && !cfg.productionMode && !cfg.richPoorDistr) (
       if cfg.bitcoinOverFlat
       then "--bitcoin-distr \"${distributionParam}\""
       else "--flat-distr \"${distributionParam}\""))
    (optionalString cfg.jsonLog "--json-log ${stateDir}/jsonLog.json")
    (optionalString (cfg.statsdServer != null) "--metrics +RTS -T -RTS --statsd-server ${cfg.statsdServer}")
    (optionalString (cfg.serveEkg)             "--ekg-server ${cfg.privateIP}:8080")
    (optionalString (cfg.productionMode && params.name != "explorer")
      "--keyfile ${stateDir}key${toString cfg.nodeIndex}.sk")
    (optionalString (cfg.productionMode && globals.systemStart != 0) "--system-start ${toString globals.systemStart}")
    (optionalString cfg.supporter "--supporter")
    "--log-config ${./../static/csl-logging.yaml}"
    "--logs-prefix /var/lib/cardano-node"
    "--db-path ${stateDir}/node-db"
    (optionalString (!cfg.enableP2P) "--kademlia-explicit-initial --disable-propagation ${smartGenPeer}")
    "--topology ${cfg.topologyYaml}"
    "--node-id ${params.name}"
    "--custom-config-name ${config.deployment.arguments.dconfig}"
  ];
in {
  options = {
    services.cardano-node = {
      enable = mkEnableOption name;
      port = mkOption { type = types.int; default = 3000; };
      systemStart = mkOption { type = types.int; default = 0; };

      enableP2P = mkOption { type = types.bool; default = true; };
      supporter = mkOption { type = types.bool; default = false; };
      productionMode = mkOption {
        type = types.bool;
        default = true;
      };
      saveCoreDumps = mkOption {
        type = types.bool;
        default = true;
        description = "automatically save coredumps when cardano-node segfaults";
      };

      executable = mkOption {
        type = types.str;
        description = "Executable to run as the daemon.";
        default = "${cardano}/bin/cardano-node-simple";
      };
      autoStart = mkOption { type = types.bool; default = true; };

      topologyYaml = mkOption { type = types.path; };
      
      genesisN = mkOption { type = types.int; default = 6; };
      slotDuration = mkOption { type = types.int; default = 20; };
      networkDiameter = mkOption { type = types.int; default = 15; };
      mpcRelayInterval = mkOption { type = types.int; default = 45; };
      stats = mkOption { type = types.bool; default = false; };
      jsonLog = mkOption { type = types.bool; default = true; };
      totalMoneyAmount = mkOption { type = types.int; default = 60000000; };
      distribution = mkOption {
        type = types.bool;
        default = true;
        description = "pass distribution flag";
      };
      bitcoinOverFlat = mkOption {
        type = types.bool;
        default = false;
        description = "If distribution is on, use bitcoin distribution. Otherwise flat";
      };
      richPoorDistr = mkOption {
        type = types.bool;
        default = false;
        description = "Enable rich-poor distr";
      };

      nodeIndex  = mkOption { type = types.int; };
      relayIndex = mkOption { type = types.int; };
      nodeName   = mkOption { type = types.str; };
      nodeType   = mkOption { type = types.enum [ "core" "relay" "other" ]; default = null; };

      publicIP = mkOption {
        type = types.nullOr types.str;
        description = "Public IP to advertise to peers";
        default = null;
      };

      privateIP = mkOption {
        type = types.str;
        description = "Private IP to bind to";
        default = "0.0.0.0";
      };

      neighbours = mkOption {
        default = [];
        # type = types.list;
        description = ''List of name:ip pairs of neighbours.'';
      };

      statsdServer = mkOption {
        type = types.nullOr types.str;
        description = "IP:Port of the EKG telemetry sink";
        default = null;
      };

      serveEkg = mkOption {
        type = types.bool;
        description = "Serve EKG web UI on port 8080";
        default = false;
      };
    };
  };

  config = mkIf cfg.enable {
    services.cardano-node.serveEkg = config.global.enableEkgWeb;

    assertions = [
    { assertion = cfg.nodeType != null;
      message = "services.cardano-node.type must be set to one of: core relay other"; }
    ];

    users = {
      users.cardano-node = {
        uid             = 10014;
        description     = "cardano-node server user";
        group           = "cardano-node";
        home            = stateDir;
        createHome      = true;
        extraGroups     = [ "keys" ];
      };
      groups.cardano-node = {
        gid = 123123;
      };
    };

    networking.firewall = {
      allowedTCPPorts = [ cfg.port ] ++ optionals cfg.serveEkg [ 8080 ];

      # TODO: securing this depends on CSLA-27
      # NOTE: this implicitly blocks DHCPCD, which uses port 68
      allowedUDPPortRanges = [ { from = 1024; to = 65000; } ];
    };

    # Workaround for CSL-1320
    systemd.services.cardano-restart = let
      getDailyTime = nodeIndex: let
          # how many minutes between each node restarting
          minute = mod (nodeIndex * 4) 60;
        # Reboot cardano-node every 6h, offset by node id (in ${interval} minute intervals)
        in "0/6:${toString minute}";
    in {
      script = ''
        /run/current-system/sw/bin/systemctl restart cardano-node
      '';
      startAt = getDailyTime cfg.nodeIndex;
    };

    systemd.services.cardano-node = {
      description   = "cardano node service";
      after         = [ "network.target" ];
      wantedBy = optionals cfg.autoStart [ "multi-user.target" ];
      script = let
        keyId = "key" + toString cfg.nodeIndex;
        key = keyId + ".sk";
      in ''
        [ -f /run/keys/${keyId} ] && cp /run/keys/${keyId} ${stateDir}${key}
        ${optionalString (cfg.saveCoreDumps) ''
          # only a process with non-zero coresize can coredump (the default is 0)
          ulimit -c unlimited
        ''}
        exec ${command}
      '';
      serviceConfig = {
        User = "cardano-node";
        Group = "cardano-node";
        # Allow a maximum of 5 retries separated by 30 seconds, in total capped by 200s
        Restart = "always";
        RestartSec = 30;
        StartLimitInterval = 200;
        StartLimitBurst = 5;
        KillSignal = "SIGINT";
        WorkingDirectory = stateDir;
        PrivateTmp = true;
      };
    };
  };
}
