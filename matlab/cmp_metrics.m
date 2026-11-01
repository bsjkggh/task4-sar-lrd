%% cmp_metrics.m -- 同指标对比 MATLAB 浮点参考图 与 FPGA 实测输出图
% 指标定义与 selectAndPlotSarPointTargets.m 完全一致:
%   IRW  = 峰值 -3dB 宽度 (16 倍 interpft 升采样后线性插值)
%   PSLR = 第一零点外最强旁瓣 / 主峰 (功率)
%   ISLR = 零点外旁瓣能量 / 主瓣能量 (功率积分)
% 用法:
%   cmp_metrics                      % 只算 MATLAB 参考
%   cmp_metrics('mag4m.bin')         % 追加 FPGA 输出对比
function cmp_metrics(fpga_bin)

cd(fileparts(mfilename('fullpath')));
if nargin < 1, fpga_bin = ''; end

S = load('img_ref.mat');
ref = abs(S.img_ref);
S.dr_m = 0.25;    % 距离向: fr 轴 2048 bin 跨 600MHz -> c/(2*600MHz)
S.da_m = 0.0128;  % 方位向: va*(4/PRF) = 4.8*4/1500
% 理论分辨率 (按 LRD_SAR.m 参数)
S.rho_r = 3e8/(2*800e6);
S.rho_a = 0.012*800.6/(2*(4.8*(2048/(1500/4))));

osf = 16;
roiHR = 10;      % 距离向 ROI 半宽
roiHA = 40;      % 方位向 ROI 半宽

%% ---------- 参考图: 全部强目标 ----------
[rp, ap] = findStrongPeaks(ref, 5, 60);
fprintf('\n===== MATLAB 浮点参考 =====\n');
printTable(ref, rp, ap, roiHR, roiHA, osf, S.dr_m, S.da_m);

%% ---------- 文档里已分析的那个点 (r≈1321, a≈950) ----------
if ~isempty(rp)
    fprintf('\n----- 文档点目标位置 (1321,950) 复核 -----\n');
    printTable(ref, 1321, 950, roiHR, roiHA, osf, S.dr_m, S.da_m);
end

%% ---------- FPGA 输出 ----------
if isempty(fpga_bin)
    fprintf('\n(未提供 FPGA 数据文件)\n');
    return;
end

if ~exist(fpga_bin,'file')
    error('找不到 FPGA 数据文件: %s', fpga_bin);
end

raw = readMagBin(fpga_bin);
fprintf('\nFPGA 数据: %s, %d 个数\n', fpga_bin, numel(raw));

%% 方向自动判别: 尝试 8 种翻转/转置, 取与参考相关最高者
cand = {raw.', flipud(raw).', fliplr(raw).', rot90(raw,2).', raw, flipud(raw), fliplr(raw), rot90(raw,2)};
names = {'转置','上下+转置','左右+转置','旋转180+转置','原序','上下','左右','旋转180'};
best = -inf; bi = 0; bestImg = [];
for k = 1:numel(cand)
    c = corr(double(cand{k}(:)), ref(:));
    fprintf('  orient %-14s corr=%.6f\n', names{k}, c);
    if c > best, best = c; bi = k; bestImg = cand{k}; end
end
fpga = double(bestImg);
fprintf('采用方向: %s (corr=%.6f)\n', names{bi}, best);

%% 幅度归一化到参考峰值, 计算整体误差 (只在 >-40dB 有效像素上统计)
scale = max(ref(:))/max(fpga(:));
fprintf('幅度归一化系数 = %.4f\n', scale);
fpga = fpga*scale;

dif = 20*log10(fpga+eps) - 20*log10(ref+eps);
mask = ref > max(ref(:))*1e-2;          % -40 dB 以上
d = dif(mask);
fprintf('整体一致性: corr=%.6f, dB 差 RMS=%.3f dB, 95%%分位=%.3f dB, 最大=%.3f dB (有效像素 %d)\n', ...
    best, sqrt(mean(d.^2)), prctile(abs(d),95), max(abs(d)), nnz(mask));

% 峰值位置几何一致性
[~, i1] = max(ref(:)); [r1, a1] = ind2sub(size(ref), i1);
[~, i2] = max(fpga(:)); [r2, a2] = ind2sub(size(fpga), i2);
fprintf('峰值位置: MATLAB (r=%d, a=%d), FPGA (r=%d, a=%d), 偏移 (%.0f, %.0f) 样点\n', ...
    r1, a1, r2, a2, r2-r1, a2-a1);

%% ---------- FPGA 图: 同一批目标 ----------
fprintf('\n===== FPGA 实测输出 =====\n');
[rp2, ap2] = findStrongPeaks(fpga, 5, 60);
printTable(fpga, rp2, ap2, roiHR, roiHA, osf, S.dr_m, S.da_m);

%% ---------- 逐目标差值 (同一 ROI 位置) ----------
m1 = struct([]); m2 = struct([]);
for k = 1:numel(rp)
    m1 = [m1, metricAt(ref,  rp(k), ap(k), roiHR, roiHA, osf, S.dr_m, S.da_m)]; %#ok<AGROW>
    m2 = [m2, metricAt(fpga, rp(k), ap(k), roiHR, roiHA, osf, S.dr_m, S.da_m)]; %#ok<AGROW>
end
fprintf('\n===== 逐目标差值 (FPGA - MATLAB, 同一 ROI) =====\n');
fprintf('%3s %6s %6s | %7s %7s | %7s %7s | %7s %7s\n', ...
    '#','r','a','dIRWr','dIRWa','dPSLRr','dPSLRa','dISLRr','dISLRa');
for k = 1:numel(rp)
    fprintf('%3d %6d %6d | %7.2f %7.2f | %7.2f %7.2f | %7.2f %7.2f\n', k, rp(k), ap(k), ...
        m2(k).irwR-m1(k).irwR, m2(k).irwA-m1(k).irwA, ...
        m2(k).pslrR-m1(k).pslrR, m2(k).pslrA-m1(k).pslrA, ...
        m2(k).islrR-m1(k).islrR, m2(k).islrA-m1(k).islrA);
end
irwR1 = [m1.irwR]; irwA1 = [m1.irwA]; pR1 = [m1.pslrR]; pA1 = [m1.pslrA];
irwR2 = [m2.irwR]; irwA2 = [m2.irwA]; pR2 = [m2.pslrR]; pA2 = [m2.pslrA];
fprintf('平均偏差: IRWr %.3f 样点, IRWa %.3f 样点, PSLRr %.2f dB, PSLRa %.2f dB\n', ...
    mean(abs(irwR2-irwR1)), mean(abs(irwA2-irwA1)), ...
    mean(abs(pR2-pR1)), mean(abs(pA2-pA1)));
fprintf('MATLAB 均值: IRWr %.3f 样点(%.3f m), IRWa %.3f 样点(%.3f m)\n', ...
    mean(irwR1), mean(irwR1)*S.dr_m, mean(irwA1), mean(irwA1)*S.da_m);
fprintf('FPGA   均值: IRWr %.3f 样点(%.3f m), IRWa %.3f 样点(%.3f m)\n', ...
    mean(irwR2), mean(irwR2)*S.dr_m, mean(irwA2), mean(irwA2)*S.da_m);
end

%% ======================== 峰值检测 ========================
function [rp, ap] = findStrongPeaks(img, nMax, minSep)
a = abs(img);
a = a/max(a(:));
mask = a >= 0.02;             % 只保留 -34 dB 以上的点
cand = a.*mask;
rp = []; ap = [];
for k = 1:nMax
    [v, idx] = max(cand(:));
    if v <= 0, break; end
    [r, c] = ind2sub(size(cand), idx);
    if ~isempty(rp) && min(hypot(r-rp, c-ap)) < minSep
        cand(r,c) = 0; continue;
    end
    cand(r,c) = 0;
    rp(end+1) = r; ap(end+1) = c;
    % 抑制邻域
    r0 = max(1,r-minSep); r1 = min(size(a,1),r+minSep);
    c0 = max(1,c-minSep); c1 = min(size(a,2),c+minSep);
    rr = r0:r1; cc = c0:c1;
    [RR, CC] = meshgrid(rr, cc);
    near = hypot(RR-r, CC-c) < minSep;
    sub = cand(rr,cc);
    sub(near) = 0;
    cand(rr,cc) = sub;
end
end

%% ======================== 输出表 ========================
function printTable(img, rp, ap, roiHR, roiHA, osf, dr, da)
fprintf('%3s %6s %6s | %10s %10s | %8s %8s | %8s %8s\n', ...
    '#','r','a','IRWr[smpl]','IRWa[smpl]','PSLRr','PSLRa','ISLRr','ISLRa');
for k = 1:numel(rp)
    m = metricAt(img, rp(k), ap(k), roiHR, roiHA, osf, dr, da);
    fprintf('%3d %6d %6d | %10.3f %10.3f | %8.2f %8.2f | %8.2f %8.2f\n', ...
        k, rp(k), ap(k), m.irwR, m.irwA, m.pslrR, m.pslrA, m.islrR, m.islrA);
end
fprintf('  采样间隔: 距离 %.4f m/样点, 方位 %.4f m/样点\n', dr, da);
end

%% ======================== 单目标指标 ========================
function m = metricAt(img, r0, a0, roiHR, roiHA, osf, dr, da)
[Nr, Na] = size(img);
r1 = max(1, r0-roiHR);  r2 = min(Nr, r0+roiHR);
c1 = max(1, a0-roiHA);  c2 = min(Na, a0+roiHA);
roi = img(r1:r2, c1:c2);

[nr, nc] = size(roi);
up = interpft(roi, nr*osf, 1);
up = interpft(up, nc*osf, 2);
upa = abs(up);

[p, idx] = max(upa(:));
[pr, pc] = ind2sub(size(upa), idx);
dbUp = 20*log10(upa/p + eps);

rUp = (0:size(up,1)-1).' * (dr/osf);
aUp = (0:size(up,2)-1)  * (da/osf);

[~, ~, wR] = irwOf(dbUp(:,pc), pr);   % 升采样索引宽度
[~, ~, wA] = irwOf(dbUp(pr,:), pc);
m.irwR = wR/osf;                       % 换算回原样点
m.irwA = wA/osf;
m.irwR_m = m.irwR*dr;
m.irwA_m = m.irwA*da;

pwR = abs(up(:,pc)).^2; pwR = pwR/max(pwR);
pwA = abs(up(pr,:)).^2; pwA = pwA/max(pwA);
[m.pslrR, m.islrR] = pslrIslrOf(rUp, pwR, pr);
[m.pslrA, m.islrA] = pslrIslrOf(aUp, pwA, pc);
m.peakR = r0; m.peakA = a0;
end

%% ---- 以下两个函数与 selectAndPlotSarPointTargets.m 内部实现一致 ----
function [xL, xR, w] = irwOf(yDB, pk)
yDB = yDB(:); x = (1:numel(yDB)).';
xL = NaN; xR = NaN; w = NaN;
if pk <= 1 || pk >= numel(yDB), return; end
li = find(yDB(1:pk-1) <= -3, 1, 'last');
if ~isempty(li)
    x1 = x(li); x2 = x(li+1); y1 = yDB(li); y2 = yDB(li+1);
    if abs(y2-y1) > eps, xL = x1 + (-3-y1)*(x2-x1)/(y2-y1); else, xL = x1; end
end
ri = find(yDB(pk+1:end) <= -3, 1, 'first');
if ~isempty(ri)
    k2 = pk + ri;
    x1 = x(k2-1); x2 = x(k2); y1 = yDB(k2-1); y2 = yDB(k2);
    if abs(y2-y1) > eps, xR = x1 + (-3-y1)*(x2-x1)/(y2-y1); else, xR = x2; end
end
if isfinite(xL) && isfinite(xR), w = xR - xL; end
end

function [pslr, islr] = pslrIslrOf(x, pw, pk)
x = x(:); pw = pw(:); N = numel(pw);
pslr = NaN; islr = NaN;
if pk <= 1 || pk >= N, return; end
pw(~isfinite(pw)) = 0; pw(pw < 0) = 0;
ln = NaN; rn = NaN;
for k = pk-1:-1:2
    if pw(k) <= pw(k-1) && pw(k) < pw(k+1), ln = k; break; end
end
for k = pk+1:N-1
    if pw(k) <= pw(k-1) && pw(k) < pw(k+1), rn = k; break; end
end
if isnan(ln) || isnan(rn), return; end
mainE = trapz(x(ln:rn), pw(ln:rn));
sE = 0;
if ln > 1, sE = sE + trapz(x(1:ln-1), pw(1:ln-1)); end
if rn < N, sE = sE + trapz(x(rn+1:N), pw(rn+1:N)); end
side = [pw(1:ln-1); pw(rn+1:N)];
if isempty(side), return; end
mp = pw(pk); sp = max(side);
if mp > 0 && sp > 0, pslr = 10*log10(sp/mp); end
if mainE > 0
    if sE == 0, islr = -Inf; else, islr = 10*log10(sE/mainE); end
end
end

%% ======================== 读 FPGA bin ========================
function v = readMagBin(f)
% u32 小端, 元素顺序 mag[a*N+r], 返回 [N,N] 且 (a,r)
fid = fopen(f,'r');
if fid < 0, error('打不开 %s', f); end
v = fread(fid, inf, 'uint32=>double');
fclose(fid);
n = round(sqrt(numel(v)));
if n*n ~= numel(v), error('元素数 %d 不是完全平方', numel(v)); end
v = reshape(v, n, n);
end
