# SteamTools (Watt Toolkit) —— NixOS 不可变系统适配包
#
# 架构：
#   outputs = [ out accelerator ssl ]
#     out        : 主程序（watt-toolkit，GUI + 插件 UI），Wrapper 注入运行时
#     accelerator: 完整加速器模块（目录发布），供 systemd 系统服务运行
#     ssl        : openssl 生成的系统根证书（cer 供 security.pki.certificateFiles 信任，
#                  pfx 供主程序启动时同步到 AppData，保证代理私钥与系统信任一致）
#
# 设计要点（NixOS 不可变特性）：
#   1. 加速器不以子进程方式随 GUI 启动，由系统级 systemd 服务（空闲，UI 点击时
#      systemctl start 拉起）运行，AmbientCapabilities 注入 cap_net_bind_service 等，
#      以普通用户身份监听 443，无需 root / fhsenv / setcap（capset 在 NixOS 返回 EPERM）。
#   2. 证书由打包期 openssl 生成到 ssl output，系统声明式信任（security.pki.certificateFiles），
#      flake 不保存私钥，证书状态不属于 flake 保证范围（漂移是预设计）。
#   3. /etc/hosts 由声明式配置管理（networking.hosts），运行时不可写；加速器的 Hosts
#      条目在 NixOS 分支下写入 AppData 供合并进系统配置。
#   4. 入口 wrapper 直接运行 dotnet + Steam++.dll（目录发布），不依赖 fhsenv。
#
# 版本来源说明：
#   默认 src = 官方 GitHub Releases 3.1.0 linux_x64 tgz（sha256 固定，可复现）。
#   ⚠️ 官方 release 是「纯净版」，不包含 NixOS 分支适配（服务式加速器 / 证书 store 直读 /
#      hosts dump）。因此：
#     - GUI 主程序：可用（wrapper 注入运行时）。
#     - 加速器系统服务（accelerator 输出）：官方包若为 SingleFile 形态，需要分支发布
#       （目录发布 + .dll）才能由 systemd 的 dotnet 直接运行；分支适配经上游合并并发布
#       新版本后，把下方 url/sha256 更新为新官方包即可。
#   自用分支构建（含全部 NixOS 适配）可覆盖参数：
#     pkgs.callPackage ./package.nix {
#       src = pkgs.fetchurl { url = "https://oazcc.qzapp.qkzy.net/Steam++.tgz"; sha256 = "..."; };
#     }
#   或在 flake 层 --override-input 替换。

{ pkgs
, stdenv
, lib
, src ? null
, sha256 ? null
, ...
}:

let
  # 官方发布包源（nixpkgs 提交/上游测试路径；可被 src/sha256 参数覆盖）
  publishUrl = "https://github.com/Aozora-Wings/SteamTools-nixos/releases/download/nixos-build/Steam++_linux_x64_nixos.tgz";
  publishSha256 = "735abf809b581b68d345ac01bf50e4a8f0cb157b3cc83105076ee2b71c8371ec";

  dotnet-sdk_11 = pkgs.dotnetCorePackages.sdk_11_0;

  # 主程序运行时原生依赖（原 fhsEnv targetPkgs 清单，经 makeWrapper 注入 LD_LIBRARY_PATH）
  runtimeLibs = with pkgs; [
    glibc
    zlib
    openssl
    libGL
    libICE
    libSM
    libX11
    libXcursor
    libXext
    libXi
    libXrandr
    libXrender
    libXfixes
    libXdamage
    libXcomposite
    libxkbcommon
    gtk3
    glib
    at-spi2-core
    gdk-pixbuf
    cairo
    pango
    fontconfig.lib
    lttng-ust
    icu74
    libunwind
    libuuid
    krb5
    curl
    alsa-lib
    pulseaudio
  ];

in
stdenv.mkDerivation {
  pname = "watt-toolkit";
  version = "3.1.0";

  # 声明多个输出：out（主程序）/ accelerator（加速子进程）/ ssl（系统根证书）
  outputs = [ "out" "accelerator" "ssl" ];

  src = if src != null then src else pkgs.fetchurl {
    url = publishUrl;
    sha256 = if sha256 != null then sha256 else publishSha256;
  };

  dontConfigure = true;
  # 发布 tgz 解压为多个顶层条目（Icons/ modules/ script/ native/ 等），
  # 无单一包目录：跳过 findSourceRoot，installPhase 直接使用解压后的工作目录。
  sourceRoot = ".";
  dontBuild = true;
  # 关键：nix stdenv 默认 strip 会重写 ELF 并丢弃尾部 SingleFile bundle
  # （Steam++.Accelerator 是 15.5MB 单文件，strip 后只剩 59KB → bundle 损坏）。
  dontStrip = true;

  nativeBuildInputs = [ pkgs.makeWrapper pkgs.patchelf pkgs.openssl ];

  installPhase = ''
    runHook preInstall

    # ---- ssl output：生成系统根证书（打包证书源） ----
    # 与软件 CertGenerator 生成的主题/用途保持一致（CN=SteamTools Certificate, CA:TRUE, SHA256, 300 天）。
    # rebuild 后系统 security.pki.certificateFiles 信任新 cer；应用启动时经入口 wrapper
    # 的 STEAMTOOLS_BUNDLED_PFX 把同一把 PFX 同步到 AppData，保证代理私钥与系统信任一致。
    mkdir -p $ssl
    openssl req -x509 -newkey rsa:2048 -sha256 -days 300 -nodes \
      -keyout $ssl/SteamTools.Certificate.key.pem \
      -out $ssl/SteamTools.Certificate.cer \
      -subj "/C=CN/O=BeyondDimension/OU=Technical Department/CN=SteamTools Certificate" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,digitalSignature,keyCertSign,cRLSign" \
      -addext "extendedKeyUsage=serverAuth,clientAuth"
    openssl pkcs12 -export \
      -inkey $ssl/SteamTools.Certificate.key.pem \
      -in $ssl/SteamTools.Certificate.cer \
      -out $ssl/SteamTools.Certificate.pfx \
      -passout pass:
    rm -f $ssl/SteamTools.Certificate.key.pem
    chmod 644 $ssl/SteamTools.Certificate.cer $ssl/SteamTools.Certificate.pfx
    echo "已生成系统根证书: $ssl/SteamTools.Certificate.cer / .pfx"

    # ---- 主程序（out output） ----
    mkdir -p $out
    cp -r ./* $out/
    mkdir -p $out/assemblies
    mv $out/*.dll $out/assemblies/ 2>/dev/null || true
    if [ -f "$out/Steam++.dll" ]; then
      mv $out/Steam++.dll $out/assemblies/
    fi

    # SkiaSharp 2.88 native resolver 只搜 app 目录/固定路径（不认 ../native/<rid>、不走 LD_LIBRARY_PATH）：
    # 必须把发布工具移出的原生库平铺回 assemblies/，同时保留 runtimes 布局（deps.json 声明）。
    chmod -R u+w $out/assemblies
    if [ -d "./native/linux-x64" ]; then
      mkdir -p $out/assemblies/runtimes/linux-x64/native
      cp -v ./native/linux-x64/*.so $out/assemblies/
      cp -v ./native/linux-x64/*.so $out/assemblies/runtimes/linux-x64/native/
    fi

    # ---- 关键修复：out/modules/Accelerator/ 只保留插件 UI 入口及其非 Avalonia 依赖 ----
    # 插件系统在独立 ALC 中从模块目录 LoadFrom。若模块目录存在 Steam++.Accelerator.dll
    # （加速器服务本体）或 Avalonia/BD.Common 等运行时副本，会与主程序 assemblies/ 形成
    # 双实例，导致 StandardAssetLoader 资源解析错乱（avares FileNotFoundException，UI 启动崩溃）。
    # 加速器服务本体由 $accelerator 输出（完整模块）供 systemd 服务运行，主程序包不携带。
    if [ -d "$out/modules/Accelerator" ]; then
      chmod -R u+w $out/modules/Accelerator
      (cd $out/modules/Accelerator && \
        find . -maxdepth 1 -type f \
          ! -name 'BD.WTTS.Client.Plugins.Accelerator.dll' \
          ! -name 'BD.WTTS.Primitives.dll' \
          ! -name 'BD.WTTS.Primitives.Models.dll' \
          ! -name 'BD.WTTS.Primitives.Resources.dll' \
          ! -name 'BD.WTTS.MicroServices.Primitives.dll' \
          ! -name 'BD.WTTS.MicroServices.Primitives.Models.dll' \
          ! -name 'BD.WTTS.MicroServices.Primitives.Resources.dll' \
          ! -name 'BD.WTTS.Client.IPC.dll' -delete \
        && rm -rf en es it ja ko ru zh-Hant)
      echo "out/modules/Accelerator/ 精简为插件入口+依赖: $(ls $out/modules/Accelerator | wc -l) 文件"
    fi

    # 入口 wrapper：优先官方包 bundled dotnet —— 官方 3.1.0 的 runtimeconfig 请求 net10.0，
    # bundled dotnet（10.0.4）完全匹配（与官方 Steam++.sh 启动方式一致：DOTNET_ROOT 指向包内
    # dotnet，直接运行 assemblies/Steam++.dll），避免桌面端"找不到框架"（nix dotnet 版本不匹配）。
    # 分支包（无 dotnet/ 目录，runtimeconfig 请求 net11 preview）退回 nix dotnet-sdk。
    mkdir -p $out/bin
    if [ -x "$out/dotnet/dotnet" ]; then
      chmod -R u+w $out/dotnet
      chmod +x $out/dotnet/dotnet 2>/dev/null || true
      DOTNET_BIN="$out/dotnet/dotnet"
      DOTNET_ROOT="$out/dotnet"
    else
      DOTNET_BIN="${dotnet-sdk_11}/bin/dotnet"
      DOTNET_ROOT="${dotnet-sdk_11}/share/dotnet"
    fi
    makeWrapper "$DOTNET_BIN" $out/bin/watt-toolkit \
      --set DOTNET_ROOT "$DOTNET_ROOT" \
      --set DOTNET_SYSTEM_GLOBALIZATION_INVARIANT "1" \
      --set STEAMTOOLS_BUNDLED_PFX "$ssl/SteamTools.Certificate.pfx" \
      --run 'export XDG_DATA_HOME="$HOME/.local/share/WattToolkit"' \
      --prefix PATH : "${dotnet-sdk_11}/bin:${pkgs.nss_latest}/bin" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath runtimeLibs}:$DOTNET_ROOT" \
      --add-flags "$out/assemblies/Steam++.dll"
    echo "Watt Toolkit 已安装到: $out/bin/watt-toolkit (dotnet: $DOTNET_BIN)"

    # ---- Accelerator（accelerator output，NixOS 目录发布） ----
    # 加速器在 NixOS 分支构建时改为目录发布（发布工具检测 /etc/NIXOS 设 SingleFile=false）：
    # SingleFile apphost 在 NixOS 加载运行时失败（宿主退出码 203），目录发布后由
    # systemd 服务用 dotnet 直接运行 Steam++.Accelerator.dll（与主程序目录发布一致）。
    # ⚠️ 官方纯净 release 若为 SingleFile 形态（无 .dll），accelerator 输出只复制可执行，
    #    需分支发布（上游合并 NixOS 补丁后的版本）才能支持 systemd 服务运行。
    mkdir -p $accelerator
    if [ -d "./modules/Accelerator" ]; then
      cp -r "./modules/Accelerator"/* $accelerator/
      chmod -R u+w $accelerator
      chmod 755 $accelerator/Steam++.Accelerator 2>/dev/null || true
      echo "已复制加速器目录（目录发布）:"
      ls $accelerator | head -25
    else
      echo "警告: 未找到 modules/Accelerator 目录"
      find . -iname '*Accelerator*' 2>/dev/null || true
    fi

    runHook postInstall
  '';

  meta = {
    description = "Watt Toolkit (Steam++) - 开源跨平台多功能游戏工具箱";
    homepage = "https://steampp.net";
    license = lib.licenses.gpl3Only;
    mainProgram = "watt-toolkit";
    platforms = [ "x86_64-linux" ];
  };
}
