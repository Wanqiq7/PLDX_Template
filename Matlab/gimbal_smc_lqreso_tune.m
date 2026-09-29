%% gimbal_smc_lqreso_tune.m
% =========================================================================
function REPORT = gimbal_smc_lqreso_tune(options)
% GIMBAL_SMC_LQRESO_TUNE 云台 SMC/LQR-ESO 参数整定核心入口。
% options.axes / options.cfg 可由 UI 或其他脚本传入；省略时使用工程基线。
% 云台 Yaw / Pitch 轴：由系统辨识参数 (J, B, tau_c) 派生 SMC 与 LQR-ESO 控制器参数
%
% 用法
%   1) 填第 1 节「辨识结果」；第 2 节「设计偏好」一般不用改
%   2) 直接运行本脚本（不依赖任何工具箱）
%   3) 把打印出的 YAML 块粘贴进 User/RobotConfig/<robot>_gimbal.yaml
%
% -------------------------------------------------------------------------
% 被控对象（与 Modules/Gimbal/SystemIdentify.hpp 的 RLS 回归模型一致）
%   J*theta_ddot + B*theta_dot + tau_c*tanh(omega/w_c) [+ mgl*sin(theta)] = tau
%
% LQR-ESO
%   A = [0 1; 0 -B/J],   Bv = [0; 1/J],   K = lqr(A, Bv, Q, R)
%   k_theta = K(1)  (N*m/rad)        k_omega = K(2)  (N*m*s/rad)
%
% SMC（对齐 Modules/Gimbal/YawSmc.hpp 的线性区实现）
%   tau = J*(alpha_ref - c*e_omega - k*s - eps*sat(s/b)),   s = e_omega + c*e_theta
%   代入 J*theta_ddot + B*theta_dot = tau 得
%     e'' + (B/J + c + k)*e' + k*c*e = -eps*sat(s/b) - (B/J)*theta_dot_ref
%   => omega_n = sqrt(k*c),   zeta = (B/J + c + k) / (2*sqrt(k*c))
%   => 与 LQR 线性区「精确等价」的条件： c + k = B/J + K2/J,   c*k = K1/J
%
% -------------------------------------------------------------------------
% 关键说明（务必读）
%   1. 上游脚本 Gimbal_Yaw_LQR_SMC_SysID.m 的反解式按 c+k = K2/J、c*k = K1/J
%      计算，**漏掉了 B/J 项**，仅在 B≈0 时成立。本脚本已修正。
%   2. SMC 线性区恒有 zeta >= 1（因为 B/J >= 0 时 (c+k)^2 >= 4ck）。
%      当 LQR 给出复极点（zeta < 1）时无法精确等价，本脚本保持 omega_n 不变、
%      把 zeta 抬到可实现域下沿。
%   3. YawSmc 的滑模律只补了 J*alpha_ref，未补 B*omega，因此 B 项会以
%      +(B/J)*e' 的形式进入误差方程（等价于附加阻尼）。这是固件现状，脚本
%      按现状建模，不替固件做补偿。
%   4. 本脚本不仿真 ESO 的扰动补偿通道（需要观测器 + 力矩回灌），
%      eso_* 参数由带宽准则推导并给出建议值，实机再验。
% =========================================================================

if nargin < 1 || isempty(options)
  options = struct();
end

%% ===================== 第 1 节：填入系统辨识结果 =====================
% J / B / tau_c 来自 SystemIdentify 的 AxisResult —— Ozone 里看
% yaw_result_ / pit_result_ 的字段 j / b / tau_c / residual_ratio。
% 只有 residual_ratio < 0.1 的辨识结果才可信；发散时该值接近或超过 1。
% 尚未辨识的量填 NaN，脚本会退化处理并在报告里标出。

% ---------------- Yaw 轴 ----------------
YAW                     = struct();
YAW.name                = 'yaw';
YAW.enabled             = true;
YAW.J                   = 0.0395300984;  % kg*m^2     已落 yaml: j_yaw
YAW.B                   = 0.199095935;   % N*m*s/rad  Ozone: yaw_result_.b
YAW.tau_c               = 0.129962802;   % N*m        Ozone: yaw_result_.tau_c
YAW.mgl                 = 0.0;           % N*m        yaw 无重力项，固定 0
YAW.residual_ratio      = 0.0642537549;  % Ozone: yaw_result_.residual_ratio
YAW.coulomb_tanh_scale  = 0.1;           % rad/s      辨识时 tanh 的平滑尺度
YAW.torque_limit_nm     = 2.223;         % N*m        硬限幅 (= pid_yaw_omega.out_limit)
YAW.torque_soft_limit_nm= 2.0;           % N*m        软限幅
YAW.torque_slew_nm_s    = 1000.0;        % N*m/s      斜率限幅
YAW.sigma_theta_rad     = 0.0010;        % rad        静止时角度反馈标准差
YAW.sigma_omega_rad_s   = 0.0100;        % rad/s      静止时角速度反馈标准差
YAW.omega_max_rad_s     = 8.0;           % rad/s      运动包线（ESO 闸门用）
YAW.alpha_max_rad_s2    = 40.0;          % rad/s^2    运动包线（ESO 闸门用）
YAW.friction_stick_rad_s= 0.02;          % rad/s      粘滞判定速度阈值（静摩擦模型）
YAW.dist_torque_nm      = 0.0;           % N*m        恒定外部扰动力矩（线束拖拽/CG 偏心）

% ---------------- Pitch 轴 ----------------
% 注意：当前固件 pitch 走 PID（pid_pit_angle / pid_pit_omega），
%       本块供切换到 SMC / LQR-ESO 时使用，默认 enabled = false。
PITCH                   = YAW;
PITCH.name              = 'pitch';
PITCH.enabled           = false;         % <<< 切换 pitch 控制器时改 true
PITCH.J                 = 0.014;         % kg*m^2     已落 yaml: j_pit
PITCH.B                 = NaN;           % N*m*s/rad  <<< 待填: pit_result_.b
PITCH.tau_c             = NaN;           % N*m        <<< 待填: pit_result_.tau_c
PITCH.mgl               = NaN;           % N*m        <<< 待填: pit_result_.mgl（重力项）
PITCH.torque_limit_nm   = 10.0;          % N*m
PITCH.torque_soft_limit_nm = 10.0;       % N*m
PITCH.sigma_theta_rad   = 0.0010;
PITCH.sigma_omega_rad_s = 0.0100;
PITCH.omega_max_rad_s   = 4.0;
PITCH.alpha_max_rad_s2  = 20.0;
PITCH.friction_stick_rad_s = 0.02;
PITCH.dist_torque_nm    = 0.0;

AXES = {YAW, PITCH};
if isfield(options, 'axes') && ~isempty(options.axes)
  AXES = options.axes;
end

%% ===================== 第 2 节：设计偏好（一般不用改）=====================
CFG = struct();
CFG.q_angle_candidates    = [20 50 100 200 500 1000];
CFG.q_velocity_candidates = [0.05 0.1 0.2 0.5 1 2 5];
CFG.r_candidates          = [0.02 0.05 0.1 0.2 0.5 1 2];
CFG.max_overshoot_pct     = 8.0;     % LQR 候选筛选：超调上限
CFG.max_torque_ratio      = 0.90;    % LQR 候选筛选：未钳位峰值力矩 / 生效限幅
CFG.max_slew_ratio         = 0.90;    % 候选筛选：峰值力矩变化率 / 配置斜率上限
CFG.max_settle_ratio       = 0.95;    % 建立时间必须落在仿真窗口前该比例内
CFG.effort_weight         = 0.05;    % 代价里控制量占比的权重（偏低增益优先，仅作并列打破）
CFG.slew_weight            = 0.03;    % 斜率占用率权重
CFG.step_ref_rad          = 10*pi/180;
CFG.step_large_rad        = 30*pi/180;
CFG.sim_dt_s              = 2e-4;
% 仿真窗口必须足够长：窗口短于慢候选的建立时间时，所有慢候选会拿到相同的
% "未建立"标志，主指标塌陷成常数，网格会反向选出最弱的控制器。
% 本轴最慢可行候选 omega_n ~ 8.9 rad/s（约 0.6 s 建立），取 1.2 s 留足余量。
CFG.sim_duration_s        = 1.2;
CFG.settle_band_ratio     = 0.02;
CFG.smc_zeta              = 1.30;    % SMC 线性区目标阻尼比（可实现域下限自动抬高）
CFG.smc_epsilon_margin    = 2.0;     % eps = margin * tau_c / J（切换项要压过库仑摩擦）
CFG.smc_epsilon_margin_candidates = [1.0 1.5 2.0 2.5];
CFG.smc_epsilon_fallback  = 0.05;    % tau_c 缺失时：eps = fallback * 软限幅 / J
CFG.smc_epsilon_min_ratio = 0.03;    % eps*J 占软限幅比例下限（防 eps 过小失效）
CFG.smc_epsilon_max_ratio = 0.25;    % eps*J 占软限幅比例上限（防 eps 过大抖振）
CFG.smc_q                 = 21;      % 终端滑模指数分子
CFG.smc_p                 = 27;      % 终端滑模指数分母（须 > q）
CFG.sat_k                 = 3.0;     % sat 边界层 = k * sigma_s
CFG.sat_k_candidates       = [2.0 3.0 4.0];
CFG.smc_robust_weight      = 0.35;    % 静摩擦/恒定扰动鲁棒性代价权重
CFG.smc_deadband_k        = 1.0;     % 误差死区 = k * sigma_omega / c，再与 sigma_theta 取小
CFG.eso_bandwidth_ratio   = 4.0;     % omega0 = ratio * omega_n
CFG.eso_bandwidth_min     = 20.0;    % rad/s
CFG.eso_bandwidth_max     = 120.0;   % rad/s
CFG.eso_comp_gain         = 1.0;
CFG.eso_comp_limit_ratio  = 0.15;    % ESO 补偿限幅 = ratio * 软限幅
CFG.lqi_ki_ratio          = 0.15;    % k_i = ratio * k_theta
CFG.lqi_limit_ratio       = 0.15;    % k_i * 积分限幅 = ratio * 软限幅
CFG.stiction_ratio        = 1.30;    % 静摩擦上界 / 辨识出的库仑摩擦（工程假设，未辨识）
CFG.eso_compare           = true;    % 做「ESO 补偿关 / 开 / SMC」三方对比仿真
% 对比窗口独立给定：静摩擦下 ESO 靠「粘滞-滑动」逐次破粘推进，残差随周期数
% 单调减小。用长窗口是为了确认残差已进入准稳态，而非停在收敛途中。
CFG.eso_compare_duration_s= 3.0;
CFG.envelope_freq_hz      = [0.5 1 2 3 5];  % 跟踪包线扫描频率点
CFG.enable_plot           = true;
if isfield(options, 'cfg') && ~isempty(options.cfg)
  CFG = mergeStruct(CFG, options.cfg);
end
if isfield(options, 'enable_plot')
  CFG.enable_plot = logical(options.enable_plot);
end

%% ===================== 第 3 节：逐轴求解与报告 =====================
REPORT = struct();
for ai = 1:numel(AXES)
  ax = AXES{ai};
  if ~ax.enabled
    fprintf('\n[跳过] 轴 %s：enabled = false\n', ax.name);
    continue;
  end

  fprintf('\n%s\n', repmat('=', 1, 76));
  fprintf('  轴 %s\n', upper(ax.name));
  fprintf('%s\n', repmat('=', 1, 76));

  ax = normalizeIdentified(ax);
  validateAxis(ax, CFG);
  printIdentification(ax);

  [lqrBest, lqrTbl] = designLqr(ax, CFG);
  smc               = designSmc(lqrBest, ax, CFG);
  eso               = designEso(lqrBest, ax, CFG);

  printLqrReport(lqrBest, lqrTbl, ax, CFG);
  printSmcReport(smc, ax, CFG);
  printEsoReport(eso, ax, CFG);
  printEnvelope(ax, CFG);

  REPORT.(ax.name) = struct('ax', ax, 'lqr', lqrBest, 'smc', smc, 'eso', eso);
  if CFG.eso_compare
    cmp = runEsoCompare(lqrBest, smc, eso, ax, CFG);
    printEsoCompare(cmp, smc, eso, ax, CFG);
    REPORT.(ax.name).cmp = cmp;
  end

  printYamlBlock(lqrBest, smc, eso, ax, CFG);
end

if ~isempty(fieldnames(REPORT)) && CFG.enable_plot
  plotAll(REPORT, CFG);
end

fprintf('\n[完成] 记得把 YAML 块里的 j_* / *_k 也一并更新。\n\n');

end

%% ======================================================================
%%                            本地函数
%% ======================================================================

function ax = normalizeIdentified(ax)
  ax = setfield_defaults(ax);
  if ~isfinite(ax.B)
    ax.B = 0.0;
    ax.B_assumed_zero = true;
  else
    ax.B_assumed_zero = false;
  end
  if ~isfinite(ax.tau_c)
    ax.tau_c = 0.0;
    ax.tau_c_assumed_zero = true;
  else
    ax.tau_c_assumed_zero = false;
  end
  if ~isfinite(ax.residual_ratio)
    ax.residual_ratio = NaN;
  end
  ax.identification_usable = isfinite(ax.J) && ax.J > 1e-6 && ...
      isfinite(ax.B) && ax.B >= 0 && isfinite(ax.tau_c) && ...
      ax.tau_c >= 0 && (isnan(ax.residual_ratio) || ax.residual_ratio < 0.1);
end

function validateAxis(ax, CFG)
  values = [ax.J ax.B ax.tau_c ax.torque_limit_nm ax.torque_soft_limit_nm ...
            ax.torque_slew_nm_s ifelse_local(isfield(ax, 'mgl'), ax.mgl, 0)];
  if any(~isfinite(values)) || ax.J <= 1e-6 || ax.B < 0 || ax.tau_c < 0
    error('轴 %s：J/B/tau_c/限幅参数必须为有限且物理可行的数值。', ax.name);
  end
  if min(ax.torque_limit_nm, ax.torque_soft_limit_nm) <= 0 || ax.torque_slew_nm_s <= 0
    error('轴 %s：力矩限幅和斜率限幅必须大于 0。', ax.name);
  end
  if isfinite(ax.residual_ratio) && ax.residual_ratio >= 0.1
    warning('轴 %s：residual_ratio=%.4f >= 0.1，辨识结果不建议直接用于实机。', ...
            ax.name, ax.residual_ratio);
  end
  if CFG.sim_dt_s <= 0 || CFG.sim_duration_s <= 10*CFG.sim_dt_s
    error('CFG.sim_dt_s/sim_duration_s 配置不合理。');
  end
end

function value = ifelse_local(condition, trueValue, falseValue)
  if condition, value = trueValue; else, value = falseValue; end
end

function ax = setfield_defaults(ax)
  defs = struct('mgl', 0.0, 'enabled', true, 'coulomb_tanh_scale', 0.1, ...
                'sigma_theta_rad', 0.001, 'sigma_omega_rad_s', 0.01, ...
                'friction_stick_rad_s', 0.02, 'dist_torque_nm', 0.0);
  f = fieldnames(defs);
  for i = 1:numel(f)
    if ~isfield(ax, f{i}) || isempty(ax.(f{i}))
      ax.(f{i}) = defs.(f{i});
    end
  end
end

function printIdentification(ax)
  fprintf('\n--- 辨识量核对 ---\n');
  fprintf('  J            = %.10g kg*m^2\n', ax.J);
  fprintf('  B            = %.10g N*m*s/rad\n', ax.B);
  fprintf('  tau_c        = %.10g N*m\n', ax.tau_c);
  fprintf('  mgl          = %.10g N*m\n', ax.mgl);
  fprintf('  tanh 尺度 w_c = %.10g rad/s\n', ax.coulomb_tanh_scale);
  if isfinite(ax.residual_ratio)
    if ax.residual_ratio < 0.1
      fprintf('  残差比       = %.4f  [可信]\n', ax.residual_ratio);
    else
      fprintf('  残差比       = %.4f  [!! 超过 0.1，辨识结果不可信，勿直接使用]\n', ax.residual_ratio);
    end
  else
    fprintf('  残差比       = 未提供 [!! 无法判定辨识可信度]\n');
  end
  fprintf('  可直接整定     = %s（残差/物理边界检查）\n', boolStr(ax.identification_usable));
  if isfield(ax, 'B_assumed_zero') && ax.B_assumed_zero
    fprintf(['  [!!] B 未辨识 -> 按 0 处理。后果：\n' ...
             '       (a) YawLqrEso 的 ESO 阻尼项 -(B/J)*z2 缺失，观测器按双积分器建模；\n' ...
             '       (b) 粘性前馈 b*omega_ref 缺失；\n' ...
             '       (c) SMC 反解无法计入 B/J。\n']);
  end
  if isfield(ax, 'tau_c_assumed_zero') && ax.tau_c_assumed_zero
    fprintf('  [!!] tau_c 未辨识 -> 按 0 处理，eps 改用兜底比例。\n');
  end
  if isfield(ax, 'mgl') && isfinite(ax.mgl) && abs(ax.mgl) > 0 && strcmp(ax.name, 'pitch')
    fprintf('  [i]  pitch 存在重力项 mgl=%.4g N*m：LQR-ESO 靠 z3 吸收；纯 LQR 需另加重力前馈。\n', ax.mgl);
  end
end

function [best, tbl] = designLqr(ax, CFG)
  J = ax.J; B = ax.B;
  A = [0 1; 0 -B/J];
  Bv = [0; 1/J];
  % 实际生效的命令限幅 = 软限幅与硬限幅的较小者。
  % 筛选必须用「未钳位的需求力矩」：若用钳位后的值，所有饱和候选都会
  % 恰好等于限幅而全部通过，网格会系统性选出最激进（持续饱和）的解。
  refLimit = min(ax.torque_soft_limit_nm, ax.torque_limit_nm);

  cands = {};
  for qa = CFG.q_angle_candidates
    for qv = CFG.q_velocity_candidates
      for rv = CFG.r_candidates
        Q = diag([qa, qv]);
        [K, ~, ok] = careHamiltonian(A, Bv, Q, rv);
        if ~ok, continue; end
        cl = eig(A - Bv*K);
        if any(real(cl) >= 0), continue; end

        resp = simulateLqr(A, Bv, K, ax, CFG, CFG.step_ref_rad);
        wn = sqrt(abs(prod(cl)));
        if abs(imag(cl(1))) > 1e-9
          zeta = -real(cl(1)) / wn;
        else
          zeta = 1.0;
        end

        c       = struct();
        c.Q     = [qa qv];
        c.R     = rv;
        c.K     = K;
        c.wn    = wn;
        c.zeta  = zeta;
        c.poles = cl;
        c.resp  = resp;
        c.torque_ratio = resp.peak_tau_raw / refLimit;
        c.slew_ratio = resp.peak_tau_slew / max(ax.torque_slew_nm_s, 1e-9);
        c.saturates    = resp.peak_tau_raw > refLimit;
        c.slew_limited = c.slew_ratio > CFG.max_slew_ratio;
        % 主指标用归一化 IAE 而非「2% 建立时间」：建立时间在窗口内未收敛时
        % 会退化成一个常数，候选之间失去区分度。
        c.cost  = resp.iae ...
                + 0.02 * max(resp.overshoot_pct - CFG.max_overshoot_pct, 0) ...
                + CFG.effort_weight * c.torque_ratio ...
                + CFG.slew_weight * c.slew_ratio;
        cands{end+1} = c; %#ok<AGROW>
      end
    end
  end

  if isempty(cands)
    error(['轴 %s：QR 候选网格里没有可控且闭环稳定的组合，' ...
           '请检查 J / B 是否合理。'], ax.name);
  end

  tbl = zeros(numel(cands), 9);
  for i = 1:numel(cands)
    c = cands{i};
    tbl(i, :) = [c.Q(1), c.Q(2), c.R, c.K(1), c.K(2), c.wn, c.zeta, ...
                 c.resp.settle_s, c.resp.peak_tau_raw];
  end

  % 三级筛选：① 不饱和且超调达标 -> ② 不饱和 -> ③ 全部（并列报告放宽）
  relaxed = 0;
  feas = cellfun(@(c) ~c.saturates && c.torque_ratio <= CFG.max_torque_ratio && ...
      c.resp.overshoot_pct <= CFG.max_overshoot_pct && ...
      c.resp.settle_s <= CFG.max_settle_ratio*CFG.sim_duration_s, cands);
  if ~any(feas)
    relaxed = 1;
    feas = cellfun(@(c) ~c.saturates && c.torque_ratio <= CFG.max_torque_ratio, cands);
  end
  if ~any(feas)
    relaxed = 2;
    feas = true(1, numel(cands));
  end
  idx = find(feas);
  costs = cellfun(@(c) c.cost, cands(idx));
  [~, j] = min(costs);

  best            = cands{idx(j)};
  best.A          = A;
  best.Bv         = Bv;
  best.ref_limit  = refLimit;
  best.relaxed    = relaxed;
  best.n_feasible = numel(idx);
  best.n_total    = numel(cands);
end

function [K, P, ok] = careHamiltonian(A, Bv, Q, R)
  n = size(A, 1);
  K = []; P = []; ok = false;
  if any(~isfinite([A(:); Bv(:); Q(:)])) || ~isfinite(R) || R <= 0
    return;
  end
  H = [A, -(Bv/R)*Bv'; -Q, -A'];
  [V, D] = eig(H);
  lam = diag(D);
  sel = real(lam) < -1e-9;
  if nnz(sel) ~= n, return; end
  V1 = V(1:n, sel);
  V2 = V(n+1:2*n, sel);
  if rcond(V1) < 1e-12, return; end
  P = real(V2 / V1);
  P = 0.5*(P + P.');
  K = (1/R) * Bv' * P;
  ok = all(isfinite(K(:))) && all(eig(P) > 0);
end

function resp = simulateLqr(A, Bv, K, ax, CFG, ref)
  dt = CFG.sim_dt_s;
  N  = round(CFG.sim_duration_s / dt);
  x  = zeros(2, 1);
  th = zeros(N+1, 1); om = zeros(N+1, 1); u = zeros(N+1, 1);
  uLast = 0.0; rawPeak = 0.0; rawSlewPeak = 0.0; rawLast = 0.0;
  for k = 1:N
    tauRaw = K(1)*(ref - x(1)) - K(2)*x(2);
    rawPeak = max(rawPeak, abs(tauRaw));
    tau = min(max(tauRaw, -ax.torque_soft_limit_nm), ax.torque_soft_limit_nm);
    tau = min(max(tau,   -ax.torque_limit_nm),      ax.torque_limit_nm);
    rawSlewPeak = max(rawSlewPeak, abs(tau - uLast)/max(dt, 1e-12));
    maxd = ax.torque_slew_nm_s * dt;
    tau = min(max(tau, uLast - maxd), uLast + maxd);
    u(k) = tau; uLast = tau;
    alpha = (tau - ax.B*x(2) - ax.tau_c*tanh(x(2)/ax.coulomb_tanh_scale)) / ax.J;
    x(2) = x(2) + dt*alpha;
    x(1) = x(1) + dt*x(2);
    th(k+1) = x(1); om(k+1) = x(2);
  end
  u(N+1) = u(N);
  resp = packResponse((0:N).'*dt, th, om, u, ref, CFG.settle_band_ratio);
  resp.peak_tau_raw = rawPeak;
  resp.peak_tau_slew = rawSlewPeak;
end

function resp = simulateSmc(smc, ax, CFG, ref, useStiction, T)
  if nargin < 5
    useStiction = false;
  end
  if nargin < 6 || ~isfinite(T) || T <= 0
    T = CFG.sim_duration_s;
  end
  dt = CFG.sim_dt_s;
  N  = round(T / dt);
  theta = 0.0; omega = 0.0;
  th = zeros(N+1, 1); om = zeros(N+1, 1); u = zeros(N+1, 1);
  uLast = 0.0; usedFtsmc = false; rawPeak = 0.0;

  for k = 1:N
    eTh = theta - ref;
    eOm = omega;
    if abs(eTh) < smc.error_deadband_rad
      % 对齐固件：死区内直接输出 0，不经过斜率限制
      tau = 0.0;
    else
      if smc.ftsmc_enable && abs(eTh) >= smc.ftsmc_switch_rad
        s = eOm + smc.c * sigpow(eTh, smc.r);
        sDotTerm = smc.c * smc.r * abs(eTh)^(smc.r - 1) * eOm;
        usedFtsmc = true;
      else
        s = eOm + smc.c * eTh;
        sDotTerm = smc.c * eOm;
      end
      satS = satFun(s / smc.sat_boundary);
      tauRaw = ax.J * (-sDotTerm - smc.epsilon*satS - smc.k*s);
      rawPeak = max(rawPeak, abs(tauRaw));
      tau = min(max(tauRaw, -ax.torque_soft_limit_nm), ax.torque_soft_limit_nm);
      tau = min(max(tau,    -ax.torque_limit_nm),      ax.torque_limit_nm);
      maxd = ax.torque_slew_nm_s * dt;
      tau = min(max(tau, uLast - maxd), uLast + maxd);
    end
    u(k) = tau; uLast = tau;
    [theta, omega] = plantStep(theta, omega, tau, ax, CFG, dt, useStiction);
    th(k+1) = theta; om(k+1) = omega;
  end
  u(N+1) = u(N);
  resp = packResponse((0:N).'*dt, th, om, u, ref, CFG.settle_band_ratio);
  resp.used_ftsmc   = usedFtsmc;
  resp.peak_tau_raw = rawPeak;
end

%% ---------------------------------------------------------------------
%%  被控对象步进（可切换 平滑摩擦 / 静摩擦粘滞 两种摩擦模型）
%% ---------------------------------------------------------------------
%
%  平滑模型（辨识与 LQR 设计用）：tau_c * tanh(omega / w_c)
%    与 SystemIdentify 的回归量同构，且在 omega = 0 处归零 —— 因此【不会】
%    产生停滞死区，无法体现静摩擦对控制器的实际阻碍。
%
%  粘滞模型（ESO 验证用）：经典库仑干摩擦
%    |omega| > w_stick         -> 滑动，摩擦力 = tau_s * sign(omega)
%    |omega| <= w_stick 且 |tau| <= tau_s -> 粘滞，摩擦力完全抵消外力矩，轴停住
%    |omega| <= w_stick 且 |tau| >  tau_s -> 即将起滑，摩擦力 = tau_s * sign(tau)
%    其中 tau_s = stiction_ratio * tau_c（静摩擦上界，脚本按工程假设给定）。
%    只有这一项才能暴露「静止瞄准静差」与 ESO/切换项的抗卡滞能力。
% ---------------------------------------------------------------------

function [theta, omega] = plantStep(theta, omega, tauApplied, ax, CFG, dt, useStiction)
  if useStiction
    tauS = CFG.stiction_ratio * abs(ax.tau_c);
    wStick = ax.friction_stick_rad_s;
    if abs(omega) > wStick
      tauFric = tauS * sign(omega);
    elseif abs(tauApplied) <= tauS
      tauFric = tauApplied;      % 粘滞：净力矩为零
      omega = 0.0;
    else
      tauFric = tauS * sign(tauApplied);
    end
  else
    tauFric = ax.tau_c * tanh(omega / ax.coulomb_tanh_scale);
  end

  gravityTorque = ax.mgl * sin(theta);
  alpha = (tauApplied - ax.B*omega - tauFric - gravityTorque - ax.dist_torque_nm) / ax.J;
  omegaNew = omega + dt * alpha;

  % 理想库仑摩擦不得把速度推过零点：若外力矩不足以维持滑动，直接停在零
  if useStiction && abs(tauApplied) <= CFG.stiction_ratio*abs(ax.tau_c) && ...
     sign(omegaNew) ~= sign(omega) && omega ~= 0
    omegaNew = 0.0;
  end

  omega = omegaNew;
  theta = theta + dt * omega;
end

%% ---------------------------------------------------------------------
%%  LQR-ESO 全链路仿真（严格对齐 YawLqrEso.hpp 的 Calculate）
%% ---------------------------------------------------------------------
%
%  逐周期复现固件的计算顺序：
%    1. 三阶 ESO 更新（输入为【上一周期实际下发力矩】last_applied_torque_nm_）
%    2. 误差 e_theta / e_omega
%    3. 前馈：J*alpha_ref（阶跃参考下为 0）、b*omega_ref（为 0）、
%       tau_c*tanh(omega_ref/w_c)（omega_ref = 0 -> 恒为 0）
%    4. LQI（可选）
%    5. tau_lqr = 前馈 + tau_lqi - k_theta*e_theta - k_omega*e_omega
%    6. ESO 扰动补偿：tau_eso = -eso_comp_gain * z3 / (1/J)，经 eso_comp_limit_nm
%       限幅 + omega/alpha 双门控
%    7. 软限幅 -> 硬限幅 -> 斜率限幅
%    8. 首周期只同步状态、输出零力矩（对齐固件 feedback_ready 逻辑）
%
%  被控对象固定使用静摩擦粘滞模型：平滑 tanh 模型在 omega = 0 处归零，
%  本就不会产生停滞死区，无法检验 ESO 补偿是否有效。
% ---------------------------------------------------------------------

function resp = simulateYawLqrEso(cfg, ax, CFG, ref, compEnable, T)
  if nargin < 6 || ~isfinite(T) || T <= 0
    T = CFG.sim_duration_s;
  end
  dt = CFG.sim_dt_s;
  N  = round(T / dt);
  J = ax.J; B = ax.B;

  theta = 0.0; omega = 0.0;
  z1 = 0.0; z2 = 0.0; z3 = 0.0;
  observerReady = false;
  firstCycle = true;
  thetaIntegral = 0.0;
  lastAppliedTau = 0.0;
  compSatCount = 0;

  th = zeros(N+1,1); om = zeros(N+1,1); u = zeros(N+1,1);
  z3h = zeros(N+1,1); res = zeros(N+1,1);
  anyCompActive = false;
  rawPeak = 0.0;

  for k = 1:N
    tauEso = 0.0;
    compActive = false;

    if firstCycle
      z1 = theta; z2 = omega; z3 = 0.0;
      observerReady = false;
      firstCycle = false;
      tau = 0.0;
    else
      if cfg.eso_enable
        w0 = cfg.eso_bandwidth_rad_s;
        b1 = 3.0*w0; b2 = 3.0*w0*w0; b3 = w0*w0*w0;
        obsErr = theta - z1;
        z1 = z1 + dt*(z2 + b1*obsErr);
        z2 = z2 + dt*(-(B/J)*z2 + (1.0/J)*lastAppliedTau + z3 + b2*obsErr);
        z3 = z3 + dt*(b3*obsErr);
        observerReady = true;
      else
        z1 = theta; z2 = omega; z3 = 0.0;
        observerReady = false;
      end

      eTheta = theta - ref;
      eOmega = omega;

      if cfg.lqi_enable
        thetaIntegral = min(max(thetaIntegral + eTheta*dt, ...
                                -cfg.theta_integral_limit_rad_s), ...
                            cfg.theta_integral_limit_rad_s);
      else
        thetaIntegral = 0.0;
      end
      tauLqi = -cfg.k_i * thetaIntegral;

      if cfg.coulomb_enable
        tauCoulFF = cfg.tau_coulomb_nm * tanh(0.0 / cfg.coulomb_smooth_rad_s);
      else
        tauCoulFF = 0.0;
      end

      tauLqr = tauCoulFF + tauLqi - cfg.k_theta*eTheta - cfg.k_omega*eOmega;

      if compEnable && cfg.eso_enable && observerReady
        g   = 1.0/J;
        raw = -cfg.eso_comp_gain * z3 / g;
        if abs(raw) > cfg.eso_comp_limit_nm
          compSatCount = compSatCount + 1;
        end
        raw = min(max(raw, -cfg.eso_comp_limit_nm), cfg.eso_comp_limit_nm);
        omegaGate = (cfg.eso_omega_gate_rad_s <= 0.0) || ...
                    (abs(omega) <= cfg.eso_omega_gate_rad_s);
        alphaGate = (cfg.eso_alpha_gate_rad_s2 <= 0.0) || ...
                    (abs(0.0) <= cfg.eso_alpha_gate_rad_s2);
        if omegaGate && alphaGate
          tauEso = raw;
          compActive = true;
        end
      end

      tau = tauLqr + tauEso;
      rawPeak = max(rawPeak, abs(tau));
      if ax.torque_soft_limit_nm > 0.0
        tau = min(max(tau, -ax.torque_soft_limit_nm), ax.torque_soft_limit_nm);
      end
      tau = min(max(tau,  -ax.torque_limit_nm), ax.torque_limit_nm);
      maxd = ax.torque_slew_nm_s * dt;
      tau = min(max(tau, lastAppliedTau - maxd), lastAppliedTau + maxd);
    end

    anyCompActive = anyCompActive || compActive;
    u(k) = tau; z3h(k) = z3; res(k) = tauEso;
    lastAppliedTau = tau;

    [theta, omega] = plantStep(theta, omega, tau, ax, CFG, dt, true);
    th(k+1) = theta; om(k+1) = omega;
  end

  u(N+1) = u(N); z3h(N+1) = z3; res(N+1) = res(N);
  resp = packResponse((0:N).'*dt, th, om, u, ref, CFG.settle_band_ratio);
  resp.z3             = z3h;
  resp.tau_eso        = res;
  resp.comp_active    = anyCompActive;
  resp.comp_sat_count = compSatCount;
  resp.peak_tau_raw   = rawPeak;
  resp.dist_estimate_nm = z3 * J;    % z3 换算到力矩域（观测器对总扰动的估计）
  resp.tau_eso_final    = res(N+1);
end

%% ---------------------------------------------------------------------
%%  ESO 补偿开/关 + SMC 三方对比
%% ---------------------------------------------------------------------

function cmp = runEsoCompare(lqrBest, smc, eso, ax, CFG)
  cfg = struct();
  cfg.eso_enable                 = true;
  cfg.eso_bandwidth_rad_s        = eso.eso_bandwidth_rad_s;
  cfg.eso_comp_gain              = eso.eso_comp_gain;
  cfg.eso_comp_limit_nm          = eso.eso_comp_limit_nm;
  cfg.eso_omega_gate_rad_s       = eso.eso_omega_gate_rad_s;
  cfg.eso_alpha_gate_rad_s2      = eso.eso_alpha_gate_rad_s2;
  cfg.tau_coulomb_nm             = eso.tau_coulomb_nm;
  cfg.coulomb_smooth_rad_s       = eso.coulomb_smooth_rad_s;
  cfg.coulomb_enable             = eso.coulomb_enable;
  cfg.k_i                        = eso.k_i;
  cfg.theta_integral_limit_rad_s = eso.theta_integral_limit_rad_s;
  cfg.lqi_enable                 = eso.lqi_enable;
  cfg.k_theta                    = lqrBest.K(1);
  cfg.k_omega                    = lqrBest.K(2);

  cmp.cfg           = cfg;
  cmp.tau_s         = CFG.stiction_ratio * abs(ax.tau_c);
  cmp.deadzone_rad  = cmp.tau_s / max(lqrBest.K(1), 1e-9);
  cmp.duration_s    = CFG.eso_compare_duration_s;
  cmp.noEso         = simulateYawLqrEso(cfg, ax, CFG, CFG.step_ref_rad, false, cmp.duration_s);
  cmp.eso           = simulateYawLqrEso(cfg, ax, CFG, CFG.step_ref_rad, true,  cmp.duration_s);
  cmp.smc           = simulateSmc(smc, ax, CFG, CFG.step_ref_rad, true, cmp.duration_s);
end

function printEsoCompare(cmp, smc, eso, ax, CFG)
  tauS = cmp.tau_s;
  fprintf('\n--- ESO 补偿通道对比仿真（对象含静摩擦粘滞，前馈无法抵消）---\n');
  fprintf('  静摩擦上界 tau_s = %.2f x |tau_c| = %.4f N*m（工程假设值，未辨识）\n', ...
          CFG.stiction_ratio, tauS);
  fprintf('  停滞死区上界     = ±tau_s/k_theta = ±%.5f rad = ±%.3f deg\n', ...
          cmp.deadzone_rad, 180/pi*cmp.deadzone_rad);
  fprintf('      实际捕获位置取决于减速过程，不一定是上界；上界是「被拖着停」的最坏情况。\n');
  fprintf('  ESO 补偿上限     = %.4f N*m  %s tau_s\n', eso.eso_comp_limit_nm, ...
          ternaryStr(eso.eso_comp_limit_nm > tauS, '(足以压过)', '[!! 不足]'));
  fprintf('  SMC 切换力矩     = eps*J = %.4f N*m  %s tau_s\n', smc.epsilon*ax.J, ...
          ternaryStr(smc.epsilon*ax.J > tauS, '(足以压过)', '[!! 不足]'));
  smcResidualRad = tauS / (ax.J * smc.c * (smc.k + smc.epsilon/smc.sat_boundary));
  fprintf('  SMC 层内残差闭式解 = tau_s/[J*c*(k+eps/b)] = %.5f rad = %.3f deg（用于核对仿真）\n', ...
          smcResidualRad, 180/pi*smcResidualRad);
  if ax.dist_torque_nm ~= 0.0
    fprintf('  叠加外部恒定扰动 = %.4f N*m（完全未建模）\n', ax.dist_torque_nm);
  end

  fprintf('\n  对比窗口 = %.2f s（用于确认残差已到准稳态，而非停在蠕动收敛途中）\n', ...
          cmp.duration_s);
  fprintf('  %-24s %13s %10s %12s %11s\n', ...
          '配置', '末值误差[deg]', '建立[s]', '归一化IAE', '峰值[N*m]');
  printCompareRow('LQR (ESO 补偿关)', cmp.noEso, cmp.duration_s);
  printCompareRow('LQR + ESO 补偿开', cmp.eso,   cmp.duration_s);
  printCompareRow('SMC',              cmp.smc,   cmp.duration_s);

  fprintf('\n  稳态 ESO 估计: z3*J = %.4f N*m  (= |tau_cmd|，即该工作点下真实的摩擦力矩)\n', ...
          cmp.eso.dist_estimate_nm);
  fprintf('      tau_eso 终值 = %.4f N*m；稳态力矩平衡 |K1*e + tau_eso| = %.4f N*m <= tau_s = %.4f N*m\n', ...
          cmp.eso.tau_eso_final, ...
          abs(cmp.cfg.k_theta*cmp.eso.ss_err + cmp.eso.tau_eso_final), tauS);
  fprintf('      [注意] z3*J 不是 tau_s 的估计量：轴停在哪个位置、用多大力矩平衡，\n');
  fprintf('             取决于粘滞捕获点，因此 z3*J 应等于 |tau_cmd| 而非满值 tau_s。\n');
  fprintf('  ESO 补偿使 IAE 由 %.4f 降到 %.4f（改善 %.1f%%），末值误差由 %.4f 降到 %.4f deg\n', ...
          cmp.noEso.iae, cmp.eso.iae, ...
          100*(cmp.noEso.iae - cmp.eso.iae)/max(cmp.noEso.iae, eps), ...
          180/pi*cmp.noEso.ss_err, 180/pi*cmp.eso.ss_err);
  if cmp.eso.comp_sat_count > 0
    fprintf('  [i] ESO 补偿有 %d 个周期触及 eso_comp_limit_nm 上限\n', cmp.eso.comp_sat_count);
  end

  fprintf(['\n  [解读]\n' ...
           '   - 「LQR (ESO 补偿关)」末值误差停在上界以内：静摩擦把轴卡在死区里。\n' ...
           '   - 「LQR + ESO 补偿开」若末值误差收敛到 0 附近，说明 z3 估计出了静摩擦力矩，\n' ...
           '     经 -z3/b0 反算成补偿力矩把轴推出粘滞区。\n' ...
           '   - 「SMC」靠 eps*sat(s/b) 在边界层内提供高增益压过静摩擦，残差应接近上面的\n' ...
           '     闭式解；若仿真值与闭式解明显不符，说明阶跃未真正落在边界层内。\n' ...
           '   - 若 ESO 补偿开反而持续抖动，说明 eso_bandwidth_rad_s 过高（噪声被放大进 z3），\n' ...
           '     需降带宽或调低 eso_comp_gain。\n']);
end

function printCompareRow(label, resp, T)
  if resp.settle_s >= T - 1e-9
    fprintf('  %-24s %13.4f %10s %12.4f %11.4f\n', label, ...
            180/pi*resp.ss_err, '未建立', resp.iae, resp.peak_tau_raw);
  else
    fprintf('  %-24s %13.4f %10.4f %12.4f %11.4f\n', label, ...
            180/pi*resp.ss_err, resp.settle_s, resp.iae, resp.peak_tau_raw);
  end
end

function resp = packResponse(t, th, om, u, ref, bandRatio)
  band = bandRatio * abs(ref);
  outside = find(abs(th - ref) > band);
  if isempty(outside)
    settle = 0.0;
  elseif outside(end) >= numel(t)
    settle = t(end);
  else
    settle = t(outside(end)+1);
  end
  lo = find(th >= 0.1*ref, 1, 'first');
  hi = find(th >= 0.9*ref, 1, 'first');
  if isempty(lo) || isempty(hi)
    rise = t(end);
  else
    rise = t(hi) - t(lo);
  end
  resp.t       = t;
  resp.theta   = th;
  resp.omega   = om;
  resp.tau     = u;
  resp.settle_s= settle;
  resp.rise_s  = rise;
  resp.overshoot_pct = max(0, (max(th) - ref)/abs(ref)*100);
  resp.ss_err  = th(end) - ref;
  resp.peak_tau= max(abs(u));
  % 归一化 IAE：无量纲、对窗口长度不敏感，作为网格搜索的主指标
  dtSim = t(2) - t(1);
  spanSim = max(t(end) - t(1), eps);
  resp.iae = sum(abs(th - ref)) * dtSim / (abs(ref) * spanSim);
end

function smc = designSmc(lqrBest, ax, CFG)
  J = ax.J; B = ax.B;
  K1 = lqrBest.K(1); K2 = lqrBest.K(2);

  S_target  = B/J + K2/J;   % 精确等价要求 c + k = B/J + K2/J
  P_target  = K1/J;         % 精确等价要求 c * k = K1/J
  wn        = sqrt(P_target);
  zetaMin   = 1 + (B/J)/(2*wn);   % 实根可实现的最低下限

  disc = S_target^2 - 4*P_target;
  exact = disc >= 0;
  if exact
    roots_ = [0.5*(S_target + sqrt(disc)), 0.5*(S_target - sqrt(disc))];
    zetaUsed = (B/J + sum(roots_)) / (2*wn);
  else
    zetaUsed = max(CFG.smc_zeta, zetaMin);
    S_target = 2*zetaUsed*wn - B/J;
    d2 = max(S_target^2 - 4*P_target, 0);
    roots_ = [0.5*(S_target + sqrt(d2)), 0.5*(S_target - sqrt(d2))];
  end

  epsLo = CFG.smc_epsilon_min_ratio * ax.torque_soft_limit_nm / J;
  epsHi = CFG.smc_epsilon_max_ratio * ax.torque_soft_limit_nm / J;
  r = CFG.smc_q / CFG.smc_p;
  eSwitchNoise = realpow_local(r, 1/(1 - r));

  % 同时扫描根指派、切换强度和边界层，并以静摩擦/恒定扰动工况
  % 的性能作为鲁棒性代价，避免只在平滑摩擦模型下选出过激参数。
  cands = {};
  margins = CFG.smc_epsilon_margin_candidates;
  if isempty(margins), margins = CFG.smc_epsilon_margin; end
  satKs = CFG.sat_k_candidates;
  if isempty(satKs), satKs = CFG.sat_k; end
  for idx = 1:2
    c_ = max(roots_(idx),     1e-3);
    k_ = max(roots_(3 - idx), 1e-3);
    for margin = margins
      if ax.tau_c > 0
        eps_ = margin * ax.tau_c / J;
      else
        eps_ = CFG.smc_epsilon_fallback * ax.torque_soft_limit_nm / J;
      end
      eps_ = min(max(eps_, epsLo), epsHi);
      for satK = satKs
        sigmaS = sqrt(c_^2 * ax.sigma_theta_rad^2 + ax.sigma_omega_rad_s^2);
        satB = satK * sigmaS;
        db = min(CFG.smc_deadband_k * ax.sigma_omega_rad_s / c_, ax.sigma_theta_rad);
        cand = struct('c', c_, 'k', k_, 'sat_boundary', satB, ...
          'sigma_s', sigmaS, 'error_deadband_rad', db, 'epsilon', eps_, ...
          'r', r, 'q', CFG.smc_q, 'p', CFG.smc_p, ...
          'ftsmc_switch_rad', max(eSwitchNoise, satK*ax.sigma_theta_rad), ...
          'ftsmc_enable', true, 'epsilon_margin', margin, 'sat_k', satK, ...
          'root_index', idx);
        cand.resp = simulateSmc(cand, ax, CFG, CFG.step_ref_rad);
        cand.robust = simulateSmc(cand, ax, CFG, CFG.step_ref_rad, true, CFG.sim_duration_s);
        cand.respLarge = simulateSmc(cand, ax, CFG, CFG.step_large_rad);
        robustCost = cand.robust.iae + 0.5*abs(cand.robust.ss_err)/max(abs(CFG.step_ref_rad),eps);
        cand.cost = cand.resp.iae + CFG.smc_robust_weight*robustCost ...
          + 0.02*cand.resp.overshoot_pct ...
          + 0.05*cand.resp.peak_tau_raw/max(ax.torque_soft_limit_nm,1e-9);
        cands{end+1} = cand; %#ok<AGROW>
      end
    end
  end

  costs = cellfun(@(s) s.cost, cands);
  [~, pickIdx] = min(costs);
  smc = cands{pickIdx};
  altIdx = find(cellfun(@(candidate) candidate.root_index ~= smc.root_index, cands), 1, 'first');
  if isempty(altIdx), altIdx = pickIdx; end
  smc.alt = cands{altIdx};
  smc.roots = roots_;
  smc.exact_equivalence = exact;
  smc.zeta_lqr = lqrBest.zeta;
  smc.zeta_used = zetaUsed;
  smc.zeta_min_realizable = zetaMin;
  smc.wn = wn;
  smc.e_switch_noise_bound = eSwitchNoise;
  smc.epsilon_before_clamp = (ax.tau_c > 0) * CFG.smc_epsilon_margin*ax.tau_c/J ...
                           + (ax.tau_c <= 0) * CFG.smc_epsilon_fallback*ax.torque_soft_limit_nm/J;
  smc.epsilon_clamped = abs(smc.epsilon - smc.epsilon_before_clamp) > 1e-12;
end

function eso = designEso(lqrBest, ax, CFG)
  eso = struct();
  wn = lqrBest.wn;
  raw = CFG.eso_bandwidth_ratio * wn;
  eso.eso_bandwidth_rad_s = min(max(raw, CFG.eso_bandwidth_min), CFG.eso_bandwidth_max);
  eso.ratio_requested = CFG.eso_bandwidth_ratio;
  eso.ratio_actual    = eso.eso_bandwidth_rad_s / wn;
  eso.bandwidth_clamped = abs(eso.eso_bandwidth_rad_s - raw) > 1e-9;
  eso.eso_comp_gain = CFG.eso_comp_gain;
  eso.eso_comp_limit_nm = min( ...
        max(1.5*abs(ax.tau_c), CFG.eso_comp_limit_ratio*ax.torque_soft_limit_nm), ...
        ax.torque_soft_limit_nm);
  eso.eso_omega_gate_rad_s = ax.omega_max_rad_s;
  eso.eso_alpha_gate_rad_s2 = ax.alpha_max_rad_s2;
  eso.tau_coulomb_nm = abs(ax.tau_c);
  eso.coulomb_smooth_rad_s = ax.coulomb_tanh_scale;

  % 仅由辨识量 + 噪声决定的部分
  eso.theta_deadband_rad = ax.sigma_theta_rad;
  eso.k_i = CFG.lqi_ki_ratio * lqrBest.K(1);
  eso.theta_integral_limit_rad_s = ...
      (CFG.lqi_limit_ratio * ax.torque_soft_limit_nm) / max(eso.k_i, 1e-9);
  eso.tau_bias_limit_nm = min(1.5*abs(ax.tau_c) + 0.02*ax.torque_limit_nm, ...
                              ax.torque_soft_limit_nm);
  eso.tau_bias_ki = 0.5;
  eso.tau_meas_lpf_alpha = 0.1;

  % 建议开关：库仑摩擦显著时才开补偿
  eso.coulomb_enable = abs(ax.tau_c) > 0.02 * ax.torque_limit_nm;
  eso.eso_enable = true;
  eso.eso_comp_enable = false;   % 首版保守：先只观测不补偿
  eso.lqi_enable = false;
  eso.torque_bias_enable = false;
  eso.torque_slew_enable = true;

  % LQR 无积分时，库仑摩擦造成的静差估计
  eso.ss_err_no_lqi_rad = abs(ax.tau_c) / max(lqrBest.K(1), 1e-9);
end

function printLqrReport(best, tbl, ax, CFG)
  fprintf('\n--- LQR 设计（对象: J*theta_ddot + B*theta_dot = tau）---\n');
  fprintf('  A = [0 1; 0 %.6f]   Bv = [0; %.6f]\n', -ax.B/ax.J, 1/ax.J);
  fprintf('  Q = diag([%g, %g]),  R = %g\n', best.Q(1), best.Q(2), best.R);
  fprintf('  网格 %d 组通过筛选（共评估 %d 组），生效限幅 = %.4f N*m\n', ...
          best.n_feasible, best.n_total, best.ref_limit);
  if best.relaxed == 1
    fprintf('  [!!] 无候选同时满足「不饱和 + 超调<=%.0f%%」，已放宽超调条件。\n', CFG.max_overshoot_pct);
  elseif best.relaxed == 2
    fprintf(['  [!!] 所有候选都会饱和（需求力矩 > 生效限幅）。\n' ...
             '       -> 说明 10deg 阶跃已超出当前力矩预算，需提高限幅或放宽 CFG.max_torque_ratio。\n']);
  end
  fprintf('  K = [%.6f, %.6f]\n', best.K(1), best.K(2));
  fprintf('  闭环极点 = %.4f%+.4fj , %.4f%+.4fj\n', ...
          real(best.poles(1)), imag(best.poles(1)), real(best.poles(2)), imag(best.poles(2)));
  fprintf('  omega_n = %.3f rad/s,  zeta = %.3f\n', best.wn, best.zeta);
  fprintf('  10deg 阶跃: 上升 %.4f s  建立 %.4f s  超调 %.2f%%  归一化 IAE %.4f  末值误差 %.3e rad\n', ...
          best.resp.rise_s, best.resp.settle_s, best.resp.overshoot_pct, ...
          best.resp.iae, best.resp.ss_err);
  fprintf('  需求峰值力矩 %.4f N*m (%.1f%% 生效限幅)  实际峰值 %.4f N*m  %s\n', ...
          best.resp.peak_tau_raw, 100*best.torque_ratio, best.resp.peak_tau, ...
          ternaryStr(best.saturates, '[饱和]', '[未饱和]'));
  fprintf('  需求峰值斜率 %.1f N*m/s (%.1f%% 配置上限)\n', ...
          best.resp.peak_tau_slew, 100*best.resp.peak_tau_slew/max(ax.torque_slew_nm_s,1e-9));
  reqSlew = ax.J * best.wn^2 * CFG.step_ref_rad * best.wn;
  fprintf('  阶跃响应所需最小斜率 ~%.1f N*m/s（配置 %.1f，%s）\n', ...
          reqSlew, ax.torque_slew_nm_s, ...
          ternaryStr(ax.torque_slew_nm_s > reqSlew, '非约束', '!! 会成为约束'));
end

function printSmcReport(smc, ax, CFG)
  fprintf('\n--- SMC 设计（由 LQR 增益反解，非独立辨识）---\n');
  fprintf('  等价条件: c+k = B/J + K2/J ,  c*k = K1/J\n');
  if smc.exact_equivalence
    fprintf('  -> 判别式 >= 0，与 LQR 线性区【精确等价】，c/k = [%.4f, %.4f]\n', ...
            smc.roots(1), smc.roots(2));
  else
    fprintf('  -> 判别式 < 0（LQR 为复极点），无法精确等价。\n');
    fprintf('     保持 omega_n = %.3f 不变，zeta 抬到 %.3f（可实现域下限 %.3f）后重投影。\n', ...
            smc.wn, smc.zeta_used, smc.zeta_min_realizable);
  end
  fprintf('  取 c = %.4f, k = %.4f（f = %.4f, g = %.4f）\n', ...
          smc.c, smc.k, smc.roots(1), smc.roots(2));
  fprintf('  实际 omega_n = %.3f rad/s,  zeta = %.3f\n', ...
          sqrt(smc.c*smc.k), (ax.B/ax.J + smc.c + smc.k)/(2*sqrt(smc.c*smc.k)));
  fprintf('  另一指派（c/k 互换）成本 %.4f vs 采用 %.4f\n', smc.alt.cost, smc.cost);
  fprintf('  epsilon = %.4f rad/s^2  (= eps*J = %.4f N*m, %.1f%% 软限幅)%s\n', ...
          smc.epsilon, smc.epsilon*ax.J, ...
          100*smc.epsilon*ax.J/ax.torque_soft_limit_nm, ...
          ternaryStr(smc.epsilon_clamped, ' [已触边界]', ''));
  fprintf('  q/p = %g/%g  ->  r = %.4f\n', smc.q, smc.p, smc.r);
  fprintf('  ftsmc_switch_rad = %.4f rad (%.2f deg)\n', smc.ftsmc_switch_rad, ...
          180/pi*smc.ftsmc_switch_rad);
  fprintf('     噪声下限 r^(1/(1-r)) = %.4f rad；10deg 阶跃%s触发终端区\n', ...
          smc.e_switch_noise_bound, ...
          ternaryStr(smc.resp.used_ftsmc, '会', '不会'));
  fprintf('  sat_boundary = %.6f  (= %.1f * sigma_s, sigma_s = %.6f)\n', ...
          smc.sat_boundary, smc.sat_k, smc.sigma_s);
  fprintf('  epsilon_margin = %.2f  鲁棒静摩擦 IAE = %.4f\n', ...
          smc.epsilon_margin, smc.robust.iae);
  fprintf('  error_deadband_rad = %.6f rad (%.4f deg)\n', ...
          smc.error_deadband_rad, 180/pi*smc.error_deadband_rad);
  fprintf('  10deg 阶跃: 上升 %.4f s  建立 %.4f s  超调 %.2f%%  归一化 IAE %.4f  需求峰值 %.4f N*m (%.1f%% 限幅)\n', ...
          smc.resp.rise_s, smc.resp.settle_s, smc.resp.overshoot_pct, ...
          smc.resp.iae, smc.resp.peak_tau_raw, ...
          100*smc.resp.peak_tau_raw/ax.torque_soft_limit_nm);
  if smc.resp.peak_tau_raw > ax.torque_soft_limit_nm
    fprintf(['  [i]  10deg 阶跃需求略超软限幅：切换项 eps*J = %.4f N*m 把峰值抬高到 %.4f N*m。\n' ...
             '       仅首周期被钳位，影响可忽略；若实机观测到起跳迟滞，先降 epsilon。\n'], ...
            smc.epsilon*ax.J, smc.resp.peak_tau_raw);
  end
  fprintf('  30deg 阶跃: 建立 %.4f s  超调 %.2f%%  需求峰值 %.4f N*m  终端区 %s\n', ...
          smc.respLarge.settle_s, smc.respLarge.overshoot_pct, ...
          smc.respLarge.peak_tau_raw, ternaryStr(smc.respLarge.used_ftsmc, '已触发', '未触发'));
  if smc.respLarge.peak_tau_raw > ax.torque_soft_limit_nm
    fprintf(['  [!!] 30deg 阶跃需求 %.4f N*m 已超生效限幅 %.4f N*m：该幅度下会持续饱和，\n' ...
             '       建立时间不可信。这是力矩预算问题，不是控制器参数问题。\n'], ...
            smc.respLarge.peak_tau_raw, ax.torque_soft_limit_nm);
  end
end

function printEsoReport(eso, ax, CFG)
  fprintf('\n--- ESO 与辅助项 ---\n');
  fprintf('  eso_bandwidth_rad_s   = %.2f  (= %.2f x omega_n, 目标 %.2f x)%s\n', ...
          eso.eso_bandwidth_rad_s, eso.ratio_actual, eso.ratio_requested, ...
          ternaryStr(eso.bandwidth_clamped, '  [受 min/max 钳制]', ''));
  fprintf('  eso_comp_gain         = %.2f\n', eso.eso_comp_gain);
  fprintf('  eso_comp_limit_nm     = %.4f\n', eso.eso_comp_limit_nm);
  fprintf('  eso_omega_gate_rad_s  = %.2f\n', eso.eso_omega_gate_rad_s);
  fprintf('  eso_alpha_gate_rad_s2 = %.2f\n', eso.eso_alpha_gate_rad_s2);
  fprintf('  tau_coulomb_nm        = %.4f   coulomb_smooth_rad_s = %.4f   coulomb_enable = %s\n', ...
          eso.tau_coulomb_nm, eso.coulomb_smooth_rad_s, boolStr(eso.coulomb_enable));
  fprintf('  k_i = %.4f   theta_integral_limit_rad_s = %.4f\n', ...
          eso.k_i, eso.theta_integral_limit_rad_s);
  fprintf('  无积分时库仑摩擦造成的静差估计 = %.5f rad (%.3f deg)\n', ...
          eso.ss_err_no_lqi_rad, 180/pi*eso.ss_err_no_lqi_rad);
  fprintf(['  [!!] 静差修正路径说明：\n' ...
           '       YawLqrEso 的库仑前馈按 tanh(reference.omega_rad_s / w_c) 计算，\n' ...
           '       静止瞄准时 omega_ref = 0 -> 该项恒为 0，因此 coulomb_enable = true\n' ...
           '       【不能】消除静止瞄准的静差。可用的两条路径是：\n' ...
           '       (a) eso_comp_enable = true：由 z3 吸收库仑力矩，不引入积分相位滞后；\n' ...
           '       (b) lqi_enable = true：积分消除静差，但大回转/目标切换时需防积分饱和。\n' ...
           '       另：tanh(w/w_c) 在 w=0 处为 0，仿真不重现真实静摩擦的停滞死区；\n' ...
           '       上表静差是按 ±tau_c/K1 的保守估计，须实机实测确认。\n']);
  fprintf('  [提示] eso_comp_gain / eso_comp_limit_nm 需实机按抖振与噪声复核；\n');
  fprintf('         本脚本不仿真 ESO 补偿通道。\n');
end

function printEnvelope(ax, CFG)
  % 单音正弦参考 theta = A*sin(2*pi*f*t) 下，前馈力矩
  %   tau_ff = J*alpha + B*omega + tau_c*tanh(...)
  % 的峰值约为 sqrt((J*A*wf^2)^2 + (B*A*wf)^2) + |tau_c|，wf = 2*pi*f。
  % 令其等于生效限幅，即得该频率下可跟踪的最大幅值。
  % 这是纯前馈口径（不计反馈贡献），因此是保守界，但足以说明力矩预算在哪一档频率饱和。
  refLimit = min(ax.torque_soft_limit_nm, ax.torque_limit_nm);
  fprintf('\n--- 自瞄跟踪包线（纯前馈口径，可用力矩 %.3f N*m）---\n', refLimit - abs(ax.tau_c));
  fprintf('  频率[Hz]   最大幅值[deg]   1 度所需力矩[N*m]\n');
  for f = CFG.envelope_freq_hz
    wf  = 2*pi*f;
    den = sqrt((ax.J*wf^2)^2 + (ax.B*wf)^2);
    if den <= 0
      amax = Inf;
    else
      amax = max(refLimit - abs(ax.tau_c), 0) / den;
    end
    if isfinite(amax)
      fprintf('  %7.2f   %11.2f   %13.6f\n', f, 180/pi*amax, den*pi/180);
    else
      fprintf('  %7.2f          Inf           0\n', f);
    end
  end
  fprintf('  [读数] 1 度所需力矩 = sqrt((J*wf^2)^2+(B*wf)^2)*pi/180；\n');
  fprintf('         超过 %.3f N*m 的频率档位就无法靠前馈跟踪，需提高限幅。\n', refLimit);
end

function printYamlBlock(best, smc, eso, ax, CFG)
  fprintf('\n--- 粘贴到 User/RobotConfig/sentry_gimbal.yaml ---\n');
  if strcmp(ax.name, 'yaw')
    fprintf('# Gimbal -> constructor_args -> GimbalParam:\n');
    fprintf('      j_yaw: %.10g\n', ax.J);
    fprintf('      yaw_k: %.10g   # <- 辨识出的 B（粘性阻尼）；原 yaml 为 0.0 即未接通\n', ax.B);
    fprintf('\n');
  else
    fprintf('# Gimbal -> constructor_args -> GimbalParam:\n');
    fprintf('      j_pit: %.10g\n', ax.J);
    fprintf('      # 注意: pitch 侧目前没有阻尼系数键位，B 无处安放；\n');
    fprintf('      #       pit_lc 是重力力臂系数(=mgl/g)，不是粘性阻尼。\n');
    fprintf('\n');
  end

  fprintf('    %s_lqr_eso:\n', ax.name);
  fprintf('      k_theta: %.6f\n', best.K(1));
  fprintf('      k_omega: %.6f\n', best.K(2));
  fprintf('      k_i: %.6f\n', eso.k_i);
  fprintf('      theta_integral_limit_rad_s: %.6f\n', eso.theta_integral_limit_rad_s);
  fprintf('      tau_coulomb_nm: %.6f\n', eso.tau_coulomb_nm);
  fprintf('      coulomb_smooth_rad_s: %.6f\n', eso.coulomb_smooth_rad_s);
  fprintf('      eso_bandwidth_rad_s: %.2f\n', eso.eso_bandwidth_rad_s);
  fprintf('      eso_comp_gain: %.2f\n', eso.eso_comp_gain);
  fprintf('      eso_comp_limit_nm: %.4f\n', eso.eso_comp_limit_nm);
  fprintf('      eso_omega_gate_rad_s: %.2f\n', eso.eso_omega_gate_rad_s);
  fprintf('      eso_alpha_gate_rad_s2: %.2f\n', eso.eso_alpha_gate_rad_s2);
  fprintf('      tau_bias_ki: %.2f\n', eso.tau_bias_ki);
  fprintf('      tau_bias_limit_nm: %.4f\n', eso.tau_bias_limit_nm);
  fprintf('      tau_meas_lpf_alpha: %.2f\n', eso.tau_meas_lpf_alpha);
  fprintf('      theta_deadband_rad: %.6f\n', eso.theta_deadband_rad);
  fprintf('      torque_soft_limit_nm: %.2f\n', ax.torque_soft_limit_nm);
  fprintf('      torque_slew_rate_nm_s: %.1f\n', ax.torque_slew_nm_s);
  fprintf('      eso_enable: %s\n', boolStr(eso.eso_enable));
  fprintf('      eso_comp_enable: %s\n', boolStr(eso.eso_comp_enable));
  fprintf('      coulomb_enable: %s\n', boolStr(eso.coulomb_enable));
  fprintf('      lqi_enable: %s\n', boolStr(eso.lqi_enable));
  fprintf('      torque_bias_enable: %s\n', boolStr(eso.torque_bias_enable));
  fprintf('      torque_slew_enable: %s\n', boolStr(eso.torque_slew_enable));

  fprintf('\n    %s_smc:\n', ax.name);
  fprintf('      c: %.6f\n', smc.c);
  fprintf('      k: %.6f\n', smc.k);
  fprintf('      epsilon: %.6f\n', smc.epsilon);
  fprintf('      q: %.1f\n', smc.q);
  fprintf('      p: %.1f\n', smc.p);
  fprintf('      error_deadband_rad: %.6f\n', smc.error_deadband_rad);
  fprintf('      ftsmc_switch_rad: %.6f\n', smc.ftsmc_switch_rad);
  fprintf('      sat_boundary: %.6f\n', smc.sat_boundary);
  fprintf('      torque_soft_limit_nm: %.2f\n', ax.torque_soft_limit_nm);
  fprintf('      # 下面两条与 %s_lqr_eso 的生效限幅保持一致；\n', ax.name);
  fprintf('      # yaml 原值若与 LQR 侧不同，两控制器力矩预算就不等，横向对比会被污染。\n');
  fprintf('      torque_min_nm: %.4f\n', -ax.torque_limit_nm);
  fprintf('      torque_max_nm: %.4f\n',  ax.torque_limit_nm);
  fprintf('      torque_slew_rate_nm_s: %.1f\n', ax.torque_slew_nm_s);
  fprintf('      ftsmc_enable: %s\n', boolStr(smc.ftsmc_enable));
  fprintf('      torque_slew_enable: %s\n', boolStr(eso.torque_slew_enable));
end

function plotAll(REPORT, CFG)
  names = fieldnames(REPORT);
  for i = 1:numel(names)
    R = REPORT.(names{i});
    figure('Name', ['Gimbal ' upper(names{i}) ' tune'], 'Color', 'w');
    t = R.lqr.resp.t;
    plot(t, R.lqr.resp.theta*180/pi, 'LineWidth', 1.4); hold on;
    plot(R.smc.resp.t, R.smc.resp.theta*180/pi, 'LineWidth', 1.4);
    plot([t(1) t(end)], [CFG.step_ref_rad CFG.step_ref_rad]*180/pi, '--', 'LineWidth', 1.0);
    grid on; xlabel('t [s]'); ylabel('\theta [deg]');
    legend('LQR-ESO (纯反馈)', 'SMC', '目标', 'Location', 'southeast');
    title(sprintf('Gimbal %s : 10 deg 阶跃（含库仑摩擦扰动）', upper(names{i})));

    figure('Name', ['Gimbal ' upper(names{i}) ' torque'], 'Color', 'w');
    plot(R.lqr.resp.t, R.lqr.resp.tau, 'LineWidth', 1.2); hold on;
    plot(R.smc.resp.t, R.smc.resp.tau, 'LineWidth', 1.2);
    grid on; xlabel('t [s]'); ylabel('\tau [N\cdotm]');
    legend('LQR-ESO', 'SMC', 'Location', 'best');
    title(sprintf('Gimbal %s : 力矩指令', upper(names{i})));

    if isfield(R, 'cmp')
      figure('Name', ['Gimbal ' upper(names{i}) ' ESO compare'], 'Color', 'w');
      subplot(3,1,1);
      plot(R.cmp.noEso.t, R.cmp.noEso.theta*180/pi, 'LineWidth', 1.4); hold on;
      plot(R.cmp.eso.t,   R.cmp.eso.theta*180/pi,   'LineWidth', 1.4);
      plot(R.cmp.smc.t,   R.cmp.smc.theta*180/pi,   'LineWidth', 1.4);
      plot([R.cmp.noEso.t(1) R.cmp.noEso.t(end)], [1 1]*CFG.step_ref_rad*180/pi, '--');
      grid on; ylabel('\theta [deg]');
      legend('LQR (ESO 关)', 'LQR + ESO 补偿', 'SMC', '目标', 'Location', 'southeast');
      title(sprintf('Gimbal %s : 静摩擦粘滞下 10 deg 阶跃', upper(names{i})));

      subplot(3,1,2);
      plot(R.cmp.noEso.t, R.cmp.noEso.tau, 'LineWidth', 1.1); hold on;
      plot(R.cmp.eso.t,   R.cmp.eso.tau,   'LineWidth', 1.1);
      grid on; ylabel('\tau [N\cdotm]');
      legend('ESO 补偿关', 'ESO 补偿开', 'Location', 'best');

      subplot(3,1,3);
      plot(R.cmp.eso.t, R.cmp.eso.tau_eso, 'LineWidth', 1.2); hold on;
      plot(R.cmp.eso.t, R.cmp.eso.dist_estimate_nm*ones(size(R.cmp.eso.t)), '--', 'LineWidth', 1.0);
      grid on; xlabel('t [s]'); ylabel('\tau_{eso} [N\cdotm]');
      legend('ESO 补偿力矩', 'z3*J（扰动估计）', 'Location', 'best');
    end
  end
end

function y = sigpow(x, r)
  y = sign(x) * abs(x)^r;
end

function y = satFun(x)
  y = min(max(x, -1), 1);
end

function y = realpow_local(base, exponent)
  if base <= 0
    y = 1;
  else
    y = base^exponent;
  end
end

function s = boolStr(v)
  if v, s = 'true'; else, s = 'false'; end
end

function s = ternaryStr(cond, a, b)
  if cond, s = a; else, s = b; end
end

function out = mergeStruct(base, override)
  out = base;
  if ~isstruct(override), return; end
  names = fieldnames(override);
  for i = 1:numel(names)
    out.(names{i}) = override.(names{i});
  end
end
