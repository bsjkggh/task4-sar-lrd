%% gen_task4_data.m
%  任务4 线性RD成像 —— 生成 FPGA/SD 卡数据与参考结果
%  ------------------------------------------------------------------
%  输入 : raw_data_dsx.mat  (2048x2048 complex double, 距离 x 方位)
%  输出 :
%    data/RDRAW.BIN        原始回波 int16(I/Q 交替)，列优先：
%                          第 ii 段 = raw_data_dsx(:,ii)，即一条距离线
%    data/COEF16.BIN       匹配滤波+运动补偿系数 H(fr,ii) 的 Q15 int16，
%                          列优先，与 RDRAW.BIN 一一对应
%    data/ref_task4_*.png  浮点参考（等价 LRD_SAR.m）
%    data/ref_fixed_*.png  定点链路参考（与板上 C 代码 + PL 复数乘一致）
%    data/sim_in.hex       复数乘法 IP 仿真输入  (2048 行, {im,re} 32bit)
%    data/sim_coef.hex     复数乘法 IP 仿真系数  (2048 行)
%    data/sim_out.hex      复数乘法 IP 仿真期望输出(2048 行)
%  ------------------------------------------------------------------
clc; clear; close all;

here    = fileparts(mfilename('fullpath'));
root    = fileparts(here);
datadir = fullfile(root, 'data');
if ~exist(datadir, 'dir'), mkdir(datadir); end

load(fullfile(here, 'raw_data_dsx.mat'));
[Nr, Na] = size(raw_data_dsx);
fprintf('raw_data_dsx: %d x %d,  max|.|=%g\n', Nr, Na, max(abs(raw_data_dsx(:))));

%% ---------------- 雷达参数（与 LRD_SAR.m 完全一致） ----------------
c        = 3e8;
fc       = 25e9;
lambda   = c/fc;
Tp       = 3e-6;
B        = 800e6;
gamma    = B/Tp;
Fs       = 2.4e9;
PRF      = 1500;
Z0       = 300;
cita_pitch  = 68/180*pi;
R0       = Z0/cos(cita_pitch);
Rg       = sqrt(R0^2 - Z0^2);
cita_squint = 0.0283;
xc       = -1*Rg*sin(cita_squint);
ta       = (-Na/2:Na/2-1)/(PRF/4);
va       = 4.8;
x_radar  = xc + va*ta;
y_radar  = sqrt((R0*cos(cita_squint))^2 - Z0^2) + 0*ta;
z_radar  = Z0 + 0*ta;
fr       = ((-Nr/2+1:Nr/2)/8192*Fs)';
Ra       = sqrt(x_radar.^2 + y_radar.^2 + z_radar.^2);

%% ---------------- 系数 H(fr,ii) ----------------
Hr = exp(1j*pi/gamma*fr.^2) .* exp(-1j*4*pi/c*R0*fr);   % 与方位无关部分
H  = zeros(Nr, Na);
for ii = 1:Na
    H(:,ii) = Hr .* exp(1j*4*pi/c*(fc+fr)*Ra(ii));
end
fprintf('H: max|H|=%.6f (理论上为 1)\n', max(abs(H(:))));

%% ---------------- 1. 原始回波 -> int16 (列优先 I/Q 交替) ----------------
S_RAW = 32767 / max(abs(raw_data_dsx(:)));
qr = round(real(raw_data_dsx) * S_RAW);
qi_ = round(imag(raw_data_dsx) * S_RAW);
qr = max(min(qr, 32767), -32768);
qi_ = max(min(qi_, 32767), -32768);
qr = int16(qr); qi_ = int16(qi_);
out = zeros(2*Nr, Na, 'int16');
out(1:2:end, :) = qr;
out(2:2:end, :) = qi_;
fid = fopen(fullfile(datadir, 'RDRAW.BIN'), 'wb');
fwrite(fid, out, 'int16');          % 列优先：先第 1 列全部点，再第 2 列…
fclose(fid);
fprintf('RDRAW.BIN : %.2f MB, scale S_RAW=%.6f\n', 2*numel(out)*2/1024/1024, S_RAW);

%% ---------------- 2. 系数 -> Q15 int16 (列优先) ----------------
cr = round(real(H) * 32767);
ci = round(imag(H) * 32767);
cr = max(min(cr, 32767), -32768);
ci = max(min(ci, 32767), -32768);
cr = int16(cr); ci = int16(ci);
cout = zeros(2*Nr, Na, 'int16');
cout(1:2:end, :) = cr;
cout(2:2:end, :) = ci;
fid = fopen(fullfile(datadir, 'COEF16.BIN'), 'wb');
fwrite(fid, cout, 'int16');
fclose(fid);
fprintf('COEF16.BIN: %.2f MB\n', 2*numel(cout)*2/1024/1024);

%% ---------------- 3. 浮点参考（等价 LRD_SAR.m） ----------------
data = double(raw_data_dsx);
for ii = 1:Na
    data(:,ii) = fftshift(fft(fftshift(data(:,ii)))) .* H(:,ii);
end
datamf = data;                                  % 距离匹配滤波后
windowsr = hamming(Nr);
windowsa = hamming(Na);
for ii = 1:Nr
    data(ii,:) = fftshift(fft(fftshift(data(ii,:) .* windowsa.')));
end
for ii = 1:Na
    data(:,ii) = ifftshift(ifft(ifftshift(data(:,ii) .* windowsr)));
end
img_ref = abs(data);
fprintf('浮点参考 : max=%.4g  mean=%.4g\n', max(img_ref(:)), mean(img_ref(:)));
save_ref_png(img_ref, 1000, fullfile(datadir, 'ref_task4_800x480.png'));

%% ---------------- 4. 定点链路（PS float FFT + PL Q15 复数乘） ----------------
% 数据读入后的浮点值 : q / S_RAW
fx = (double(qr) + 1j*double(qi_)) / S_RAW;     % 与板上 C 一致：先 /S_RAW 再 FFT
ROUND_SHIFT = 16384;                            % (prod + 2^14) >> 15
fixout = zeros(Nr, Na);
for ii = 1:Na
    x  = fftshift(fft(fftshift(fx(:,ii))));     % 距离向 FFT
    mx = max(abs(x));  if mx == 0, mx = 1; end
    s  = 32767/mx;                              % 每列缩放到 int16
    xr = round(real(x)*s); xi2 = round(imag(x)*s);
    xr = max(min(xr, 32767), -32768);
    xi2 = max(min(xi2, 32767), -32768);
    ar = double(xr); ai = double(xi2);
    br = double(cr(:,ii)); bi = double(ci(:,ii));
    % ---- 4 乘法复数乘 + 舍入 + 饱和 ----
    pr = ar.*br - ai.*bi;
    pi = ar.*bi + ai.*br;
    pr = floor((pr + ROUND_SHIFT) / 32768);
    pi = floor((pi + ROUND_SHIFT) / 32768);
    pr = max(min(pr, 32767), -32768);
    pi = max(min(pi, 32767), -32768);
    % ---- 恢复浮点（PS 端用 mx/32767 还原） ----
    fixout(:,ii) = (pr + 1j*pi) * (mx/32767);
end

for ii = 1:Nr
    fixout(ii,:) = fftshift(fft(fftshift(fixout(ii,:) .* windowsa.')));
end
for ii = 1:Na
    fixout(:,ii) = ifftshift(ifft(ifftshift(fixout(:,ii) .* windowsr)));
end
img_fix = abs(fixout);
save_ref_png(img_fix, 1000, fullfile(datadir, 'ref_fixed_800x480.png'));

% 与浮点参考比较（降采样后的 800x480）
rp = 480; cp = 800;
r_idx = round((0:rp-1)*(Nr-1)/(rp-1)) + 1;
c_idx = round((0:cp-1)*(Na-1)/(cp-1)) + 1;
a = img_ref(r_idx, c_idx);  b = img_fix(r_idx, c_idx);
cc = corrcoef(a(:), b(:));
fprintf('定点 vs 浮点 : corr=%.6f  maxdiff=%.3g  rmsdiff=%.3g (clip=1000)\n', ...
        cc(1,2), max(abs(a(:)-b(:))), sqrt(mean((a(:)-b(:)).^2)));

%% ---------------- 5. 复数乘法 IP 仿真向量（第 1 列） ----------------
ii = 1;
x  = fftshift(fft(fftshift(fx(:,ii))));
mx = max(abs(x)); s = 32767/mx;
xr = round(real(x)*s); xi2 = round(imag(x)*s);
xr = max(min(xr, 32767), -32768);
xi2 = max(min(xi2, 32767), -32768);
ar = double(xr); ai = double(xi2);
br = double(cr(:,ii)); bi = double(ci(:,ii));
pr = ar.*br - ai.*bi;  pi_ = ar.*bi + ai.*br;
pr = floor((pr + ROUND_SHIFT)/32768); pi_ = floor((pi_ + ROUND_SHIFT)/32768);
pr = max(min(pr, 32767), -32768);    pi_ = max(min(pi_, 32767), -32768);

% 打包 {im[31:16], re[15:0]}
fid = fopen(fullfile(datadir, 'sim_in.hex'), 'w');
for k = 1:Nr
    w = bitor(bitshift(uint32(typecast(int16(xi2(k)),'uint16')),16), ...
              uint32(typecast(int16(xr(k)),'uint16')));
    fprintf(fid, '%08x\n', w);
end
fclose(fid);
fid = fopen(fullfile(datadir, 'sim_coef.hex'), 'w');
for k = 1:Nr
    w = bitor(bitshift(uint32(typecast(int16(bi(k)),'uint16')),16), ...
              uint32(typecast(int16(br(k)),'uint16')));
    fprintf(fid, '%08x\n', w);
end
fclose(fid);
fid = fopen(fullfile(datadir, 'sim_out.hex'), 'w');
for k = 1:Nr
    w = bitor(bitshift(uint32(typecast(int16(pi_(k)),'uint16')),16), ...
              uint32(typecast(int16(pr(k)),'uint16')));
    fprintf(fid, '%08x\n', w);
end
fclose(fid);
fprintf('仿真向量已写入 sim_in.hex / sim_coef.hex / sim_out.hex\n');
fprintf('全部完成。\n');

%% ================= 局部函数 =================
function save_ref_png(img, clip, outfile)
    [nr, nc] = size(img);
    rp = 480; cp = 800;
    r_idx = round((0:rp-1)*(nr-1)/(rp-1)) + 1;
    c_idx = round((0:cp-1)*(nc-1)/(cp-1)) + 1;
    ds = img(r_idx, c_idx);
    ds = min(ds/clip, 1);
    ds = flipud(ds);                    % YDir normal => 屏幕 y=0 对应最后一行
    rgb = uint8(ds*255);
    imwrite(repmat(rgb, [1 1 3]), outfile);
    fprintf('  已写 %s\n', outfile);
end
