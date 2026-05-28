# TiKV 3-Replica + 3-PD Cluster on WSL with QEMU VMs

在 WSL2 上通过 3 个 QEMU 虚拟机部署 TiKV 三副本 + 三节点 PD 集群，宿主机作为客户端。

## 架构

```
Host (WSL2)                 172.16.0.1 (br0 Bridge)
  ├─ socat relay (172.16.0.1:8889 → 127.0.0.1:7897)  ← 代理中继，为 VM 提供外网
  │
  ├─ VM1: tikv-vm1 (172.16.0.101)
  │    ├─ PD1  (:2379, :2380)  +  TiKV1 (:20160)
  │    └─ Disk: vda(root) + vdb(data)
  │
  ├─ VM2: tikv-vm2 (172.16.0.102)
  │    ├─ PD2  (:2379, :2380)  +  TiKV2 (:20160)
  │    └─ Disk: vda(root) + vdb(data)
  │
  └─ VM3: tikv-vm3 (172.16.0.103)
       ├─ PD3  (:2379, :2380)  +  TiKV3 (:20160)
       └─ Disk: vda(root) + vdb(data)

Inter-VM:  br0 172.16.0.0/24 (二层互通)

Host → VM:
  localhost:2379 → VM1:2379 (PD API)
  localhost:20160 → VM1:20160, localhost:20161 → VM2:20160, localhost:20162 → VM3:20160
  ssh ubuntu@172.16.0.101 / 102 / 103 (SSH via bridge)

VM → Internet:
  http_proxy=http://172.16.0.1:8889 → socat → 127.0.0.1:7897 → Windows proxy → 外网
```

## 前置要求

- WSL2 (kernel 5.x+)
- 至少 8GB 可用内存，30GB 可用磁盘
- sudo 权限，KVM 加速可用
- 宿主机有 HTTP 代理可用（本方案假设 `http://127.0.0.1:7897`）

## 快速开始

### 1. 安装依赖

```bash
cd tikv-qemu
sudo bash install.sh
```

安装 QEMU、cloud-utils、bridge-utils、sshpass、numactl、socat、TiUP 等。

### 2. 下载基础镜像

```bash
bash download-image.sh
```

下载 Ubuntu 24.04 cloud image，仅需执行一次。

### 3. 设置网络

```bash
sudo bash setup-network.sh
```

创建网桥 br0 + 3 个 tap 设备，并启动 socat 代理中继（VM 通过它访问外网）。
**每次重启 WSL 后需重新执行此步骤。**

### 4. 创建虚拟机

```bash
bash create-vms.sh
```

基于 cloud image 创建 3 个 qcow2 写时复制盘 + 各 10G 独立数据盘 + cloud-init 配置 ISO。

### 5. 启动虚拟机

```bash
sudo bash start-vms.sh
```

启动 3 个 QEMU VM。等待约 40 秒 cloud-init 初始化完成。

### 6. 部署 TiKV 集群

**方式 A：手动部署（推荐，更透明）**

```bash
bash deploy-tikv.sh
```

宿主机 wget 二进制 → scp 到 3 台 VM → 创建 systemd 服务 → 启动 PD 集群 → 启动 TiKV。

**方式 B：TiUP 官方部署**

```bash
bash deploy-tikv-tiup.sh
```

自动配置 SSH 密钥 → 生成拓扑文件 → `tiup cluster deploy` 部署 → `tiup cluster start` 启动。

> 切换部署方式前先执行 `bash clean-deploy.sh` 清理旧部署状态（不删 VM）。

### 7. 验证集群

```bash
bash status.sh
```

或手动验证：

```bash
curl --noproxy '*' http://172.16.0.101:2379/pd/api/v1/health
curl --noproxy '*' http://172.16.0.101:2379/pd/api/v1/members
curl --noproxy '*' http://172.16.0.101:2379/pd/api/v1/stores
```

### 8. 数据读写测试

```bash
bash run-test.sh
```

自动安装 Go（如未安装），编译并运行 5 个测试用例，模拟 JuiceFS 元数据场景：

| 测试 | 模拟场景 |
|------|---------|
| Test 1: Put + Get | 文件创建 + stat |
| Test 2: Batch Put/Get | 批量文件操作 |
| Test 3: Scan | 目录遍历 |
| Test 4: Delete | 文件删除 |
| Test 5: Concurrent Puts | 多客户端并发访问 |

## SSH 连接

```bash
ssh ubuntu@172.16.0.101   # VM1 (PD1 + TiKV1)
ssh ubuntu@172.16.0.102   # VM2 (PD2 + TiKV2)
ssh ubuntu@172.16.0.103   # VM3 (PD3 + TiKV3)
# 默认密码: ubuntu
```

> SSH 走桥接网络直连。QEMU 端口转发因 SLIRP 协议不兼容 SSH 横幅握手而不可用。
> 每次重建 VM 后需清理 known_hosts：
> `ssh-keygen -f ~/.ssh/known_hosts -R 172.16.0.101`

## VM 外网访问

VM 通过宿主机桥接 IP 上的 socat 中继访问外网，cloud-init 已将代理写入 `/etc/profile.d/tikv-proxy.sh`：

```bash
echo $http_proxy   # http://172.16.0.1:8889
apt update         # 可正常使用
```

内网 PD/TiKV 通信不受影响（`no_proxy=172.16.0.0/24`）。

## 停止 / 清理

```bash
sudo bash stop-vms.sh       # 停止所有 VM
bash clean-deploy.sh        # 清理 TiKV/PD 部署状态（VM 保留）
bash clean.sh               # 删除所有 VM 镜像和数据
```

## 文件结构

```
tikv-qemu/
├── install.sh              # 安装 QEMU、依赖、TiUP
├── download-image.sh       # 下载 Ubuntu cloud image
├── setup-network.sh        # 创建 br0/tap + socat 代理中继
├── create-vms.sh           # 创建 VM 磁盘（root + data）和 cloud-init
├── start-vms.sh            # 启动 3 个 QEMU VM
├── stop-vms.sh             # 停止所有 VM
├── deploy-tikv.sh          # 手动部署 TiKV + PD 集群
├── deploy-tikv-tiup.sh     # TiUP 官方方式部署
├── clean-deploy.sh         # 清理 TiKV/PD 部署状态（保留 VM）
├── clean.sh                # 删除所有 VM 镜像
├── status.sh               # 查看集群状态
├── run-test.sh             # 编译并运行数据读写测试
├── tests/                  # 测试代码
│   ├── tikv-rawkv-test.go      # TiKV RawKV 读写测试（Go）
├── cloud-init/             # cloud-init 配置文件
│   ├── vm{1,2,3}-user-data     # 网络、用户、SSH、代理、数据盘配置
│   └── vm{1,2,3}-meta-data     # 主机名
├── config/                 # TiKV/PD 配置文件
│   ├── pd1.toml            # PD 节点 1 (172.16.0.101)
│   ├── pd2.toml            # PD 节点 2 (172.16.0.102)
│   ├── pd3.toml            # PD 节点 3 (172.16.0.103)
│   ├── tikv1.toml          # TiKV 节点 1
│   ├── tikv2.toml          # TiKV 节点 2
│   ├── tikv3.toml          # TiKV 节点 3
│   └── topology.yaml       # TiUP 拓扑文件 (deploy-tikv-tiup.sh 生成)
├── docs/
│   ├── network.md          # 网络拓扑详解
│   └── troubleshooting.md  # 调试问题记录
├── downloads/              # 缓存下载的 TiKV/PD 二进制
└── images/                 # VM 磁盘镜像 (base + qcow2 + data + seed)
```

## 注意事项

1. **WSL2 重启后**需重新执行 `sudo bash setup-network.sh` 重建网桥和 socat 中继
2. 3 个 PD 节点使用 Raft 一致性协议，需全部启动后集群才可用
3. VM 默认密码 `ubuntu`，重建 VM 后需清理 `~/.ssh/known_hosts`
4. VM 外网依赖代理中继（172.16.0.1:8889），若宿主机代理端口不同需在脚本中修改
5. 每台 VM 有独立 10G 数据盘挂载到 `/data`，PD 和 TiKV 数据均存于此
6. 如果代理不可用（或不需要），deploy-tikv.sh 仍然可工作——它从宿主机下载后再 scp 到 VM
