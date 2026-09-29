function gimbal_smc_lqreso_ui()
% GIMBAL_SMC_LQRESO_UI 云台控制器整定交互界面。
% 通过参数表收集辨识结果，调用 gimbal_smc_lqreso_tune 统一计算。

  scriptDir = fileparts(mfilename('fullpath'));
  addpath(scriptDir);
  [axesData, cfgData] = loadDefaults();

  fig = uifigure('Name', 'Gimbal SMC / LQR-ESO Tuner', ...
      'Position', [50 50 1500 900]);
  root = uigridlayout(fig, [1 2]);
  root.ColumnWidth = {470, '1x'};
  root.Padding = [12 12 12 12];
  root.ColumnSpacing = 12;

  left = uigridlayout(root, [3 1]);
  left.RowHeight = {42, '1x', 230};
  left.RowSpacing = 10;
  left.Padding = [0 0 0 0];

  top = uigridlayout(left, [1 3]);
  top.ColumnWidth = {'1x', '1x', '1x'};
  yawButton = uibutton(top, 'Text', 'Yaw', 'ButtonPushedFcn', @(~,~) selectAxis('yaw'));
  pitButton = uibutton(top, 'Text', 'Pitch', 'ButtonPushedFcn', @(~,~) selectAxis('pitch'));
  uibutton(top, 'Text', '运行整定', 'ButtonPushedFcn', @(~,~) runTune());

  inputPanel = uipanel(left, 'Title', '辨识参数与工程约束');
  inputGrid = uigridlayout(inputPanel, [1 1]);
  inputTable = uitable(inputGrid, 'ColumnName', {'参数', '数值', '单位'}, ...
      'ColumnEditable', [false true false], 'CellEditCallback', @editInput);

  cfgPanel = uipanel(left, 'Title', '设计偏好');
  cfgGrid = uigridlayout(cfgPanel, [1 1]);
  cfgTable = uitable(cfgGrid, 'ColumnName', {'参数', '数值', '单位'}, ...
      'ColumnEditable', [false true false], 'CellEditCallback', @editCfg);

  right = uigridlayout(root, [3 1]);
  right.RowHeight = {160, '1x', 190};
  right.RowSpacing = 10;
  reportPanel = uipanel(right, 'Title', '整定结果');
  reportGrid = uigridlayout(reportPanel, [2 4]);
  reportGrid.RowHeight = {'1x', '1x'};
  cards = gobjects(8,1);
  labels = {'Ktheta','Komega','SMC c / k','ESO 带宽','建立时间','超调','静差','辨识状态'};
  for i=1:8
    cards(i) = uilabel(reportGrid, 'Text', [labels{i} newline '-'], ...
      'FontSize', 13, 'FontWeight', 'bold', 'WordWrap', 'on');
  end

  chartPanel = uipanel(right, 'Title', '响应曲线');
  chartGrid = uigridlayout(chartPanel, [2 1]);
  axTheta = uiaxes(chartGrid); title(axTheta, '角度响应'); grid(axTheta, 'on');
  axTorque = uiaxes(chartGrid); title(axTorque, '力矩指令'); grid(axTorque, 'on');

  outputPanel = uipanel(right, 'Title', 'YAML 输出与诊断');
  outputGrid = uigridlayout(outputPanel, [1 1]);
  outputText = uitextarea(outputGrid, 'Editable', 'off', 'FontName', 'Consolas');

  activeAxis = 'yaw';
  refreshTables();
  selectAxis('yaw');

  function selectAxis(name)
    activeAxis = name;
    yawButton.FontWeight = ternary(strcmp(name,'yaw'), 'bold', 'normal');
    pitButton.FontWeight = ternary(strcmp(name,'pitch'), 'bold', 'normal');
    refreshTables();
  end

  function refreshTables()
    ax = axesData.(activeAxis);
    inputTable.Data = { ...
      'J', ax.J, 'kg*m^2'; 'B', ax.B, 'N*m*s/rad';
      'tau_c', ax.tau_c, 'N*m'; 'mgl', ax.mgl, 'N*m';
      'residual_ratio', ax.residual_ratio, '-';
      'torque_limit_nm', ax.torque_limit_nm, 'N*m';
      'torque_soft_limit_nm', ax.torque_soft_limit_nm, 'N*m';
      'torque_slew_nm_s', ax.torque_slew_nm_s, 'N*m/s';
      'sigma_theta_rad', ax.sigma_theta_rad, 'rad';
      'sigma_omega_rad_s', ax.sigma_omega_rad_s, 'rad/s';
      'omega_max_rad_s', ax.omega_max_rad_s, 'rad/s';
      'alpha_max_rad_s2', ax.alpha_max_rad_s2, 'rad/s^2';
      'dist_torque_nm', ax.dist_torque_nm, 'N*m'};
    inputTable.UserData = {'J','B','tau_c','mgl','residual_ratio', ...
      'torque_limit_nm','torque_soft_limit_nm','torque_slew_nm_s', ...
      'sigma_theta_rad','sigma_omega_rad_s','omega_max_rad_s', ...
      'alpha_max_rad_s2','dist_torque_nm'};
    cfgTable.Data = {'max_overshoot_pct',cfgData.max_overshoot_pct,'%'; ...
      'max_torque_ratio',cfgData.max_torque_ratio,'ratio'; ...
      'step_ref_rad',cfgData.step_ref_rad,'rad'; ...
      'sim_duration_s',cfgData.sim_duration_s,'s'; ...
      'eso_bandwidth_ratio',cfgData.eso_bandwidth_ratio,'ratio'; ...
      'eso_bandwidth_min',cfgData.eso_bandwidth_min,'rad/s'; ...
      'eso_bandwidth_max',cfgData.eso_bandwidth_max,'rad/s'; ...
      'stiction_ratio',cfgData.stiction_ratio,'ratio'; ...
      'smc_epsilon_margin',cfgData.smc_epsilon_margin,'ratio'; ...
      'sat_k',cfgData.sat_k,'ratio'};
    cfgTable.UserData = {'max_overshoot_pct','max_torque_ratio','step_ref_rad', ...
      'sim_duration_s','eso_bandwidth_ratio','eso_bandwidth_min', ...
      'eso_bandwidth_max','stiction_ratio','smc_epsilon_margin','sat_k'};
  end

  function editInput(src, event)
    key = src.UserData{event.Indices(1)};
    value = event.NewData;
    if ~isnumeric(value) || ~isscalar(value) || ~isfinite(value)
      src.Data{event.Indices(1),2} = event.PreviousData;
      uialert(fig, '请输入有限数值。', '输入错误'); return;
    end
    axesData.(activeAxis).(key) = value;
  end

  function editCfg(src, event)
    key = src.UserData{event.Indices(1)};
    value = event.NewData;
    if ~isnumeric(value) || ~isscalar(value) || ~isfinite(value)
      src.Data{event.Indices(1),2} = event.PreviousData;
      uialert(fig, '请输入有限数值。', '输入错误'); return;
    end
    cfgData.(key) = value;
  end

  function runTune()
    try
      opts.axes = {axesData.yaw, axesData.pitch};
      opts.enable_plot = false;
      opts.cfg = cfgData;
      report = gimbal_smc_lqreso_tune(opts);
      r = report.(activeAxis);
      updateCards(r);
      plot(axTheta, r.lqr.resp.t, r.lqr.resp.theta*180/pi, ...
        r.smc.resp.t, r.smc.resp.theta*180/pi, '--');
      legend(axTheta, 'LQR', 'SMC', 'Location', 'best');
      plot(axTorque, r.lqr.resp.t, r.lqr.resp.tau, ...
        r.smc.resp.t, r.smc.resp.tau, '--');
      legend(axTorque, 'LQR', 'SMC', 'Location', 'best');
      outputText.Value = makeYamlText(r);
    catch err
      uialert(fig, err.message, '整定失败', 'Icon', 'error');
    end
  end

  function updateCards(r)
    vals = {sprintf('%.5g',r.lqr.K(1)), sprintf('%.5g',r.lqr.K(2)), ...
      sprintf('%.4g / %.4g',r.smc.c,r.smc.k), sprintf('%.3g rad/s',r.eso.eso_bandwidth_rad_s), ...
      sprintf('%.4g s',r.lqr.resp.settle_s), sprintf('%.3g %%',r.lqr.resp.overshoot_pct), ...
      sprintf('%.4g rad',r.eso.ss_err_no_lqi_rad), boolText(r.ax.identification_usable)};
    for i=1:numel(cards), cards(i).Text = [labels{i} newline vals{i}]; end
  end

  function text = makeYamlText(r)
    text = sprintf(['%s_lqr_eso:\n' ...
      '  k_theta: %.6f\n  k_omega: %.6f\n  k_i: %.6f\n' ...
      '  eso_bandwidth_rad_s: %.3f\n  eso_comp_limit_nm: %.4f\n' ...
      '  torque_soft_limit_nm: %.4f\n  torque_slew_rate_nm_s: %.3f\n\n' ...
      '%s_smc:\n  c: %.6f\n  k: %.6f\n  epsilon: %.6f\n' ...
      '  sat_boundary: %.6f\n  torque_soft_limit_nm: %.4f\n' ...
      '  torque_min_nm: %.4f\n  torque_max_nm: %.4f\n'], ...
      r.ax.name, r.lqr.K(1), r.lqr.K(2), r.eso.k_i, ...
      r.eso.eso_bandwidth_rad_s, r.eso.eso_comp_limit_nm, ...
      r.ax.torque_soft_limit_nm, r.ax.torque_slew_nm_s, ...
      r.ax.name, r.smc.c, r.smc.k, r.smc.epsilon, r.smc.sat_boundary, ...
      r.ax.torque_soft_limit_nm, -r.ax.torque_limit_nm, r.ax.torque_limit_nm);
  end

  function [a,c] = loadDefaults()
    capture = struct('enable_plot', false);
    % 通过脚本默认基线获取输入结构，避免 UI 复制一份数值。
    % 脚本会打印报告，但 UI 初始化阶段不运行整定，因此使用固定工程基线。
    a.yaw = struct('name','yaw','enabled',true,'J',0.0395300984,'B',0.199095935, ...
      'tau_c',0.129962802,'mgl',0,'residual_ratio',0.0642537549, ...
      'torque_limit_nm',2.223,'torque_soft_limit_nm',2,'torque_slew_nm_s',1000, ...
      'sigma_theta_rad',0.001,'sigma_omega_rad_s',0.01,'omega_max_rad_s',8, ...
      'alpha_max_rad_s2',40,'dist_torque_nm',0,'coulomb_tanh_scale',0.1, ...
      'friction_stick_rad_s',0.02);
    a.pitch = a.yaw; a.pitch.name='pitch'; a.pitch.enabled=false; a.pitch.J=0.014;
    a.pitch.B=0; a.pitch.tau_c=0; a.pitch.mgl=0; a.pitch.residual_ratio=NaN;
    c = struct('max_overshoot_pct',8,'max_torque_ratio',0.9,'step_ref_rad',10*pi/180, ...
      'sim_duration_s',1.2,'eso_bandwidth_ratio',4,'eso_bandwidth_min',20, ...
      'eso_bandwidth_max',120,'stiction_ratio',1.3, ...
      'smc_epsilon_margin',2.0,'sat_k',3.0);
    %#ok<NASGU>
  end

  function out = ternary(condition, yes, no)
    if condition, out=yes; else, out=no; end
  end
  function out = boolText(value)
    if value, out='可用'; else, out='需复核'; end
  end
end
