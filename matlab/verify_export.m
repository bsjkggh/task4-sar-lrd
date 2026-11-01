cd('D:\task4_lrd_v2\matlab');
img = load_fpga_img(fullfile('..','build','RDIMG_FPGA_U16.bin'));
S = load('img_ref.mat');
ref = abs(S.img_ref); ref = ref/max(ref(:));
c = corr(img(:), ref(:));
d = 20*log10(img+eps)-20*log10(ref+eps);
m = ref > 0.01;
fprintf('CHECK size=%dx%d corr=%.6f rms_dB=%.3f max_dB=%.3f peakrc=%d,%d\n', size(img,1), size(img,2), c, sqrt(mean(d(m).^2)), max(abs(d(m))), find(max(img(:))==img,1));
