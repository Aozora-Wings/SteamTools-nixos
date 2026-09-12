# SteamTools (Watt Toolkit) — NixOS 优化适配分支

本项目是 **SteamTools（Watt Toolkit，原 Steam++）官方源码的 NixOS 适配分支**，解决不可变系统（NixOS）下的三个核心问题：

1. **声明式打包**：`flake.nix` + `package.nix` 提供 `out`（主程序 GUI）/ `accelerator`（加速器系统服务）/ `ssl`（系统根证书）三输出包；
2. **系统级加速器服务**：加速器不以子进程随 GUI 启动，由 `programs.watt-toolkit` 模块配置的 systemd 服务运行（空闲，UI 点击时拉起），`AmbientCapabilities` 注入 `cap_net_bind_service` 等，普通用户即可监听 443，无需 root / fhsenv / setcap；
3. **版本锁定 + CI 自动发布**：`flake.lock` 锁定 nixpkgs revision；GitHub Actions 每次构建成功后自动上传 Release 并**回填 `package.nix` 的 url / sha256**（运行版本与构建版本一致，防漂移）。

## 分支与文件

| 路径 | 说明 |
| --- | --- |
| `nixos-branch` | 官方源码 + NixOS 适配补丁 + CI workflow |
| `steamtools-nixos-branch.patch` | NixOS 适配补丁（`git apply` 可应用） |
| `flake.nix` / `flake.lock` | 可直接 import 的 flake（包 + NixOS 模块 + 开发环境） |
| `package.nix` | 包定义（url/sha256 由 CI 自动回填） |
| `module.nix` | `programs.watt-toolkit` 模块（服务/证书/polkit） |
| `.github/workflows/nixos-branch-build.yml` | CI：构建发布 linux-x64 → 上传 Release → 回填 url/sha256 |

## NixOS 使用（直接 import 本 flake）

在 nixos-configuration 中：

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    steamtools = {
      url = "github:Aozora-Wings/SteamTools-nixos/nixos-branch";
      # 国内网络可换镜像源（与 nixpkgs 同法）：
      # url = "git+https://mirrors.nju.edu.cn/git/SteamTools-nixos.git?ref=nixos-branch";
    };
  };

  outputs = { nixpkgs, steamtools, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        steamtools.nixosModules.default
        ({ pkgs, ... }: {
          programs.watt-toolkit = {
            enable = true;
            # 默认已指向 steamtools.packages.${pkgs.system}.default，可显式覆盖：
            # package = steamtools.packages.${pkgs.system}.default;
            user = "wt";                       # 加速器服务运行用户（不能是 root）
            enableAcceleratorService = true;   # 系统级加速器服务（空闲，UI 点击时拉起）
            trustCertificate = true;           # security.pki.certificateFiles 信任打包根证书
            enablePolkit = true;               # 允许主用户无密码启停加速器服务
          };
        })
      ];
    };
  };
}
```

### 调用例子（简写）

```nix
# 只装软件（不带服务）：
environment.systemPackages = [ steamtools.packages.${pkgs.system}.default ];

# 只用模块（含加速器服务 + 证书信任 + polkit）：
imports = [ steamtools.nixosModules.watt-toolkit ];
programs.watt-toolkit.enable = true;

# 旧名兼容：
services.steamtools.enable = true;   # 映射到同一配置
```

## 输出说明

| 输出 | 内容 | 用途 |
| --- | --- | --- |
| `out` | 主程序（watt-toolkit GUI，wrapper 注入运行时） | `environment.systemPackages` |
| `accelerator` | 加速器模块（目录发布，含 `Steam++.Accelerator.dll`） | systemd 服务 `ExecStart` |
| `ssl` | openssl 生成的系统根证书（cer + pfx） | `security.pki.certificateFiles` / 应用启动同步 AppData |

## CI 自动回填（url / sha256）

`.github/workflows/nixos-branch-build.yml` 构建成功后自动：

1. 计算 tgz 的 sha256；
2. 上传到 GitHub Release（固定 tag `nixos-build`，固定文件名 `Steam++_linux_x64_nixos.tgz`，URL 稳定）；
3. 回填 `package.nix` 的 `publishUrl` / `publishSha256`；
4. `[skip ci]` 提交推送（不触发循环构建）。

**前置要求**：仓库 Actions 需要 **Read and write** 权限（`Settings → Actions → General → Workflow permissions → Read and write permissions`），否则 Release 上传 / 回填提交会失败。

## 开发测试环境

```sh
nix develop        # 进入（.NET SDK 11 preview + 构建/发布工具链）
git apply ./steamtools-nixos-branch.patch
dotnet build src/BD.WTTS.Client.Tools.Publish -c Release -t:Rebuild -p:UseSharedCompilation=false
cd src/BD.WTTS.Client.Tools.Publish/bin/Release/net11.0
dotnet pub.dll run --rids linux-x64
```

## 许可证

上游项目为 GPL-3.0-only，本分支同样遵循（见 `LICENSE` / 上游 [BeyondDimension/SteamTools](https://github.com/BeyondDimension/SteamTools)）。
