{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }: {

    packages.x86_64-linux.pysockserve = ./pysockserve/pysockserve.nix;

    packages.x86_64-linux.default = self.packages.x86_64-linux.hello;

  };
}