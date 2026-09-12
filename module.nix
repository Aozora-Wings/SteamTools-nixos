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
#   };
#
# 对应现网部署（nixos-config/modules/system/security/default.nix 中
# systemd.services.steampp-accelerator + polkit 规则的独立可复用形式）。
# 兼容旧用法：services.steamtools = { ... } 仍可用（映射到同一配置）。

{ lib, config, pkgs, ... }:

let
  cfg = config.programs.watt-toolkit;
  legacyCfg = config.services.steamtools;
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
      serviceName = lib.mkDefault legacyCfg.serviceName;
    };

    environment.systemPackages = [ cfg.package ];

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
      };
      # 不设置 wantedBy：服务保持空闲，仅当 UI 点击加速模块时才被拉起。
    };

    # polkit：允许主用户无密码启停加速器服务（主程序以主用户身份执行 systemctl start）。
    security.polkit.extraConfig = lib.mkIf cfg.enablePolkit ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            subject.user == "${cfg.user}" &&
            action.lookup("unit") == "${cfg.serviceName}.service") {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
