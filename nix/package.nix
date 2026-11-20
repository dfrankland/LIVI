# LIVI for Nix/NixOS.
#
# Builds the five host binaries the same way `cargo xtask build-native` does,
# then lays them out like the AppImage's `resources/` tree so livi-core finds
# everything through LIVI_RESOURCES. Differences from the AppImage:
#
#   - GStreamer comes from nixpkgs, not the prebuilt bundle. With no
#     `resources/gstreamer/<platform>` dir livi-core leaves the plugin
#     environment alone, so the wrappers set GST_PLUGIN_SYSTEM_PATH_1_0.
#   - Libraries the UI and compositor dlopen (EGL, Wayland, xkbcommon,
#     fontconfig) are added to their RPATH, since there is no /usr/lib.
#   - Run it with LIVI_SYSTEM_MANAGED=1 (the NixOS module does) so it does not
#     try to install udev rules, sudoers or units into a read-only /etc.
{
  lib,
  rustPlatform,
  pkg-config,
  cmake,
  makeWrapper,
  patchelf,
  openssl,
  gst_all_1,
  wayland,
  libxkbcommon,
  fontconfig,
  freetype,
  udev,
  libinput,
  seatd,
  libgbm,
  libdrm,
  libGL,
  libglvnd,
  libx11,
  libxcursor,
  libxi,
  libxrandr,
  # runtime tools livi-core calls by name
  bash,
  coreutils,
  procps,
  pulseaudio,
  systemd,
  version ? "10.5.0",
}: let
  gstPlugins = with gst_all_1; [
    gstreamer
    gst-plugins-base
    gst-plugins-good # pulsesink/pulsesrc, rtp, v4l2 decoders
    gst-plugins-bad # h264parse/h265parse, va, waylandsink, openh264
    gst-plugins-ugly
    gst-libav # avdec_h264/aac/alac
  ];

  # dlopen()ed at runtime by winit/glutin/femtovg (livi-ui) and smithay
  # (livi-compositor).
  dlopenLibs = [
    libglvnd
    libGL
    wayland
    libxkbcommon
    fontconfig
    freetype
    libgbm
    libdrm
    libx11
    libxcursor
    libxi
    libxrandr
  ];

  runtimePath = [
    bash
    coreutils
    procps # pgrep, pkill
    pulseaudio # pactl
    gst_all_1.gstreamer # gst-inspect
    gst_all_1.gst-plugins-base # gst-device-monitor-1.0
    fontconfig # fc-list
    systemd # busctl, systemctl
  ];

  bins = ["livi-core" "livi-helperd" "livi-output" "livi-compositor" "LIVI"];
in
  rustPlatform.buildRustPackage {
    pname = "livi";
    inherit version;

    src = lib.fileset.toSource {
      root = ./..;
      fileset = lib.fileset.unions [
        ../native
        # include_str!()ed by livi-wifi / livi-link-host (AP and dongle configs)
        ../scripts/livi-link/common/rootfs/etc/hostapd.conf
        ../scripts/livi-link/common/initramfs/net-up
        ../assets/linux
        ../assets/displays
        ../assets/icons/linux
        ../LICENSE
        ../NOTICE
      ];
    };

    cargoRoot = "native";
    buildAndTestSubdir = "native";
    # fetchCargoVendor rather than importCargoLock: the lockfile has nusb 0.2.9
    # twice (crates.io, and the Android-only git fork), and importCargoLock
    # vendors by name-version so the two collide. Bump this on Cargo.lock changes.
    cargoHash = "sha256-RRaTBoLaVeODfcRmb36ZpbICjkQyJIqR38RHdDVK+6M=";

    cargoBuildFlags = map (p: "--package=${p}") [
      "livi-core"
      "livi-helperd"
      "livi-output"
      "livi-ui"
      "livi-compositor"
    ];

    # Many tests touch the host (sockets, /sys, BlueZ); CI runs them on Debian.
    doCheck = false;

    env = {
      LIVI_VERSION = version;
      BUILD_SHA = "nix";
      LIVI_BUILD_SHA = "nix";
      LIVI_BUILD_DATE = "1970-01-01";
    };

    nativeBuildInputs = [
      pkg-config
      cmake # aws-lc-sys
      makeWrapper
      patchelf
      rustPlatform.bindgenHook
    ];

    buildInputs =
      [
        openssl
        udev
        libinput
        seatd
      ]
      ++ dlopenLibs
      ++ gstPlugins;

    # cargoInstallHook drops every binary into $out/bin. Rearrange them into the
    # tree livi-core expects (see livi-core/src/resources.rs, `installed`).
    postInstall = ''
      app=$out/lib/livi
      res=$app/resources
      mkdir -p $res/{core,driver,output,compositor}

      mv $out/bin/LIVI            $app/livi-ui
      mv $out/bin/livi-core       $res/core/livi-core
      mv $out/bin/livi-helperd    $res/driver/livi-helperd
      mv $out/bin/livi-output     $res/output/livi-output
      mv $out/bin/livi-compositor $res/compositor/livi-compositor
      rm -rf $out/bin/*

      for f in 99-LIVI.rules.template 99-LIVI-helper.sudoers.template \
               livi-wifi-ap.service.template 99-LIVI-wifi-ap.sudoers.template \
               livi-kiosk.service.template livi-touch-filter; do
        install -m644 assets/linux/$f $res/$f
      done
      chmod +x $res/livi-touch-filter
      patchShebangs $res/livi-touch-filter
      cp -r assets/displays $res/displays
      install -m644 LICENSE NOTICE -t $res

      install -Dm644 assets/linux/dev.f-io.livi.metainfo.xml \
        $out/share/metainfo/dev.f-io.livi.metainfo.xml
      install -Dm644 assets/icons/linux/livi.png $out/share/icons/hicolor/512x512/apps/livi.png
    '';

    postFixup = ''
      res=$out/lib/livi/resources
      for f in $out/lib/livi/livi-ui $res/compositor/livi-compositor $res/output/livi-output; do
        patchelf --add-rpath ${lib.makeLibraryPath dlopenLibs} "$f"
      done

      gst=(--prefix GST_PLUGIN_SYSTEM_PATH_1_0 : ${lib.makeSearchPathOutput "lib" "lib/gstreamer-1.0" gstPlugins})

      # livi-output is a child of livi-core; makeWrapper's `exec -a "$0"` keeps
      # its argv[0] so livi-core's `pgrep -f` checks still match.
      wrapProgram $res/output/livi-output "''${gst[@]}"

      wrapProgram $res/core/livi-core "''${gst[@]}" \
        --set-default LIVI_RESOURCES $res \
        --prefix PATH : ${lib.makeBinPath runtimePath}

      # livi-helperd is NOT wrapped: it runs via `sudo -n -E <path>` and is
      # matched by `pgrep -f driver/livi-helperd$`. It finds its tools through
      # livi_base::sys::tool(), which also searches /run/current-system/sw.

      # `livi` starts the head unit, `livi telemetry ...` pushes test data, as
      # with the AppImage.
      mkdir -p $out/bin
      ln -s $res/core/livi-core $out/bin/livi
      ln -s $res/core/livi-core $out/bin/livi-core
    '';

    passthru = {inherit gstPlugins dlopenLibs;};

    meta = {
      description = "Linux In-Vehicle Infotainment: native CarPlay and Android Auto head unit";
      homepage = "https://github.com/f-io/LIVI";
      license = lib.licenses.gpl3Plus;
      platforms = lib.platforms.linux;
      mainProgram = "livi";
    };
  }
