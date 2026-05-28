# VM 镜像目录

此目录存放 QEMU 虚拟机运行所需的镜像文件，均在执行脚本时自动生成或下载：

| 文件 | 来源 | 说明 |
|------|------|------|
| `noble-server-cloudimg-amd64.img` | `download-image.sh` | Ubuntu 24.04 基础云镜像（约 600MB） |
| `vm{1,2,3}.qcow2` | `create-vms.sh` | 各 VM 的根文件系统（写时复制增量层） |
| `vm{1,2,3}-data.qcow2` | `create-vms.sh` | 各 VM 的独立 TiKV/PD 数据盘（10GB） |
| `vm{1,2,3}-seed.img` | `create-vms.sh` | cloud-init 配置打包的 ISO |
| `vm{1,2,3}.pid` | `start-vms.sh` | QEMU 进程 PID 文件（运行时生成） |

以上文件均不纳入版本控制。基础镜像需执行 `bash download-image.sh` 下载，其余文件执行 `bash create-vms.sh` 生成。
