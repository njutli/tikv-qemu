# 部署架构 FAQ

记录在调试完成后，关于 TiUP 部署方式、配置文件关系、宿主机与 VM 协作机制等问题的问答。

---

## topology.yaml 与 TiKV/PD 配置文件的关系

**Q：官方文档没有提到 TiKV 和 PD 的配置文件怎么用，是我看漏了吗？控制节点没用过 TiKV 和 PD 的配置文件。**

A：你没看漏。官方 TiUP 部署**不直接写 pd.toml / tikv.toml**，配置全部在 `topology.yaml` 的 `server_configs` 段里：

```yaml
server_configs:
  pd:
    replication.max-replicas: 3
    log.level: "info"
  tikv:
    storage.reserve-space: "1GB"
    rocksdb.defaultcf.block-size: "64KB"
```

TiUP 在 `deploy` 阶段把这些 YAML 自动转换成对应组件能读的 TOML 配置文件，下发到各节点。

我们的 `config/` 目录下那些 toml 文件是给**手动部署** (`deploy-tikv.sh`) 用的——因为手动方式没有 TiUP 帮你做这个转换，所以需要自己写好配置文件再 scp 过去。

---

## topology.yaml 中 `.` 号语法的含义

**Q：官方文档说 "Use . to indicate the subcategory of the configuration, such as storage.scheduler-concurrency"，是什么意思？如果可以自定义格式，配置文件的识别要怎么适配？**

A：这是 TiUP 的核心设计——**YAML 点号语法会自动转换成 TOML 层级结构**。

例如在 `topology.yaml` 里写：

```yaml
server_configs:
  tikv:
    storage.scheduler-concurrency: 204800
    rocksdb.defaultcf.block-size: "64KB"
```

TiUP 的 `deploy` 阶段自动转换成 TiKV 能读的标准 TOML：

```toml
[storage]
scheduler-concurrency = 204800

[rocksdb.defaultcf]
block-size = "64KB"
```

点号 `.` 就是 TOML 里的嵌套层级分隔符。`a.b.c = value` → `[a.b] \n c = value`。不需要你做任何适配——TiUP 内部维护了每个组件的 TOML schema，知道如何映射。

### 两层配置

| 位置 | 作用域 | 示例 |
|------|--------|------|
| `server_configs.tikv` | **全局默认**，所有 TiKV 节点生效 | `log.level: info` |
| `tikv_servers[0].config` | **单节点覆盖**，优先级更高 | `log.level: warn` |

我们的 `topology.yaml` 没有写 `server_configs`，用的是 TiKV/PD 内部默认值。`config/` 目录下的 toml 文件是给手动部署 (`deploy-tikv.sh`) 用的，TiUP 方式用不到它们。

---

## deploy_dir 和 data_dir 参数的含义

**Q：deploy-tikv-tiup.sh 中，deploy_dir 和 data_dir 两个参数是做什么的？**

A：TiUP 在每个 VM 上创建的两个目录：

| 参数 | 值 | 存放内容 |
|------|----|---------|
| `deploy_dir` | `/opt/tikv-deploy` | 二进制文件、启动脚本、配置文件 |
| `data_dir` | `/data` | TiKV/PD 运行时数据 |

TiUP 部署后 VM 上的实际目录结构：

```
/opt/tikv-deploy/          ← deploy_dir，TiUP 管理的全部部署文件
  ├── pd-2379/
  │   ├── bin/pd-server     ← PD 二进制
  │   ├── conf/pd.toml      ← TiUP 根据 topology.yaml 生成的配置文件
  │   └── scripts/run_pd.sh ← TiUP 生成的启动脚本
  └── tikv-20160/
      ├── bin/tikv-server
      ├── conf/tikv.toml
      └── scripts/run_tikv.sh

/data/                      ← data_dir，所有运行时数据
  ├── pd-2379/              ← PD 的 Raft 日志、集群成员信息
  └── tikv-20160/           ← TiKV 的 RocksDB、RaftDB、WAL
```

和手动部署的对应关系：

| 手动部署 | TiUP 部署 | 内容 |
|---------|----------|------|
| `/opt/pd/bin/pd-server` | `/opt/tikv-deploy/pd-2379/bin/pd-server` | 二进制 |
| `/opt/pd/conf/pd.toml` | `/opt/tikv-deploy/pd-2379/conf/pd.toml` | 配置 |
| `/data/pd/` | `/data/pd-2379/` | 数据 |
| `/opt/tikv/bin/tikv-server` | `/opt/tikv-deploy/tikv-20160/bin/tikv-server` | 二进制 |
| `/data/tikv/` | `/data/tikv-20160/` | 数据 |

两个目录分开的好处：升级时 `deploy_dir` 可以整体替换，不影响 `data_dir` 里已有的数据。

---

## 宿主机上没有 /opt/tikv-deploy/ 和 /data/ 目录

**Q：我现在处于部署状态，为什么在宿主机上没有 /opt/tikv-deploy/ 和 /data/ 这两个目录？**

A：这两个目录在 **VM 里面**，不在宿主机上。TiUP 通过 SSH 远程在每台 VM 上创建它们。

验证：

```bash
ssh ubuntu@172.16.0.101 "ls /opt/tikv-deploy/ /data/"
```

宿主机上只有这些：

```
~/demo/tikv-qemu/
  ├── deploy-tikv-tiup.sh    ← 部署脚本
  ├── config/topology.yaml   ← 拓扑声明
  └── ~/.tiup/               ← TiUP 自身的状态数据
```

部署是 TiUP → SSH → VM 执行的，所有二进制、配置、数据都在 VM 里。

---

## 宿主机与 VM 的部署协作机制

**Q：VM 中的二进制、配置、数据是怎么来的？是 TiUP 所在的宿主机传过去的，还是 TiUP 登录到 VM 上创建的，还是 VM 自己下载或者创建的？执行 `tiup cluster deploy` 和 `tiup cluster start` 时，宿主机和 VM 各自做了什么，是怎么一步步配合将集群部署起来的？**

A：整个部署过程中，**宿主机是大脑，VM 是执行者**。

### tiup cluster deploy 阶段

```
宿主机 (WSL2)                              VM (172.16.0.x)
─────────────                              ─────────────────
1. 读取 topology.yaml
   知道: 3 PD + 3 TiKV 在哪

2. SSH 到 VM "你是 PD 节点"
        ─────────────────────────────────→  3. 我就是，但我什么都没有

4. 从 tiup-mirrors 下载 pd-server
   到宿主机本地缓存 (~/.tiup/)              （等待中）

5. scp pd-server → VM
        ───────── pd-server.tar.gz ────→  6. 收到，解压到
                                              /opt/tikv-deploy/pd-2379/bin/

7. 根据 topology.yaml 生成 pd.toml
        ───────── pd.toml ─────────────→  8. 放到
                                              /opt/tikv-deploy/pd-2379/conf/

9. 生成启动脚本 run_pd.sh
        ───────── run_pd.sh ───────────→  10. 放到
                                              /opt/tikv-deploy/pd-2379/scripts/

11. 检查环境 (tiup cluster check)
     - cpu、内存、磁盘、端口、内核参数
        ───────── 提问 ────────────────→  12. 回答系统状态
     - 不满足则 --apply 自动修复
        (比如写 sysctl 参数)

13. 对另外 2 个 PD 和 3 个 TiKV 重复步骤 2-12
```

关键：**二进制是宿主机下载后 scp 过去的，不是 VM 自己下的**。TiUP 在宿主机有个本地缓存 `~/.tiup/components/`，避免重复下载。

### tiup cluster start 阶段

```
宿主机                                    VM
─────────────                             ─────────────────
1. 按 topology.yaml 顺序决定启动顺序
   先 PD，再 TiKV

2. SSH 到 VM1 "启动 PD"
        ─── start pd ─────────────────→  3. systemctl start pd
                                           pd-server 读取
                                           /opt/tikv-deploy/pd-2379/conf/pd.toml
                                           → 尝试连接 PD2、PD3
                                           → 形成 Raft 集群

4. SSH 到 VM2 "启动 PD"
5. SSH 到 VM3 "启动 PD"
6. 等待 PD 集群选举 Leader

7. SSH 到 VM1 "启动 TiKV"
        ─── start tikv ───────────────→  8. systemctl start tikv
                                           → 向 PD 注册自己
                                           → PD 分配 Region

9. SSH 到 VM2、VM3 依次启动 TiKV
10. --init: 初始化 PD 集群元数据
        ─── pd-ctl 命令 ───────────────→  11. PD 执行初始化

12. UpdateTopology: 把最终状态写回
    ~/.tiup/storage/cluster/clusters/
```

### 总结

| 谁做的 | 做什么 |
|--------|--------|
| **宿主机** | 下载二进制、生成配置文件、生成启动脚本、决定启动顺序、存储集群元数据 |
| **VM** | 接收文件、运行 systemd 服务、执行 PD/TiKV 进程 |
| **没有发生的** | VM 自己下载任何东西 —— 都是宿主机传过去的 |

这和 `deploy-tikv.sh` 做的事情本质一样——下载 → scp → systemd——只是 TiUP 把这套流程标准化了。

---

## TiUP 生成的配置文件为何是空的

**Q：pd 和 tikv 的 toml 文件一般会有哪些配置？我在 VM 上看配置文件是空的，但集群依然能通过读写测试，这个配置文件没有是不是也不影响集群正常工作？**

A：TiUP 生成的配置文件确实基本为空——只有注释，没有实际配置项：

```bash
$ cat /opt/tikv-deploy/pd-2379/conf/pd.toml
# WARNING: This file is auto-generated. Do not edit!
# All configuration items you want to change can be added to:
# server_configs:
#   pd:
#     aa.b1.c3: value
$ cat /opt/tikv-deploy/tikv-20160/conf/tikv.toml
# WARNING: This file is auto-generated. Do not edit!
# All configuration items you want to change can be added to:
# server_configs:
#   tikv:
#     aa.b1.c3: value
```

集群正常工作是因为 **TiKV 和 PD 的所有参数都有内置默认值**。空配置文件意味着全部使用默认值，不是漏配了。

### 常见配置段

**PD 配置**（`pd.toml`）：

| 段 | 常用项 | 默认值 | 说明 |
|-----|--------|--------|------|
| `name` | — | hostname | 节点名 |
| `data-dir` | — | `./` | PD 数据目录 |
| `client-urls` | `http://0.0.0.0:2379` | `http://0.0.0.0:2379` | 客户端 API 监听地址 |
| `peer-urls` | `http://0.0.0.0:2380` | `http://0.0.0.0:2380` | PD 节点间通信 |
| `initial-cluster` | — | — | 首次启动时的成员列表 |
| `log.level` | `info` | `info` | 日志级别 |
| `replication.max-replicas` | `3` | `3` | 数据副本数 |

**TiKV 配置**（`tikv.toml`）：

| 段 | 常用项 | 默认值 | 说明 |
|-----|--------|--------|------|
| `server.addr` | — | `127.0.0.1:20160` | 服务端口 |
| `server.advertise-addr` | — | — | 对外宣告地址 |
| `storage.data-dir` | — | `./` | RocksDB 数据目录 |
| `pd.endpoints` | — | — | **必填**，连哪个 PD |
| `rocksdb.defaultcf.block-size` | `64KB` | `64KB` | 数据块大小 |
| `raftstore.raftdb-path` | — | `./raft` | Raft 日志目录 |
| `log.level` | `info` | `info` | 日志级别 |
| `coprocessor.split-region-on-table` | `false` | `false` | 自动分裂 Region |

### 为什么空配置也能工作

官方文档里洋洋洒洒几百个参数，实际上**只有两个是必须指定的**：

1. `pd.endpoints` — TiKV 连接哪个 PD
2. `data-dir` — 数据存在哪里

这两个 TiUP 作为**命令行参数**传给了进程（`--pd-endpoints`、`--data-dir`），不需要写进 toml 文件。TiUP 在生成的启动脚本中自动处理了这些关键参数。

**总结：没有写到 toml 里的配置 = 使用内置默认值，不是漏配。** 只有想把某个参数改成非默认值时，才需要写到 topology.yaml 的 `server_configs` 段里，TiUP 会在下次 `reload` 时更新生成的配置文件。
