%% gen_bin.m -- 把 DDR dump 的 u32 幅度图导出为 uint16 / mat
cd(fileparts(mfilename('fullpath')));
build_dir = fullfile(fileparts(pwd), 'build');

fid = fopen(fullfile(build_dir,'mag4m.bin'),'r');
v = fread(fid, inf, 'uint32=>double');
fclose(fid);

N = round(sqrt(numel(v)));
img = reshape(v, N, N);        % [range][azimuth], 与 raw_data_dsx 同向
img = img / max(img(:));
img16 = uint16(round(img * 65535));

fid = fopen(fullfile(build_dir,'RDIMG_FPGA_U16.bin'),'w');
fwrite(fid, img16, 'uint16');  % 列优先写出: 文件顺序 = MATLAB 线性顺序
fclose(fid);

save(fullfile(build_dir,'RDIMG_FPGA.mat'),'img','N','-v7');
fprintf('EXPORT_OK N=%d peak=%d bytes=%d\n', N, max(img16(:)), numel(img16)*2);
