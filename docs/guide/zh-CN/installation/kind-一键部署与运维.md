# kind 一键部署与运维

本文记录在 Windows + WSL(Ubuntu) + Docker Desktop 环境下，使用 `scripts/wsl-up-kind.sh` 一键部署 IAM 到 kind 的方法。

## 1. 一键部署

在 PowerShell 执行：

```bash
wsl -d Ubuntu-22.04 -- bash -lc "cd /mnt/d/iam && ./scripts/wsl-up-kind.sh"
```

常用参数：

- `RECREATE_CLUSTER=0`：默认复用已有 kind 集群（推荐，启动更快）
- `RECREATE_CLUSTER=1`：强制删除并重建 kind 集群（首次排障时使用）
- `INSTALL_INGRESS=1`：默认安装 ingress-nginx 并创建 IAM Ingress
- `PASSWORD=...`：覆盖默认数据库密码
- `INGRESS_HOST=...`：覆盖默认入口域名（默认 `iam.local`）

示例：

```bash
wsl -d Ubuntu-22.04 -- bash -lc "cd /mnt/d/iam && RECREATE_CLUSTER=1 INSTALL_INGRESS=1 ./scripts/wsl-up-kind.sh"
```

## 2. Dashboard 访问

启动 Dashboard 端口转发：

```bash
wsl --% -d Ubuntu-22.04 -- kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard 10443:443
```

获取 token：

```bash
wsl --% -d Ubuntu-22.04 -- kubectl -n kubernetes-dashboard create token dashboard-admin --duration=24h
```

浏览器访问：

- `https://127.0.0.1:10443/`

## 3. Ingress 验证

启动 ingress-controller 端口转发：

```bash
wsl --% -d Ubuntu-22.04 -- kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 38080:80
```

验证健康检查和登录：

```powershell
$h = @{ Host = 'iam.local' }
Invoke-RestMethod -Uri 'http://127.0.0.1:38080/healthz' -Headers $h -Method Get

$body = '{"username":"admin","password":"Admin@2021"}'
Invoke-RestMethod -Uri 'http://127.0.0.1:38080/login' -Headers $h -Method Post -ContentType 'application/json' -Body $body
```

## 4. 运行与重启建议

- 日常使用建议保持 `RECREATE_CLUSTER=0`，可复用已有集群和镜像缓存。
- 仅在需要重置环境时使用 `RECREATE_CLUSTER=1`。
- 脚本会自动修复 `iamctl.yaml` ConfigMap 缺失问题，并使用可达镜像仓库地址。
- 脚本在开发模式下会清理 ingress admission jobs，降低无意义事件噪音。
