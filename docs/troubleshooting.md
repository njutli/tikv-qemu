# 调试问题记录

本文档记录整个 TiKV QEMU 部署方案在调试过程中遇到的问题和解决方式。

---

## install.sh

### 问题 1：DNS 解析失败
```
curl: (6) Could not resolve host: tiup-mirrors.pingcap.com
```
- **根因**：`sudo` 默认不继承用户的代理环境变量（`https_proxy=http://127.0.0.1:7897`），root 环境没有代理就无法解析外部域名
- **解决**：通过 `/proc/<pid>/environ` 自动探测原始用户的代理配置并注入 root 环境

### 问题 2：代理污染了 apt-get
```
错误:5 http://security.ubuntu.com/ubuntu 502 Bad Gateway [IP: 127.0.0.1 7897]
```
- **根因**：代理变量同时被设给了 `http_proxy`，`apt-get` 访问 Ubuntu 源也走了代理，代理返回 502
- **解决**：同时传递 `no_proxy`，追加 `archive.ubuntu.com, security.ubuntu.com, *.ubuntu.com` 让 apt 源绕过代理直连

### 问题 3：TiUP 装到了 root 用户
```
$ tiup → 找不到命令
/home/lilingfeng/.tiup/ → 空
```
- **根因**：脚本以 root 运行，`curl | sh` 安装到 `/root/.tiup/`，普通用户没有该路径
- **解决**：所有 TiUP 操作通过 `sudo -u "${SUDO_USER}"` 以真实用户身份执行

### 问题 4：tiup cluster 组件偷偷失败
```
脚本输出: TiUP cluster component installed.
实际验证: Error: component not installed
```
- **根因**：`2>/dev/null || true` 吞掉了下载失败的错误信息；检测命令 `tiup cluster version` 是无效子命令
- **解决**：取消沉默吞错，关键步骤失败直接 `exit 1`；改用文件目录检测 (`~/.tiup/components/cluster/`) + `tiup install cluster`

### 问题 5：sudo -u 不传递代理
```
run_as_user 内的 tiup 命令 → Timeout（代理未生效）
```
- **根因**：`sudo -u user -E` 的 `-E` 不一定完整传递所有环境变量
- **解决**：改用 `sudo --preserve-env=all -u user`，确保 proxy 变量完整传递

---

## download-image.sh

### 问题 1：`sh` 不兼容 `${BASH_SOURCE[0]}`
```
$ sh download-image.sh
download-image.sh: 8: Bad substitution
>>> Downloading Ubuntu 24.04 cloud image...  ← 报错但没退出
```
- **根因**：Ubuntu 上 `sh` 是 `dash`，不支持 `${BASH_SOURCE[0]}` 等 bash 特有语法。`set -e` 也未生效，脚本带着错误继续跑
- **解决**：始终用 `bash` 执行：`bash download-image.sh`，或先 `chmod +x` 后 `./download-image.sh`（靠 shebang 自动调用 bash）

### 问题 2：SHA256SUMS 下载 URL 拼接错误
- **现象**：`wget -q` 静默失败，checksum 验证阶段直接退出无输出
- **根因**：`${IMG_URL}/SHA256SUMS` 拼接成了 `...noble-server-cloudimg-amd64.img/SHA256SUMS`，目标文件不存在
- **解决**：改用已定义的 `${IMG_SHA256SUMS}` 变量，该变量保存了正确的 `.../noble/current/SHA256SUMS` 地址

### 问题 3：qemu-img resize 后文件大小未变化
```
$ ls -lh noble-server-cloudimg-amd64.img → 599M
$ qemu-img info → virtual size: 10G, disk size: 599M
```
- **解释**：qcow2 是稀疏格式（sparse file），`qemu-img resize` 只改变虚拟磁盘容量，物理文件实际占用多少取决于 VM 写入了多少数据。后续运行 VM 时文件会自动增长
- **解决**：不是 bug，是正常行为

---

## setup-network.sh

### 问题 1：创建 tap 设备时报 "invalid user"
```
>>> Creating tap device tap0...
invalid user ""
```
- **根因**：`logname 2>/dev/null` 在某些 sudo 环境下返回 exit 0 但输出为空，导致 `|| echo "${SUDO_USER}"` 后备逻辑未触发，`user` 参数收到空字符串
- **解决**：移除 `logname` 依赖，直接使用 `${SUDO_USER}`；并在脚本开头检查 `SUDO_USER` 是否为空，提前报错退出

---

## create-vms.sh

（待补充）

---

## start-vms.sh

### 问题 1：`-nographic` 和 `-daemonize` 互斥
```
qemu-system-x86_64: -nographic cannot be used with -daemonize
```
- **根因**：`-nographic` 重定向串口到 stdio（需要前台终端），`-daemonize` 脱离终端后台运行，两者矛盾
- **解决**：`-nographic` 替换为 `-display none`（不弹图形窗口但不绑定终端）

### 问题 2：PipeWire 音频库警告
```
[W][...] pw.conf: can't load config client.conf
```
- **根因**：QEMU 链接了 PipeWire 音频库，尝试加载配置文件但 QEMU VM 不需要音频
- **解决**：添加 `-audiodev none,id=audio0` 完全禁用音频；QEMU 命令末尾加 `2>/dev/null` 抑制残余 stderr

### 问题 3：pidfile root 属主导致读权限被拒
```
cat: /tmp/qemu-vm1.pid: Permission denied
VM1: FAILED
```
- **根因**：`sudo qemu-system-x86_64 -pidfile ...` 以 root 创建 pidfile（权限 0600），普通用户 cat 被拒
- **尝试过的方案**：① pidfile 移到 `images/` 目录 ② `chown` 改成用户属主 ③ `sudo cat` 读文件
- **最终方案**：`pgrep -f "qemu-system.*tikv-vm{id}"` 代替读 pidfile——不依赖文件，直接查进程表

### 问题 4：cloud-init 网卡名称不匹配
- **现象**：VM 启动后网络不通，`systemd-networkd-wait-online` 永远等待
- **根因**：q35 机器类型下 virtio 网卡被 systemd 重命名为 `enp0s2`/`enp0s3`，而 cloud-init 配的是 `ens3`/`ens4`
- **解决**：cloud-init 全部改为 `enp0s2`/`enp0s3`

### 问题 5：netplan 配置与 cloud image 默认配置冲突
- **现象**：接口名修正后 `systemd-networkd-wait-online` 仍然卡住
- **根因**：Ubuntu cloud image 自带 netplan 配置 `match: {name: "*"} dhcp4: true`（所有接口 DHCP），cloud-init 追加的静态 IP 配置与之合并冲突
- **尝试过的方案**：① cloud-init 原生 `network` key ② write_files 写 netplan ③ `runcmd` 里 `netplan apply`
- **最终方案**：在 `bootcmd` 阶段（systemd 启动前）用 `ip addr add` 直接配网 + `systemctl mask` 屏蔽 wait-online

### 问题 6：QEMU SLIRP 端口转发 SSH 失效
- **现象**：`ssh ubuntu@localhost -p 2201 → Connection timed out during banner exchange`
- **根因**：QEMU SLIRP 用户态网络栈与 SSH 协议层不兼容，TCP 能建立但横幅握手阶段卡死。`UseDNS no` 和 `GSSAPIAuthentication no` 均无法解决
- **解决**：SSH 改为走桥接网络直连 `ssh ubuntu@172.16.0.101`。QEMU 端口转发只用于 PD API

### 问题 7：`SUDO_USER: 未绑定的变量`
- **根因**：`bash start-vms.sh` 执行时 `SUDO_USER` 未设置（只有 `sudo bash` 时才有）
- **解决**：改用 `${SUDO_USER:-$USER}` 提供后备值

### 问题 8：`local: 只能在函数中使用`
- **根因**：status check 在脚本主体而非函数内，误用了 `local` 关键字
- **解决**：改为普通变量赋值

---

## VM 网络与外网访问

### 问题 1：VM 无法访问外网
- **现象**：cloud-init 安装软件包时报 `Temporary failure resolving 'archive.ubuntu.com'`
- **根因**：宿主机的代理跑在 Windows 侧（`127.0.0.1:7897`），QEMU SLIRP 用户态 NAT 直连目标 IP 不经过代理，DNS 解析和 HTTP 请求均失败
- **解决**：在宿主机桥接 IP 上启动 socat 中继：`socat TCP-LISTEN:8889,bind=172.16.0.1,fork,reuseaddr TCP:127.0.0.1:7897`，VM 设置 `http_proxy=http://172.16.0.1:8889`

### 问题 2：iptables DNAT 到 127.0.0.1 不通
- **现象**：`iptables -t nat -A PREROUTING -i br0 -p tcp --dport 7897 -j DNAT --to 127.0.0.1:7897` 后 VM 仍连不上代理
- **根因**：DNAT 只改目标地址不改源地址，回包路由需要 `route_localnet=1`，且 7897 端口被 Windows 占用（WSL2 端口共享）
- **解决**：放弃 iptables，改用 socat 在另一个端口（8889）做中继

---

## deploy-tikv.sh

### 问题 1：stop-vms.sh 误判 VM 未运行
- **现象**：`bash stop-vms.sh` 打印 `[skip] VM is not running`，但 `ps aux` 显示 QEMU 在跑
- **根因**：`sudo cat pidfile` 需要密码，无终端交互导致读取失败，误判为未运行
- **解决**：改用 `pgrep -f` 搜进程名，不再依赖 pidfile 文件

### 问题 2：SSH 重建后 known_hosts 冲突
- **现象**：`WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`
- **根因**：每次重建 VM（新 qcow2）SSH 主机密钥都会变，`~/.ssh/known_hosts` 缓存了旧密钥
- **解决**：`ssh-keygen -f ~/.ssh/known_hosts -R 172.16.0.101` 删除旧条目

### 问题 3：iptables FORWARD 阻断 VM 间桥接流量
- **现象**：宿主机能 ping 通 VM2，但 VM1 无法 ping 通 VM2；PD 集群报 `context deadline exceeded` 无法互相发现
- **根因**：Docker 将 `FORWARD` 链默认策略设为 `DROP`，`bridge-nf-call-iptables=1` 导致桥接流量受 iptables 限制
- **解决**：`iptables -I FORWARD 1 -i br0 -j ACCEPT` 和 `iptables -I FORWARD 1 -o br0 -j ACCEPT`；已加入 `setup-network.sh`

### 问题 4：curl 走代理导致桥接 IP 请求挂死
- **现象**：`curl http://172.16.0.101:2379/pd/api/v1/health` 超时，但 telnet 能通，curl `--noproxy '*'` 正常
- **根因**：宿主机设置了 `http_proxy`，curl 将桥接 IP 的 HTTP 请求也发了代理（`no_proxy` 通配符 `172.16.*` 未正确生效）
- **解决**：所有内部 curl 调用加 `--noproxy '*'`

### 问题 5：pd-ctl / tikv-ctl 不在二进制包中
- **现象**：`mv: cannot stat 'pd-ctl': No such file or directory` / `mv: cannot stat 'tikv-ctl': No such file or directory`
- **根因**：TiKV v7.1 的 PD 包只含 `pd-server`，TiKV 包只含 `tikv-server`，管理工具需从其他渠道获取
- **解决**：移除 `mv pd-ctl` 和 `mv tikv-ctl` 命令；集群验证改用 `curl` 调 PD HTTP API

### 问题 6：QEMU SLIRP 端口转发完全不可用
- **现象**：`localhost:2379` (PD API)、`localhost:2201` (SSH) 的端口转发全部超时，TCP 能建连但应用层数据不通
- **根因**：QEMU SLIRP 用户态网络栈与标准 TCP 协议交互存在兼容性问题，不仅限于 SSH
- **影响**：所有客户端连接只能走桥接 IP（172.16.0.x），QEMU 端口转发仅保留用于 `hostfwd` 参数占位
- **解决**：deploy-tikv.sh、status.sh、测试程序全部改用桥接 IP；README 移除 localhost 端口转发说明

### 问题 7：重新执行脚本时 `mv` 文件已存在报错
- **根因**：脚本中断后重跑，部分二进制已在上次执行时提取到目标目录
- **解决**：所有 `mv` 改为 `mv -f` 强制覆盖
