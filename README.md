# 3x-ui 一键部署脚本（纯 IP + 自签名 HTTPS）

默认配置：

- 用户名: `admin`
- 密码: `123456`
- 面板端口: `10601`
- Web 根路径: `/xui`（可用 `-b` 自定义）
- 默认入站: VLESS + REALITY on port `443`
- 面板链接: `https://<VPS公网IP>:10601/xui/`（自签证书，浏览器首次需点"高级 -> 继续访问"）

## 用法

在 VPS 上以 root 运行，**一条命令自动判断**：

- 新 VPS：自动初始化系统（更新、防火墙、BBR、swap）后安装
- 老 VPS：自动检测到旧的 x-ui / 3x-ui / v2-ui 等，先彻底清理再安装

```bash
bash install.sh
```

## 上传到 GitHub 后的一键命令

假设脚本放在 `hongfeiz830/codex-3x-ui` 仓库的 `3x-ui/install.sh` 路径下，main 分支：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/hongfeiz830/codex-3x-ui/main/install.sh)
```

新老 VPS 都用这一条命令，脚本会自动检测并处理。

## 改"子目录"

面板根路径默认是 `xui`。两种改法：

1. 运行时用 `-b` 参数：`bash install.sh -b mypath`，链接就变成 `https://IP:10601/mypath/`
2. 直接改脚本第 22 行：`XUI_WEBBASEPATH="${XUI_WEBBASEPATH:-xui}"` 里的 `xui` 改成你想要的名字
