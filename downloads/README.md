# 下载缓存目录

此目录存放部署过程中从 `tiup-mirrors.pingcap.com` 下载的 TiKV/PD 二进制包，由 `deploy-tikv.sh` 自动管理：

| 文件 | 来源 | 说明 |
|------|------|------|
| `tikv-*.tar.gz` | `deploy-tikv.sh` | TiKV server 二进制（约 280MB） |
| `pd-*.tar.gz` | `deploy-tikv.sh` | PD server 二进制（约 50MB） |

以上文件不纳入版本控制。部署时脚本自动检测是否需要下载，已存在则跳过。
