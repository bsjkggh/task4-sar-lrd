function img = load_fpga_img(fname)
%LOAD_FPGA_IMG 读入 FPGA 实测 RD 成像结果
%   img = load_fpga_img('RDIMG_FPGA_U16.bin')
%   返回 [range][azimuth] 的 2048x2048 幅度图 (double, 峰值归一为 1),
%   与 raw_data_dsx 的行列方向一致, 可直接替换 LRD_SAR.m 中的
%       img = raw_data_dsx;
%
%   数据来源: 板卡 PS+PL 整幅处理完成后, JTAG 从 DDR 的 MAG 区
%   (0x07500000, u32 幅度) 整块读出, 未做任何抽样或降采样。

if nargin < 1 || isempty(fname)
    fname = 'RDIMG_FPGA_U16.bin';
end

fid = fopen(fname, 'r');
if fid < 0
    error('打不开 %s', fname);
end
v = fread(fid, inf, 'uint16=>double');
fclose(fid);

N = round(sqrt(numel(v)));
if N*N ~= numel(v)
    error('%s 元素数 %d 不是完全平方, 不是 NxN 图', fname, numel(v));
end

img = reshape(v, N, N) / 65535.0;   % [range][azimuth]
end
