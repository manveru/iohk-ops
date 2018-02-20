{ globals, ... }: with (import ./../lib.nix);
let nodeMap = { inherit (globals.fullMap) report-server; }; in

{
  require = [ ./report-server-bucket-storage.nix ];
  report-server = { config, resources, ...}: {
    imports = [
      ./../modules/staging.nix
      ./../modules/datadog.nix
      ./../modules/papertrail.nix
    ];

    config.services.report-server.zendesk = {
      email = "daedalus-bug-reports@iohk.io";
      tokenFile = "/run/keys/zendesk-token";
    };
  };

  resources.elasticIPs = nodesElasticIPs nodeMap;
}
