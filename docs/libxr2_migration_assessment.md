# 当前工程 LibXR 2.0 升级可行性评估

核查日期：2026-10-13。结论：可以迁移，但不能只更新 LibXR 或批量替换模块。本文是源码与工具包检查，未升级固件、未执行升级后的双配置编译或硬件验证。上游逐模块证据见 [模块调查](libxr2_upstream_findings.md)。

## 本地基线与明确阻塞

- LibXR 当前检出 `c512b364a`，并非本次查询到的最新 release `v2.0.1`。上游删除旧动态 Application 框架的提交为 [c9c638b4c](https://github.com/xrobot-org/LibXR/commit/c9c638b4c)。
- Modules 下实际存在 30 个独立模块仓库，来源均为 GUET-PLDX；模块索引仍是 `GUET-PLDX/pldx-modules`，不是 QDU-Robomaster。
- 29 个模块的顶层头文件引用 Application、HardwareContainer 或 ApplicationManager；Motor 虽不继承 Application，仍 include `app_framework.hpp`。因此 30 个模块均有旧框架头依赖。
- `User/app_main.cpp` 仍 include `app_framework.hpp`，创建 HardwareContainer，调用 `XRobotMain(peripherals)`。这些都需要迁移。
- 本地 `.venv-xrobot` 安装 xrobot 0.3.1，其 GenerateMain.py 输出旧 ApplicationManager。CMakeLists.txt 通过 `xrobot_gen_main` 生成代码；Linux 构建脚本也检查这个命令。
- [PyPI xrobot 1.0.1](https://pypi.org/project/xrobot/1.0.1/) 的 wheel 已单独下载检查：console entry 仅 `xrobot`，生成命令是 `xrobot gen`；配置示例使用 `module: 组织/模块` 和 `args`；BSP 使用 `XR_REGISTER`、`XROBOT_MAIN()`。当前 `name` / `constructor_args` / `@&实例` 写法需要按新版实际解析规则迁移，不能只换生成器程序。
- Modules/CMakeLists.txt 会包含有 CMakeLists.txt 的子目录。应检查未实例化模块是否也有编译源，不能假定只迁移 YAML 中直接列出的模块即可。

## 实际运行范围

云台配置直接使用 12 类模块：BMI088、BuzzerAlarm、CMD、DR16、DualBoard、EventBinder、Gimbal、InfantryLauncher、MadgwickAHRS、RMMotor、Referee、TalosLink。

底盘配置直接使用 11 类模块：BMI088、BuzzerAlarm、CMD、Chassis、DualBoard、MadgwickAHRS、PowerControl、RMMotor、Referee、SentryProtocol、SuperPower。

联合为 16 类（交集 7 类）；还须跟随头文件与 manifest 依赖迁移 Motor、DebugCore、共享 Topic 等被间接使用的模块。其余模块可后续处理，但要检查构建是否包含它们。

## 必须保留的本地行为

| 范围 | 检查到的本地契约 | 升级要求 |
| --- | --- | --- |
| Motor / RMMotor / DMMotor | Motor::IsOnline、Feedback::received_time_us、Feedback::sequence；RMMotor 在有效反馈解析时记录时间与递增序号 | 电机接口和实现一起迁移，保留离线保护和反馈新鲜度语义 |
| Gimbal | YawSmc、YawLqrEso、实测角速度导数、SetFeedForward、在线检测 | 迁移构造与硬件注入，保留本地控制器和 PID 语义 |
| Chassis / PowerControl / SuperPower | 当前舵轮与小陀螺参数、功率控制模块连接 | 核对单位、功率限幅与失联状态；上游算法变化另作行为升级评估 |
| DualBoard / SentryProtocol / SharedTopic 系列 | 板间帧、共享 Topic、购弹及复活状态 | 双板同时验证，保留帧布局、Topic 类型和超时保护 |
| TalosLink / HostDataLink | 本地外部通信集成 | 按本地协议迁移；没有同名上游模块不能据此删掉 |
| InfantryLauncher / Referee | 发射、热控和裁判系统消息消费者 | 对齐数据结构和热量限制，保留本地安全逻辑 |

Gimbal、Referee 的嵌套仓库当前有未提交改动；根仓库也有 YAML、构建脚本和文档改动。调查未覆盖或回退这些改动。

## 推荐实施顺序与验收

1. 固定 LibXR release、xrobot 版本及各模块 commit，先在隔离副本建立当前双配置构建基线。
2. 迁移 BSP 注册、CMake 生成命令和两份 YAML，先用 BlinkLED 验证新版静态装配最小链路。
3. 按依赖顺序迁移 Motor/DebugCore、传感器与电机、CMD/遥控器/裁判系统，再迁移控制模块与本地板间、主机协议模块。借鉴上游构造器与显式依赖注入，保留 PLDX 行为。
4. 两份配置分别通过生成与 `-Werror` 编译，检查 Flash/RAM/线程栈占用；运行已有模块回归检查。
5. 硬件验收覆盖电机反馈离线、遥控器失联、板间通信超时、姿态轴方向、云台限位、发射热控、底盘功率限制。编译成功不能替代这些验收。

不建议先统一换成 QDU 模块索引再拉取最新版：那会把结构迁移与控制/协议行为变化混在一起。优先以现有 PLDX 模块为迁移主体，从对应 QDU 模块移植静态装配方式。

## 依据

本地：Modules/sources.yaml、各模块顶层头文件、User/app_main.cpp、User/RobotConfig/*.yaml、CMakeLists.txt、tools/Linux/build_firmware.sh；xrobot 0.3.1 GenerateMain.py 与 xrobot 1.0.1 wheel 的 METADATA、entry_points.txt、generate_main.py。

上游：[LibXR releases](https://github.com/xrobot-org/LibXR/releases)、[旧框架删除提交](https://github.com/xrobot-org/LibXR/commit/c9c638b4c)、[xrobot 1.0.1 发布包](https://pypi.org/project/xrobot/1.0.1/)。Gimbal 的更细历史对照见已有 [Gimbal 核查](gimbal_upstream_review.md)。
