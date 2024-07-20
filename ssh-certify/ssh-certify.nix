{ config, lib, pkgs, ... }:

with lib;

{
  options.services.ssh-certify = {
    enable = mkEnableOption (mdDoc "ssh-certify");
    encryptedCredentials = mkOption {
      type = types.bool;
      description = "Whether to use systemd-creds to decrypt the CA keys.";
      default = false;
    };
    ca = mkOption {
      type = types.attrsOf (types.submodule ({ config, name, ...}: {
        options = {
          enable = mkEnableOption (mdDoc "ssh-certify instance");
          group = mkOption {
            type = types.str;
            description = "CA service and socket's group";
          };
          privateKeyFile = mkOption {
            type = types.path;
            description = "Path to CA private key";
          };
          allowUserCertificates = mkOption {
            type = types.bool;
            description = "Whether to allow creation of user certificates. Not implemented.";
            default = false;
          };
          allowHostCertificates = mkOption {
            type = types.bool;
            description = "Whether to allow creation of host certificates. Not implemented.";
            default = false;
          };
        };
      }));
    };
  };
  config = mkIf config.services.ssh-certify.enable {
    systemd.tmpfiles.rules = [
      "d /run/ssh-certify 0755 root root"
    ];
    systemd.sockets = mapAttrs' (name: cfg: nameValuePair "ssh-certify-${name}" {
      enable = cfg.enable;
      wantedBy = ["sockets.target"];
      socketConfig = {
        Accept = true;
        ListenStream = "/run/ssh-certify/${name}.sock";
        SocketUser = "root";
        SocketGroup = cfg.group;
        SocketMode = "660";
        ReusePort = true;
      };
    }) config.services.ssh-certify.ca;
    systemd.services = mapAttrs' (name: cfg: nameValuePair "ssh-certify-${name}@" {
      stopIfChanged = true;
      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        RuntimeDirectory = "ssh-certify/%N";
        RuntimeDirectoryMode = "700";
        RuntimeDirectoryPreserve = false;
        UMask = "077";
        Group = cfg.group;
        StandardError = "journal";
        StandardInput = "socket";
        StandardOutput = "socket";
      } // (
      if config.services.ssh-certify.encryptedCredentials
        then { LoadCredentialEncrypted = "privKey:${cfg.privateKeyFile}"; }
        else { LoadCredential = "privKey:${cfg.privateKeyFile}"; }
      );
      script = ''
        set -euxo pipefail
        ${pkgs.jq}/bin/jq --compact-output --unbuffered '
          .SIGNCMD=("${pkgs.openssh}/bin/ssh-keygen" + if .REQ_ISHOST then " -h" else "" end)
          | {SIGNCMD, REQ_PUBKEY, REQ_IDENTITY, REQ_PRINCIPALS, REQ_VALIDITY}
          | .REQ_PRINCIPALS=(.REQ_PRINCIPALS | join(","))
          ' |
          while read -r ln ; do
            echo "Processing: $ln" >&2
            source <(
              echo "$ln" |
                ${pkgs.jq}/bin/jq --raw-output '
                    to_entries[]
                    | select(.value | type == "string")
                    | [.key, (.value | @sh)]
                    | join("=")
                  '
              )
            echo "$REQ_PUBKEY" > "$RUNTIME_DIRECTORY/req.pub"
            
            $SIGNCMD \
              -I "$REQ_IDENTITY" \
              -s "$CREDENTIALS_DIRECTORY/privKey" \
              -n "$REQ_PRINCIPALS" \
              -V "$REQ_VALIDITY" \
              "$RUNTIME_DIRECTORY/req.pub"
            ${pkgs.coreutils}/bin/cut -d ' ' -sf 1,2 "$RUNTIME_DIRECTORY/req-cert.pub"
            ${pkgs.coreutils}/bin/rm "$RUNTIME_DIRECTORY/req-cert.pub"
            unset SIGNCMD REQ_PUBKEY REQ_IDENTITY REQ_PRINCIPALS REQ_VALIDITY
          done
      '';
    }) config.services.ssh-certify.ca;
  };
}
