# LibXR 2.0 上游模块核查

核查日期：2026-10-13。只读检查本地工作区与上游源码，未升级固件、未执行迁移编译。上游默认分支均以本次下载的完整 commit 固定，下表链接是源码证据；这些 commit 的迁移接口不等于固定 LibXR 2.0.1 的整机验证。

## 结论

当前 30 个模块中，QDU-Robomaster 有 21 个公开同名仓库。20 个最新版本已移除 `app_framework.hpp`；QDU 的 BMI088 仍依赖旧动态框架。另有 9 个在组织公开仓库列表未找到同名仓库，其中 6 个可从 xrobot-org 找到 v2 候选。不能通过直接覆盖目录完成升级：多个 PLDX 模块有控制算法、安全保护及协议定制。

本地装配、工具链和实际两板依赖范围见 [整机迁移评估](libxr2_migration_assessment.md)。已有 Gimbal 历史逐提交对照见 [云台上游核查](gimbal_upstream_review.md)。本次不会覆盖 Gimbal、Referee 已存在的未提交修改。

## QDU 同名模块：21 个

“定制程度”基于当前头文件和本地 Git 最近行为改动的静态核对，不是行数或充分回归验证。

| 模块 / 固定上游源码 | 建议 |
| --- | --- |
| [BMI088 `0c9f8e74`](https://github.com/QDU-Robomaster/BMI088/blob/0c9f8e746daa3876011844664ded58114cd6a81e/BMI088.hpp) | 旧框架仍在；优先参考 xrobot-org 对应 v2，而非这个 QDU 分支。保留本地微秒写延迟和空校准保护。 |
| [CMD `37b7700e`](https://github.com/QDU-Robomaster/CMD/blob/37b7700e9cce3ee74601d9fdcb67961792a21359/CMD.hpp) | 高：本地 SI/force 底盘命令、主机云台设定与遥控回退；移植装配接口，保留命令契约。 |
| [CameraSync `6cb451df`](https://github.com/QDU-Robomaster/CameraSync/blob/6cb451df977f85d05156fa2b22df9cd5301924ca/CameraSync.hpp) | 较低：可参考 GPIO 引用注入/Param；保留类型回调与 divider 限制。 |
| [Chassis `32761d01`](https://github.com/QDU-Robomaster/Chassis/blob/32761d015294031f3d5ac8326b1a394c796302a9/Chassis.hpp) | 高：本地 Omni 状态/力命令与功率控制联动；不能直接覆盖。 |
| [DMMotor `7f1dc12a`](https://github.com/QDU-Robomaster/DMMotor/blob/7f1dc12abc8b05993671befcb8f1bba694755f5b/DMMotor.hpp) | 中高：本地反馈帧校验、IsOnline() 和特殊命令发送；不能退回上游直接实现。 |
| [DR16 `79c22deb`](https://github.com/QDU-Robomaster/DR16/blob/79c22deb4187f5af4225077fe19434bd81835171/DR16.hpp) | 中：本地右拨杆中位 feed 行为上游没有，替换会改变操作逻辑。 |
| [Dart `249326bf`](https://github.com/QDU-Robomaster/Dart/blob/249326bfbc7aa42e6460302dafa0e871770eb596/Dart.hpp) | 中高：本地离线停机、重复目标刷新、测量角速度 D 项；保留行为修复。 |
| [DebugCore `5362bbfa`](https://github.com/QDU-Robomaster/DebugCore/blob/5362bbfa08908437bef7c5b3cab7ff99452790ff/DebugCore.hpp) | 较低：构造变为无参，移除动态应用；保留本地 SleepUntil 监控调度。 |
| [EventBinder `3d4adde3`](https://github.com/QDU-Robomaster/EventBinder/blob/3d4adde3a7c10152a6a0b6c67738b88c972bd675/EventBinder.hpp) | 中：改为显式 ModuleInfo 表而非 ApplicationManager 名称查找；重建事件映射。 |
| [Gimbal `502a9dba`](https://github.com/QDU-Robomaster/Gimbal/blob/502a9dba7737cd37cd2f48da901a76e9583d5ed2/Gimbal.hpp) | 高：本地 SMC、LQR/ESO、辨识与离线保护；保留控制核心，移植 Param/Topic 参数化。 |
| [HeroLauncher `254179db`](https://github.com/QDU-Robomaster/HeroLauncher/blob/254179db8c85de49adb51b4ded76023e1646a903/HeroLauncher.hpp) | 中：本地固定 2 ms 周期、冷却 rate×dt 修复；迁移装配后重放测试。 |
| [HostData `7fb5d783`](https://github.com/QDU-Robomaster/HostData/blob/7fb5d7836383e48e97993216fff158977fe85a58/HostData.hpp) | 高：上游没有 PLDX HostDataLink，主机命令协议/失效状态机不同。 |
| [InfantryLauncher `857d1882`](https://github.com/QDU-Robomaster/InfantryLauncher/blob/857d18828877165286a19099181e34184db591e6/InfantryLauncher.hpp) | 高：本地 HostDataLink、在线信息、弹量/弹速反馈与热控；保持链路契约。 |
| [MiniGimbal `608447c5`](https://github.com/QDU-Robomaster/MiniGimbal/blob/608447c55f9e33b2bc2f75030907e4f0a227fe51/MiniGimbal.hpp) | 中高：本地电机离线 Relax、CycleValue 与 Reset 修复；保留行为修复。 |
| [Motor `b7827499`](https://github.com/QDU-Robomaster/Motor/blob/b78274996f93eec611efab2ba7ecc51fbd5672b9/Motor.hpp) | 高影响基础接口：上游不含本地 IsOnline()，需要保留并联动 RMMotor/DMMotor。 |
| [PowerControl `4097e1f6`](https://github.com/QDU-Robomaster/PowerControl/blob/4097e1f6a3fad89126e82b920217961286966d84/PowerControl.hpp) | 高：本地 RM2024 模型、内部能量预算与反馈接口；上游实现不是等价替换。 |
| [RMMotor `e9d5fa37`](https://github.com/QDU-Robomaster/RMMotor/blob/e9d5fa3748cd984777a9fabdce40062d610660b2/RMMotor.hpp) | 中高：本地反馈时间戳、队列与 IsOnline()；迁移 CAN 引用注入时保留新鲜度判定。 |
| [Referee `79f8e5ca`](https://github.com/QDU-Robomaster/Referee/blob/79f8e5ca0afb56eaf2554d760eef67d067bca504/Referee.hpp) | 高：本地解析重同步、监控/视频链路离线处理，并有未提交修改；逐块迁移。 |
| [SentryProtocol `81b3a8c5`](https://github.com/QDU-Robomaster/SentryProtocol/blob/81b3a8c55a89f6d3fd1787c8468570765f0b9bcb/SentryProtocol.hpp) | 较低：参考无 hw/app 构造及可配置 Topic；核对数据结构与本地类型回调。 |
| [SuperPower `aaa8db0d`](https://github.com/QDU-Robomaster/SuperPower/blob/aaa8db0d379874d1f90dfcfde1d4b0bbb9d9a05a/SuperPower.hpp) | 高：本地遥测快照、反馈队列/同步与电容使用控制；联动 PowerControl 保留。 |
| [VT13 `7927154b`](https://github.com/QDU-Robomaster/VT13/blob/7927154b47f5da7bab47e86da098705a8d4e26ae/VT13.hpp) | 较低：可参考 UART 引用注入/Param；仍核对遥控事件和本地 CMD 类型。 |

## QDU 未找到同名仓库：9 个

组织公开仓库分页检查为 [第 1 页](https://github.com/orgs/QDU-Robomaster/repositories)、[第 2 页](https://github.com/orgs/QDU-Robomaster/repositories?page=2&type=all)、第 3 页为空。此处仅表示本次公开可见结果，不推断私有仓库或其他名称实现。

| 本地模块 | 可参考的固定源码 / 建议 |
| --- | --- |
| BlinkLED | [xrobot-org/BlinkLED `0ca16202`](https://github.com/xrobot-org/BlinkLED/blob/0ca1620261fea84a3a391ff219199b7bef4d9a1e/BlinkLED.hpp)：已使用 manifest v2，头文件无旧 app_framework；仍需对照 PLDX 参数、Topic 和行为差异。 |
| BuzzerAlarm | [xrobot-org/BuzzerAlarm `a7c17cf7`](https://github.com/xrobot-org/BuzzerAlarm/blob/a7c17cf7b1d10409848c32bd420cb393515e7f27/BuzzerAlarm.hpp)：已使用 manifest v2，头文件无旧 app_framework；仍需对照 PLDX 参数、Topic 和行为差异。 |
| IST8310 | [xrobot-org/IST8310 `10da519c`](https://github.com/xrobot-org/IST8310/blob/10da519cdad5a37713287ae719e57c90adf206ba/IST8310.hpp)：已使用 manifest v2，头文件无旧 app_framework；仍需对照 PLDX 参数、Topic 和行为差异。 |
| MadgwickAHRS | [xrobot-org/MadgwickAHRS `e98a223b`](https://github.com/xrobot-org/MadgwickAHRS/blob/e98a223b84e44ca8718fe8e68b4b63577ec70499/MadgwickAHRS.hpp)：已使用 manifest v2，头文件无旧 app_framework；仍需对照 PLDX 参数、Topic 和行为差异。 |
| SharedTopic | [xrobot-org/SharedTopic `60057126`](https://github.com/xrobot-org/SharedTopic/blob/6005712610dc754e842482f52fd2c5a335f67d99/SharedTopic.hpp)：已使用 manifest v2，头文件无旧 app_framework；仍需对照 PLDX 参数、Topic 和行为差异。 |
| SharedTopicClient | [xrobot-org/SharedTopicClient `157d8bc1`](https://github.com/xrobot-org/SharedTopicClient/blob/157d8bc1e5d45cb35526b8892046f23ae33947ab/SharedTopicClient.hpp)：已使用 manifest v2，头文件无旧 app_framework；仍需对照 PLDX 参数、Topic 和行为差异。 |
| DualBoard | 本次未定位 QDU 同名实现；保留 PLDX 自定义协议，独立迁移旧框架接口。 |
| HostDataLink | 本次未定位 QDU 同名实现；保留 PLDX 自定义协议，独立迁移旧框架接口。 |
| TalosLink | 本次未定位 QDU 同名实现；保留 PLDX 自定义协议，独立迁移旧框架接口。 |

BMI088 虽然 QDU 有同名库，但更相关的候选是 [xrobot-org/BMI088 `e4e64d70`](https://github.com/xrobot-org/BMI088/blob/e4e64d705f5b61685e629a91e123ad2febe75fc7/BMI088.hpp)：已使用 manifest v2，头文件不再引用 app_framework。QDU 最新 Chassis 的 manifest 也明确依赖 xrobot-org/BMI088、xrobot-org/MadgwickAHRS，说明上游自身已转向这些公共模块。

## 上游迁移接口与冲突

1. **构造和装配同步变化**：新版头文件普遍为 `MODULE MANIFEST V2`，依赖改为 `id/ref`；构造函数显式注入 UART/CAN/GPIO、CMD、Motor 引用及 `Param`，移除 `HardwareContainer`、`ApplicationManager` 与 Application 继承。上表每个固定源码可直接核对。旧 `constructor_args` YAML 不能原样连接这些构造函数。
2. **事件绑定变化**：EventBinder 新版接受显式 `std::initializer_list<ModuleInfo>`；本地基于动态应用注册表查找模块，配置和生成逻辑必须联动。
3. **电机生命周期契约**：本地 Motor 的纯虚 `IsOnline()` 已被多处离线保护消费；上游 Motor 最新没有该接口。换成上游会同时导致编译和行为变化，必须把 PLDX 接口与驱动反馈新鲜度实现保留下来。
4. **链路契约**：HostData、InfantryLauncher 本地依赖 `Pldx::HostDataLink`，上游对应源码没有该协议依赖；不能因同名模块便假定 Topic payload 兼容。SharedTopic/SharedTopicClient 也需与对端同时核对。
5. **功率链路**：本地 PowerControl 通过 SuperPower::GetTelemetrySnapshot 与内部预算工作，上游 PowerControl 使用不同实现与 API；需整体保留本地模型，再迁移外层接口。

## 推荐执行顺序

先在隔离分支固定 LibXR、xrobot 与每个上游候选 commit；保留 PLDX 注册源。先迁移 Motor/CMD/公共模块及平台静态装配，再以现有实现迁移底盘功率链和主机链，最后迁移云台/发射控制。对低定制模块也应选取迁移接口，而非盲目 pull 覆盖。

完成两板配置 `-Werror` 构建后，回归离线电机保护、遥控拨杆映射、主机命令超时、双板协议、功率限制和发射热控；涉及控制循环和时序的变更还需要实机验证。本次源码核查未证明上游所有模块固定版本组合可编译运行。

## 方法与边界

GitHub REST API 返回限流 403，因此组织枚举使用 GitHub 官方仓库页分页，代码使用各官方仓库 `git clone --depth 1`；临时副本均位于 `/tmp/qdu-module-audit`。只读比较了本地当前头文件、模块 Git 最近历史和上游头文件。没有替换既有 registry，也没有把“同名”当作已证明同源或可直接 fast-forward。
