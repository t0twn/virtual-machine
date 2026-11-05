# vmctl-portable

`vmctl` 是一个面向 Ubuntu 22.04/24.04 x86_64 宿主的便携式虚拟机管理器。
发布包解压后即可使用，不需要在宿主执行 `apt install`，也不依赖
libvirt、Docker、系统 QEMU、NFS 或 Samba。

项目默认创建无窗口的 Ubuntu Server 虚拟机，通过 SSH 管理，并可用
VirtioFS 将宿主目录挂载进 Guest。

## 宿主边界

项目能够携带用户态程序、固件、动态链接器和共享库，但不能携带或替换宿主
Linux 内核：

- 宿主必须是 x86_64 Linux；正式支持 Ubuntu 22.04 和 24.04。
- BIOS/UEFI 中应开启 Intel VT-x 或 AMD-V。
- 当前用户能读写 `/dev/kvm` 时使用 KVM；否则警告后使用较慢的 TCG。
- 目录共享要求宿主允许非特权 user namespace。禁用时 VM 仍可运行，但
  VirtioFS 共享会拒绝启动。
- 首次下载 Ubuntu cloud image 需要 HTTPS；镜像缓存后可以离线创建实例。

先运行：

```sh
./vmctl doctor
```

## 快速开始

```sh
# 下载、验签 Ubuntu 24.04 镜像，创建并启动 VM
./vmctl create dev

# 登录
./vmctl ssh dev

# 查看和管理
./vmctl list
./vmctl status dev
./vmctl logs dev
./vmctl stop dev
./vmctl start dev
./vmctl delete dev
```

默认资源为 2 vCPU、2048 MiB RAM 和 20 GiB 虚拟磁盘。SSH 自动使用
`127.0.0.1:22000-22999` 中的空闲端口。

自定义示例：

```sh
./vmctl create build \
  --ubuntu 22.04 \
  --cpus 4 \
  --memory 4096 \
  --disk 40 \
  --forward tcp:28080:8080 \
  --strict-kvm
```

`create` 默认启动实例；使用 `--no-start` 只创建磁盘和配置。

## 调整 CPU、内存和磁盘

`resize` 每次调整一种资源，成功后保存配置，下次启动继续使用：

```sh
# 当前内存目标为 2 GiB，上限为 8 GiB
./vmctl create dev --memory 2048 --memory-max 8192

# 以下命令可在 VM 运行时执行
./vmctl resize dev --cpus 4
./vmctl resize dev --memory 4096
./vmctl resize dev --disk 40
```

| 资源 | 运行时 | 关机后 |
| --- | --- | --- |
| CPU | 支持增加，通常最多 255 个 vCPU | 支持增加、减少 |
| 内存 | 通过 virtio-balloon 调整目标，范围为 256 MiB 到本次启动的内存上限 | 支持增加、减少；超过原上限时自动提高上限 |
| 内存上限 | 不支持修改 | `resize NAME --memory-max MIB`，不能低于内存目标 |
| 磁盘 | 支持扩容 | 支持扩容；始终拒绝缩容 |

内存上限默认等于创建时的内存大小。需要扩大已有 VM 的在线调整范围时：

```sh
./vmctl stop dev
./vmctl resize dev --memory-max 16384
./vmctl start dev
./vmctl resize dev --memory 8192
```

内存采用 balloon 方式，QEMU 在启动时提供上限大小的 RAM，Guest 启动后才设置
目标值，因此启动阶段可能使用到上限内存，宿主需要能承受该上限。
运行时命令成功表示 QEMU 接受目标，实际调整是异步的，取决于 Guest 的 balloon
驱动和内存压力；不会保证立即释放或获得精确数量的可用内存。
`status` / `list` 中的内存数值为配置目标，可在 Guest 内用 `free -m` 检查实际情况。
新增 CPU 也需要 Guest 将其上线，可用 `lscpu` 查看。默认预留 255 个 CPU 插槽，
避免普通宿主额外依赖扩展 APIC 支持；如需 256 个 vCPU，请关机后设置，并确保
宿主和 Guest 支持相应 APIC 配置。

磁盘命令只扩展 qcow2 虚拟磁盘容量，不自动修改 Guest 分区和文件系统。
请先在 Guest 内使用 `lsblk -f`、`findmnt /` 确认布局，再按实际分区及文件系统
使用 `growpart`、`resize2fs` 或 `xfs_growfs`；LVM 布局还需要扩展相应卷。

升级前已运行的 VM 需要先通过 `stop` / `start` 重启一次，才能在线调整 CPU 和
内存。CPU 批量增加若中途失败，会逐个保存已经成功增加的数量；QMP 超时或连接
错误时，需检查运行状态后再重试，因为请求可能已在 QEMU 中生效。

## 目录共享

相对宿主路径总是相对于项目根目录解析，而不是当前 shell 的工作目录：

```sh
# 默认只读，Guest 挂载点为 /mnt/source
./vmctl create dev --share source

# 指定 Guest 路径
./vmctl create dev --share source:/mnt/code

# 显式允许 Guest 写宿主目录
./vmctl create dev --share source:/mnt/code:rw
```

也可以在 VM 关机后修改：

```sh
./vmctl share add dev --source source --target /mnt/code
./vmctl share add dev --source output --target /mnt/output --read-write
./vmctl share list dev
./vmctl share remove dev --target /mnt/output
```

项目内相对路径会随整个项目目录移动。绝对路径也可使用，但
`share list` 会标记为不可便携。

读写共享不是复制：Guest 的删除和覆盖会立即影响宿主文件。`vmctl` 会阻止
共享自身的 `.vmctl` 状态、SSH 私钥、磁盘、镜像缓存、运行时目录或项目根。

## 镜像与磁盘

```sh
./vmctl image pull 24.04
./vmctl image pull 22.04
./vmctl image list
```

下载流程先用内置 Ubuntu cloud image keyring 验证 `SHA256SUMS.gpg`，再校验
镜像 SHA-256。基础镜像按内容哈希保存且永不原地覆盖；每个 VM 使用 qcow2
增量盘和相对 backing path。

运行状态保存在 `.vmctl/`：

```text
.vmctl/
├── images/objects/       # 不可变官方基础镜像
├── images/refs/          # 22.04/24.04 当前引用
├── instances/<name>/     # 配置、增量盘、seed、PID、socket、日志
└── ssh/                  # 项目专用密钥与 known_hosts
```

只能在所有 VM 关机后移动项目目录。

## 构建便携运行时

源码仓库不提交数百 MB 的第三方二进制。构建机需要 Podman 或 Docker；目标机
不需要。

```sh
./tools/build-runtime.sh
./tools/package.sh
```

构建固定使用 Ubuntu 22.04、QEMU 11.0.3 和 Rust virtiofsd 1.13.2，生成：

- `dist/vmctl-0.1.0-linux-x86_64.tar.gz`
- 对应 SHA-256 文件
- 独立的 GPL 对应源码归档及 SHA-256

运行时包括 BusyBox、QEMU、SeaBIOS、virtiofsd、curl/CA、gpgv/keyring、
xorriso、OpenSSH、socat、unshare、ELF loader 和动态库闭包。

## 测试

```sh
make test
```

该命令执行 shell 语法检查、状态/路径单元测试以及使用假 QEMU/virtiofsd 的
完整生命周期测试。真实验收步骤见
[docs/ubuntu-acceptance.md](docs/ubuntu-acceptance.md)。

## 非目标

首版不支持 GUI、桥接/TAP、热插拔共享、快照、休眠、实时迁移、Windows、
非 Ubuntu Guest、ARM 宿主或 9p 回退。
