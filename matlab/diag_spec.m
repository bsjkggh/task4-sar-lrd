%% diag_spec.m -- 判断距离/方位向有效带宽占比, 定标采样间隔
cd(fileparts(mfilename('fullpath')));
S = load('img_ref.mat');
img = abs(S.img_ref);

a0 = 1019; r0 = 1216;
sp_r = abs(fftshift(fft(img(:,a0)))).^2; sp_r = sp_r/max(sp_r);
sp_a = abs(fftshift(fft(img(r0,:)))).^2; sp_a = sp_a/max(sp_a);

fprintf('距离向像谱占用(-3dB): %d/2048  bin, (-10dB): %d/2048\n', ...
    sum(sp_r>0.5), sum(sp_r>0.1));
fprintf('方位向像谱占用(-3dB): %d/2048  bin, (-10dB): %d/2048\n', ...
    sum(sp_a>0.5), sum(sp_a>0.1));

% 以 fr 轴定义 (LRD_SAR.m): bin 间隔 Fs/8192, ±1024 bin -> ±300 MHz
fprintf('LRD_SAR.m 的 fr 轴: 步长 %.4f MHz, 总跨度 %.1f MHz\n', ...
    2.4e3/8192, 2*1024*2.4e3/8192);
fprintf('=> 距离向等效采样率 %.1f MHz, 采样间隔 %.4f m (c/2Fs)\n', ...
    2*1024*2.4e3/8192, 3e8/(2*2*1024*2.4e6/8192));
