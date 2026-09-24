# GL.iNet AGH + OpenClash

让 GL.iNet 路由器上的 **AdGuard Home 与 OpenClash 正确共存**：使用各自原生开关，关闭一项后，另一项继续工作。AGH 先过滤广告，再由 OpenClash 提供 Fake-IP 和代理分流；兼容程序完全运行在路由器上，自动处理开关和服务重启。

**AdGuard Home and OpenClash compatibility for GL.iNet routers.** Use their native switches independently: turning one off keeps the other working. AGH filters ads before OpenClash handles Fake-IP and proxy routing. Everything runs on the router and adapts to service toggles and restarts.

```text
设备 → dnsmasq → AGH 先过滤 → OpenClash → 上游 DNS
Devices → dnsmasq → AGH filters first → OpenClash → upstream DNS
```

| AGH | OpenClash | 功能 / Available features |
|---|---|---|
| 开 / On | 开 / On | 广告过滤 + Fake-IP 代理分流 / Ad filtering + Fake-IP proxy routing |
| 关 / Off | 开 / On | Fake-IP 代理分流 / Fake-IP proxy routing |
| 开 / On | 关 / Off | 广告过滤 + 直连上网 / Ad filtering + direct internet access |
| 关 / Off | 关 / Off | 普通 DNS、直连上网 / Normal DNS and direct internet access |

关闭 OpenClash 后不再提供代理；关闭 AGH 后不再过滤广告。安装和切换可能中断访问并需要重新解析；耗时取决于原生服务启动、过滤器加载和防火墙重建，服务未就绪时暂用仍可用的 DNS 路径。

Turning off OpenClash disables proxying; turning off AGH disables ad filtering. Installation and transitions may interrupt access and require fresh DNS lookups. Recovery time depends on native startup, filter loading and firewall rebuilding; DNS temporarily bypasses services that are not ready.

## 兼容范围 / Compatibility

**v1.1.0 新增 GL-BE3600 的 fw4 / nftables 适配，保留 GL-MT5000 的 fw3 支持。**

**v1.1.0 adds GL-BE3600 support with fw4 / nftables and retains GL-MT5000 support with fw3.**

| 型号 / Model | 已适配环境 / Supported environment | 防火墙 / Firewall |
|---|---|---|
| GL-MT5000 | GL.iNet 4.9.0 | fw3 / iptables |
| GL-BE3600 | 4.10.1，OpenWrt 23.05 衍生定制构建 / custom OpenWrt 23.05 build | fw4 / nftables |

安装器同时核验固件及插件文件哈希；同版本但文件不同也会拒绝安装。BE3600 的适配针对本次实测构建，不代表所有原厂或第三方 4.10.1 固件。

The installer also checks exact firmware/plugin file hashes and rejects different files, even with the same version number. BE3600 support covers the tested build, not every stock or third-party 4.10.1 firmware.

- 已安装 / Already installed: AGH, OpenClash, Ruby/YAML, `dig`, `timeout`, `uci`, `ubus`, `netstat`, `pidof`, `pgrep`, `sha256sum`；另需 / plus `iptables` + `ip6tables` (fw3), or `fw4` + `nft` (fw4). 下载命令另需 / The download command also requires `curl`.
- 配置前提 / Required settings: 单个 / one dnsmasq (port `53`); AGH DNS `3053`, **Handle Client Requests: OFF**; GL.iNet DNS: **Automatic**; OpenClash: **Fake-IP Mix**, DNS port `7874`.
- OpenClash DNS 劫持可关闭或使用 Dnsmasq Redirect，保留原选择；关闭时手动指定其他 DNS 的客户端可能绕过过滤。fw4 开启 IPv6 时需使用 IPv6 模式 `3`。 / OpenClash DNS redirection may be disabled or set to Dnsmasq Redirect; the existing choice is preserved. With redirection disabled, clients using another DNS server may bypass filtering. IPv6 mode `3` is required when IPv6 is enabled on fw4.
- 自定义按域名 DNS 或 AGH 上游文件需另行适配。 / Custom per-domain DNS or an AGH upstream file requires separate integration.

保留 OpenClash 的节点、订阅、规则、节点 DNS 和 DNS 劫持，以及 AGH 的过滤器、缓存容量、日志和统计设置；仅协调必要 DNS 字段并部署路由器服务。两种防火墙均应用 watchdog 兼容补丁；原有 nat6 补丁仅用于 fw3，fw4 不修改 nat6。关闭本机 OpenClash 后优先使用可用 WAN DNS，备用为 `223.5.5.5`（普通 DNS）。上级路由器的过滤或代理仍由上级控制。

Preserves OpenClash nodes, subscriptions, rules, node DNS and DNS redirection, plus AGH filters, cache capacity, logging and statistics settings. It manages required DNS fields and a router-local service. Both backends use a watchdog patch; the existing nat6 patch applies only to fw3. With local OpenClash off, DNS uses a working WAN resolver, with `223.5.5.5` as a plain-DNS backup. Any upstream router's filtering or proxying remains under its own control.

## 安装 / Install

**SSH 登录路由器，以 root 执行这一行。 / Run this line as root in the router's SSH terminal.**

```sh
curl -fL --retry 3 https://github.com/CyberChun0329/glinet-agh-openclash/releases/download/v1.1.0/glinet-agh-openclash-compat-1.1.0.sh -o /tmp/glinet-agh-openclash-compat.sh && sh /tmp/glinet-agh-openclash-compat.sh
```

先完整下载，成功后才安装。脚本自带全部组件，自动备份并设置开机启动；同版本健康安装会直接跳过。无需电脑端常驻程序。

Downloads the complete self-contained script before running it, creates backups and enables startup on boot. A healthy installation of the same version is left unchanged. No computer-side daemon is needed.

已有 v1.0.0 的设备无需为 BE3600 适配而升级。v1.1.0 不覆盖旧安装；如需迁移，先用 v1.0.0 脚本卸载，再安装新版。

Existing v1.0.0 installations do not need an update for BE3600 support. v1.1.0 does not overwrite an older installation; use the v1.0.0 script to uninstall before installing the new version.

检查 / Check:

```sh
sh /tmp/glinet-agh-openclash-compat.sh check
```

卸载 / Uninstall:

```sh
sh /tmp/glinet-agh-openclash-compat.sh uninstall
```

重启后 `/tmp` 文件可能消失；可从同一地址重新下载脚本，再运行检查或卸载。备份位于 `/root/router-dns-coordinator-backups/`。卸载后恢复受管设置并移除兼容层；安装或卸载时不要同时修改配置。

The downloaded `/tmp` file may disappear after reboot; download it again before checking or uninstalling. Backups are in `/root/router-dns-coordinator-backups/`. Uninstall restores managed settings and removes the compatibility layer. Avoid concurrent configuration edits during installation or removal.

MT5000 已实测原生开关组合、IPv4/IPv6、广告过滤、Fake-IP、OpenClash 重启及 Geo 更新。BE3600 的实机验收记录见对应 Release；安装、卸载、回滚及两种防火墙的行为另有隔离回归检查。

MT5000 testing covered native toggle combinations, IPv4/IPv6, filtering, Fake-IP, OpenClash restarts and Geo updates. See the release notes for BE3600 live verification. Isolated regression checks also cover installation, removal, rollback and both firewall backends.
