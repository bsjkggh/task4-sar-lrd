%% verify_c_fft.m
%  验证 main_4.c 中的软件 FFT (float radix-2 DIT) 与 MATLAB fft 的一致性
%  - 完全复刻 C 代码的旋转因子递推、bit-reverse、蝶形运算 (single 精度)
%  - 统计相对误差, 并检查 fftshift(fft(fftshift(x))) 的等价性
%  ------------------------------------------------------------------
clear; clc;

N    = 2048;
LOGN = 11;

%% -------- 1. 复刻 C 的 fft_init (见 main_4.c fft_init) --------
w1_re = single(0.999995293809576);
w1_im = single(-0.003067956762966);
tw_re = zeros(1, N/2, 'single');
tw_im = zeros(1, N/2, 'single');
re = single(1.0); im = single(0.0);
for k = 1:N/2
    tw_re(k) = re; tw_im(k) = im;
    nr = single(re*w1_re - im*w1_im);
    ni = single(re*w1_im + im*w1_re);
    re = nr; im = ni;
end

% 与精确值的偏差 (递推累积误差应在 1e-4 量级)
kk = (0:N/2-1).';
err_tw = max(abs(double(tw_re).' - cos(2*pi*kk/N))) + ...
         max(abs(double(tw_im).' + sin(2*pi*kk/N)));
fprintf('twiddle 递推最大误差 = %.3e\n', err_tw);

% bit-reverse 表
br = zeros(1, N);
for k = 0:N-1
    j = 0;
    for b = 0:LOGN-1
        if bitand(k, 2^b)
            j = j + 2^(LOGN-1-b);
        end
    end
    br(k+1) = j;
end
assert(isequal(sort(br), 0:N-1), 'bit-reverse 不是置换!');

%% -------- 2. 随机数据测试 --------
rng(1);
x  = single(randn(N,1)) + 1j*single(randn(N,1));
[yr, yi] = fft_c(real(x), imag(x), tw_re, tw_im, br, N);
y_c = double(yr) + 1j*double(yi);
y_m = fft(double(x));
rel = norm(y_c - y_m) / norm(y_m);
fprintf('随机数据: 相对误差 = %.3e  (C-FFT vs MATLAB fft)\n', rel);

%% -------- 3. 实测回波一条距离线: 与 LRD_SAR.m 的处理链对比 --------
here = fileparts(mfilename('fullpath'));
load(fullfile(here, 'raw_data_dsx.mat'));

S_RAW = 32767 / max(abs(raw_data_dsx(:)));
q     = round(raw_data_dsx * S_RAW);
q     = max(min(q, 32767), -32768);          % 与 RDRAW.BIN 的 int16 量化一致
fx    = double(q) / S_RAW;                   % 板上先 /SRAW 再做 FFT

ii = 1;
xr = zeros(N,1,'single'); xi = zeros(N,1,'single');
for c = 0:N-1
    sc = mod(c + N/2, N);                    % 板上的 fftshift(输入)
    xr(sc+1) = single(fx(c+1, ii));
end
[yr, yi]  = fft_c(xr, xi, tw_re, tw_im, br, N);
y_c       = double(yr) + 1j*double(yi);
y_c_s     = y_c(mod((0:N-1) + N/2, N) + 1);  % 板上的 fftshift(输出)

y_m = fftshift(fft(fftshift(fx(:,ii))));     % MATLAB 参考

rel2 = norm(y_c_s - y_m) / norm(y_m);
fprintf('实测第 1 条距离线: 相对误差 = %.3e\n', rel2);

%% -------- 4. 结论 --------
if max(err_tw, rel) < 1e-3 && rel2 < 1e-3
    fprintf('RESULT: PASS   (软件 FFT 与 MATLAB 一致)\n');
else
    fprintf('RESULT: FAIL\n');
end

%% ================= 局部函数 =================
function [yr, yi] = fft_c(xr, xi, tw_re, tw_im, br, N)
% 与 main_4.c fft_2048 逐行对应: 原地 bit-reverse + radix-2 DIT
    yr = xr; yi = xi;
    for i = 1:N-1
        j = br(i+1);
        if i < j
            t = yr(i+1); yr(i+1) = yr(j+1); yr(j+1) = t;
            t = yi(i+1); yi(i+1) = yi(j+1); yi(j+1) = t;
        end
    end
    len = 2;
    while len <= N
        half = len/2; step = N/len;
        for start = 1:len:N
            for k = 0:half-1
                c = tw_re(k*step + 1);
                s = tw_im(k*step + 1);          % 前向: exp(-j2pi/N)
                vr = yr(start+k+half); vi = yi(start+k+half);
                tr = single(vr*c - vi*s);
                ti = single(vr*s + vi*c);
                ur = yr(start+k); ui = yi(start+k);
                yr(start+k)      = single(ur + tr);
                yi(start+k)      = single(ui + ti);
                yr(start+k+half) = single(ur - tr);
                yi(start+k+half) = single(ui - ti);
            end
        end
        len = len*2;
    end
end
