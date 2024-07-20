{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }: {

    pysockserve = ./pysockserve/pysockserve.nix;
    ssh-certify = ./ssh-certify/ssh-certify.nix;
    vouch-proxy = ./vouch-proxy/vouch-proxy.nix;

  };
}
