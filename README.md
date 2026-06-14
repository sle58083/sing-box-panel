# sing-box-panel

给 `233boy/sing-box` 一键脚本增加类似 x-ui 的轻量 Web 管理面板。

## 特性

- 后端：Python FastAPI
- 数据库：SQLite，默认路径 `/etc/sing-box-panel/panel.db`
- 前端：原生 HTML/CSS/JavaScript，无构建工具
- 后端只监听 `127.0.0.1:54321`
- 默认通过 Nginx 反代暴露 `2053` 端口
- 安装时手动输入面板用户名和密码，并要求重复确认密码
- 密码使用 PBKDF2-SHA256 哈希保存
- API 使用 HttpOnly Cookie 登录鉴权
- 系统命令全部使用 `subprocess.run([...], shell=False)`
- 节点名、协议、配置路径和到期时间均做输入校验

## 安装

一键安装：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/sle58083/sing-box-panel/main/install.sh)
```

一键卸载：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/sle58083/sing-box-panel/main/uninstall.sh)
```

安装完成后会输出：

- 面板地址：`http://服务器IP:2053`
- 你手动输入的用户名
- 你手动输入并确认的密码

凭据会保存到：

```text
/etc/sing-box-panel/admin.txt
```

## 运行要求

服务器需要先安装 `233boy/sing-box`：

```bash
bash <(wget -qO- https://github.com/233boy/sing-box/raw/main/install.sh)
```

面板会自动探测 `sing-box` 管理命令，优先使用 `command -v sing-box`，再检查 `/usr/local/bin/sing-box`。

面板调用方式为：

```bash
sing-box add <protocol> auto
sing-box del <name>
sing-box info <name>
sing-box url <name>
sing-box qr <name>
sing-box status
sing-box log
sing-box restart
```

配置目录自动探测顺序：

```text
/etc/sing-box/conf
/etc/sing-box
find /etc/sing-box -name "*.json"
```

协议映射在 [backend/singbox.py](backend/singbox.py) 的 `protocol_map` 中维护。如果你的脚本命令名不同，可以在 systemd service 中设置：

```ini
Environment=SING_BOX_CMD=/path/to/sing-box
```

## 服务管理

```bash
systemctl status sing-box-panel
systemctl restart sing-box-panel
systemctl status sing-box-panel-expire.timer
```

## API

- `POST /api/login`
- `POST /api/logout`
- `GET /api/me`
- `GET /api/nodes`
- `POST /api/nodes`
- `DELETE /api/nodes/{name}`
- `PATCH /api/nodes/{name}/expire`
- `GET /api/nodes/{name}/url`
- `GET /api/nodes/{name}/qr`
- `GET /api/status`
- `GET /api/logs`

## 卸载

```bash
bash /opt/sing-box-panel/uninstall.sh
```

卸载默认保留 `/etc/sing-box-panel` 中的数据库和凭据。
