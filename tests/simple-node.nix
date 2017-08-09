let
  nodeArgs = import ./cardano-node-simple-config.nix;
in
import <nixpkgs/nixos/tests/make-test.nix> ({ pkgs, ... }: {
  name = "simple-node";
  nodes = {
    machine = { config, pkgs, ... }: {
      imports = [ (import ../modules/cardano-node-config.nix (nodeArgs.machine)) ];
      virtualisation.qemu.options = [ "-cpu Haswell" ];
      services.cardano-node = {
        autoStart = true;
        initialKademliaPeers = [];
        neighbours = [];
      };
    };
  };
  testScript = ''
    startAll
    $machine->waitForUnit("cardano-node.service");
    # TODO, implement sd_notify?
    $machine->waitForOpenPort(3000);
  '';
})
