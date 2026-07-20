# Vision CBoard V2 双端通信设计

**日期：** 2026-07-20

**固件工程：** `/home/sb/PLDX_Template`

**视觉工程：** `/home/sb/PLDX_Sentry_Vision`

**协议基准：** 视觉工程生产哨兵 `io::CBoard`

## 1. 目标

在不修改机器人业务控制代码的前提下，使 STM32 固件与视觉小电脑使用一套明确、可测试、逐字节兼容现有 `io::CBoard` 的 V2 通信协议。

固件侧使用 LibXR 的 CAN、Topic、线程、同步和时间设施。视觉侧保留 SocketCAN，避免引入 LibXR Linux CAN 驱动及 C++20 构建依赖，只抽取无状态 V2 Codec。视觉侧 `io::CBoard` 的类名、公开接口、配置名称和调用方式保持不变。

V2 是协议规格、Codec 和测试契约的版本，不在线上增加版本字段、握手或附加帧。

## 2. 硬约束

1. 以生产哨兵 `io::CBoard` 为唯一线协议基准。
2. 物理链路为视觉小电脑 `can0` 到云台板 `can1`。
3. 只允许三类标准 CAN 数据帧：`0x01`、`0x110`、`0xFF`。
4. 每帧固定 8 字节，不增加或删除字段，不增加心跳、确认、诊断、版本或分片帧。
5. CAN ID、字段顺序、比例、大端表示和有效输入的量化结果与现有 `io::CBoard` 逐字节兼容。
6. `shoot_mode` 固定为 `both_shoot(2)`，对应当前单云台、单发射机构机器人。
7. 不修改 `CMD`、`Gimbal`、`InfantryLauncher`、`Referee`、`DualBoard`、`User/app_main.cpp`、`Core/`、`Drivers/` 或 `Middlewares/`。
8. 保留 `HostData` 对 `chassis_data`、`target_euler` 和 `fire_notify` 的现有汇总职责。
9. 视觉侧不修改 `src/`、`tasks/`、`tools/`、`configs/`、`io/command.hpp` 或 `io/socketcan.hpp`。
10. 固件侧遵循现有命名和格式规范，所有 `const`/`constexpr` 常量使用全大写名称。

## 3. 非目标

- 不增加小符、大符或前哨站业务模式。
- 不给现有单发射机构增加左右枪切换逻辑。
- 不将 `horizon_distance` 接入固件业务控制。
- 不在 MCU 内估算视觉未提供的目标角速度或目标角加速度。
- 不将视觉工程整体迁移到 LibXR。
- 不改造 USB CDC、终端或其他已有通信用途。

## 4. 总体架构

```text
视觉业务代码
    |
    | 保持 io::CBoard 公开接口不变
    v
io::CBoard
    |
    | SocketCAN + Vision CBoard V2 Codec
    v
Linux can0 / USB2CAN
    |
==================== Classic CAN ====================
    |
STM32 CAN1
    |
    | LibXR::CAN
    v
VisionCBoardV2 xrobot Module
    |                  |                    |
    v                  v                    v
target_euler      fire_notify      vision_control_valid
    \                  |                    /
     \                 |                   /
      +-------------- HostData -----------+
                         |
                         v
                     CMD::FeedAI()
```

反馈方向：

```text
ahrs_quaternion --------------------------> CAN 0x01
launcher_ref + CMD::GetCtrlMode() --------> CAN 0x110
```

控制方向：

```text
CAN 0xFF ---> VisionCBoardV2 ---> HostData Topics ---> CMD::FeedAI()
```

## 5. 固件组件

### 5.1 `VisionCBoardV2Protocol.hpp`

纯协议单元，不依赖硬件和 xrobot 生命周期，负责：

- 三类 8 字节载荷的数据类型。
- 大端 `int16_t` 读写。
- 向零截断和饱和量化。
- 四元数、状态和控制载荷的编码与解码。
- CAN ID、比例、边界和默认值常量。

建议接口：

```cpp
namespace VisionCBoardV2Protocol {

struct QuaternionData {
  float x;
  float y;
  float z;
  float w;
};

struct RobotStateData {
  float bullet_speed;
  uint8_t mode;
  uint8_t shoot_mode;
  float ft_angle;
};

struct VisionCommandData {
  bool control;
  bool shoot;
  float yaw;
  float pitch;
  float horizon_distance;
};

void EncodeQuaternion(const QuaternionData& input, uint8_t (&output)[8]);
void EncodeRobotState(const RobotStateData& input, uint8_t (&output)[8]);
VisionCommandData DecodeVisionCommand(const uint8_t (&input)[8]);

}  // namespace VisionCBoardV2Protocol
```

### 5.2 `VisionCBoardV2.hpp`

xrobot 应用模块，负责：

- 从 `HardwareContainer` 查找 `can1`。
- 使用 `LibXR::CAN::Register()` 精确订阅标准帧 `0xFF`。
- 订阅 `ahrs_quaternion` 和 `launcher_ref` Topic。
- 使用 `CMD::GetCtrlMode()`生成参考协议的 `mode`。
- 使用 `LibXR::CAN::AddMessage()`发送 `0x01` 和 `0x110`。
- 发布 `target_euler`、`fire_notify` 和 `vision_control_valid`。
- 记录有效控制帧时间并执行 150 ms 掉线保护。
- 统计接收拒绝、发送失败和控制超时，不阻塞 AHRS 或电机控制路径。

构造参数：

```yaml
- id: vision_cboard
  name: VisionCBoardV2
  constructor_args:
    cmd: '@cmd'
    can_bus_name: can1
    quaternion_tx_id: 0x01
    state_tx_id: 0x110
    command_rx_id: 0xff
    quaternion_topic_name: ahrs_quaternion
    launcher_ref_topic_name: launcher_ref
    target_euler_topic_name: target_euler
    fire_notify_topic_name: fire_notify
    control_valid_topic_name: vision_control_valid
    state_tx_period_ms: 20
    command_timeout_ms: 150
    thread_priority: LibXR::Thread::Priority::MEDIUM
    task_stack_depth: 1024
```

CAN ID 保留为构造参数以保持 `io::CBoard` 配置接口的灵活性，但 `sentry_gimbal.yaml` 必须使用参考值。

### 5.3 `HostData`

`HostData` 保持原有三个业务 Topic 和 `CMD::FeedAI()` 路径，只增加可选的 `vision_control_valid` 本地 Topic。

现有构造调用必须继续可用。实现可使用尾部默认参数或兼容重载，避免破坏其他配置。

`BuildHostCMD()` 只有在以下条件同时成立时才设置 `gimbal_online`：

```text
vision_control_valid == true
且 target_euler 在 150 ms 内更新
```

收到 `vision_control_valid=false` 时立即：

1. 清除云台目标和导数。
2. 清除开火状态。
3. 将云台和开火时间戳置为无效。
4. 调用 `CMD::FeedAI()` 发布安全状态。

原有 `chassis_data` 路径不受影响，`WsProtocol` 仍可持续提供底盘 AI 命令。

## 6. 视觉组件

### 6.1 `io/cboard_v2_protocol.hpp`

无状态、仅依赖标准库的 header-only Codec，职责与固件协议头一致。它使用视觉工程现有命名风格，不引入 LibXR 或新运行依赖。

### 6.2 `io::CBoard`

以下公开接口保持不变：

```cpp
CBoard(const std::string& config_path);
Eigen::Quaterniond imu_at(std::chrono::steady_clock::time_point timestamp);
void send(Command command) const;

double bullet_speed;
Mode mode;
ShootMode shoot_mode;
double ft_angle;
```

以下配置名保持不变：

```yaml
quaternion_canid: 0x01
bullet_speed_canid: 0x110
send_canid: 0xff
can_interface: can0
```

`cboard.cpp` 继续管理现有 SocketCAN 生命周期、回调和四元数时间队列，但所有载荷字节操作改为调用 V2 Codec。

## 7. 线上协议

所有帧均为标准 11-bit CAN 数据帧，`DLC` 必须为 8。

| CAN ID | 方向 | 含义 | 发送规则 |
| --- | --- | --- | --- |
| `0x01` | 固件到视觉 | 四元数 | 每次 `ahrs_quaternion` 更新 |
| `0x110` | 固件到视觉 | 弹速和机器人模式 | 每 20 ms |
| `0xFF` | 视觉到固件 | 云台和开火控制 | 保持视觉主循环现有频率 |

### 7.1 四元数帧 `0x01`

```text
Byte 0-1 : q.x * 10000，有符号 int16，大端
Byte 2-3 : q.y * 10000，有符号 int16，大端
Byte 4-5 : q.z * 10000，有符号 int16，大端
Byte 6-7 : q.w * 10000，有符号 int16，大端
```

线上顺序固定为 `x, y, z, w`。视觉解码后使用：

```cpp
Eigen::Quaterniond quaternion(w, x, y, z);
```

单位四元数黄金向量：

```text
Input:  x=0, y=0, z=0, w=1
Bytes:  00 00 00 00 00 00 27 10
```

### 7.2 状态帧 `0x110`

```text
Byte 0-1 : bullet_speed * 100，有符号 int16，大端
Byte 2   : mode
Byte 3   : shoot_mode
Byte 4-5 : ft_angle * 10000，有符号 int16，大端
Byte 6-7 : 0x00, 0x00
```

字段来源：

```text
bullet_speed <- launcher_ref.ld.bullet_speed
mode         <- CMD_AUTO_CTRL ? auto_aim(1) : idle(0)
shoot_mode   <- both_shoot(2)
ft_angle     <- 0
reserved     <- 0, 0
```

状态黄金向量：

```text
Input:  bullet_speed=24.0, mode=1, shoot_mode=2, ft_angle=0
Bytes:  09 60 01 02 00 00 00 00
```

### 7.3 控制帧 `0xFF`

```text
Byte 0   : control，0 表示 false，非 0 表示 true
Byte 1   : shoot，0 表示 false，非 0 表示 true
Byte 2-3 : yaw * 10000，有符号 int16，大端
Byte 4-5 : pitch * 10000，有符号 int16，大端
Byte 6-7 : horizon_distance * 10000，有符号 int16，大端
```

控制黄金向量：

```text
Input:
  control=1
  shoot=0
  yaw=0.12
  pitch=-0.03
  horizon_distance=2.5

Bytes:
  01 00 04 B0 FE D4 61 A8
```

`horizon_distance` 必须完整解码和保存在通信模块状态中，但不接入当前固件业务控制。

## 8. 量化规则

有效输入必须与原 `static_cast<int16_t>` 的向零截断行为一致，并为超范围输入增加确定性饱和：

```text
scaled  = value * scale
limited = clamp(scaled, -32768, 32767)
encoded = truncate_toward_zero(limited)
```

比例：

```text
QUATERNION_SCALE   = 10000.0
ANGLE_SCALE        = 10000.0
DISTANCE_SCALE     = 10000.0
BULLET_SPEED_SCALE = 100.0
```

边界黄金向量：

```text
value * scale > 32767  -> 7F FF
value * scale < -32768 -> 80 00
```

编解码必须使用显式大端帮助函数，不依赖主机字节序、结构体 packing、未对齐访问或有符号右移。

## 9. 控制字段适配

视觉控制帧只包含 yaw 和 pitch 目标，没有 roll、目标角速度或目标角加速度。转换为 `HostData::HostGimbalTarget` 时：

```text
rol      = 0
pit      = decoded pitch
yaw      = decoded yaw

rol_dot  = 0
pit_dot  = 0
yaw_dot  = 0

rol_ddot = 0
pit_ddot = 0
yaw_ddot = 0
```

这些零表示“无视觉前馈”，不表示 yaw 或 pitch 目标为零。云台角度控制仍根据目标角与当前角的误差产生控制输出。

不在 MCU 内差分估算速度和加速度，避免噪声、时基依赖和协议语义变化。

## 10. 控制发布顺序

为避免旧目标或旧开火状态短暂残留，`VisionCBoardV2` 按以下顺序发布本地 Topic。

### `control=false`

```text
1. fire_notify = false
2. vision_control_valid = false
```

不发布新目标，`HostData` 立即清除视觉控制状态。

### `control=true, shoot=false`

```text
1. vision_control_valid = true
2. fire_notify = false
3. target_euler = decoded target
```

停火先于新目标生效。

### `control=true, shoot=true`

```text
1. vision_control_valid = true
2. target_euler = decoded target
3. fire_notify = true
```

开火只在新目标已进入 `HostData` 后生效。

`HostData` 对 `vision_control_valid=true` 只更新有效标志，不立即用旧目标调用 `CMD::FeedAI()`。业务更新仍由随后到达的目标或开火 Topic 驱动。

## 11. 校验与异常处理

固件只接受同时满足以下条件的控制帧：

```text
type == LibXR::CAN::Type::STANDARD
id == configured command_rx_id
dlc == 8
```

扩展帧、远程帧、错误帧、错误 ID 和错误 DLC 均直接丢弃，且不得刷新最后有效控制时间。

视觉侧解码规则：

```text
非法 mode       -> idle(0)
非法 shoot_mode -> both_shoot(2)
异常四元数模长   -> 丢弃，不更新插值队列
```

固件发送失败时：

- 不阻塞 Topic 回调或协议线程。
- 累计发送失败计数。
- 丢弃本次反馈帧，等待下一周期或下一条 Topic 更新。

四元数尚未产生时不发送伪造姿态。`launcher_ref` 尚未产生时发送 `bullet_speed=0.0`。

## 12. 掉线与安全

最后一个通过校验的 `0xFF` 帧更新控制接收时间。超时固定为 150 ms。

超时后：

```text
fire_notify = false
vision_control_valid = false
```

安全规则：

1. `control=false` 立即撤销视觉控制并禁止开火。
2. `shoot=true` 只有在 `control=true` 时有效。
3. 非法帧不能维持在线状态。
4. 超时处理由 `VisionCBoardV2` 自己的 LibXR 线程执行，不依赖当前 1000 ms 的 `ApplicationManager` 监控周期。
5. 原 `CMD` 的发射许可逻辑保持不变，视觉开火仍与遥控器发射许可做逻辑与，不绕过人工安全开关。

## 13. 配置迁移

`User/RobotConfig/sentry_gimbal.yaml`：

- 保留 `HostData`。
- 保留 `WsProtocol` 和 `chassis_data`。
- 新增 `VisionCBoardV2`，绑定 `can1`。
- 给 `HostData` 配置 `vision_control_valid`。
- 删除旧 USB 视觉实例：`sharetopic`、`client_topic`、`client_topic_autoaim`。

USB FS/HS CDC 的硬件初始化不删除，`User/app_main.cpp` 不修改。

`Modules/modules.yaml` 增加：

```yaml
- pldx/VisionCBoardV2
```

`VisionCBoardV2` 应作为独立模块仓库发布，并在 PLDX module index 注册。模块发布配置属于通信模块交付的一部分，不修改机器人业务代码。

## 14. 文件范围

### 固件工程

创建：

```text
Modules/VisionCBoardV2/VisionCBoardV2.hpp
Modules/VisionCBoardV2/VisionCBoardV2Protocol.hpp
Modules/VisionCBoardV2/CMakeLists.txt
Modules/VisionCBoardV2/README.md
Modules/VisionCBoardV2/tests/vision_cboard_v2_protocol_test.cpp
```

修改：

```text
Modules/HostData/HostData.hpp
Modules/HostData/README.md
Modules/modules.yaml
User/RobotConfig/sentry_gimbal.yaml
```

### 视觉工程

创建：

```text
io/cboard_v2_protocol.hpp
tests/cboard_v2_protocol_test.cpp
```

修改：

```text
io/cboard.cpp
CMakeLists.txt
```

## 15. 测试设计

### 15.1 双端 Codec 黄金向量

固件和视觉测试必须分别包含相同的黄金向量，不通过跨仓库 include 共享测试源码。

覆盖：

- 单位四元数。
- 正负四元数分量。
- 24 m/s 状态帧。
- `both_shoot(2)` 固定值。
- 正负 yaw/pitch。
- `control=false` 时的有效开火结果。
- 正负向零截断。
- `int16_t` 上下界饱和。
- 保留字节固定为零。

### 15.2 固件模块行为

使用假的 `LibXR::CAN` 和测试 Topic 验证：

- 只接收标准 `0xFF`、DLC 8。
- AHRS 更新生成一帧且仅一帧 `0x01`。
- 每 20 ms 生成一帧且仅一帧 `0x110`。
- 不生成协议定义外的 CAN ID。
- `shoot_mode` 始终为 `2`。
- `control=false` 立即停火和失效。
- 150 ms 无有效帧后停火和失效。
- 非法帧不刷新超时。
- 发送失败不阻塞调用线程。
- 没有 AHRS 时不发送姿态。
- 没有弹速时状态帧发送零弹速。

### 15.3 `HostData` 回归

验证：

- 未配置 `vision_control_valid` 时保持旧行为。
- 配置后只有有效标志和新鲜目标同时满足才设置 `gimbal_online`。
- 收到 `false` 后立即清除云台和开火状态。
- `chassis_data` 汇总不受视觉控制失效影响。
- 零角度、零速度仍可作为合法在线目标。

### 15.4 视觉回归

新增无需 CAN 设备的 `cboard_v2_protocol_test`，验证：

- 所有黄金向量。
- `io::CBoard::send()` 产生与旧实现相同的有效输入字节。
- 状态解码仍更新原公开成员。
- 线上 `xyzw` 与 Eigen 构造 `wxyz` 的转换正确。
- 非法枚举安全回落。
- 异常四元数不进入插值队列。

现有硬件交互测试 `cboard_test` 保留。

### 15.5 构建验证

固件：

```bash
tools/format_code.sh --check
tools/build.sh --skip-format \
  -c User/RobotConfig/sentry_gimbal.yaml \
  -b build/sentry_gimbal
```

视觉：

```bash
cmake -S /home/sb/PLDX_Sentry_Vision \
      -B /home/sb/PLDX_Sentry_Vision/build-v2
cmake --build /home/sb/PLDX_Sentry_Vision/build-v2 \
      --target cboard_v2_protocol_test sentry
ctest --test-dir /home/sb/PLDX_Sentry_Vision/build-v2 \
      -R cboard_v2_protocol_test --output-on-failure
```

### 15.6 总线联调

先使用 `vcan` 验证：

- 线上只出现 `0x01`、`0x110`、`0xFF` 三类协议 ID。
- 所有 DLC 均为 8。
- 黄金输入产生预期字节。
- 错误 DLC、扩展帧和错误 ID 被拒绝。
- 停止 `0xFF` 后 150 ms 内固件撤销视觉控制。

再连接真实 CAN1，验证：

- 视觉能连续获得四元数并完成时间插值。
- 弹速和模式正确更新。
- 单云台使用通用 `yaw_offset`。
- `control=false` 和断线均可靠停火。
- CAN1 上拨弹电机通信无明显丢帧或控制抖动。

## 16. 验收标准

1. 视觉业务源文件无需修改即可编译和运行。
2. `io::CBoard` 公开 API 和配置键全部保持不变。
3. 三类帧与现有参考协议有效输入逐字节兼容。
4. 固件不发送第四类 V2 协议帧。
5. `shoot_mode` 在线上始终为 `both_shoot(2)`。
6. `control=false` 立即撤销视觉控制，断线在 150 ms 内撤销视觉控制。
7. 视觉未提供的 roll、角速度和角加速度均作为零前馈处理。
8. `CMD`、`Gimbal`、`InfantryLauncher`、`Referee` 和 `DualBoard` 无代码改动。
9. 固件格式检查、云台配置构建、双端 Codec 测试和视觉 `sentry` 构建全部通过。
10. CAN1 实机联调不影响现有拨弹电机通信。
