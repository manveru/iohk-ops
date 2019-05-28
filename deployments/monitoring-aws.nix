{ globals, IOHKaccessKeyId, IOHKroute53accessKeyId, ... }:

with import ../lib.nix;
let
  accessKeyId = IOHKaccessKeyId;
  nodeMap = { inherit (globals.fullMap) monitoring; };
  monitoring = nodeMap.monitoring;
  region = monitoring.region;
  org = monitoring.org;
in {
  resources = {
    ec2SecurityGroups = {
      "allow-wireguard-in-${region}-${org}" = {
        inherit region accessKeyId;
        description = "wireguard";
        rules = [{
          protocol = "udp";
          fromPort = 51820; toPort = 51820;
          sourceIp = "0.0.0.0/0";
        }];
      };
    };
  };
  monitoring = { lib, resources, ... }: {
    deployment = {
      route53.accessKeyId = lib.mkForce IOHKroute53accessKeyId;
      ec2 = {
        securityGroups = [
          resources.ec2SecurityGroups."allow-wireguard-in-${region}-${org}"
          resources.ec2SecurityGroups."allow-to-monitoring-${region}"
          resources.ec2SecurityGroups."allow-monitoring-static-peers-${region}-${org}"
        ];
        region         = mkForce monitoring.region;
        accessKeyId    = monitoring.accessKeyId;
        keyPair        = resources.ec2KeyPairs.${monitoring.keyPairName};
      };
    };
  };

  resources.elasticIPs = nodesElasticIPs nodeMap;
}