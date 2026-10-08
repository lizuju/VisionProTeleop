# R1 Tracking Streamer：原生透视与机器人第一人称

配套发布：**production-20261008-runtime-reconnect**，完整变化与机器人端验证见 [xr_teleoperate 发布说明](https://github.com/lizuju/xr_teleoperate/blob/production-20261008-runtime-reconnect/docs/releases/production-20261008-runtime-reconnect.md)。

本分支在 [Improbable-AI/VisionProTeleop](https://github.com/Improbable-AI/VisionProTeleop) 的 `4c549905c2a8b214d79f7cd88e535101a1ce32af` 基础上，接入 R1 头手追踪和机器人双目视频。上游 MIT 许可证保留在 [LICENSE](LICENSE)。机器人端配套代码在 [lizuju/xr_teleoperate](https://github.com/lizuju/xr_teleoperate) 和 [lizuju/teleimager](https://github.com/lizuju/teleimager)。

支持两种原生入口：

- **Start**：进入透视空间，看真实房间，向 Ubuntu 发送头手输入。
- **机器人第一人称**：显示机器人双目视频，同时发送相同头手输入；状态栏显示跟随、暂停原因、采集状态及每条保存后的质量结果。

原生输入沿用机器人端现有坐标转换、手指映射和 IK。Safari 仍使用原有网页和启动脚本，每次只运行一个控制模式。

## 在 Vision Pro 安装

本版本实际构建和真机验证环境为 **Xcode 27 / visionOS 27**。工程的较低 deployment target 不代表旧版本系统已验证。

```sh
git clone https://github.com/lizuju/VisionProTeleop.git
cd VisionProTeleop
open 'Tracking Streamer.xcodeproj'
```

需要复现特定发布时，先 checkout 相应 tag。保留项目的 `Package.resolved`，不要在安装时无意升级依赖。

1. Scheme 选 **VisionProTeleop**，Target 为 **Tracking Streamer**。显示名是 **R1 Tracking Streamer**。
2. 在 Xcode 登录自己的 Apple ID，在 Signing & Capabilities 选择自己的 Team，并设置唯一 Bundle Identifier。仓库的 Team 留空、默认 Bundle ID 为 `local.r1.TrackingStreamer`。签名证书与 provisioning profile 由自己的 Xcode 管理；无需拷贝其他人的证书。
3. Mac 和 Vision Pro 连接可互通的局域网，开启 Wi-Fi / 蓝牙。在头显“设置 → 通用 → 远程设备”保持可发现；Xcode 27 的 **Device Hub → ＋ → Pair Nearby Device…** 配对，按提示启用开发者模式。无线安装不需要 Developer Strap，配对两端不要求同一个 Apple ID。
4. 选择自己的 Vision Pro，保持佩戴解锁，Build & Run。首次安装按系统提示信任开发者。个人签名到期后用自己的 Xcode 重新签名安装。
5. 允许手部追踪、世界感知和本地网络。Hand Tracking → Prediction Offset 保持 **0 ms**。

未经本分支修改的 App Store 客户端不提供 R1 要求的有效性协议，不能替代本版本开启机器人跟随。

## 第一人称所需服务

App 内第一人称地址填写 **Ubuntu 视频网关的 IP / 主机名**，不带协议和端口。默认 `192.168.124.147` 是现有部署示例，其他部署应填写自己的地址。遥操脚本中的 IP 则是 **Vision Pro 的 IP**，二者不要混用。

| 链路 | 所需能力 |
| --- | --- |
| Ubuntu → Vision Pro | gRPC TCP 12345，接收 protocol v1 头手姿态 |
| Vision Pro → Ubuntu | HTTPS 60001 `/offer` 视频协商、`/r1/status` 遥操/采集状态 |
| PC2 / Ubuntu → Vision Pro | WebRTC H.264 视频和 `r1-video-meta-v1` 时间信息通道，局域网 UDP 可达 |

网关与相机端需要配套的 R1 原生视频/时间信息实现；仅运行上游普通 `avp_stream` 视频示例不能代替它。部署服务的命令、状态文件和配置以机器人端仓库说明为准。

第一人称目前使用固定 **1088×448 左右并排画面**，每眼 **544×448**，顺序为 head_left、head_right，视频源固定 **10 FPS**。本客户端不插帧，也不改变共享相机源的帧率。

### HTTPS 证书与相机校准

`Tracking Streamer/RobotVideoRootCA.der` 是当前部署的**公开 CA 证书**，不是私钥；有效期至 **2027-08-25 UTC**。其 SHA-256 为 `6e6f49cbb31815a2d02a4d82fa02b9633599193274163bcb07480d9861e64c5a`。换用自己的网关时，以自己的公开 CA 替换同名资源并重新构建；网关证书 SAN 必须匹配 App 填写的主机名或 IP。客户端仍检查证书有效期和主机名。不要提交 CA 私钥或服务器私钥。

`Tracking Streamer/head-optics.json` 是当前机器人头部相机的实际标定，双目基线约 **59.1 mm**。App 在 GPU 上去畸变和双目校正；这份标定不代表所有 R1 都通用。更换相机、裁剪、分辨率或光学安装后，应使用对应实际标定，不能只改数值让画面通过。文件的 `source_calibration_path` 仅记录来源，运行时不读取该机器路径。

左右相机顺序固定。取景范围支持 **60–120°**，默认取景为 **120°**，可在「…」选 **最大取景 120°**；超过 80° 的源内容映射到 80° 显示范围，以更多桌面/双手内容换取较小的物体比例。调整视角会暂时撤销视频有效性；已开始跟随时，画面和双手输入恢复连续有效更新后会自动重新对齐并继续，首次启动仍需按 r，手动暂停后按 r/s。

## 先只读检查，再启动遥操

佩戴头显，进入 Start 或机器人第一人称，双手放在视野内。在 Ubuntu 的 `xr_teleoperate` 目录运行（替换 IP）：

```sh
../.venv-xr/bin/python tools/check_visionpro_input.py VISION_PRO_IP --seconds 10
```

该工具只接收输入，不创建机器人命令发布器。确认头手有效、失追后相应侧失效、恢复后收到新源数据。第一人称还要确认画面正立、双眼舒适及源画面时间有效。

随后由操作者启动其中一个：

```sh
# 原生遥操
./teleop/run_r1_a7_visionpro.sh VISION_PRO_IP

# 或：原生遥操并逐条采集
./teleop/run_r1_a7_visionpro_capture.sh VISION_PRO_IP 这次测试名 "这次测试目标"
```

采集脚本已经包含遥操。首次按 `r` 跟随/重新对齐，`p` 手动暂停保持，手动暂停后按 `r/s` 恢复，`s` 开始一条，`y/n/x` 结束并标注成功/失败/丢弃；`x` 保留文件。结束一条后可继续按 `s`，无需重启。`q` 退出。

旧 Safari 模式仍用 `./teleop/run_r1_a7_vector.sh` 或 `./teleop/run_r1_a7_capture.sh`。

## 输入有效性、暂停与诊断

- `tracking_protocol_version=1`：字段 4–12 提供源端单调时钟采样、ARKit anchor 时间及每侧有效性；重复包不会把旧 anchor 盖成新数据。
- `diagnostics_version=1`：新增字段 13–23，分开报告原始头部追踪、视频门禁、保留的源失效次数及原因、上一包本机提交等待、当前 RPC 姿态包序号。协议定义见 `avp_stream/grpc_msg/handtracking.proto`。
- 发送端只在源状态变化时提交姿态，最高120Hz；没有变化时保留100ms心跳。每次等待写入完成后重新取最新源状态，保留期间出现过的短失效事件。
- 「…」显示已发姿态包数和本机提交等待。提交等待不是网络 RTT、送达确认或机器人响应延迟。
- 真实手/头数据过期、断线或第一人称视频过期仍触发保持。已开始跟随时，头部或整体输入失效后保持当前目标；恢复连续有效输入至少 0.35 秒，并收到至少 5 次不同的双手新样本后，自动以保持目标重新对齐继续。这里不检测双手空间静止。首次启动仍需 `r`，手动 `p` 不会自动解除，需 `r/s` 恢复；自动恢复不会开始新一条采集。单手失追沿用原来的单侧保持逻辑。
- 第一人称状态栏区分接收超时、姿态过期、头部失追、视频断连/过期、时间同步、取景调整和显示错误；整体保持原因保留到成功重新对齐。

配套原生启动脚本当前使用 500 ms 输入过期保护，第一人称视频门禁保持 500 ms；自动恢复不放宽这些阈值。gRPC/TCP已经接受的字节不能由本应用撤回，软件优化不能消除无线断流。实机只读验证仍观察到超过 500 ms 的接收间隔，不能把自动恢复理解为“无线暂停已彻底解决”。

视频重连等待按连续失败次数为 1–5 秒，累计重连次数仅用于显示。连续收到源序列和源时间均递增的新鲜画面至少 2 秒后重置退避，之后偶发故障等 1 秒；重复、未来、过期或时钟无效的数据不能触发重置。既有 3 秒无帧重连检查保持不变，日志提供 `retry_delay_s`、`consecutive_failures` 和累计 `reconnects`。

每条保存后，原位置状态栏显示“第 N 条 · 质检中”；完成后显示满足默认连续 40 帧门槛的可导出段数/帧数，或说明没有足够长的片段。“…”内查看任务标签、文件完整性、合格帧数、最长片段及主要筛除原因。失败、丢弃或未标记的数据不提示可用于默认成功示范训练。质检结果按保存目录关联，下一条采集不必等待。

机器人端采集、质量报告与训练导出使用配套同名 tag；IMU 不作为有效训练输入。

## 验证与开发

本次重连修复通过 31 项生产逻辑提取的 Swift 检查，完整 visionOS 编译及真机安装成功；配套运行版本预检与 socket 清理共 29 项 Python 检查通过。真实无线断线恢复耗时尚未测量。重连测试方法见 [tests/video_reconnect/README.md](tests/video_reconnect/README.md)。

本版 App 源码已完成 visionOS 全量编译、签名安装，发布源码与已安装的质量 HUD 源码一致。27 项 Swift 质量 DTO/标签检查通过，包括缺省字段的 pending/failed 状态、多条结果关联、非成功标签以及主要筛除原因。真实 Python 保存→质检 worker→状态发布 JSON 被生产 Swift DTO 正确读取，隔离合成数据实际导出 1 段 40 帧。本版尚未重新采集真实机器人任务；前一版本的视频、追踪与恢复验证不能代替本版采集效果实测。

可在 Mac 重新运行仓库内发送回归，方法见 [tests/native_sender/README.md](tests/native_sender/README.md)。它覆盖慢写、最新姿态、短失效、心跳和重连隔离，不代表无线或机器人运动验收。

Swift protobuf生成文件随仓库保存。修改 `.proto` 后用与锁文件对应的 SwiftProtobuf 1.33.3 `protoc-gen-swift` 生成 `Visibility=Public` 的 `handtracking.pb.swift`，同步到 `Tracking Streamer/Proto/` 和 `avp_stream/grpc_msg/`。Python 接收协议另在机器人端仓库生成。
