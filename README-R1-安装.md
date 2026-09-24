# R1 Tracking Streamer

本仓库是 Improbable-AI/VisionProTeleop 的 R1 原生输入分支，基于上游提交 `4c549905c2a8b214d79f7cd88e535101a1ce32af`，保留 MIT 许可证。

配套机器人端：https://github.com/lizuju/xr_teleoperate 。两端使用 `production-20260924` 标签。

## 本分支改动

- 在 mixed 透视空间采集头部和双手，默认预测偏移为 0 ms。
- 协议 v1 携带实际锚点采样时间和每侧追踪有效性；失追后不会用缓存姿态冒充新数据。
- 姿态服务只有绑定端口成功后才显示就绪；重复 Start 不会重复创建监听。进入后台停止服务，回到前台或再次 Start 时恢复。
- 发送只保留最新待发送姿态，取消长连接后释放端口，支持停止后重新启动。
- 移除上游作者的 iCloud、共享钥匙串权限与云登录引导，使用 R1 独立应用标识。
- 锁定 swift-async-algorithms 1.1.2，适配 Xcode 27 的并发检查。

## 编译与安装

1. 用 Xcode 27 打开根目录 `Tracking Streamer.xcodeproj`，选择 `VisionProTeleop` scheme。
2. 在 Signing & Capabilities 选择自己的 Team，并按需修改 Bundle Identifier。仓库中的 Team 和应用标识是当前部署配置；不包含签名证书或私钥。
3. 在 Device Hub 配对自己的 Vision Pro，启用开发者模式，选择真实设备后编译安装。个人账号签名到期后需重新编译安装。
4. 在头显打开 **R1 Tracking Streamer**，允许手部追踪、世界感知和本地网络；点击 Start，保持双手可见。
5. 确认设置中的 Hand Tracking → Prediction Offset 为 **0 ms**，记录 App 显示的 IP。

## 配套 Ubuntu 接收端

在 `xr_teleoperate` 的对应版本中按 `outputs/VisionProTeleop透视接入.md` 安装独立接收环境。先只验证输入：

```bash
../.venv-xr/bin/python tools/check_visionpro_input.py 头显IP --seconds 10
```

检查通过后，由操作者启动其中一种模式：

```bash
./teleop/run_r1_a7_visionpro.sh 头显IP
./teleop/run_r1_a7_visionpro_capture.sh 头显IP 这次测试名 "这次测试目标"
```

按 `r` 跟随，`s` 开始采集，`y/n/x` 分别保存为成功、失败、丢弃；`p` 暂停，`q` 退出。头部丢失或网络超时后需按 `r/s` 重新对齐再跟随；单手失追时该侧保持。原生模式暂不显示机器人相机小窗和力矩 HUD，相机数采不受影响。

Ubuntu 接收端要求协议 v1，不能用未经修改的 App Store 客户端代替本分支。机器人端使用自己的协议接收器；上游 `avp_stream` Python 包的使用方式不属于本次接入。

## 已有验证

本版本原生源码已通过 visionOS 27 编译、签名及安装，完成五种 gRPC 生命周期场景和真实头显锁屏/唤醒恢复测试。实际机器人运动应由操作者验证；这些验证不代表无线网络不会断流。
