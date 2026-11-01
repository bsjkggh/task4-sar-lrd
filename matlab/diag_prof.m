%% diag_prof.m -- 核对主瓣宽度与数据带宽
cd(fileparts(mfilename('fullpath')));
S = load('img_ref.mat');
img = abs(S.img_ref);
global mx; mx = max(img(:));

% 强目标 (1216,1019) 与文档目标 (1321,950)
pts = [1216 1019; 1321 950];
for k = 1:size(pts,1)
    r0 = pts(k,1); a0 = pts(k,2);
    fprintf('\n=== 目标 (%d,%d) ===\n', r0, a0);
    dbr = 20*log10(img(r0-12:r0+12, a0)/mx + eps);
    fprintf('距离向剖面 (r-12..r+12, dB):\n');
    fprintf('  %6.2f', dbr); fprintf('\n');
    dba = 20*log10(img(r0, max(1,a0-30):min(2048,a0+30))/mx + eps);
    fprintf('方位向剖面 (a-30..a+30, dB):\n');
    fprintf('  %6.2f', dba); fprintf('\n');
    % -3dB 宽度 (按索引线性插值, 单位样点)
    w1 = width3db(20*log10(img(:,a0)/mx+eps), r0);
    w2 = width3db(20*log10(img(r0,:)/mx+eps), a0);
    fprintf('-3dB 宽度(未升采样): 距离 %.2f 样点, 方位 %.2f 样点\n', w1, w2);
end

%% 数据带宽占用 (判断实际采样间隔)
x = load('C:\Users\鲍\Documents\Trae-CN\temp_20261029_01\task4_ref\任务4--线性RD成像处理\raw_data_dsx.mat');
f = fieldnames(x); raw = x.(f{1});
sp = abs(fftshift(fft(raw(:,1000)))).^2;
sp = sp/max(sp);
occ = sum(sp > 0.5);
fprintf('\n原始回波距离谱 -3dB 宽度(按功率50%%计): %d / %d bin\n', occ, numel(sp));
fprintf('距离谱首尾功率比 at bins: start %.1f dB, end %.1f dB\n', ...
    10*log10(sp(1)+eps), 10*log10(sp(end)+eps));
saz = abs(fftshift(fft(raw(1000,:)))).^2; saz = saz/max(saz);
fprintf('方位谱 -3dB 宽度: %d / %d bin\n', sum(saz > 0.5), numel(saz));

function w = width3db(yDB, pk)
w = NaN; N = numel(yDB);
if pk <= 1 || pk >= N, return; end
li = find(yDB(1:pk-1) <= -3, 1, 'last');
ri = find(yDB(pk+1:end) <= -3, 1, 'first');
if isempty(li) || isempty(ri), return; end
y1 = yDB(li); y2 = yDB(li+1);
xL = li + (-3-y1)/(y2-y1);
ri = pk + ri;
y1 = yDB(ri-1); y2 = yDB(ri);
xR = (ri-1) + (-3-y1)/(y2-y1);
w = xR - xL;
end
