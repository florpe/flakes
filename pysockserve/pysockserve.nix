{ config, lib, pkgs, ... }:

with lib;

{
  options.services.pysockserve = mkOption { type = types.attrsOf (
    types.submodule({config, name, ...}: { options = {
      enable = mkEnableOption (mdDoc "PySockServe server instance");
#      name = mkOption {
#        type = types.str;
#        description = "Project name";
#      };
      socketGroup = mkOption {
        type = types.str;
        description = "Socket group";
        example = "nginx";
      };
      serviceGroup = mkOption {
        type = types.nullOr types.str;
        description = "Service group";
        default = null;
        example = "nginx";
      };
      environment = mkOption {
        type = types.attrsOf types.str;
        description = "Environment variables";
        default = {};
        example = "{ MYVAR = \"MYVALUE\"; }";
      };
      protectHome = mkOption {
        type = types.enum [ true false "read-only" "tmpfs" ];
        description = "The service's `ProtectHome=` setting. Defaults to denying all access.";
        default = false;
      };
      wantedBy = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Optional coupling with other services to avoid the delay incurred by socket activation.";
        example = [ "nginx.service" ];
      };
      extraPackages = mkOption {
        type = types.listOf types.str;
        description = "Extra packages for the service's PATH";
        default = [];
        example = [ pkgs.bash ];
      };
      source = mkOption {
        type = types.submodule({config, name, ...}: { options = {
          url = mkOption {
            type = types.str;
            description = "Git repository URL.";
          };
          ref = mkOption {
            type = types.str;
            description = "Which commit of the repository to check out, specified e.g. as a commit id, a tag, or a branch name - see `man git-checkout`.";
            default = "main";
          };
        };});
      };
      pythonPackage = mkOption {
        type = types.raw;
        description = "Python package to use when setting up the virtual environment.";
        default = pkgs.python3;
        example = "pkgs.python311";
      };
      setupScript = mkOption {
        type = types.str;
        description = ''
          Service setup commands. Invoked on every restart, so should be idempotent. The virtual
          environment is already initialized at `VIRTUAL_ENV="$STATE_DIRECTORY/venv"`, and the
          project itself has been pulled to `PWD="$STATE_DIRECTORY/project"`. `CACHE_DIRECTORY`
          is set by systemd and may be used.
          '';
        example = "POETRY_CACHE_DIR=\"$CACHE_DIRECTORY\" ${pkgs.poetry}/bin/poetry install";
      };
      execScript = mkOption {
        type = types.str;
        description = "Service execution commands to be run in the virtual environment after it is activated.";
        example = "exec gunicorn myproject:app --worker-class uvicorn.workers.UvicornWorker --log-level debug";
      };
    };}
  ));};
  config = mkIf ( config.services.pysockserve != {} ) {
    systemd.tmpfiles.rules = [
      "d /run/pysockserve 0755 root root"
      "d /var/lib/pysockserve 0755 root root"
      "d /var/cache/pysockserve 0755 root root"
    ];
    systemd.sockets = mapAttrs' (name: cfg: nameValuePair "pysockserve-${name}" {
      enable = cfg.enable;
      wantedBy = ["sockets.target"];
      socketConfig = {
        ListenStream = "/run/pysockserve/${name}.sock";
        SocketMode = "660";
        SocketUser = "root";
        SocketGroup = cfg.socketGroup;
        ReusePort = true;
      };
    }) config.services.pysockserve;
    systemd.services = mapAttrs' (name: cfg: nameValuePair "pysockserve-${name}" {
      # wantedBy = ["multi-user.target"];
      enable = true;
      requires = ["pysockserve-${name}.socket"]; #No socketless service start!
      wantedBy = cfg.wantedBy;
      stopIfChanged = true;
      environment = cfg.environment;
      path = cfg.extraPackages;
      preStart = ''
        set -x
        ${pkgs.coreutils}/bin/mkdir -p "$STATE_DIRECTORY/venv" "$STATE_DIRECTORY/project"
        ls -la ${cfg.pythonPackage}/bin/python3
        ls -la "$STATE_DIRECTORY/venv/bin"
        ${cfg.pythonPackage}/bin/python3 -m venv --upgrade "$STATE_DIRECTORY/venv"
        export VIRTUAL_ENV="$STATE_DIRECTORY/venv"

        cd "$STATE_DIRECTORY/project"
        if [ ! -d "./.git" ] ; then
          ${pkgs.git}/bin/git init
        fi
        echo "Fetching repo data" >&2
        commit="$(
          ${pkgs.git}/bin/git ls-remote "${cfg.source.url}" |
            grep -F -- "${cfg.source.ref}" |
            head -n 1 |
            cut -f 1
          )"
        if [ -z "$commit" ] ; then
          echo "No commit found matching ${cfg.source.ref}" >&2
          exit 1
        fi
        ${pkgs.git}/bin/git fetch "${cfg.source.url}" "$commit"
        ${pkgs.git}/bin/git -c advice.detachedHead=false checkout "$commit"
        echo -n "Current commit: " >&2
        ${pkgs.git}/bin/git show --oneline -s >&2
        exec ${pkgs.writeScript "pysockserve-${name}-setup.sh" cfg.setupScript}
        '';
      script = ''
        cd "$STATE_DIRECTORY/project"
        source $STATE_DIRECTORY/venv/bin/activate
        exec ${pkgs.writeScript "pysockserve-${name}-exec.sh" cfg.execScript}
        '';
      serviceConfig = {
        StateDirectory = "pysockserve/${name}";
        CacheDirectory = "pysockserve/${name}";
        Restart = "always";
        Type = "notify";
        NotifyAccess = "all";
        ProtectHome = cfg.protectHome;
        DynamicUser = true;
      } // (
        if cfg.serviceGroup == null
          then {}
          else { Group = cfg.serviceGroup; }
      );
    }) config.services.pysockserve;
  };
}
