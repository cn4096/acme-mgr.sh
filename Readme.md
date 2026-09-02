# acme-mgr

基于 [acme.sh](https://github.com/acmesh-official/acme.sh) + [acme-dns](https://github.com/joohoi/acme-dns) 的多层级泛域名证书管理脚本。

**服务器上不存放任何 DNS 服务商 API 密钥**，通过 CNAME 委托完成 ACME DNS-01 验证。适用于 80/443 端口不可用、需要泛域名、或不愿把 DNS API Key 放在机器上的场景。

---

## 特性

- 一个脚本管理多个层级的泛域名证书，配置集中在文件头部
- 全程 Docker 运行 acme.sh，宿主机无需安装任何 ACME 客户端
- 每个域名独立的数据目录与 acme-dns 凭据，互不影响
- 自动生成 nginx 配置、自动续期、自动 reload
- 证书可用于**任意端口**（8443、9443 等），不限于 443

## 工作原理

ACME 的 DNS-01 验证要求在 `_acme-challenge.<域名>` 放一条 TXT 记录。本方案不直接操作你的 DNS，而是把这个位置**永久 CNAME 到 acme-dns 的一个专属子域**：

```
_acme-challenge.example.com.  CNAME  <uuid>.auth.acme-dns.io.
```

之后所有 TXT 的写入删除都发生在 acme-dns 上，脚本持有的凭据只能操作那一条记录。CNAME 一次配好，永久不动。

### 为什么每个层级要一张证书

acme-dns 每个子域只保留最近 **2 条** TXT 记录——恰好够 `example.com` + `*.example.com` 这一对。而 acme.sh 的 `dns_acmedns` 插件对一张证书只维护一组凭据，无法为多个层级分别注册。

因此本脚本采用**一个基准域一张证书**的结构：

| 基准域 | 证书覆盖 | 数据目录 |
|---|---|---|
| `example.com` | `example.com`、`*.example.com` | `data/example.com/` |
| `app.example.com` | `app.example.com`、`*.app.example.com` | `data/app.example.com/` |
| `api.example.com` | `api.example.com`、`*.api.example.com` | `data/api.example.com/` |

nginx 通过 SNI 自动选择对应证书，对访问者透明。

> 如果你能接受在服务器上存放 DNS API 密钥，用 `--dns dns_ali` / `dns_cf` 等插件可以把所有层级签进**一张**证书，不需要任何 CNAME。本脚本是为不使用 API 密钥的场景设计的。

---

## 环境要求

- Docker
- 域名的 DNS 可以自由添加 CNAME 记录（在哪家托管都行）
- `dig`、`openssl`、`sha256sum`

OpenWrt 上安装依赖：

```bash
opkg update
opkg install bash bind-dig openssl-util coreutils-sha256sum
# OpenWrt 25.x / snapshot 用 apk add
```

安装后自检：

```bash
./acme-mgr.sh deps
```

---

## 配置

编辑脚本头部的配置区：

```bash
ROOT="example.com"

# 每行一个，各自签发 <域名> + *.<域名>；不需要就留空 SUBS=""
SUBS="
app.example.com
api.example.com
dev.example.com
"

ACMEDNS_BASE_URL="https://auth.acme-dns.io"

ACME_HOME="/opt/acme"
SSL_DIR="/opt/docker-data/nginx/ssl"      # 宿主机上 nginx 读取证书的目录

NGINX_CONTAINER="nginx"
NGINX_SSL_PATH="/etc/nginx/ssl"           # 同一目录在 nginx 容器内的路径
NGINX_PORT="8443"
NGINX_CONF_OUT="/opt/docker-data/nginx/conf.d/acme-ssl.conf"

ACME_IMAGE="neilpang/acme.sh"
DNSSLEEP=120
```

`SSL_DIR` 与 `NGINX_SSL_PATH` 是同一个目录的两个视角，查询实际挂载：

```bash
docker inspect nginx --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
```

nginx 不在容器里的话，把 `cmd_apply` / `cmd_renew` 中的 `docker exec nginx ...` 改成 `nginx -s reload` 即可。

---

## 首次部署

```bash
mkdir -p /opt/acme
cp acme-mgr.sh /opt/acme/
chmod +x /opt/acme/acme-mgr.sh
cd /opt/acme
```

### 1. 检查环境

```bash
./acme-mgr.sh deps
./acme-mgr.sh list
```

### 2. 初始化

```bash
./acme-mgr.sh init
```

拉取镜像、创建各域名的数据目录。

### 3. 首轮签发，获取 CNAME 目标

```bash
./acme-mgr.sh staging
```

**预期会失败。** 每个域名会输出类似：

```
##########################################################
# Create _acme-challenge.app.example.com CNAME
#   6683289c-8e73-47ba-908a-9228a8ddffde.auth.acme-dns.io DNS entry #
##########################################################
Press enter to continue...
```

看到提示时可以另开终端去加记录，加完再回车；也可以先全部跑完、记下所有 UUID 后统一添加。

### 4. 添加 CNAME 记录

在 DNS 控制台添加，每个基准域一条：

| 记录类型 | 主机记录 | 记录值 | TTL |
|---|---|---|---|
| CNAME | `_acme-challenge` | `<uuid1>.auth.acme-dns.io` | 600 |
| CNAME | `_acme-challenge.app` | `<uuid2>.auth.acme-dns.io` | 600 |
| CNAME | `_acme-challenge.api` | `<uuid3>.auth.acme-dns.io` | 600 |

> **主机记录 = 完整记录名去掉末尾的托管域名部分。**
> 托管 `example.com` 时，`_acme-challenge.app.example.com` 的主机记录是 `_acme-challenge.app`。
> 这是最容易填错的地方——漏掉中间层级会导致 `No TXT record found`。

### 5. 核对

```bash
./acme-mgr.sh cname
```

```
记录名                               当前解析                                    本地已注册
_acme-challenge.example.com          uuid1.auth.acme-dns.io.                     OK
_acme-challenge.app.example.com      uuid2.auth.acme-dns.io.                     OK
_acme-challenge.api.example.com      uuid3.auth.acme-dns.io.                     OK
```

全绿再继续。红色说明 DNS 未生效或值不匹配。

### 6. 测试签发

```bash
./acme-mgr.sh staging
```

全部 `Cert success.` 说明验证链路无误。

### 7. 正式签发

```bash
./acme-mgr.sh prod
```

### 8. 部署

```bash
./acme-mgr.sh install     # 配置证书输出到 SSL_DIR
./acme-mgr.sh apply       # 生成 nginx 配置并 reload
./acme-mgr.sh check       # 验收
./acme-mgr.sh cron        # 安装每日续期任务
./acme-mgr.sh backup      # 备份凭据
```

---

## 命令参考

```
./acme-mgr.sh <命令> [域名...]
```

不指定域名则对配置中的全部域名操作。

| 命令 | 说明 | 支持指定域名 |
|---|---|---|
| `list` | 显示当前配置 | – |
| `deps` | 检查工具依赖 | – |
| `init` | 拉镜像、建目录、设默认 CA | ✅ |
| `staging` | 用测试 CA 签发 | ✅ |
| `cname` | 核对 DNS 解析与本地注册是否一致 | ✅ |
| `prod` | 用正式 CA 签发 | ✅ |
| `install` | 配置证书输出路径 | ✅ |
| `nginx` | 打印 nginx 配置到标准输出 | – |
| `apply` | 写入 nginx 配置文件并 reload | – |
| `check` | 依赖 + 证书有效期 + TLS 握手 | – |
| `renew` | 续期（供 cron 调用） | – |
| `cron` | 安装每日定时任务 | – |
| `backup` | 打包 `data/` 与凭据 | – |

单独操作某个域名：

```bash
./acme-mgr.sh staging app.example.com
./acme-mgr.sh prod app.example.com
```

### staging 与 prod

两者流程完全相同，区别只在签发的 CA：

| | staging | prod |
|---|---|---|
| 浏览器信任 | ❌ | ✅ |
| 速率限制 | 极宽松 | 每周 50 张新证书，同组域名每周 5 次重复签发 |

**CNAME 记录对两者通用**，staging 验证通过则 prod 必然通过。先跑 staging 是为了避免试错烧掉正式配额。

`check` 中显示 `STAGING(测试证书)` 表示尚未转正，需要跑一次 `prod`。

---

## 新增一个层级

以添加 `cdn.example.com` 为例：

```bash
# 1. 在 SUBS 中加入 cdn.example.com

D=cdn.example.com
./acme-mgr.sh init $D
./acme-mgr.sh staging $D      # 失败并输出 CNAME 目标

# 2. DNS 添加: 主机记录 _acme-challenge.cdn

./acme-mgr.sh cname $D        # 确认为 OK
./acme-mgr.sh staging $D      # 应成功
./acme-mgr.sh prod $D
./acme-mgr.sh install $D
./acme-mgr.sh apply
```

`init` 与 `install` 对已存在的域名是幂等的，重复执行无害。

---

## 日常维护

### 自动续期

`cron` 命令安装的任务每天执行一次：

```
23 4 * * * /opt/acme/acme-mgr.sh renew >> /opt/acme/renew.log 2>&1
```

`--cron` 只在证书接近到期时才真正动作，其余时间几乎无开销，也不消耗 CA 配额。每天执行是为了留出重试窗口——单次失败次日自动重试。

证书内容发生变化时才 reload nginx。

### 备份

```bash
./acme-mgr.sh backup
```

`data/` 中保存着各域名的 acme-dns 凭据。丢失后需要重新注册并更新全部 CNAME 记录，因此首次部署完成后应立即备份。

---

## 关于端口

证书不包含端口信息，同一份 `crt` / `key` 可被任意数量的服务在任意端口使用：

```nginx
server {
    listen 8443 ssl;
    server_name example.com *.example.com;
    ssl_certificate     /etc/nginx/ssl/example.com.crt;
    ssl_certificate_key /etc/nginx/ssl/example.com.key;

    # http自动转https, 关键：用 $http_host 保留客户端访问的端口 9999
    error_page 497 =301 https://$http_host$request_uri;
    # nginx 自身产生的跳转（如目录补斜杠）也别带上 443
    absolute_redirect off;
}
```

DNS-01 验证不需要任何入站端口，80 和 443 被封或被占用都不影响签发与续期。

---

## 故障排除

**`No TXT record found`**
CNAME 未生效或主机记录填错。用 `cname` 子命令核对，注意主机记录需包含中间层级。

**`Incorrect TXT record`**
同一个 acme-dns 子域被写入了超过 2 条 TXT。检查是否把多个基准域签进了同一张证书——本脚本的结构不会出现这种情况。

**`cname` 的"当前解析"全部为 `-`**
`dig` 未安装。运行 `./acme-mgr.sh deps` 确认。

**`Segmentation fault` / `POST JWS not signed`**
容器内 openssl 崩溃。检查磁盘空间与内存；确认镜像架构与主机一致：

```bash
uname -m
docker image inspect neilpang/acme.sh --format '{{.Architecture}} {{.Os}}'
```

偶发情况重跑即可。

**续期后 nginx 仍使用旧证书**
未执行过 `install`，证书只更新在容器内部而未同步到 `SSL_DIR`。运行：

```bash
./acme-mgr.sh install
docker run --rm -v /opt/acme/data/example.com:/acme.sh \
  neilpang/acme.sh --info -d example.com | grep -i path
```

应能看到 `Le_RealFullChainPath=/certs/example.com.crt`。

---

## 覆盖范围提醒

通配符只匹配一级标签：

```
a.example.com        ✅  匹配 *.example.com
a.b.example.com      ❌  不匹配
```

需要更深层级时，为该层级单独增加一个基准域（见"新增一个层级"）。

---

## 安全说明

- 服务器上不存在 DNS 服务商的 API 密钥
- 每个域名的 acme-dns 凭据只能操作对应的一条 challenge 记录，泄露不影响主域名解析
- `auth.acme-dns.io` 是公共实例，运营方理论上可为你的域名签发证书。对此敏感的场景建议[自建 acme-dns](https://github.com/joohoi/acme-dns#installation) 并修改 `ACMEDNS_BASE_URL`
- 泛域名证书私钥泄露会影响该层级下所有子域名，低信任环境建议单独签发具体域名的证书

---

## 许可

脚本本身可自由使用与修改。acme.sh 采用 GPLv3，acme-dns 采用 MIT。
