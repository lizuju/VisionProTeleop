# 原生质量状态与标签检查

从仓库根目录在 Mac 运行：

```sh
python3 tests/operator_quality/generate.py /tmp/r1-operator-quality
swiftc /tmp/r1-operator-quality/Production.swift tests/operator_quality/Tests.swift -o /tmp/r1-operator-quality/checks
/tmp/r1-operator-quality/checks
```

生成器提取生产 `RobotOperatorStatus.swift` 中的状态 DTO，检查 pending/failed 缺省字段、保存目录关联、非成功任务的导出提示及质量统计标签。测试不启动头显或机器人；不代表真实采集效果或空间 HUD 可读性验收。
