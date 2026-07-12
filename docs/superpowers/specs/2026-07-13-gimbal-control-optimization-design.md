# 云台控制链性能优化设计

## 1. 目标与范围

本设计针对现有 XRobot/LibXR 工程中的 RoboMaster 两轴云台控制链，首验对象为
`sentry_gimbal.yaml`，硬件为 GM6020 Yaw、DM4310 Pitch、云台 BMI088，以及底盘
控制板 BMI088 提供的实测 `gyro_z`。首验通过后再迁移到其他车型。

目标是改善动态跟踪、控制时序和小陀螺状态下的云台稳定性，同时保持现有模块边界、
Topic 语义和 YAML 驱动方式。

本设计明确不做以下事情：

- 不新增 `GimbalController.hpp`、`Telemetry`、`ChassisMotion` 或公共控制 DTO。
- 不修改 Pitch 重力补偿公式、`pit_lc`、`pit_theta` 的含义。
- 不在首验阶段把控制频率提升到 1 kHz。
- 不在首验阶段全局删除 `Gimbal.hpp` 中的 legacy 轴取反。
- 不增加高阶 Coulomb/二次阻力模型；Yaw 先沿用线性 `yaw_k`。
- 不手工修改生成的 `User/xrobot_main.hpp`。

Ozone 负责采集现有类成员并导出完整时间序列，实时控制线程不计算 RMS、p95 或
窗口统计。

## 2. 固定控制管线

控制顺序保持不变：

```text
命令/传感器快照
  -> Gimbal::Update()
  -> Gimbal::ParseCMD()
  -> Gimbal::Control()
  -> Gimbal::Solve()
  -> Motor::Control()
```

观测旁路只有：

```text
Gimbal 成员变量 -> Ozone -> 时间序列 -> 离线分析
```

Gimbal 不依赖 `DualBoard` 或任何 `Chassis` 类型。底盘运动只通过基础 Topic
输入，避免控制模块与车型模板耦合。

## 3. 坐标与兼容策略

工程目标坐标系为：`+X` 车体前、`+Y` 车体左、`+Z` 向上，Yaw 左转为正，Pitch
上抬为负。云台 C 板 USB 口朝车体前方时，首验记录的传感器到车体变换为：

```text
q_BS = (0.70710678, 0, 0, -0.70710678)
R_BS = [[ 0, 1, 0],
        [-1, 0, 0],
        [ 0, 0, 1]]
```

首验采用保守兼容策略：保留 `Gimbal.hpp` 当前 Euler Pitch 和 gyro-Y 的
legacy 手工取反，仅在 T0 记录并验证标准坐标的符号。不得只修改 sentry YAML
后删除共享代码中的取反，因为 `gimbal_euler` 还被底盘 FOLLOW、DualBoard 和
其他模块消费，`gimbal_gyro` 也可能被其他车型使用。

底盘 BMI088 的安装方向必须单独实测，不能复制云台的四元数。底盘坐标门禁未通过
前，底盘前馈始终关闭。完整坐标迁移作为后续逐车型任务，需同时回归 AHRS、Gimbal、
DualBoard attitude、底盘 FOLLOW 和 Pitch 重力行为。

## 4. 控制律设计

### 4.1 人工目标速度前馈

保持现有死区、方向和灵敏度，只改变目标生成语义。

人工控制时：

```text
operator_rate = command * GIMBAL_MAX_SPEED * sensitivity
target_angle += operator_rate * dt
target_rate_ff = operator_rate
target_ddot = 0
```

低灵敏度、普通手动和非 AI 自动分支分别保留当前符号约定；自动巡航分支必须显式
写入目标速度和加速度，不能残留上一控制模式的值。AI 分支继续使用命令中携带的
角度、角速度和角加速度。

### 4.2 加速度前馈去重

当前实现对包含 `target_*_dot` 的完整目标速度求差分，又叠加 `target_*_ddot`，
会在摇杆阶跃时重复计算加速度。改为保存角度环输出的独立历史量：

```text
angle_loop_omega = PID_angle(angle_error)
target_omega     = angle_loop_omega + target_rate_ff
alpha_I_cmd      = derivative(angle_loop_omega) + target_ddot
inertia_ff       = J * alpha_I_cmd
```

`last_*_angle_loop_omega_` 在异常 `dt`、模式切换和 IMU 无效时重置。Pitch 重力
项保持原式：

```text
gravity_ff_pit = -pit_lc * sin(Pitch + pit_theta)
```

### 4.3 小陀螺速度前馈

云台 BMI088 已提供惯性角速度反馈，因此底盘角速度不能再次直接加到惯性速率误差。
底盘项只进入执行器侧相对速度模型：

```text
omega_motor_ref = omega_I_cmd - rotor_weight * chassis_gyro_z

tau_yaw = rate_PID(omega_I_cmd - gimbal_gyro_z)
         + j_yaw * alpha_I_cmd
         + yaw_k * omega_motor_ref
         - rotor_accel_k * rotor_weight * chassis_alpha_z
```

`rotor_weight` 仅在底盘实际处于 ROTOR 且运动数据有效时从 0 平滑渐入；数据过期或
模式退出时渐出。非 ROTOR 路径的 `rotor_weight` 固定为 0。

### 4.4 扭矩限幅

保留电机自身物理保护，并在 Gimbal 输出端增加总扭矩限幅和饱和成员。首验安全初值：

```text
yaw_torque_limit = 2.223 N·m
pit_torque_limit = 10.0 N·m
```

额外的 `yaw_ff_torque_limit` 为 0 时表示不启用独立前馈限幅；所有限幅都必须记录
原始输出、最终输出和饱和状态供 Ozone 采集。

## 5. 底盘运动数据链

### 5.1 Topic 边界

底盘 BMI088 在底盘侧发布本地 `chassis_gyro`。Gimbal 构造/线程启动前使用
`FindOrCreate` 预创建以下基础 Topic，并开启 `multi_publisher=true`：

- `chassis_gyro`：`Eigen::Matrix<float, 3, 1>`。
- `chassis_rotor_active`：`bool`。

这样没有 DualBoard 的 aerial、hero 或其他车型也不会因
`ASyncSubscriber` 的永久 `WaitTopic` 而卡死；预创建必须发生在 Gimbal 创建控制线程
之前。DualBoard 只负责发布，不引入公共 DTO。现有 `dualboard_chassis_mode` 继续
表示本地请求模式，绝不复用为反馈。

### 5.2 CAN MotionFrame

沿用 `DualBoard.hpp` 已有私有 8 字节帧风格，不新增模块或 CMake 文件：

```text
CAN ID: tx_id + 0x10（sentry 底盘为 0x321）
周期: 5 ms

int16 gyro_x_q
int16 gyro_y_q
int16 gyro_z_q
uint8 sequence
uint8 mode_and_flags
```

陀螺单位为 rad/s，固定量化比例为 `GYRO_SCALE = 900.0f` LSB/(rad/s)，可表示
±36.4 rad/s，覆盖 BMI088 的 ±2000 deg/s 量程。编码必须显式 clamp，不能使用 C
bitfield；超过编码范围时置 `GYRO_VALID=0`。`mode_and_flags` 的低位为
`GYRO_VALID`，高四位编码底盘端已接受的模式。底盘端通过已有 `remote_mode_` 反映
已执行的 `ForceRemoteMode()` 结果，写入和 MotionFrame 快照读取都在
`data_mutex_` 下完成，避免新增并发竞态；Gimbal 侧只将其转换为
`chassis_rotor_active`。

底盘 BMI 样本停止更新、数值非有限或本地 freshness 超时后，帧仍可作为心跳发送，
但必须清除 `GYRO_VALID`；不能把旧 gyro 当作新样本重发。只有新样本到达时才递增
`sequence`。接收端按 `delta != 0 && delta < 128` 接受序号，支持 `254 -> 255 -> 0`，
发送端超时重启后允许重新建立序号基准。收到无效帧时立即发布
`chassis_rotor_active=false`，但不刷新 gyro 样本时间戳。

### 5.3 Freshness 与角加速度

Gimbal 只在收到有效且序号前进的 MotionFrame 时更新 `chassis_gyro_z_` 和样本年龄。
运动数据年龄 `<= 30 ms` 才允许速度前馈，`100 ms` 时强制权重为 0；权重在
50--100 ms 内渐入/渐出。

`chassis_alpha_z` 只对新的 5 ms MotionFrame 样本求差分，使用 Topic 时间戳间隔，
不能按 2 ms Gimbal 控制周期重复差分。首帧、序号重置、异常时间间隔时加速度置 0，
随后执行低通、死区和限幅。`rotor_accel_k` 默认 0，必须在速度前馈 A/B 通过后单独
评估。

跨板端到端延迟不能仅由 Ozone 证明，因为 MotionFrame 不携带源时间戳。Ozone 记录
接收间隔、最大 age 和丢帧计数；若需要真正的端到端延迟，使用 CAN analyzer 或
同步 GPIO 台架测试。

## 6. 时序与失效安全

`Gimbal::ThreadFunc()` 改用 `SleepUntil`，控制线程保持 2 ms 周期。命令、Euler、
gyro 和电机反馈都记录最近时间戳；异常 `dt` 不进入 PID 微分或惯量前馈，并重置相应
历史量。

电机 freshness 独立于 rotor 算法：

- `DMMotor::Update()` 增加首次反馈宽限和首次反馈后的时间超时，修复当前无条件返回
  `OK` 的问题。
- `RMMotor` 将循环次数离线判断改为基于时间的判断。
- 任一云台电机反馈无效时，Gimbal 进入 RELAX，不使用旧反馈。
- 底盘运动数据失效只关闭底盘前馈，不影响云台自身惯性闭环。

HostData 的 150 ms 目标 freshness 保留为独立后续安全任务，不能依赖 1 Hz
`OnMonitor()` 才清零；它与首验 rotor A/B 无直接依赖。

## 7. 分阶段实施门禁

### T0：基线与硬件门禁（无代码）

冻结供电、功率限制、温度、测试速度和 500 Hz 周期，采集静止、人工移动和 ROTOR
三组 Ozone 基线。确认两块 BMI088 的轴向、单位、正负号，并记录 raw -> AHRS ->
Gimbal -> FOLLOW 的符号链。

### T1：坐标兼容门禁

保留 legacy 取反，验证标准坐标记录不会改变当前 sentry 行为。覆盖静止重力、Yaw
正反转、Pitch 七个测试角度、DualBoard attitude 和底盘 FOLLOW。失败时不进入任何
前馈调参。

### T2：Gimbal 时序、数值保护和限幅

只改 Gimbal 控制内部，不开启新的底盘项。使用同一输入回放比较原始输出与限幅后的
输出，覆盖异常 `dt`、NaN、模式切换和扭矩饱和。

### T3：反馈 freshness 与 RELAX

分别拔除 DM4310、GM6020、云台 BMI088，验证云台在门限内退出闭环；恢复反馈后必须
先收到有效样本再重新 Enable。

### T4：人工/AI 参考动态

固定底盘，先验证人工 `target_rate_ff`，再验证 AI 的 dot/ddot。确认摇杆阶跃没有
惯量尖峰，Pitch 重力项与基线一致。失败时将 `target_rate_ff` 置 0 即可回退。

### T5：MotionFrame 影子链路

增加底盘 BMI 配置、0x321 帧和两个基础 Topic，但 `rotor_weight` 保持 0。使用 CAN
回放覆盖丢帧、重复序号、序号回绕、BMI 停更、模式切换和双板断链。

### T6：ROTOR 速度前馈

在固定底盘速度下先辨识 signed `yaw_k`，再只对 sentry 开启
`rotor_ff_enabled`。正向和反向小陀螺必须分别通过 gyro、相对速度和扭矩符号检查。

### T7：底盘角加速度前馈（可选）

仅对已接受的 5 ms gyro 样本求导，独立比较 `rotor_accel_k=0` 与非零结果。噪声或
峰值没有改善时保持关闭。

### T8：逐车型迁移

逐车型审计 BMI 变换、Topic 名、电机方向、限位、Yaw 阻力系数和扭矩边界。现有
`Gimbal` 固定订阅名与 aerial/hero 的 `ahrs_euler`、`bmi088_gyro` 等配置差异必须
先解决，不能直接复制 sentry 参数。本 spec 对其他车型不授权盲目重命名 Topic；每个
车型迁移前必须单独确定其 Topic 归一化方案并通过下游 FOLLOW/双板回归。构造参数或
manifest 改动后运行 CI 的九个配置：

```text
aerial, dart, helm_infantry, hero, omni_infantry_3,
omni_infantry_4, radar, sentry, wheel_leg
```

没有独立底盘 BMI 的车型保持 `rotor_ff_enabled=false`。

## 8. Ozone 指标与验收门限

建议采集的真实成员包括：`dt_`、目标角/目标速度、Euler、云台 gyro、电机反馈、
`chassis_gyro_z_`、`chassis_alpha_z_`、motion age、`rotor_weight_`、各项 Yaw
扭矩、Pitch 最终扭矩、输出饱和状态和在线状态。

所有 A/B 使用相同供电、温度、功率限制、动作轨迹和重复次数，交替执行 A/B，离线
计算角度误差 RMS/p95、速度误差、扭矩 RMS/峰值、相位延迟、饱和比例和丢帧统计。

首验初始门限如下；正式调参前可依据冻结基线修订，但不能在看见结果后临时放宽：

| 指标 | 门限 |
|---|---|
| 控制周期 | p99 <= 3 ms；正常 60 s 内无 `dt > 10 ms` |
| 云台 IMU age | 正常 <= 4 ms；超过 30 ms 触发保护 |
| 底盘 MotionFrame | 接收间隔 p95 <= 10 ms；age <= 30 ms 才前馈；100 ms 硬关闭 |
| 电机失效 | <= 100 ms 进入 RELAX |
| 人工速度前馈 | 动态角误差 RMS 下降至少 15%，超调增加不超过 10% |
| ROTOR 速度前馈 | Yaw 误差 RMS 下降至少 20%，非 ROTOR 指标恶化不超过 5% |
| Pitch 重力 | 静态误差和保持扭矩相对基线变化不超过 5% |
| 饱和 | 正常动作饱和比例 < 1%，峰值不超过物理限幅 |

Pitch 重力公式不允许因门限未达标而改写；只能回退其他新增前馈。

## 9. 文件与提交边界

生产代码的修改范围限制为现有文件：

- Gimbal nested repo：`Gimbal.hpp`。
- 电机 nested repo：`DMMotor.hpp`、`RMMotor.hpp`，作为独立 freshness 变更。
- 主工程模块：`DualBoard.hpp` 和现有 `tests/dualboard_static_regression.ps1`。
- 车型配置：首验的 `sentry_gimbal.yaml`、`sentry_chassis.yaml`，随后逐车型 YAML。
- `HostData.hpp` freshness 作为独立后续变更，不混入首验控制律提交。

各 nested repo 必须先提交可引用的模块 commit/分支，再更新主工程的
`Modules/modules.yaml` 引用；根工程 YAML、生成文件和模块提交分开。不得把当前
工作区已有的无关修改回滚或混入功能提交。

## 10. 回退策略

每个新增路径都有独立关闭条件：

- `rotor_ff_enabled=false`：完全关闭底盘速度前馈。
- `rotor_accel_k=0`：关闭底盘角加速度前馈。
- `target_rate_ff=0`：回退人工速度前馈，但保留目标角积分。
- 保留现有 legacy 坐标取反：回退坐标迁移。
- 总扭矩限幅始终保留，不能通过配置绕过电机物理边界。

只有 T0--T6 全部通过，才允许把首验结论写入其他车型迁移任务；T7 和坐标标准化
不是首验的隐含前置条件。
