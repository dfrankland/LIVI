# NixOS module for LIVI.
#
# Does declaratively what scripts/install/{common,headless}.sh and livi-core's
# self-install do imperatively on Debian: udev rule, sudoers, the access point
# unit, Bluetooth/PipeWire setup and the tty1 kiosk. LIVI runs with
# LIVI_SYSTEM_MANAGED=1 so it uses all of this instead of writing its own copies
# into /etc.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.livi;
  pkg = cfg.package;
  res = "${pkg}/lib/livi/resources";
  helper = "${res}/driver/livi-helperd";
  home = config.users.users.${cfg.user}.home;
  userData = "${home}/.config/LIVI";

  # Tools the root helper runs. livi_base::sys::tool() finds them in
  # /run/current-system/sw, so they go into systemPackages too.
  helperTools = with pkgs; [
    hostapd
    dnsmasq
    iw
    iproute2
    procps
    util-linux # rfkill
    coreutils
    avahi
    bluez
    systemd
    wireless-regdb
  ];

  udevRules = pkgs.runCommand "livi-udev-rules" {} ''
    mkdir -p $out/lib/udev/rules.d
    substitute ${res}/99-LIVI.rules.template $out/lib/udev/rules.d/99-LIVI.rules \
      --replace-fail /usr/local/lib/livi/livi-touch-filter ${res}/livi-touch-filter \
      --replace-fail /sbin/sysctl ${pkgs.procps}/bin/sysctl
  '';

  # The paths livi-core looks for (see livi-core/src/system/{power,wifi_ap}.rs).
  powerHelper = pkgs.writeShellScript "livi-power.sh" ''
    set -euo pipefail
    case "''${1:-}" in
      poweroff) ${pkgs.systemd}/bin/systemctl poweroff ;;
      reboot)   ${pkgs.systemd}/bin/systemctl reboot ;;
      *) echo "usage: livi-power.sh poweroff|reboot" >&2; exit 2 ;;
    esac
  '';

  # livi-core resolves systemctl through livi_base::sys::tool(); depending on
  # whether sw/sbin carries it that is either of these.
  systemctls = ["/run/current-system/sw/bin/systemctl" "/run/current-system/sw/sbin/systemctl"];

  settingsFormat = pkgs.formats.json {};
  settingsFile = settingsFormat.generate "livi-settings.json" cfg.settings;
  stationsFile = settingsFormat.generate "livi-fm-stations.json" (map (st: {
      inherit (st) khz name favorite;
    })
    cfg.fm.stations);
  applySettings = pkgs.writeShellScript "livi-apply-settings" (''
      set -euo pipefail
      f=${lib.escapeShellArg userData}/config.json
      mkdir -p "$(dirname "$f")"
      if [ -s "$f" ] && ${lib.getExe pkgs.jq} -e 'type == "object"' "$f" >/dev/null 2>&1; then
        ${lib.getExe pkgs.jq} --slurpfile s ${settingsFile} '. * $s[0]' "$f" >"$f.nixos"
      else
        # LIVI fills in every key it does not find from its defaults.
        cp ${settingsFile} "$f.nixos"
      fi
      chmod 0644 "$f.nixos"
      mv "$f.nixos" "$f"
    ''
    + lib.optionalString (cfg.fm.stations != []) ''

      # FM stations: upsert the declared ones (by frequency) at the top of the
      # list livi-core keeps in state/sdr.json; scanned/starred ones stay below.
      s=${lib.escapeShellArg userData}/state/sdr.json
      mkdir -p "$(dirname "$s")"
      if ! { [ -s "$s" ] && ${lib.getExe pkgs.jq} -e '.version == 1 and (.payload | type == "object")' "$s" >/dev/null 2>&1; }; then
        echo '{"version": 1, "timestamp": "1970-01-01T00:00:00.000Z", "payload": {}}' >"$s"
      fi
      ${lib.getExe pkgs.jq} --slurpfile d ${stationsFile} '
        ($d[0]) as $decl
        | (.payload.fmStations // []) as $old
        | .payload.fmStations =
            [ $decl[] as $n
              | (($old | map(select(.khz == $n.khz)) | first) // {name: "", pi: null, hidden: false})
                + ($n | with_entries(select(.value != null)))
                + {hidden: false} ]
            + [ $old[] | select(.khz as $k | $decl | map(.khz) | index($k) | not) ]
      ' "$s" >"$s.nixos"
      chmod 0644 "$s.nixos"
      mv "$s.nixos" "$s"
    '');
in {
  options.services.livi = {
    enable = lib.mkEnableOption "LIVI, the CarPlay / Android Auto head unit";

    package = lib.mkPackageOption pkgs "livi" {};

    user = lib.mkOption {
      type = lib.types.str;
      description = "User LIVI runs as. Its ~/.config/LIVI holds config.json and pairings.";
    };

    kiosk = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Start LIVI on tty1 at boot, driving the display directly through its
          own compositor (DRM/KMS via seatd/logind), like the headless installer.
        '';
      };
      powerControl = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Let LIVI power the host off when it quits and reboot it on restart
          (kiosk only). Off by default so quitting LIVI over SSH while testing
          does not shut the board down.
        '';
      };
    };

    wifiAp = {
      interface = lib.mkOption {
        type = lib.types.str;
        default = "wlan0";
        description = "Wi-Fi interface LIVI turns into the access point for wireless projection.";
      };
      networkManagerMatch = lib.mkOption {
        type = lib.types.str;
        default = "interface-name:${cfg.wifiAp.interface}";
        defaultText = lib.literalExpression ''"interface-name:''${config.services.livi.wifiAp.interface}"'';
        example = "driver:brcmfmac";
        description = ''
          NetworkManager device match that keeps the dedicated AP interface
          unmanaged. A driver match is safer when another Wi-Fi adapter can
          briefly hold the AP's kernel name (e.g. wlan0) before udev renames it.
        '';
      };
      dedicated = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Bring the access point up at boot and keep the interface away from
          NetworkManager (LIVI's "Dedicated Interface", which settings forces to
          match). When off, LIVI starts the AP on demand.
        '';
      };
    };

    settings = lib.mkOption {
      inherit (settingsFormat) type;
      default = {};
      example = {
        country = "US";
        wirelessAaEnabled = true;
      };
      description = ''
        Keys forced into LIVI's config.json (camelCase, as LIVI writes them)
        at boot and on every switch, merged over what the UI saved. Keys not
        set here stay under the UI's control. The wifiAp options fill in
        wifiInterface and wifiDedicatedInterface: livi-core stops and disables
        livi-wifi-ap.service when its own config disagrees with them.
      '';
    };

    fm.stations = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          khz = lib.mkOption {
            type = lib.types.ints.positive;
            example = 88500;
            description = "Frequency in kHz (88.5 MHz is 88500).";
          };
          name = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Label shown in the list. null keeps the RDS name LIVI picked up.";
          };
          favorite = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Starred, i.e. a preset.";
          };
        };
      });
      default = [];
      example = [
        {
          khz = 88500;
          name = "KQED";
        }
      ];
      description = ''
        FM stations to keep in LIVI's station list, in this order at the top.
        Applied before each LIVI start (state/sdr.json); stations scanned or
        starred in the UI are kept after them.
      '';
    };

    carplay = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Configure for wireless CarPlay as well (disables bluetoothd's midi plugin).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.livi.settings = {
      wifiInterface = lib.mkDefault cfg.wifiAp.interface;
      wifiDedicatedInterface = lib.mkDefault cfg.wifiAp.dedicated;
    };

    # Applied before LIVI starts, and again whenever the settings change.
    systemd.services.livi-settings = {
      description = "Apply NixOS settings to LIVI's config.json and station list";
      wantedBy = ["multi-user.target"];
      before = lib.optional cfg.kiosk.enable "livi-kiosk.service";
      restartTriggers = [settingsFile stationsFile];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.user;
        ExecStart = applySettings;
      };
    };

    environment.systemPackages = [pkg] ++ helperTools;
    environment.sessionVariables.LIVI_SYSTEM_MANAGED = "1";

    users.users.${cfg.user} = {
      extraGroups = ["video" "render" "input" "audio" "plugdev" "dialout"] ++ lib.optional cfg.kiosk.enable "seat";
      linger = true; # PipeWire user services without a login
    };
    users.groups.plugdev = {};

    # --- udev: touch-panel filter + phone handling, and RTL-SDR access ---
    services.udev.packages = [udevRules];
    hardware.rtl-sdr.enable = true; # udev rule + blacklists the DVB driver

    systemd.tmpfiles.rules =
      [
        # livi-core checks these exact paths.
        "d /usr/local/sbin 0755 root root -"
        "d /usr/local/lib/livi 0755 root root -"
        "L+ /usr/local/sbin/livi-helperd - - - - ${helper}"
        "L+ /usr/local/lib/livi/livi-touch-filter - - - - ${res}/livi-touch-filter"
      ]
      ++ lib.optional (cfg.kiosk.enable && cfg.kiosk.powerControl)
      "L+ /usr/local/lib/livi/livi-power.sh - - - - ${powerHelper}";

    # --- sudo: what 99-LIVI-helper / 99-LIVI-wifi-ap grant on Debian ---
    security.sudo.extraRules = [
      {
        users = [cfg.user];
        commands =
          [
            {
              command = helper;
              options = ["NOPASSWD" "SETENV"];
            }
            {
              command = "/usr/local/sbin/livi-helperd --wifi-ap-teardown";
              options = ["NOPASSWD"];
            }
            {
              command = "${pkgs.procps}/bin/pkill";
              options = ["NOPASSWD"];
            }
          ]
          ++ lib.concatMap (sc:
            map (verb: {
              command = "${sc} ${verb} livi-wifi-ap.service";
              options = ["NOPASSWD"];
            }) ["start" "stop" "restart" "enable" "disable"])
          systemctls
          ++ lib.optional cfg.kiosk.powerControl {
            command = "/usr/local/lib/livi/livi-power.sh";
            options = ["NOPASSWD"];
          };
      }
    ];

    # --- Wireless projection access point ---
    systemd.services.livi-wifi-ap = {
      description = "LIVI wireless projection AP";
      after = ["network.target"];
      wantedBy = lib.mkIf cfg.wifiAp.dedicated ["multi-user.target"];
      path = helperTools;
      environment = {
        SUDO_USER = cfg.user;
        LIVI_USER_DATA = userData;
        LIVI_SYSTEM_MANAGED = "1";
      };
      serviceConfig = {
        Type = "simple";
        ExecStartPre = "${helper} --wifi-ap-claim";
        ExecStart = "${helper} --wifi-ap";
        ExecStopPost = "${helper} --wifi-ap-teardown";
        TimeoutStopSec = 8;
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
    networking.networkmanager.unmanaged = lib.mkIf cfg.wifiAp.dedicated [cfg.wifiAp.networkManagerMatch];
    # livi-helperd writes this file itself when it claims the interface, with an
    # interface-name match, and a conf.d [keyfile] key replaces the main file's.
    # Owning it keeps the match above in force (its write fails, harmlessly).
    environment.etc."NetworkManager/conf.d/99-livi-ap-unmanaged.conf" = lib.mkIf cfg.wifiAp.dedicated {
      text = "[keyfile]\nunmanaged-devices=${cfg.wifiAp.networkManagerMatch}\n";
    };
    networking.firewall.trustedInterfaces = [cfg.wifiAp.interface];

    # --- Bluetooth: car-kit class, LIVI owns HFP ---
    hardware.bluetooth = {
      enable = true;
      powerOnBoot = true;
      settings.General.Class = "0x200418";
      disabledPlugins = ["sap"] ++ lib.optional cfg.carplay "midi";
    };

    # --- Audio: PipeWire with Pulse; A2DP only so LIVI's own HFP gets SCO ---
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      pulse.enable = true;
      alsa.enable = true;
      wireplumber.extraConfig."99-livi-hfp" = {
        "monitor.bluez.properties"."bluez5.roles" = ["a2dp_sink" "a2dp_source"];
      };
    };
    security.pam.loginLimits = [
      {
        domain = cfg.user;
        type = "-";
        item = "rtprio";
        value = "30";
      }
    ];

    # --- Discovery, graphics, iPhone USB networking ---
    services.avahi = {
      enable = true;
      publish = {
        enable = true;
        userServices = true;
      };
    };
    hardware.graphics.enable = true;
    boot.kernelModules = ["cdc_ncm" "cdc_ether" "ipheth"];

    # --- Kiosk on tty1 (livi-kiosk.service.template) ---
    services.seatd.enable = cfg.kiosk.enable;
    security.pam.services.livi-kiosk = lib.mkIf cfg.kiosk.enable {startSession = true;};
    systemd.services.livi-kiosk = lib.mkIf cfg.kiosk.enable {
      description = "LIVI kiosk";
      after = ["systemd-user-sessions.service" "seatd.service" "getty@tty1.service" "bluetooth.service" "livi-settings.service"];
      wants = ["livi-settings.service"];
      # LIVI holds config and stations in memory and writes them back, so a
      # settings change restarts it around livi-settings (stop, apply, start).
      restartTriggers = [settingsFile stationsFile];
      conflicts = ["getty@tty1.service"];
      wantedBy = ["multi-user.target"];
      environment = {
        LIVI_KIOSK = "1";
        LIVI_SYSTEM_MANAGED = "1";
      };
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        PAMName = "livi-kiosk";
        WorkingDirectory = home;
        TTYPath = "/dev/tty1";
        TTYReset = "yes";
        TTYVHangup = "yes";
        StandardInput = "tty-fail";
        StandardOutput = "journal";
        StandardError = "journal";
        ExecStart = lib.getExe pkg;
        LimitRTPRIO = 30;
        Restart = "on-failure";
        RestartSec = 2;
      };
    };
  };
}
