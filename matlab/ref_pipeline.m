%% ref_pipeline.m -- 复现 LRD_SAR.m 的浮点链路, 保存参考图像与耗时
% 供 cmp_metrics.m 与 FPGA 输出做同指标对比
cd(fileparts(mfilename('fullpath')));

load raw_data_dsx.mat
[Nr,Na] = size(raw_data_dsx);

%% 雷达参数 (与 LRD_SAR.m 完全一致)
c   = 3e8;
fc  = 25e9;
lambda = c/fc;
Tp  = 3e-6;
B   = 800e6;
gamma = B/Tp;
Fs  = 2.4e9;
PRF = 1500;
Z0  = 300;
cita_pitch = 68/180*pi;
R0  = Z0/cos(cita_pitch);
Rg  = sqrt(R0^2-Z0^2);
cita_squint = 0.0283;
xc  = -1*Rg*sin(cita_squint);
ta  = (-Na/2:Na/2-1)/(PRF/4);
va  = 4.8;
x_radar = xc + va*ta;
y_radar = sqrt((R0*cos(cita_squint))^2-Z0^2) + 0*ta;
z_radar = Z0 + 0*ta;
fr  = ((-Nr/2+1:Nr/2)/8192*Fs)';
Ra  = sqrt(x_radar.^2 + y_radar.^2 + z_radar.^2);

%% 线性RD: 匹配滤波 + 运动补偿 (浮点参考, 计时)
t0 = tic;
for ii = 1:Na
    raw_data_dsx(:,ii) = fftshift(fft(fftshift(raw_data_dsx(:,ii)))).* exp(1j*pi/gamma*fr.^2) ...
        .* exp(1j*4*pi/c*(fc+fr)*Ra(ii)) .* exp(-1j*4*pi/c*R0*fr);
end
t_range = toc(t0);

%% 2DFFT: 方位 hamming+FFT, 距离 hamming+IFFT
t0 = tic;
windowsr = hamming(Nr);
windowsa = hamming(Na);
for ii = 1:Nr
    raw_data_dsx(ii,:) = fftshift(fft(fftshift(raw_data_dsx(ii,:).*windowsa.')));
end
for ii = 1:Na
    raw_data_dsx(:,ii) = ifftshift(ifft(ifftshift(raw_data_dsx(:,ii).*windowsr)));
end
t_2dfft = toc(t0);
t_total = t_range + t_2dfft;

%% 参数换算: 采样间隔 (m)
dr_m = c/(2*Fs);            % 距离向采样间隔
da_m = va*(4/PRF);          % 方位向采样间隔 (4抽1)
rho_r_theory = c/(2*B);     % 距离向理论分辨率
Ka = 2*va^2/(lambda*R0);
Bd = Ka*(Na/(PRF/4));       % 方位多普勒带宽
rho_a_theory = va/(2*Bd);   % 方位向理论分辨率

img_ref = raw_data_dsx;
img_abs = abs(img_ref);

save('img_ref.mat','img_ref','img_abs','dr_m','da_m','rho_r_theory','rho_a_theory', ...
     't_range','t_2dfft','t_total','-v7');

fprintf('REF_TIME range=%.3f s  az/range_2dfft=%.3f s  total=%.3f s\n', ...
        t_range, t_2dfft, t_total);
fprintf('REF_PEAK abs max=%.6g at r=%d a=%d\n', ...
        max(img_abs(:)), 0, 0);
[mx,idx] = max(img_abs(:));
[r,a] = ind2sub(size(img_abs),idx);
fprintf('REF_PEAK r=%d a=%d val=%.6g\n', r, a, mx);
fprintf('DR_M=%.6f DA_M=%.6f RHO_R=%.6f RHO_A=%.6f\n', dr_m, da_m, rho_r_theory, rho_a_theory);
