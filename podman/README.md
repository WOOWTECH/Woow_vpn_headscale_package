# Podman Deployment — Headscale + Headplane / Podman 單機版部署

A lightweight single-node alternative to the K8s stack: the same Headscale v0.29.2 + Headplane v0.7.0, running under **rootless Podman** with `podman-compose`. Verified on Podman 4.9.3 / podman-compose 1.0.6 (Ubuntu).

不依賴 Kubernetes 的輕量單機版：同樣的 Headscale v0.29.2 + Headplane v0.7.0，跑在 **rootless Podman** 上。

## Quick Start / 快速開始

```bash
cd podman
cp .env.example .env      # optionally set SERVER_URL (ngrok URL / your domain)
./deploy.sh
```

`deploy.sh` automates everything / 全自動化：

1. Patches `server_url` from `.env` into the Headscale config
2. Generates the 32-char Headplane cookie secret
3. Starts Headscale → waits for `/health`
4. Creates the `default` user (idempotent)
5. Creates a 90-day Headscale API key → wires it into Headplane
6. Starts Headplane → verifies `/admin` responds
7. Creates a reusable 72 h PreAuthKey and prints the `tailscale up` command

## Endpoints / 端點

| Service | URL |
|---------|-----|
| Headscale control plane | `http://localhost:28080` (health: `/health`) |
| Headplane admin UI | `http://localhost:23000/admin` (login with printed API key) |
| Headscale metrics | `http://localhost:29090/metrics` |

## Screenshot / 截圖

<p align="center"><img src="../docs/screenshots/podman_headplane_machines.png" alt="Podman Headplane" width="900"/></p>

## External access / 外部曝露

Same rules as the K8s stack — **Cloudflare Tunnel will NOT work** for VPN clients. Verified path:

```bash
ngrok http 28080
# set SERVER_URL=https://<ngrok-url> in .env, then ./deploy.sh again
```

For production, front port 28080 with any upgrade-passing reverse proxy (Traefik/Nginx/Caddy) + TLS and a stable domain. See [`../docs/EXTERNAL-ACCESS.md`](../docs/EXTERNAL-ACCESS.md).

## Boot persistence (optional) / 開機自啟

```bash
cd ~/headscale-podman
podman generate systemd --new --files --name headscale headplane
mkdir -p ~/.config/systemd/user && mv container-*.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable container-headscale container-headplane
loginctl enable-linger $USER
```

## Gotchas fixed in these configs / 這些設定已修掉的雷

| Issue | Fix baked in |
|-------|--------------|
| Headscale v0.29.2 removed `randomize_client_port` | Key omitted from `config.yaml` |
| Policy-v2 file mode rejects `"*"` in `autoApprovers` | Uses `default@` username format in `policy.json` |
| Headplane secure-cookie warning breaks HTTP login | `cookie_secure: false` (set `true` behind HTTPS) |
| podman-compose 1.0.6 may not honor `in_pod` | Headplane reaches Headscale via the compose network alias `http://headscale:8080` |
| Headplane v0.7.0 validates `integration.kubernetes.pod_name` even when disabled | No `integration:` section in config |

## Files / 檔案

```
podman/
├── podman-compose.yml        # headscale + headplane services
├── deploy.sh                 # one-shot automation
├── .env.example              # SERVER_URL template
└── config/
    ├── headscale/config.yaml # v0.29.2 config (server_url patched by deploy.sh)
    ├── headscale/policy.json # ACL + autoApprovers (file mode)
    └── headplane/config.yaml # v0.7.0 config (no integration section)
```

> Runtime-generated secrets (`config/headplane/cookie-secret`, `config/headplane/api-key`) are git-ignored — never commit them.
