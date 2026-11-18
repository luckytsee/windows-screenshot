param(
    [Parameter(Mandatory = $true)][string]$Dir,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [int]$CropTop = 0,
    [switch]$NoClipboard
)

$ErrorActionPreference = 'Stop'
$logFile = Join-Path $Dir 'stitch_error.log'
try { Remove-Item $logFile -Force -ErrorAction SilentlyContinue } catch { }

try {
    "START $(Get-Date -Format o) PS=$($PSVersionTable.PSVersion)" | Out-File $logFile -Encoding UTF8

    # AHK 启动的子进程可能丢失 Windows PowerShell 5.1 模块路径，导致 cmdlet 自动加载失败
    if ($env:PSModulePath -notlike '*WindowsPowerShell\v1.0\Modules*') {
        $env:PSModulePath = "$env:windir\System32\WindowsPowerShell\v1.0\Modules;$env:PSModulePath"
    }

    Add-Type -AssemblyName System.Drawing

    if (-not ([System.Management.Automation.PSTypeName]'RowStitcher').Type) {
        Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class RowStitcher {
    // 行像素打包（去掉 stride 填充），一次锁定全帧复用
    public static byte[] PackedBytes(Bitmap bmp, int y, int height) {
        if (y < 0) { height += y; y = 0; }
        if (y + height > bmp.Height) { height = bmp.Height - y; }
        if (height <= 0) return new byte[0];
        Rectangle rect = new Rectangle(0, y, bmp.Width, height);
        BitmapData data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        int stride = Math.Abs(data.Stride);
        int wbytes = bmp.Width * 4;
        byte[] result = new byte[wbytes * height];
        try {
            long scan = data.Scan0.ToInt64();
            for (int ry = 0; ry < height; ry++)
                Marshal.Copy((IntPtr)(scan + ry * stride), result, ry * wbytes, wbytes);
        }
        finally { bmp.UnlockBits(data); }
        return result;
    }

    public static uint[] RowHashes(byte[] packed, int width, int height) {
        uint[] rows = new uint[height];
        int wbytes = width * 4;
        for (int ry = 0; ry < height; ry++) {
            uint hv = 2166136261;
            int off = ry * wbytes;
            for (int x = 0; x < wbytes; x += 4) {
                hv = (hv ^ (uint)(packed[off + x] & 0xF8)) * 16777619;
                hv = (hv ^ (uint)(packed[off + x + 1] & 0xF8)) * 16777619;
                hv = (hv ^ (uint)(packed[off + x + 2] & 0xF8)) * 16777619;
            }
            rows[ry] = hv;
        }
        return rows;
    }

    public static int FindShift(uint[] a, uint[] b, int minOverlap, int lastS) {
        int n = a.Length;
        int maxAbs = n - minOverlap;
        if (maxAbs < 1) return int.MinValue;
        List<int> cand = new List<int>();
        for (int s = -maxAbs; s <= maxAbs; s++) cand.Add(s);
        cand.Sort((x, y) => Math.Abs(x - lastS).CompareTo(Math.Abs(y - lastS)));
        int best = int.MinValue;
        double bestRatio = 0.0;
        int uniform = int.MinValue;
        foreach (int s in cand) {
            int ov = n - Math.Abs(s);
            int aStart = Math.Max(0, s), bStart = Math.Max(0, -s);
            int match = 0;
            for (int i = 0; i < ov; i++) {
                if (a[aStart + i] == b[bStart + i]) match++;
            }
            double ratio = (double)match / ov;
            if (ratio >= 0.999) {
                HashSet<uint> set = new HashSet<uint>();
                for (int i = 0; i < ov; i++) set.Add(b[bStart + i]);
                if (set.Count >= Math.Min(6, ov)) return s;
                if (uniform == int.MinValue) uniform = s;
            }
            if (ratio > bestRatio) { bestRatio = ratio; best = s; }
        }
        if (bestRatio >= 0.85) return best;
        return uniform;
    }

    // 逐行置信度精对齐（纹理加权）：纯色行不参与置信计数，
    // 防止大面积纯色背景在任何偏移下 diff 都为 0 而造成错误重叠/内容塌缩
    // 返回 [偏移, 匹配的纹理行数]，无可靠对齐返回 null
    public static int[] RefineShift(byte[] a, byte[] b, int width, int effH, int s0, int lastS, int window, int minOverlap) {
        int stride = width * 4;
        int limit = effH - minOverlap;
        if (limit < 1) return null;
        int lo = s0 - window; if (lo < -limit) lo = -limit;
        int hi = s0 + window; if (hi > limit) hi = limit;
        int best = int.MinValue, bestScore = int.MinValue, bestMatched = 0, bestTextured = 0;
        for (int s = lo; s <= hi; s++) {
            int ov = effH - Math.Abs(s);
            int aStart = Math.Max(0, s) * stride;
            int bStart = Math.Max(0, -s) * stride;
            int matched = 0, textured = 0;
            for (int i = 0; i < ov; i++) {
                int offA = aStart + i * stride;
                int offB = bStart + i * stride;
                int diff = 0; long sum = 0, sumSq = 0; int cnt = 0;
                for (int x = 0; x < stride; x += 8) {
                    int ra = a[offA + x], ga = a[offA + x + 1], ba = a[offA + x + 2];
                    int rb = b[offB + x], gb = b[offB + x + 1], bb = b[offB + x + 2];
                    diff += Math.Abs(ra - rb) + Math.Abs(ga - gb) + Math.Abs(ba - bb);
                    sum += ra + ga + ba;
                    sumSq += (long)ra * ra + (long)ga * ga + (long)ba * ba;
                    cnt++;
                }
                int cnt3 = cnt * 3;
                double mean = (double)sum / cnt3;
                double variance = (double)sumSq / cnt3 - mean * mean;
                if (variance >= 9.0) {                 // std>=3 视为纹理行
                    textured++;
                    if ((double)diff / cnt3 < 6.0) matched++;
                }
            }
            int score = 2 * matched - textured;        // 匹配加分，失配扣分
            if (score > bestScore || (score == bestScore && best != int.MinValue && Math.Abs(s - lastS) < Math.Abs(best - lastS))) {
                best = s; bestScore = score; bestMatched = matched; bestTextured = textured;
            }
        }
        if (best == int.MinValue) return null;
        if (bestMatched < 8) return null;                                  // 纹理证据不足 → 不重叠
        if (bestTextured >= 20 && bestMatched * 5 < bestTextured * 4) return null;  // 纹理行匹配率 < 80% → 不重叠
        return new int[] { best, bestMatched };
    }

    // 全范围纹理评分搜索（不依赖上一位移锚点）：粗扫 step 4 → 局部精扫 ±6。
    // 解决哈希粗定位在文字页面上失配后，±16 精对齐窗口无法回到真实位移的问题。
    public static string Debug = "";
    public static int[] BestShift(byte[] a, byte[] b, int width, int effH, int lastS, int minOverlap) {
        int stride = width * 4;
        int limit = effH - minOverlap;
        if (limit < 1) return null;
        int bestS = int.MinValue;
        int bestScore = int.MinValue;
        int span = 2 * limit + 1;
        int[] cs = new int[span];
        for (int s = -limit; s <= limit; s++) {
            int[] r = ScoreRowwise(a, b, stride, effH, s, 24, 6);
            int score = r[2];
            cs[s + limit] = score;
            if (score > bestScore || (score == bestScore && bestS != int.MinValue && Math.Abs(s - lastS) < Math.Abs(bestS - lastS))) {
                bestScore = score; bestS = s;
            }
        }
        if (bestS == int.MinValue) return null;
        // 次优峰（离最优至少 8px）：用来判断最优位移是否"一枝独秀"。
        // 文字/文件列表类画面本身就带大量结构相似行，正确位移通常只有 ~75% 匹配率，
        // 但它是唯一的峰，而错误位移的匹配率只有 ~52%，且不会形成孤立尖峰。
        int secondS = int.MinValue, secondScore = int.MinValue;
        for (int s = -limit; s <= limit; s++) {
            if (Math.Abs(s - bestS) < 8) continue;
            int v = cs[s + limit];
            if (v > secondScore) { secondScore = v; secondS = s; }
        }
        int lo = bestS - 6; if (lo < -limit) lo = -limit;
        int hi = bestS + 6; if (hi > limit) hi = limit;
        int fS = bestS, fScore = int.MinValue, fMatched = 0, fTextured = 0;
        for (int s = lo; s <= hi; s++) {
            int[] r = ScoreRowwise(a, b, stride, effH, s, 8, 1);
            if (r[2] > fScore || (r[2] == fScore && fS != int.MinValue && Math.Abs(s - lastS) < Math.Abs(fS - lastS))) {
                fScore = r[2]; fS = s; fMatched = r[0]; fTextured = r[1];
            }
        }
        Debug = "coarse=" + bestS + "/" + bestScore + " second=" + secondS + "/" + secondScore + " fine=" + fS + "/" + fScore + " matched=" + fMatched + " textured=" + fTextured;
        if (fMatched < 8) return null;
        // 阈值 70%：文件列表/IDE 这类界面里，选区内常夹着「不滚动的固定区域」（活动栏、预览/大纲面板），
        // 正确位移一般只能到 75~80%，而错误位移约 50~65%，所以 70% 仍能分开，且不再把正确位移误判成 JUMP。
        if (fTextured >= 20 && fMatched * 10 < fTextured * 7) return null;
        return new int[] { fS, fMatched };
    }

    // 返回 [matched, textured, score]
    public static int[] ScoreRowwise(byte[] a, byte[] b, int stride, int effH, int s, int xStep, int rowStep) {
        int ov = effH - Math.Abs(s);
        if (ov <= 0) return new int[] { 0, 0, int.MinValue };
        int aStart = Math.Max(0, s) * stride;
        int bStart = Math.Max(0, -s) * stride;
        int matched = 0, textured = 0;
        for (int i = 0; i < ov; i += rowStep) {
            int offA = aStart + i * stride;
            int offB = bStart + i * stride;
            int diff = 0; long sum = 0, sumSq = 0; int cnt = 0;
            for (int x = 0; x < stride; x += xStep) {
                int ra = a[offA + x], ga = a[offA + x + 1], ba = a[offA + x + 2];
                int rb = b[offB + x], gb = b[offB + x + 1], bb = b[offB + x + 2];
                diff += Math.Abs(ra - rb) + Math.Abs(ga - gb) + Math.Abs(ba - bb);
                sum += ra + ga + ba;
                sumSq += (long)ra * ra + (long)ga * ga + (long)ba * ba;
                cnt++;
            }
            int cnt3 = cnt * 3;
            double mean = (double)sum / cnt3;
            double variance = (double)sumSq / cnt3 - mean * mean;
            if (variance >= 9.0) {
                textured++;
                if ((double)diff / cnt3 < 6.0) matched++;
            }
        }
        return new int[] { matched, textured, 2 * matched - textured };
    }

    // 检测"固定不滚动的 UI 带"（标题栏/工具栏/列头/状态栏）。
    // 判据：把每一帧和它的下一帧在【相同行号】上逐像素比较，同一行在多数帧对里都完全一致
    // → 这一行在滚动时没有动，属于窗口固定 UI；再取顶部/底部的连续段。
    // 返回 [topRows, bottomRows]。返回的段会被从每帧里裁掉，最后只在整图顶部/底部各画一次。
    public static int[] StaticBand(byte[][] packed, int stride, int effH) {
        int n = packed.Length;
        if (n < 3) return new int[] { 0, 0 };
        int[] votes = new int[effH];
        int pairs = 0;
        for (int i = 1; i < n; i++) {
            pairs++;
            byte[] A = packed[i - 1], B = packed[i];
            for (int r = 0; r < effH; r++) {
                int o = r * stride;
                bool same = true;
                for (int x = 0; x < stride; x += 4) {
                    if (A[o + x] != B[o + x] || A[o + x + 1] != B[o + x + 1] || A[o + x + 2] != B[o + x + 2]) { same = false; break; }
                }
                if (same) votes[r]++;
            }
        }
        int need = (int)Math.Ceiling(pairs * 0.6);
        if (need < 2) need = 2;
        int cap = effH / 3;
        // 允许带内有少量"非纯静态"的行（工具栏上的数字/进度/时间一直在变），
        // 但连续 10 行都不静态就认为带结束了。
        int top = 0, miss = 0;
        for (int r = 0; r < cap; r++) {
            if (votes[r] >= need) { top = r + 1; miss = 0; }
            else { miss++; if (miss >= 10) break; }
        }
        int bot = 0; miss = 0;
        for (int r = effH - 1; r >= effH - cap && r > top; r--) {
            if (votes[r] >= need) { bot = effH - r; miss = 0; }
            else { miss++; if (miss >= 10) break; }
        }
        if (top + bot > cap) { if (top >= bot) bot = Math.Max(0, cap - top); else top = Math.Max(0, cap - bot); }
        return new int[] { top, bot };
    }

    // 检测四边同色的 1~maxEdge 像素抓屏边框（选框描边残留），返回 [top,bottom,left,right]
    public static int[] DetectBorder(Bitmap bmp, int maxEdge) {
        int w = bmp.Width, h = bmp.Height;
        Color c00 = bmp.GetPixel(0, 0), c10 = bmp.GetPixel(w - 1, 0);
        Color c01 = bmp.GetPixel(0, h - 1), c11 = bmp.GetPixel(w - 1, h - 1);
        if (!Same(c00, c10) || !Same(c00, c01) || !Same(c00, c11)) return new int[] { 0, 0, 0, 0 };
        int top = EdgeRows(bmp, c00, true, maxEdge);
        int bottom = EdgeRows(bmp, c00, false, maxEdge);
        int left = EdgeCols(bmp, c00, true, maxEdge);
        int right = EdgeCols(bmp, c00, false, maxEdge);
        return new int[] { top, bottom, left, right };
    }
    static bool Same(Color x, Color y) {
        return Math.Abs(x.R - y.R) <= 4 && Math.Abs(x.G - y.G) <= 4 && Math.Abs(x.B - y.B) <= 4;
    }
    static int EdgeRows(Bitmap bmp, Color c, bool fromTop, int maxEdge) {
        int w = bmp.Width, h = bmp.Height, k = 0;
        while (k < maxEdge) {
            int y = fromTop ? k : h - 1 - k;
            if (y < 0 || y >= h) break;
            int hit = 0, samples = 0;
            for (int x = 0; x < w; x += 7) { samples++; if (Same(bmp.GetPixel(x, y), c)) hit++; }
            if (hit < samples * 0.98) break;
            k++;
        }
        return k;
    }
    static int EdgeCols(Bitmap bmp, Color c, bool fromLeft, int maxEdge) {
        int w = bmp.Width, h = bmp.Height, k = 0;
        while (k < maxEdge) {
            int x = fromLeft ? k : w - 1 - k;
            if (x < 0 || x >= w) break;
            int hit = 0, samples = 0;
            for (int y = 0; y < h; y += 7) { samples++; if (Same(bmp.GetPixel(x, y), c)) hit++; }
            if (hit < samples * 0.98) break;
            k++;
        }
        return k;
    }
}
"@
    }
    "Add-Type OK" | Out-File $logFile -Append -Encoding UTF8

    $files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.png' | Sort-Object Name)
    if ($files.Count -lt 1) { throw '没有找到帧文件' }
    "frames=$($files.Count)" | Out-File $logFile -Append -Encoding UTF8

    # 去掉内容完全相同的连续帧（没滚动成功的情况）
    $unique = New-Object System.Collections.Generic.List[object]
    $prevHash = $null
    foreach ($f in $files) {
        # 不用 Get-FileHash（部分环境下不可用），纯 .NET 计算 SHA256
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $fs = [System.IO.File]::OpenRead($f.FullName)
        try { $h2 = [System.BitConverter]::ToString($sha.ComputeHash($fs)) }
        finally { $fs.Dispose(); $sha.Dispose() }
        if ($h2 -ne $prevHash) { $unique.Add($f) }
        $prevHash = $h2
    }
    "unique=$($unique.Count)" | Out-File $logFile -Append -Encoding UTF8

    $bitmaps = @($unique | ForEach-Object { [System.Drawing.Bitmap]::FromFile($_.FullName) })
    $w = $bitmaps[0].Width
    $h = $bitmaps[0].Height
    foreach ($b in $bitmaps) {
        if ($b.Width -ne $w -or $b.Height -ne $h) { throw '帧尺寸不一致' }
    }

    # 去掉四边同色的选框描边（1~4px）。不裁的话每个接缝都会留一条横贯整幅的描边色线，
    # 而且这些行在任意位移下都"完全匹配"，会污染对齐评分。
    $edge = [RowStitcher]::DetectBorder($bitmaps[0], 4)
    if (($edge[0] + $edge[1] + $edge[2] + $edge[3]) -gt 0) {
        $rect = New-Object System.Drawing.Rectangle($edge[2], $edge[0], ($w - $edge[2] - $edge[3]), ($h - $edge[0] - $edge[1]))
        for ($i = 0; $i -lt $bitmaps.Count; $i++) {
            $clone = $bitmaps[$i].Clone($rect, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $bitmaps[$i].Dispose()
            $bitmaps[$i] = $clone
        }
        $w = $bitmaps[0].Width
        $h = $bitmaps[0].Height
        "border=$($edge -join ',') cropped=${w}x${h}" | Out-File $logFile -Append -Encoding UTF8
    }

    if ($CropTop -lt 0 -or $CropTop -ge $h) { throw 'CropTop 超出范围' }
    $effH = $h - $CropTop
    $n = $bitmaps.Count
    "size=${w}x${h} effH=$effH n=$n" | Out-File $logFile -Append -Encoding UTF8

    # 预打包每帧行像素 + 行哈希（一次锁定，复用）
    $packed = [byte[][]]::new($n)
    $hashes = [uint32[][]]::new($n)
    for ($i = 0; $i -lt $n; $i++) {
        $packed[$i] = [RowStitcher]::PackedBytes($bitmaps[$i], $CropTop, $effH)
        $hashes[$i] = [RowStitcher]::RowHashes($packed[$i], $w, $effH)
    }

    # 裁掉固定不滚动的 UI 带（标题栏/工具栏/列头/状态栏）。不裁的话，这些行会在每个接缝处重复出现，
    # 拼出来的长图就是"一个个窗口叠在一起"；而且它们在对齐评分里恒为失配，会把真实位移的匹配率拉低。
    $contentTop = $CropTop
    $staticTop = 0
    $staticBot = 0
    if ($n -ge 3) {
        $sb = [RowStitcher]::StaticBand($packed, ($w * 4), $effH)
        $staticTop = $sb[0]
        $staticBot = $sb[1]
        if (($staticTop + $staticBot) -gt 0) {
            $contentTop = $CropTop + $staticTop
            $effH = $effH - $staticTop - $staticBot
            for ($i = 0; $i -lt $n; $i++) {
                $packed[$i] = [RowStitcher]::PackedBytes($bitmaps[$i], $contentTop, $effH)
                $hashes[$i] = [RowStitcher]::RowHashes($packed[$i], $w, $effH)
            }
            "static=top$staticTop bottom$staticBot contentH=$effH" | Out-File $logFile -Append -Encoding UTF8
        }
    }

    # 链式偏移：全范围纹理评分对齐（支持上下滚动）
    # 第一遍只求相邻帧位移，第二遍再按整体滚动方向决定 JUMP 往上还是往下堆叠，
    # 避免"第一对就对不上"时方向未知导致整幅内容被放到画布错误的一端。
    $pairS = New-Object 'int[]' $n
    $pairOk = New-Object 'bool[]' $n
    $alignLog = New-Object System.Text.StringBuilder
    $lastS = 0
    $upCount = 0
    $downCount = 0
    for ($i = 1; $i -lt $n; $i++) {
        $sHash = [RowStitcher]::FindShift($hashes[$i - 1], $hashes[$i], 24, $lastS)
        $ref = [RowStitcher]::BestShift($packed[$i - 1], $packed[$i], $w, $effH, $lastS, 24)
        if ($null -ne $ref) {
            $pairS[$i] = $ref[0]
            $pairOk[$i] = $true
            if ($ref[0] -ne 0) { $lastS = $ref[0] }
            if ($ref[0] -lt 0) { $upCount++ } elseif ($ref[0] -gt 0) { $downCount++ }
            [void]$alignLog.AppendFormat('pair{0}: hash={1} refined={2} conf={3} [{4}]; ', $i, $sHash, $ref[0], $ref[1], [RowStitcher]::Debug)
        }
        else {
            [void]$alignLog.AppendFormat('pair{0}: hash={1} JUMP conf-reject [{2}]; ', $i, $sHash, [RowStitcher]::Debug)
        }
    }

    $scrollDir = 1
    if ($upCount -ge $downCount -and $upCount -gt 0) { $scrollDir = -1 }

    $offsets = New-Object 'int[]' $n
    $offsets[0] = 0
    $discont = 0
    for ($i = 1; $i -lt $n; $i++) {
        if ($pairOk[$i]) {
            $offsets[$i] = $offsets[$i - 1] + $pairS[$i]
        }
        else {
            if ($scrollDir -lt 0) {
                $minTop = $offsets[0]
                for ($j = 1; $j -lt $i; $j++) { if ($offsets[$j] -lt $minTop) { $minTop = $offsets[$j] } }
                $offsets[$i] = $minTop - $effH
            }
            else {
                $maxBottom = 0
                for ($j = 0; $j -lt $i; $j++) {
                    if (($offsets[$j] + $effH) -gt $maxBottom) { $maxBottom = $offsets[$j] + $effH }
                }
                $offsets[$i] = $maxBottom
            }
            $discont++
        }
    }
    "dir=$scrollDir up=$upCount down=$downCount" | Out-File $logFile -Append -Encoding UTF8
    "align: $($alignLog.ToString())" | Out-File $logFile -Append -Encoding UTF8
    "offsets=$($offsets -join ',') discont=$discont" | Out-File $logFile -Append -Encoding UTF8

    # 每一对都成功对齐在 0 → 画面根本没滚动（滚轮没送到目标窗口 / 指针不在可滚动区域）。
    # 注意：对齐失败（Jump）不算"没滚动"，那是另一回事（见下面的 noOverlap）。
    $noScroll = $true
    for ($i = 1; $i -lt $n; $i++) {
        if (-not $pairOk[$i] -or $pairS[$i] -ne 0) { $noScroll = $false; break }
    }
    "noScroll=$noScroll" | Out-File $logFile -Append -Encoding UTF8

    # 帧之间有变化，但没有任何一对能对齐 → 相邻两帧根本不重叠（滚太多/选区太矮）。
    # 这跟 noScroll 完全不同：内容其实在滚，只是每帧跨越的距离超过了窗口高度，物理上拼不起来。
    $noOverlap = $false
    if ($n -gt 1 -and -not $noScroll) {
        $okCount = 0
        for ($i = 1; $i -lt $n; $i++) { if ($pairOk[$i]) { $okCount++ } }
        if ($okCount -eq 0) { $noOverlap = $true }
    }
    "noOverlap=$noOverlap" | Out-File $logFile -Append -Encoding UTF8
    $top = $offsets[0]
    $bottom = $offsets[0] + $effH
    for ($i = 0; $i -lt $n; $i++) {
        if ($offsets[$i] -lt $top) { $top = $offsets[$i] }
        if (($offsets[$i] + $effH) -gt $bottom) { $bottom = $offsets[$i] + $effH }
    }
    $totalH = $bottom - $top
    if (($staticTop + $staticBot) -gt 0) { $totalH = $totalH + $staticTop + $staticBot }

    $canvas = New-Object System.Drawing.Bitmap($w, $totalH)
    $g = [System.Drawing.Graphics]::FromImage($canvas)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    for ($i = 0; $i -lt $n; $i++) {
        $g.DrawImage($bitmaps[$i],
            (New-Object System.Drawing.Rectangle(0, ($offsets[$i] - $top + $staticTop), $w, $effH)),
            (New-Object System.Drawing.Rectangle(0, $contentTop, $w, $effH)),
            [System.Drawing.GraphicsUnit]::Pixel)
    }
    # 固定 UI 带只画一次：顶部和底部各一条（取自第一帧，所有帧里这些行都一样）
    if ($staticTop -gt 0) {
        $g.DrawImage($bitmaps[0],
            (New-Object System.Drawing.Rectangle(0, 0, $w, $staticTop)),
            (New-Object System.Drawing.Rectangle(0, $CropTop, $w, $staticTop)),
            [System.Drawing.GraphicsUnit]::Pixel)
    }
    if ($staticBot -gt 0) {
        $g.DrawImage($bitmaps[0],
            (New-Object System.Drawing.Rectangle(0, ($totalH - $staticBot), $w, $staticBot)),
            (New-Object System.Drawing.Rectangle(0, ($contentTop + $effH), $w, $staticBot)),
            [System.Drawing.GraphicsUnit]::Pixel)
    }

    $outDir = Split-Path -Parent $OutFile
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $canvas.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
    "saved=$OutFile totalH=$totalH" | Out-File $logFile -Append -Encoding UTF8

    $g.Dispose(); $canvas.Dispose()
    foreach ($b in $bitmaps) { $b.Dispose() }

    if (-not $NoClipboard) {
        try { Set-Clipboard -Path $OutFile -ErrorAction Stop }
        catch {
            try {
                Add-Type -AssemblyName System.Windows.Forms
                $drop = New-Object System.Collections.Specialized.StringCollection
                [void]$drop.Add($OutFile)
                [System.Windows.Forms.Clipboard]::SetFileDropList($drop)
            }
            catch { }
        }
    }
    if (-not $env:LONGSHOT_KEEP_LOG) { Remove-Item $logFile -Force -ErrorAction SilentlyContinue }
    # 给 AHK 留一份结果清单（日志默认会被删掉），失败时也能据此提示
    try { "OK $totalH discontinuities=$discont noscroll=$([int]$noScroll) nooverlap=$([int]$noOverlap)" | Out-File (Join-Path $Dir 'stitch_status.txt') -Encoding UTF8 } catch { }
    if ($noScroll) {
        Write-Output "OK $totalH discontinuities=$discont noscroll=1 nooverlap=0"
    } elseif ($noOverlap) {
        Write-Output "OK $totalH discontinuities=$discont noscroll=0 nooverlap=1"
    } else {
        Write-Output "OK $totalH discontinuities=$discont noscroll=0 nooverlap=0"
    }
    exit 0
}
catch {
    try {
        "FAILED: $($_.Exception.GetType().FullName): $($_.Exception.Message)" | Out-File $logFile -Append -Encoding UTF8
        $_.ScriptStackTrace | Out-File $logFile -Append -Encoding UTF8
    }
    catch { }
    exit 1
}




