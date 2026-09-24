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

关闭 OpenClash 后不再提供代理；关闭 AGH 后不再过滤广告。安装和切换可能短暂中断并需要重新解析，服务未就绪时暂用仍可用的 DNS 路径。

Turning off OpenClash disables proxying; turning off AGH disables ad filtering. Installation and transitions may briefly interrupt access and require fresh DNS lookups; DNS temporarily bypasses services that are not ready.

## 兼容范围 / Compatibility

**v1.0.0 仅适配已验证的 GL-MT5000 / GL.iNet 4.9.0 / fw3（iptables）环境。** 安装器还会核验原厂及插件文件哈希；同版本但文件不同也会拒绝安装。不是所有 GL.iNet 型号通用。

**v1.0.0 supports only the validated GL-MT5000 / GL.iNet 4.9.0 / fw3 (iptables) environment.** Exact firmware/plugin file hashes must also match. Other models or builds are rejected.

- 已安装 / Already installed: AGH, OpenClash, Ruby/YAML, `dig`, `timeout`, `uci`, `ubus`, `netstat`, `iptables`, `ip6tables`, `pidof`, `pgrep`, `sha256sum`. 下载命令另需 / The download command also requires `curl`.
- 配置前提 / Required settings: 单个 / one dnsmasq; AGH DNS `3053`, **Handle Client Requests: OFF**; GL.iNet DNS: **Automatic**; OpenClash: **Fake-IP Mix**, **Dnsmasq Redirect**.
- 自定义按域名 DNS 或 AGH 上游文件需另行适配。 / Custom per-domain DNS or an AGH upstream file requires separate integration.

保留 OpenClash 的节点、订阅、规则和 DNS 劫持，以及 AGH 的过滤器、缓存容量、日志和统计设置；仅协调必要 DNS 字段，并部署服务及两处兼容补丁。直连 DNS 优先使用可用 WAN DNS，备用为 `223.5.5.5`（普通 DNS）。

Preserves OpenClash nodes, subscriptions, rules and DNS redirection, plus AGH filters, cache capacity, logging and statistics settings. Only required DNS fields, a local service and two compatibility patches are managed. Direct DNS uses a working WAN resolver, with `223.5.5.5` as a plain-DNS backup.

## 安装 / Install

**SSH 登录路由器，以 root 执行这一行。 / Run this line as root in the router's SSH terminal.**

```sh
curl -fL --retry 3 https://github.com/CyberChun0329/glinet-agh-openclash/releases/download/v1.0.0/glinet-agh-openclash-compat-1.0.0.sh -o /tmp/glinet-agh-openclash-compat.sh && sh /tmp/glinet-agh-openclash-compat.sh
```

先完整下载，成功后才安装。脚本自带全部组件，自动备份并设置开机启动；同版本健康安装会直接跳过。无需电脑端常驻程序。

Downloads the complete self-contained script before running it, creates backups and enables startup on boot. A healthy installation of the same version is left unchanged. No computer-side daemon is needed.

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

已实测原生开关组合、IPv4/IPv6、广告过滤、Fake-IP、OpenClash 重启及 Geo 更新；全新安装与卸载另经隔离测试，尚未在第二台原厂设备实测。

Native toggle combinations, IPv4/IPv6, filtering, Fake-IP, OpenClash restarts and Geo updates were tested on the target router. Fresh install and uninstall were tested in isolation, not on a second stock device.
