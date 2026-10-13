# PLDX 模块静态装配迁移

完成日期：2026-10-13。已迁移当前 30 个 PLDX 模块的旧框架接口；两板固件在 LibXR v2.0.1、xrobot 1.0.1 下通过编译。30 个模块迁移已分别提交并推送至各模块仓库；主工程保留远端历史并固定发布版本，未刷写固件。

## 版本与源码归属

- LibXR：`v2.0.1`，commit `5161373dbe6d9d9fb1904d90e0ebd4344a44047a`，安装在 `.tooling/LibXR-v2.0.1`。`Middlewares/`、`Drivers/` 和 CubeMX 生成的 Core 文件未修改。
- xrobot：`1.0.1`，安装在 `.venv-xrobot2`。
- 模块仍使用 GUET-PLDX 实现和各自的独立 Git 仓库；未替换为 QDU 控制算法。根目录 `xrobot.lock` 固定已发布的迁移 commit。
- [基线清单](libxr2/module-baselines.json) 记录迁移前各模块 HEAD 与已有改动。Gimbal 原有 Topic 参数化单独提交，Referee 原有格式调整随迁移保留。迁移前源码副本位于本机 `.tooling/migration-baseline/`，不作为发布依赖。

## 已完成的迁移

| 模块范围 | 迁移接口 | 保留的行为 |
| --- | --- | --- |
| Motor、RMMotor、DMMotor | 移除旧框架 include/继承；显式 CAN 引用 | IsOnline、反馈时间戳/序号、反馈校验、分组拼包 |
| BMI088、IST8310、MadgwickAHRS | 注入 SPI/I2C/GPIO/PWM、RamFS、Database | 传感器坐标变换、采样/恒温、校准、姿态监控 |
| BlinkLED、BuzzerAlarm、CameraSync | 注入 GPIO/PWM | 定时器、致命错误告警、相机触发 |
| CMD、DR16、VT13、EventBinder、DebugCore | 普通类；显式 UART/CMD/事件列表 | 控制模式、遥控事件映射、初始化开关同步、调试工具 |
| Chassis（Omni/Mecanum/Helm）、Gimbal、MiniGimbal、Dart | 移除 hw/app 参数；保留显式电机与控制依赖 | 原有控制算法、周期、离线保护、限位、系统辨识 |
| PowerControl、SuperPower | 普通类；注入 CAN/模块依赖 | PLDX 功率模型、能量预算、电容遥测与使用控制 |
| InfantryLauncher、HeroLauncher、Referee、SentryProtocol | 普通类；裁判 UART 引用 | 发射热控、在线信息、冷却、裁判解析与监控、哨兵决策 |
| DualBoard、HostData、HostDataLink、TalosLink | CAN/UART 引用、普通类 | 板间与主机帧布局、Topic、通信超时与回退 |
| SharedTopic、SharedTopicClient | UART/RamFS 注入；写端口使用 Writable/Capacity | 共享 Topic 格式、发送槽位与同步门控 |

所有模块 manifest 只保留描述、依赖和库标记，构造函数成为参数接口。模块 README 已记录新装配约定。Motor 标记为 `standalone: false`。

BSP 使用 `XR_REGISTER` / `XROBOT_MAIN()`，保留已有外设别名与 USB Talos 通道独占行为。USB CDC 的 SetConfig 增加并传递 `in_isr`。Flash 使用新版 FlashRegion 表，描述 STM32F407 的 4×16 KiB、1×64 KiB、7×128 KiB 扇区，数据库仍使用 `0x080C0000` / `0x080E0000` 两个扇区。`User/flash_map.hpp` 保留远端独立提交生成的新版表，未手工编辑。

两份机器人配置与默认 BlinkLED 配置改为 `module` / 有序 `args`；旧 YAML 中与实际构造函数不同的标签已对齐。PID 与 Quaternion 使用完整 C++ 聚合表达式，参数值保持原配置。EventBinder 使用显式模块事件表。非空 OnMonitor 保留，直接进入生成器监控循环。

CMake、Linux/Windows 构建脚本和 CI 改用新版生成器。构建脚本优先使用原生 CMake。应用目标显式启用 `-Werror`，补齐原先目录级选项未覆盖已创建应用目标的问题。

## 复现

```bash
python3 tools/setup_libxr2.py
export PATH="$PWD/.venv-xrobot2/bin:/opt/st-arm-clang/bin:$PATH"
export GCC_TOOLCHAIN_ROOT=/opt/arm-gnu-toolchain-14.2.rel1-x86_64-arm-none-eabi/bin
export CLANG_GCC_CMSIS_COMPILER=/opt/st-arm-clang
bash tools/Linux/buildgimbal.sh --skip-format -b build/libxr2_gimbal
bash tools/Linux/buildchassis.sh --skip-format -b build/libxr2_chassis
python3 tools/check_libxr2.py --build-dir build/libxr2_gimbal
```

Windows 用 `python tools/setup_libxr2.py`；PowerShell 构建脚本使用 `.venv-xrobot2/Scripts`。安装脚本在已有模块目录上检查锁定的 HEAD，不回退或清理冲突改动；包名目录通过 Linux symlink / Windows junction 指向独立模块仓库。

xrobot 1.0.1 使用固定 `User/xrobot_main.hpp`，两个配置应顺序构建。CMake 在配置与构建时生成当前产品，并在编译前执行 LibXR 的输入摘要检查。不要同时运行两板构建，也不要用旧生成器覆盖迁移后的应用。

模块迁移发布到独立仓库后，安装脚本直接使用锁文件中的迁移 commit，无需工作区补丁。

## 验证

- 默认 BlinkLED、云台、底盘三份配置：xrobot 1.0.1 生成成功。
- 全部 30 个模块主头文件：Cortex-M4 工具链 `-Werror -fsyntax-only` 检查成功；检查脚本为 `tools/check_libxr2.py`。该检查不等于所有未使用模板变体的实例化验证。
- 云台与底盘：通过实际 Linux 构建脚本的 Debug 编译与 ELF/BIN/HEX 输出。
- 33 个改动模块头文件：clang-format 21.1.8 格式检查通过。
- 主机回归：Gimbal SMC、LQR/ESO、系统辨识；Gimbal 配置顺序、Topic 契约、控制器行为及电机在线归属；RMMotor/DMMotor 新鲜度、DMMotor 编码；DualBoard 控制帧/裁判 CAN/哨兵决策帧；InfantryLauncher 热控；Dart 重复目标；HostData 新鲜度/单线程所有权；HostDataLink 帧布局；SharedTopicClient 发送门控；Talos 分包、坏帧、收发和队列满。
- Talos 测试改用新版 ReadQueue/WriteQueue 公开接口。HostData/Gimbal 配置测试改用新的构造函数/YAML 契约。
- DualBoard 原测试错误地拒绝现有协议支持的模式和导航速度；迁移前原版源码/LibXR 已复现相同失败。校正了测试断言，生产协议编解码没有修改。

| Debug 固件 | Flash | RAM（静态区域） | CCMRAM |
| --- | ---: | ---: | ---: |
| 云台 | 292,912 B | 56,848 B | 65,536 B |
| 底盘 | 279,332 B | 59,696 B | 65,536 B |

CCMRAM 的 64 KiB 是链接脚本中的堆区域预留；以上数字不代表运行时模块分配后的剩余堆，也不验证线程栈余量。

尚未刷机验证。实机仍须检查校准数据读取、电机/遥控/板间失联保护、传感器轴向、云台限位、发射热控和功率限制。Windows 脚本与 GitHub CI 已更新，但本次只执行了 Linux 本地验证。
