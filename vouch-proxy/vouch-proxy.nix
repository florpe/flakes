{ config, lib, pkgs, ... }:

with lib;

{
  options.services.vouch-proxy = {
    enable = mkEnableOption (mdDoc "vouch-proxy");
    instance = mkOption {
      type = types.attrsOf (types.submodule ({ config, name, ... }: {
        options = {
          enable = mkEnableOption (mdDoc "Vouch instance");
          group = mkOption {
            type = types.nullOr types.str;
            description = ''
              The service's group. Members of this group are able to
              listen on the instance's socket.
              '';
            default = null;
          };
          wantedBy = mkOption {
            type = types.listOf types.str;
            description = ''
              List of services requiring this Vouch instance.
              '';
            default = [];
          };
          configuration = mkOption {
            type = types.attrsOf types.str;
            description = ''
              Environment variables for Vouch configuration. Secrets should not
              be passed here, but instead be specified via their respective
              options.
              '';
            default = {};
          };
          jwtEncryptionSecret = mkOption {
            type = types.nullOr types.str;
            description = ''
              JWT encryption secret to retrieve using the
              `LoadCredentialEncrypted=` directive. May include a path as per
              systemd.exec(5).
              '';
            default = null;
          };
          oauth2ClientId = mkOption {
            type = types.str;
            description = ''
              OAuth2 client ID. Used to retrieve the client secret using the
              `LoadCredentialEncrypted=` directive after percent encoding and
              prefixing with `oauth2_`.
              '';
          };
         oauth2ClientSecretLocation = mkOption {
           type = types.nullOr types.str;
           description = ''
             Optional explicit location of the OAuth2 client secret.
             '';
           default = "";
        };
        };
      }));
    };
  };
  config = mkIf config.services.vouch-proxy.enable {
    users.users.vouch-proxy.isSystemUser = true;
    users.users.vouch-proxy.group = "vouch-proxy";
    users.groups.vouch-proxy = {};
    systemd.tmpfiles.rules = [
      "d /var/lib/vouch-proxy 0755 root vouch-proxy"
    ];
    systemd.services = mapAttrs' (name: cfg:
      let
        svcGroup = if cfg.group == null then "vouch-proxy" else cfg.group;
        oauth2Cred = "oauth2_${lib.escapeURL cfg.oauth2ClientId}" + (
          if cfg.oauth2ClientSecretLocation == null
            then ""
            else ":${cfg.oauth2ClientSecretLocation}"
          );
        jwtCred = if cfg.jwtEncryptionSecret == null #TODO: Disaggregate locations
          then null
          else "oauth2_${lib.escapeURL cfg.oauth2ClientId}:oauth2_${lib.escapeURL cfg.oauth2ClientId}";
        allCreds = if jwtCred == null then [oauth2Cred] else [jwtCred oauth2Cred];
      in nameValuePair "vp-${name}" {
        enable = cfg.enable;
        wantedBy = cfg.wantedBy;
        after = ["network.target"];
        stopIfChanged = true;
        environment = cfg.configuration // {
          VOUCH_LISTEN = "unix:/var/lib/vouch-proxy/${name}/${name}.sock";
          VOUCH_SOCKETGROUP = svcGroup;
          OAUTH_CLIENT_ID = cfg.oauth2ClientId;
        };
        serviceConfig = {
          Type = "simple";
          User = "vouch-proxy"; #TODO: Make this dynamic, somehow
          Group = svcGroup;
          StateDirectory = "vouch-proxy/${name}";
          StateDirectoryMode = "0750";
          Restart = "on-failure";
          RestartSec = 5;
          LoadCredentialEncrypted = allCreds;
        };
        unitConfig = {
          StartLimitInterval = "60s";
          StartLimitBurst = 3;
        };
        script = ''
          cd "$STATE_DIRECTORY"
          mkdir --parents --mode 0750 ./config

          if [ -f "$CREDENTIALS_DIRECTORY/jwtEncryptionSecret" ] ; then
            touch ./config/secret
            chmod 640 ./config/secret
            cat "$CREDENTIALS_DIRECTORY/jwtEncryptionSecret" > ./config/secret
          fi
          export OAUTH_CLIENT_SECRET="$(cat "$CREDENTIALS_DIRECTORY/oauth2_${lib.escapeURL cfg.oauth2ClientId}")"

          export VOUCH_ROOT="$STATE_DIRECTORY"
          exec "${pkgs.vouch-proxy}/bin/vouch-proxy"
          '';
      }
    ) config.services.vouch-proxy.instance;
  };
}
