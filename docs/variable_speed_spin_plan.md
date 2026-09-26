# 变速小陀螺（ROTOR_VARIABLE）研发方案

> 版本 v1.1 ｜ 2026-09-25 ｜ 状态：**已实施**（双板编译 `-Werror` 全绿，生成代码实参展开已核验；待台架验证 M3）
> 定位：**新增模式**，与现有 `ROTOR`（恒速小陀螺）并存，不替换、不改动现有模式行为。

---

## 1. 背景与目标

### 1.1 需求来源（社区讨论结论，B站评论区）

| 楼层 | 观点 | 对本方案的输入 |
| ---- | ---- | ---- |
| 87楼（TrojanGeneric） | 东北大学的变速小陀螺是**分段正弦波**而非标准正弦；分段正弦在加减速段功率消耗较大；更好的设计是**"力控层面的方波"**：半周期施加旋转扭矩、半周期扭矩为零（滑行）；**速度是力的积分** | 控制域选择：扭矩域而非速度域 |
| 100楼 | 省功率做法：**不控速度、只控扭矩**，让扭矩按正弦或方波变化；前提是**力控底盘 + 角速度（转矩）前馈** | 确认可行性路径；本底盘满足前提（`Motor::ControlMode::MODE_TORQUE` 全时生效） |

### 1.2 目标

1. 新增 `Omni::ChassisMode::ROTOR_VARIABLE`：扭矩域方波驱动，转速在设定窗口内自然起伏（扭矩=方波，速度=积分后的三角波）。
2. 同平均转速下，**底盘回转电功率显著低于现有 `ROTOR`**（机理预估约降 30–50%，以 M1 仿真与 M4 实车裁判系统数据为准）。
3. 现有 `ROTOR` 全链路零改动（回归风险隔离）。
4. 云台侧行为不变（`ChassisMotionMode` 仍映射为 ROTOR，反陀螺补偿不受影响）。

---

## 2. 现状审计（只读结论，代码事实）

### 2.1 控制链（Omni，1 kHz，`ThreadFunction`）

```
Update → UpdateCMD → SelfResolution → InverseKinematicsSolution
       → DynamicInverseSolution → FeedForward → CalculateMotorCurrent
       → PowerControlUpdate → OutputToDynamics
```

- 现有 `ROTOR`（Omni.hpp L336-338 / L392-405）：
  `wz_setpoint = -max_v / wheel_to_center`（满速 ≈15.9 rad/s），再乘
  `rotor_translation_scale`（平移输入占比）× `motion_.rotor_dynamic_scale`
  （功率缓冲 35–70 J → 0.55–1.0，LPF α=0.2）。
  **本质是速度控**：`pid_omega_`(p=30) 闭 wz 环 → `FORCE_Z` → 四轮力分配 → 轮速 PID + 前馈 → 扭矩。为跟踪恒转速，扭矩持续非零 → 电功率持续非零。
- 扭矩注入点已存在且干净：`DynamicInverseSolution()`（L646-663）中 `FORCE_Z` 按四轮均分 `+FORCE_Z/4`，`CalculateMotorCurrent()` 中 `torque_output[i] = force_setpoint[i]·wheel_radius + ...`。

### 2.2 扭矩→转速的映射推导（虚拟功一致性）

由正/逆运动学：纯回转时每轮切向线速度 `v = ω·wheel_to_center`，轮侧力 `f_i = FORCE_Z/4`，
`P = Σ f_i·v = FORCE_Z·ω·wheel_to_center = τ_z·ω`，故：

```
FORCE_Z = τ_z / wheel_to_center          （τ_z：底盘偏航总扭矩，N·m）
每轮轮侧扭矩 = τ_z · r / (4·R)           （r=0.075, R=0.245 → ≈0.0765·τ_z）
```

τ_z = 20 N·m 时单轮约 1.53 N·m（轮侧），远在 `OutputToDynamics` ±6 N·m 限幅内。**参数量纲以底盘级 τ_z（N·m）定义，代码内一次换算。**

### 2.3 功率控制（PowerControl.hpp）

- RLS 在线辨识功率模型（含 `DEFAULT_TORQUE_SQUARE_LOSS=1.2` 扭矩平方损耗项）——扭矩域指令在其建模覆盖范围内，兼容性好。
- `OutputLimit()` 对**最终电流**限幅，与模式无关 → 扭矩模式下限功率保护自动有效，无需改动。
- 缓冲能量来源：`referee_chassis_pack_.power_buffer`（裁判系统在线时）。

### 2.4 模式协议链（两板契约）

```
EventBinder(sentry_gimbal.yaml, 左拨杆) → dual_board 事件
  → Pldx::DualBoardControl::Mode(4bit, MODE_MASK=0x0F)
  → CAN → chassis ForceRemoteMode() → chassis_->GetEvent().Active(mode)
  → Omni::SetMode()
```

锁定点（新增模式必须全部同步）：
- `Omni::ChassisMode`（Omni.hpp L58-64，RELAX=0…NAVIGATION=4）
- `Pldx::DualBoardControl::Mode`（DualBoard.hpp L75-81）+ **7 条 static_assert**（L790-798）
- `dual_board_event_` 注册（L1021-1029）、`IsSupportedMode()` 白名单（L2235-2241）
- `ChassisMotionMode` 映射（L2187-2190）：`ROTOR→ROTOR，其余→NON_ROTOR`
- `Chassis<ChassisType>` 构造器事件注册（Chassis.hpp L280-293，NAVIGATION 用 `if constexpr (Omni)` 护栏）

### 2.5 触发资源

- 左拨杆三档已占满（TOP=RELAX / MID=FOLLOW / BOT=ROTOR，sentry_gimbal.yaml L312-324）。
- 空余触发：DR16 键盘（Q/E 已绑云台视觉，R 等空余）、`self_define` 自定义按钮（`ChasStat`）。

---

## 3. 控制方案

### 3.1 候选波形对比

| 方案 | 原理 | 优点 | 缺点 | 结论 |
| ---- | ---- | ---- | ---- | ---- |
| **B 速度窗滞环（推荐）** | `\|ω\|<ω_lo`→DRIVE：τ=−τ_amp 恒扭矩；`\|ω\|≥ω_hi`→COAST：τ=0 滑行；滞环往复 | 力控方波+速度=积分；对摩擦/电压/负载变化**自校正**；周期自然抖动，敌方更难预测 | 需可靠 ω 反馈（用 IMU） | **主方案** |
| A 定时开环方波 | τ_amp 持续 T_drive → 0 持续 T_coast，按时间切换 | 实现最简、周期确定 | 速度域随摩擦/电压漂移，需人工重调 | 作为 B 的降级/兜底（drive 超时保护即退化形态） |
| C 正弦扭矩 | τ(t)=τ₀+τₐ·sin(2πt/T)，τ₀≥τₐ 保证同向 | 平滑 | 无纯滑行段，省电不如 A/B；参数多 | 备选，M5 后评估 |
| D 分段正弦（速度域，东北大学式） | 保留现速度环，仅整形 wz 设定值 | 架构零改动 | 即 87楼指出的加减速段高功耗形态 | 对照组/紧急回退方案 |

### 3.2 主方案状态机（B）

```
          ┌────────────────────────────┐
          │  DRIVE: τ_z = −τ_amp 恒扭矩 │◀─────────────┐
          │  (ω 单调上升, 扭矩=方波高电平) │              │
          └──────┬─────────────────────┘              │
        |ω_imu| ≥ ω_hi  或  DRIVE 超时 spin_drive_timeout_s
                 ▼                                    │
          ┌────────────────────────────┐              │
          │  COAST: τ_z = 0 (自由滑行)   │──────────────┘
          │  (摩擦减速, 电功率≈0)         │  |ω_imu| ≤ ω_lo
          └────────────────────────────┘

安全层（任意相生效）：
  |ω_imu| > ω_max(硬上限) → 强制 COAST 并闭锁 DRIVE 直至回落
  gyro z 信号超时(100 ms) → ω 源回退轮速里程计 SelfResolution().wz
  轮速里程计亦失效        → 整体回退现有 ROTOR 速度控（保底可用）
```

- 扭矩方向固定负向（与现 ROTOR 转向一致），滞环作用于幅值。
- 期望参数初值（M1 仿真后修订）：τ_amp ∈ [10, 25] N·m，ω_hi ≈ 14 rad/s，ω_lo ≈ 6 rad/s（与现 ROTOR 有效转速同量纲），ω_max = 16 rad/s，drive 超时 2 s。
- 稳定性说明：功率受限时电流被 `OutputLimit` 压低 → 加速率变小 → DRIVE 相自动变长 → 无正反馈失稳（滞环天然稳定）。

### 3.3 与现有子系统的交互

| 子系统 | 交互 | 处理 |
| ---- | ---- | ---- |
| 功率限幅 | `OutputLimit()` 对最终电流限幅 | **不改**；扭矩模式请求电流由 τ_amp 直接决定，限流自动生效 |
| `rotor_dynamic_scale` | 仅 ROTOR 生效的缓冲降速缩放 | 相位 1 不扩展；复位条件加入 ROTOR_VARIABLE（强制 1.0）。相位 2（可选）把 `buffer_scale` 折算进 τ_amp |
| 平移叠加 | ROTOR 允许边转边平移 | ROTOR_VARIABLE 同样保留：vx/vy 走原 `pid_velocity_x/y` 链路，仅 wz 由扭矩通路接管 |
| 阻力补偿 | `ResistanceTorque()` 维持转速用 | 本模式**不启用**（滑行段要靠摩擦减速；τ_amp 整定时吸收摩擦） |
| 云台 | `ChassisMotionMode` 告知"是否在转" | ROTOR_VARIABLE → 映射 `ChassisMotionMode::ROTOR`，云台侧零改动 |
| ω 反馈源 | 新增订阅 `chassis_gyro`（BMI088 1 kHz，本板） | 打滑时轮速里程计失真，IMU 为准；里程计作回退 |

---

## 4. 代码改动清单

> 改动原则：追加式（enum 追加尾部、参数追加尾部），0–4 号模式语义与取值不变；两板同刷。
> ⚠️ 遵守既有护栏：ChassisParam 多处重复**保持现状**（合并方案已被否决，勿再提）；`xrobot_gen_main` 生成前后 diff 验证实参展开（防下标左移错绑）。

### 4.1 `Modules/Chassis/Omni.hpp`（核心）

| # | 位置 | 改动 |
| - | ---- | ---- |
| 1 | `enum class ChassisMode`（L58） | 追加 `ROTOR_VARIABLE`（=5，尾部） |
| 2 | `Omni::ChassisParam`（L40-57） | 尾部追加 5 字段：`spin_torque_amp_nm`、`spin_omega_hi_rad_s`、`spin_omega_lo_rad_s`、`spin_omega_max_rad_s`、`spin_drive_timeout_s` |
| 3 | `ThreadFunction`（L198-209） | 新增 `chassis_gyro` 的 `ASyncSubscriber`（类型与 BMI088 发布对齐，参照 Gimbal 用法），写入 `motion_.gyro_wz`；记录最近更新时戳 |
| 4 | `MotionState`（L736） | 追加 `float gyro_wz`；新增嵌套 `struct SpinState { phase, phase_enter_us, ... } spin_`（仿 `patrol_`/四组分层先例，不入 `motion_`） |
| 5 | `SetMode()`（L277-288） | 复位 `spin_`（相位→COAST、计时清零） |
| 6 | `UpdateCMD()`（L324-388） | 平移 switch 追加 `ROTOR_VARIABLE` case（与 ROTOR 相同的 yawmotor_angle 旋转）；wz switch 置 0（扭矩通路接管）；`rotor_translation_scale` 块不改（仍 ROTOR-only） |
| 7 | `DynamicInverseSolution()`（L646） | ROTOR_VARIABLE 分支：**跳过 `pid_omega_`**，`FORCE_Z = τ_cmd / wheel_to_center`（τ_cmd 来自 spin_ 波形机，含符号）；vx/vy 两环照常 |
| 8 | `CalculateMotorCurrent()`（L538） | ROTOR_VARIABLE 分支：跳过轮速 PID，`torque_output[i] = force_setpoint[i]·r + feedforward_torque[i]`；COAST 相力设定为 0 → 请求电流≈0 |
| 9 | `InverseKinematicsSolution()` 后 | ROTOR_VARIABLE 下 `omega_setpoint[i]` 改按 `measured.wz` 的运动学映射写入（使功率模块 wheel_speed_error≈0，语义=“无跟踪需求，仅扭矩请求”） |
| 10 | `PowerControlUpdate()`（L636） | `rotor_dynamic_scale` 复位条件加 ROTOR_VARIABLE |

### 4.2 `Modules/Chassis/Chassis.hpp`（外壳 + manifest）

- 构造器事件注册（L290-293）：`if constexpr (Omni)` 块内追加 `ROTOR_VARIABLE` 注册（与 NAVIGATION 同款护栏；Mecanum/Helm 枚举无此值）。
- `Chassis<>::ChassisParam`（L211-226）与**位置转译 brace-init**（L256-266）：尾部按相同顺序追加 5 字段（⚠️ 顺序必须与 `Omni::ChassisParam` 声明一致）。
- 文件头 MANIFEST V2 注释块 `ChassisParam` 默认值（L19-33）：同步追加（维持"manifest 默认 == Config 默认"守护惯例）。

### 4.3 `Modules/DualBoard/DualBoard.hpp`（两板契约）

- `Pldx::DualBoardControl::Mode`（L75）追加 `ROTOR_VARIABLE = 5U`（4bit 掩码内）。
- static_assert 组（L790-798）追加第 8 条对应断言。
- `dual_board_event_` 注册（L1025 附近）追加。
- `IsSupportedMode()`（L2235）追加。
- `motion_state_.mode` 映射（L2187）：`ROTOR_VARIABLE → ChassisMotionMode::ROTOR`。

### 4.4 yaml（两份配置）

- `User/RobotConfig/sentry_chassis.yaml`：`chassis.ChassisParam` 尾部追加 5 键（初值即 3.2 节初值）。
- `User/RobotConfig/sentry_gimbal.yaml`：左拨杆下段（`DR16_SW_L_POS_BOT`）由 `ROTOR` 改绑 `ROTOR_VARIABLE`——**变速替代恒速成为拨杆下段模式**；恒速 `ROTOR` 保留在代码与协议中，暂无遥控入口（需要时加一行绑定即可恢复）。

### 4.5 栈余量核算

- `task_stack_depth: 2048`（字节）。新增 1 个 ASyncSubscriber（gyro，约 12–16 B）+ `SpinState`（约 16 B）+ 若干局部量，需按"局部量峰值栈核算"惯例在 M3 复核（LibXR `Thread::Create` 栈深单位为字节）。

---

## 5. 验证计划（含反向验证）

### 5.1 里程碑

| 阶段 | 内容 | 交付物 | 出口判据 |
| ---- | ---- | ---- | ---- |
| M1 离线仿真 | `tmp/spin_sim.py`：J+粘性/库伦摩擦模型，A/B/C/D 四波形同平均转速能耗对比；参数域预估（τ_amp–窗口–周期关系） | 仿真报告+推荐参数 | B 方案能耗优势 ≥25%；负向：零摩擦下 ω 被 ω_hi 截停（防飞车） |
| M2 协议与编译 | 4.2–4.4 全部改动；`buildgimbal.ps1`/`buildchassis.ps1` 全绿；`xrobot_gen_main` diff 核对实参展开 | diff 清单 | `-Werror` 零告警；生成代码实参无左移 |
| M3 台架 | 见 5.2 | 台架记录 | 全部通过 |
| M4 实车 A/B | 同平均 \|ω\| 下裁判系统底盘功率对比（ROTOR vs ROTOR_VARIABLE）；缓冲能量曲线；操作手主观评估 | 数据记录 | 变速模式平均功率低于恒速；无可感知云台跟踪劣化 |
| M5 收尾 | 参数固化进 yaml；C 正弦扭矩是否追加的决策 | 结题纪要 | — |

### 5.2 台架项（M3）

1. **滑行相电流**：COAST 相四电机请求电流 ≈ 0（遥测 `output_current_3508`），电功率≈0。
2. **波形正确性**：遥测 ω 呈三角波、扭矩呈方波；周期与仿真预估同量级。
3. **硬上限**（负向）：故意调低 `spin_omega_max_rad_s`，DRIVE 必须被强制切断转入 COAST。
4. **DRIVE 超时**（负向）：垫高轮子空转+人为加大负载模拟，超时保护触发。
5. **模式切换原子性**（负向）：ROTOR_VARIABLE→RELAX 立即 Relax 无残留扭矩；ROTOR↔ROTOR_VARIABLE 往返、FOLLOW→ROTOR_VARIABLE 直切各 20 次。
6. **反馈降级链**（负向）：屏蔽 IMU gyro 主题 → 回退轮速里程计；再断电机反馈 → 回退现有 ROTOR 速度控。
7. **功率受限稳定性**（负向）：裁判系统离线默认 100 W 上限 + 缓冲耗尽场景，确认滞环延长 DRIVE 而非振荡。
8. **功率模块语义**：确认 `wheel_speed_error≈0` 时 RLS/分配权重行为正常（异常则改为传"扭矩需求折算的等效误差"）。

### 5.3 风险表

| 风险 | 等级 | 缓解 |
| ---- | ---- | ---- |
| 轮地打滑使轮速里程计失真 → 窗口判断错误 | 中 | 主用 IMU gyro z；里程计仅回退 |
| C620 零扭矩指令是否严格自由滑行（无反电动势制动/能耗） | 低 | M3 第 1 项台架实测确认 |
| 云台偏航电机需承受转速波动（力矩波动加大） | 中 | 云台代码零改动；M4 实测 yaw 力矩余量 |
| 摩擦变化导致开环波形（方案 A）速度域漂移 | — | 主方案 B 自校正，A 仅作兜底 |
| 两板固件版本不一致时新模式帧 | 低 | `IsSupportedMode()` 白名单拒绝非法值 → 维持原模式；**两板同刷**为发布纪律 |
| 静态回归既有失败基线（gimbal_core 9 条、chassis_serial 1 条，脚本缺陷） | — | 与基线对比，不新增失败即通过 |

---

## 6. 量纲与参数速查

| 参数 | 含义 | 初值 | 单位 |
| ---- | ---- | ---- | ---- |
| `spin_torque_amp_nm` | DRIVE 相底盘偏航扭矩幅值（底盘级 τ_z） | 15（仿真后修订） | N·m |
| `spin_omega_hi_rad_s` | 滞环上限（进入 COAST） | 14 | rad/s |
| `spin_omega_lo_rad_s` | 滞环下限（恢复 DRIVE） | 6 | rad/s |
| `spin_omega_max_rad_s` | 硬安全上限 | 16 | rad/s |
| `spin_drive_timeout_s` | 单次 DRIVE 最长时间 | 2.0 | s |

换算关系：`FORCE_Z = τ_z / 0.245`；单轮轮侧扭矩 ≈ `0.0765·τ_z`；现 ROTOR 满速 ≈ 15.9 rad/s（2.53 rev/s）。
