# NixOS 模块：programs.watt-toolkit（Steam++ / Watt Toolkit）
#
# 用法（在 nixos-config 的 configuration 中）：
#   imports = [ steamtools-flake.nixosModules.default ];
#   programs.watt-toolkit = {
#     enable = true;
#     user = "wt";            # 加速器服务运行用户（不能是 root）
#     enableAcceleratorService = true;   # 系统级加速器服务（空闲，UI 点击时拉起）
#     trustCertificate = true;           # security.pki.certificateFiles 信任打包证书
#     enablePolkit = true;               # 允许主用户无密码启停加速器服务
#     proxyMode = "hosts";    # 加速模式：hosts（静态域名，默认）| dns（全局 dnsmasq 动态劫持）
#   };
#
# 对应现网部署（nixos-config/modules/system/security/default.nix 中
# systemd.services.steampp-accelerator + polkit 规则的独立可复用形式）。
# 兼容旧用法：services.steamtools = { ... } 仍可用（映射到同一配置）。

{ lib, config, pkgs, ... }:

let
  cfg = config.programs.watt-toolkit;
  legacyCfg = config.services.steamtools;

  # dns 模式：加速器服务启停时更新 dnsmasq 域名映射的 root oneshot 服务
  dnsUpdateScript = pkgs.writeShellScript "watt-toolkit-dns-update" ''
    set -e
    mkdir -p /run/dnsmasq.d
    if [ -f /run/watt-toolkit/domains.conf ]; then
      # 每行一个域名 → address=/域名/127.0.0.1
      sed 's|^|address=/|; s|$|/127.0.0.1|' /run/watt-toolkit/domains.conf > /run/dnsmasq.d/steampp.conf
    else
      : > /run/dnsmasq.d/steampp.conf
    fi
    systemctl reload dnsmasq || true
  '';
in
{
  options.programs.watt-toolkit = {
    enable = lib.mkEnableOption "Watt Toolkit (Steam++)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.watt-toolkit;
      defaultText = lib.literalExpression "pkgs.watt-toolkit";
      description = "Watt Toolkit 包（需包含 out / accelerator / ssl 三个输出）。";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "wt";
      description = "加速器系统服务的运行用户（不能为 root；AmbientCapabilities 由 root systemd 注入）。";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "users";
      description = "加速器系统服务的运行组。";
    };

    enableAcceleratorService = lib.mkEnableOption ''
      加速器系统级 systemd 服务（空闲，由主程序 UI 点击加速时 systemctl start 触发；
      AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_NET_ADMIN 使普通用户
      可监听 443，无需 root/fhsenv/setcap）''
    ;

    trustCertificate = lib.mkEnableOption ''
      将打包生成的 SteamTools 根证书（ssl 输出）加入 security.pki.certificateFiles
      （NixOS 声明式证书信任，加速器代理证书与系统信任一致）''
    ;

    enablePolkit = lib.mkEnableOption ''
      允许 ${cfg.user} 无密码启停加速器服务（主程序点击加速时 systemctl start 所需）''
    ;

    proxyMode = lib.mkOption {
      type = lib.types.enum [ "hosts" "dns" ];
      default = "hosts";
      description = ''
        加速代理模式：
        - hosts：静态域名劫持（默认）。域名列表由本模块/系统配置静态写入
          （当前仅覆盖 Steam 平台域名），加速器监听 443 做 HTTPS 中间人。
        - dns：全局 dnsmasq 动态劫持。启用 dnsmasq 作为系统解析器
          （networking.nameservers=127.0.0.1，NetworkManager dns=none 禁用 DHCP 下发 DNS），
          主程序点击加速时把选中平台的监听域名列表写入 /tmp/steampp-domains.conf，
          由加速器服务 ExecStartPost 联动 root oneshot 服务更新
          /run/dnsmasq.d/steampp.conf（address=/域名/127.0.0.1）并 reload dnsmasq，
          选中域名走本地加速器、其他域名由 dnsmasq 转发上游直连；
          停止加速时自动撤销映射恢复直连。接口无关（多 WiFi/有线通用）。
      '';
    };

    serviceName = lib.mkOption {
      type = lib.types.str;
      default = "steampp-accelerator";
      description = "加速器 systemd 服务名（与主程序 NixOS 分支 StartupNixOS.SERVICE_NAME 一致）。";
    };
  };

  # 向后兼容：services.steamtools = { ... } 映射到 programs.watt-toolkit
  options.services.steamtools = {
    enable = lib.mkEnableOption "SteamTools (Watt Toolkit)（旧名，已迁移到 programs.watt-toolkit）";
    package = lib.mkOption { type = lib.types.package; };
    user = lib.mkOption { type = lib.types.str; default = "wt"; };
    group = lib.mkOption { type = lib.types.str; default = "users"; };
    enableAcceleratorService = lib.mkEnableOption "加速器系统服务（同 programs.watt-toolkit）";
    trustCertificate = lib.mkEnableOption "证书信任（同 programs.watt-toolkit）";
    enablePolkit = lib.mkEnableOption "polkit 授权（同 programs.watt-toolkit）";
    proxyMode = lib.mkOption { type = lib.types.enum [ "hosts" "dns" ]; default = "hosts"; };
    serviceName = lib.mkOption { type = lib.types.str; default = "steampp-accelerator"; };
  };

  config = lib.mkIf (cfg.enable || legacyCfg.enable) {
    # 合并：programs 优先，services.steamtools 作为兼容层填充
    programs.watt-toolkit = lib.mkIf legacyCfg.enable {
      package = lib.mkDefault legacyCfg.package;
      user = lib.mkDefault legacyCfg.user;
      group = lib.mkDefault legacyCfg.group;
      enableAcceleratorService = lib.mkDefault legacyCfg.enableAcceleratorService;
      trustCertificate = lib.mkDefault legacyCfg.trustCertificate;
      enablePolkit = lib.mkDefault legacyCfg.enablePolkit;
      proxyMode = lib.mkDefault legacyCfg.proxyMode;
      serviceName = lib.mkDefault legacyCfg.serviceName;
    };

    environment.systemPackages = [ cfg.package ];

    # 系统配置代理模式：主程序启动时读取，决定加速行为（/etc/watt-toolkit/proxy-mode）。
    # NixOS 声明式生成，只读；主程序侧 StartupNixOS 读取该文件。
    environment.etc."watt-toolkit/proxy-mode".text = cfg.proxyMode;

    # NixOS 声明式证书信任：rebuild 后系统信任打包生成的 cer；
    # 应用启动时经 wrapper STEAMTOOLS_BUNDLED_PFX 同步同一 PFX 到 AppData。
    security.pki.certificateFiles = lib.mkIf cfg.trustCertificate [
      "${cfg.package.ssl}/SteamTools.Certificate.cer"
    ];

    systemd.services.${cfg.serviceName} = lib.mkIf cfg.enableAcceleratorService {
      description = "Steam++ (Watt Toolkit) Accelerator";
      after = [ "network.target" ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        # 主程序点击加速时写入：STEAMPP_PIPE / STEAMPP_PID / STEAMPP_MODEL
        EnvironmentFile = "/tmp/steampp-accel.env";
        Environment = [
          "DOTNET_ROOT=${pkgs.dotnetCorePackages.sdk_11_0}/share/dotnet"
          "STEAMPP_PROXY_MODE=${cfg.proxyMode}"
          # 打包证书源：服务进程直接读取 nix store 最新 PFX（rebuild 自动跟随新 store 路径），
          # 与系统 security.pki.certificateFiles 信任的 cer 保持同一把密钥，避免漂移不一致。
          "STEAMTOOLS_BUNDLED_PFX=${cfg.package.ssl}/SteamTools.Certificate.pfx"
        ];
        ExecStart = "${pkgs.dotnetCorePackages.sdk_11_0}/bin/dotnet ${cfg.package.accelerator}/Steam++.Accelerator.dll $STEAMPP_PIPE $STEAMPP_PID $STEAMPP_MODEL";
        # root systemd 在服务进程（主用户身份）上设置 ambient capabilities，
        # 加速器因此可监听 443 而不需要以 root 运行。
        AmbientCapabilities = "CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_NET_ADMIN";
        Restart = "on-failure";
        RestartSec = 1;
        # 供 dns 模式联动脚本写域名映射（/run/watt-toolkit，属主为服务用户）
        RuntimeDirectory = "watt-toolkit";
      };
      # dns 模式：启动/停止时更新 dnsmasq 域名映射（root oneshot 服务写 /run/dnsmasq.d）
      serviceConfig.ExecStartPost = lib.mkIf (cfg.proxyMode == "dns") [
        "-${pkgs.coreutils}/bin/cp -f /tmp/steampp-domains.conf /run/watt-toolkit/domains.conf"
        "${pkgs.systemd}/bin/systemctl start watt-toolkit-dns-update.service"
      ];
      serviceConfig.ExecStopPost = lib.mkIf (cfg.proxyMode == "dns") [
        "${pkgs.coreutils}/bin/rm -f /run/watt-toolkit/domains.conf"
        "${pkgs.systemd}/bin/systemctl start watt-toolkit-dns-update.service"
      ];
      # 不设置 wantedBy：服务保持空闲，仅当 UI 点击加速模块时才被拉起。
    };

    # dns 模式：root oneshot，把加速器域名列表写入 dnsmasq 配置并 reload
    systemd.services.watt-toolkit-dns-update = lib.mkIf (cfg.enableAcceleratorService && cfg.proxyMode == "dns") {
      description = "Watt Toolkit DNS 映射更新（dnsmasq）";
      after = [ "dnsmasq.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };
      script = "${dnsUpdateScript}";
    };

    # dns 模式：全局 dnsmasq 作为系统解析器（接口无关，多 WiFi/有线通用）
    services.dnsmasq = lib.mkIf (cfg.enableAcceleratorService && cfg.proxyMode == "dns") {
      enable = true;
      # dnsmasq 额外读取 /run/dnsmasq.d/*.conf（root oneshot 服务写入的域名映射）
      settings = {
        conf-dir = "/run/dnsmasq.d,*.conf";
        domain-needed = true;
        bogus-priv = true;
        # 上游转发：选中域名以外的所有查询直连上游 DNS
        server = [ "223.5.5.5" "119.29.29.29" "8.8.8.8" ];
      };
    };

    # dns 模式：系统解析器全局指向 dnsmasq；NetworkManager 不管理 DNS（禁 DHCP 下发）
    networking.nameservers = lib.mkIf (cfg.enableAcceleratorService && cfg.proxyMode == "dns") [ "127.0.0.1" ];
    networking.networkmanager.settings = lib.mkIf (cfg.enableAcceleratorService && cfg.proxyMode == "dns") {
      main.dns = "none";
    };

    # polkit：允许主用户无密码启停加速器服务与 dns 更新服务（主程序以主用户身份执行 systemctl）。
    security.polkit.extraConfig = lib.mkIf cfg.enablePolkit ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            subject.user == "${cfg.user}" &&
            (action.lookup("unit") == "${cfg.serviceName}.service" ||
             action.lookup("unit") == "watt-toolkit-dns-update.service" ||
             action.lookup("unit") == "dnsmasq.service")) {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
