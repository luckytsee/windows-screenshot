#Requires AutoHotkey v2.0
#SingleInstance Force
CoordMode "Mouse", "Screen"

; ================= 可配置 =================
global SettleMs := 160        ; 每帧滚动后等待画面的毫秒数（越小截得越密，帧间重叠越多）
global MinSelect := 40        ; 选区最小边长（像素）
global CropTop := 0           ; 每帧忽略顶部像素（应对吸顶栏，如 0 或 60）
global SaveSubDir := "LongShots"
global DebugHUD := true       ; 左上角调试状态条
global KeepFrames := true     ; 调试期：拼接成功后也保留帧目录，便于复现问题
global FocusOnStart := true   ; 按下左键时激活鼠标下的窗口（保证滚轮能滚它）

; ================= 状态 =================
global InMode := false
global Dragging := false
global Locked := false
global AnchorX := 0, AnchorY := 0
global RX := 0, RY := 0, RW := 0, RH := 0
global FrameDir := ""
global FrameCount := 0
global TickCount := 0
global SnapPending := false
global Busy := false
global StaleCount := 0       ; 连续多少帧与上一帧完全相同（滚轮没生效）
global BandGuis := []
global StitchPid := 0, PendingTemp := "", PendingOut := ""

GdipStartup()   ; 整个脚本生命周期只初始化一次，不再按会话启停
; 启动/重载后给一次可见反馈：看不到这行字，就说明脚本没真的重载（或加载报错了）
ShowTip("LongShot 已就绪：Ctrl+Alt+A 开始", 1500)

; Ctrl+Alt+A 进入/退出截屏模式
^!a::EnterMode()

#HotIf InMode
Esc::CancelAll()

*LButton:: {
    global
    if Dragging
        return
    MouseGetPos &AnchorX, &AnchorY
    if FocusOnStart {
        MouseGetPos , , &mwin
        if mwin && !WinActive("ahk_id " mwin)
            WinActivate("ahk_id " mwin)
    }
    Dragging := true
    SetTimer(UpdateBand, 15)
    HUD()
}

*LButton up:: {
    global
    if !Dragging
        return
    Dragging := false
    SetTimer(UpdateBand, 0)
    if Locked {
        if SnapPending {
            Sleep SettleMs
            SnapNow()
        }
        Finish()
    } else {
        ; 没滚过滚轮 = 普通截屏
        if LockRect() {
            SnapNow()
            Finish()
        } else {
            CancelAll()
        }
    }
}
#HotIf InMode && Dragging
~*WheelDown::OnWheel()
~*WheelUp::OnWheel()
#HotIf

EnterMode() {
    global
    if Busy {
        ShowTip("正在处理上一张长图，请稍候…", 1200)
        return
    }
    if InMode {
        CancelAll()
        return
    }
    InMode := true
    try FileAppend("enter " A_TickCount "`n", A_Temp "\LongShot_band.log", "UTF-8")
    FrameDir := A_Temp "\LongShot_" A_TickCount
    DirCreate(FrameDir)
    FrameCount := 0
    TickCount := 0
    StaleCount := 0
    Locked := false
    Dragging := false
    SnapPending := false
    ShowTip("按住左键拖出选区 → 滚动滚轮（上/下都行，慢一点）接长图 → 松开左键完成（Esc 取消）")
    HUD()
}

OnWheel() {
    global
    TickCount++
    if !Locked {
        if !LockRect()
            return
        SnapNow()   ; 第 0 帧：滚动前画面
    }
    LogWheelTarget()
    ; 非重置调度：已有待拍帧时不重复排队，连续滚动也会按 SettleMs 节奏持续截帧
    if !SnapPending {
        SnapPending := true
        SetTimer(SnapAfterSettle, -SettleMs)
    }
    HUD()
}

SnapAfterSettle() => SnapNow()

; 记录滚轮落点与前台窗口：下次画面不动时能直接看出是"窗口没激活"还是"指针在不可滚区域"
LogWheelTarget() {
    global
    MouseGetPos &mx, &my, &hw
    cls := "", ttl := "", act := "", actc := ""
    try cls := WinGetClass("ahk_id " hw)
    try ttl := WinGetTitle("ahk_id " hw)
    try act := WinExist("A")
    try actc := WinGetClass("A")
    try FileAppend("wheel tick=" A_TickCount " active=" act "(" actc ") cursor=(" mx "," my ") under=" hw "(" cls " | " ttl ")`n", A_Temp "\LongShot_band.log", "UTF-8")
}

SnapNow() {
    global
    SnapPending := false
    SetTimer(SnapAfterSettle, 0)
    f := FrameDir "\f" Format("{:04}", FrameCount) ".png"
    if CaptureRect(RX, RY, RW, RH, f) {
        FrameCount++
        ShowTip("已捕获 " FrameCount " 帧（松开左键完成）", 1200)
        ; 与上一帧完全相同 = 画面没滚，滚轮根本没生效。必须当场提示，不能等拼接完再报"成功"
        if (FrameCount >= 2 && SameImageFile(FrameDir "\f" Format("{:04}", FrameCount - 2) ".png", f)) {
            StaleCount++
            ShowTip("画面没有变化（" StaleCount " 次）：滚轮没有滚到内容`n选区已锁定，可以把鼠标移到可滚动区域再滚", 2000)
        } else {
            StaleCount := 0
        }
    } else {
        ShowTip("截图失败！", 1500)
    }
    HUD()
}

; 同一编码器输出同一像素必然得到相同字节，所以直接比 PNG 文件字节即可
SameImageFile(a, b) {
    if !FileExist(a) || !FileExist(b)
        return false
    sa := FileGetSize(a), sb := FileGetSize(b)
    if (sa != sb)
        return false
    ba := FileRead(a, "RAW"), bb := FileRead(b, "RAW")
    return DllCall("msvcrt\memcmp", "ptr", ba, "ptr", bb, "uptr", sa, "int") = 0
}

LockRect() {
    global
    MouseGetPos &mx, &my
    RX := Min(mx, AnchorX), RY := Min(my, AnchorY)
    RW := Abs(mx - AnchorX), RH := Abs(my - AnchorY)
    if (RW < MinSelect || RH < MinSelect) {
        ShowTip("选区太小（至少 " MinSelect "×" MinSelect "）", 1500)
        return false
    }
    Locked := true
    try FileAppend("lock " A_TickCount "`n", A_Temp "\LongShot_band.log", "UTF-8")
    aw := 0, awc := "", mw := 0, mwc := "", mwt := ""
    try {
        aw := WinExist("A")
        awc := WinGetClass("A")
    }
    try {
        MouseGetPos , , &mw
        mwc := WinGetClass("ahk_id " mw)
        mwt := WinGetTitle("ahk_id " mw)
    }
    try FileAppend(Format("locked rect={1},{2} {3}x{4} active={5}({6}) under={7}({8} | {9})`n"
        , RX, RY, RW, RH, aw, awc, mw, mwc, mwt), A_Temp "\LongShot_band.log", "UTF-8")
    SetTimer(UpdateBand, 0)
    BandShow(RX, RY, RW, RH, "00B050")
    ShowTip("已锁定：滚动滚轮（可上可下）加长截图，松开左键完成", 1500)
    return true
}

UpdateBand() {
    global
    if !Dragging || Locked
        return
    MouseGetPos &mx, &my
    x := Min(mx, AnchorX), y := Min(my, AnchorY)
    w := Abs(mx - AnchorX), h := Abs(my - AnchorY)
    if (w >= 8 && h >= 8)
        BandShow(x, y, w, h, "FF0000")
}

Finish() {
    global
    InMode := false
    Dragging := false
    Locked := false
    SnapPending := false
    BandHide()
    SetTimer(SnapAfterSettle, 0)
    SetTimer(UpdateBand, 0)
    if FrameCount = 0 {
        ShowTip()
        HUDClear()
        return
    }
    Busy := true
    ShowTip("拼接 " FrameCount " 帧中…")
    HUD()
    outDir := PicturesDir() "\" SaveSubDir
    DirCreate(outDir)
    PendingOut := outDir "\LongShot_" FormatTime(, "yyyyMMdd_HHmmss") ".png"
    PendingTemp := FrameDir
    FrameDir := ""     ; 移交给看护计时器，避免被 CancelAll 误删
    ps := A_ScriptDir "\stitch.ps1"
    Run('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' ps '" -Dir "' PendingTemp '" -OutFile "' PendingOut '" -CropTop ' CropTop, , "Hide", &StitchPid)
    SetTimer(CheckStitch, 500)
}

CheckStitch() {
    global
    if ProcessExist(StitchPid)
        return
    SetTimer(CheckStitch, 0)
    Busy := false
    noScroll := false
    noOverlap := false
    discont := 0
    statusFile := PendingTemp "\stitch_status.txt"
    if FileExist(statusFile) {
        try {
            st := FileRead(statusFile, "UTF-8")
            noScroll := InStr(st, "noscroll=1") > 0
            noOverlap := InStr(st, "nooverlap=1") > 0
            if RegExMatch(st, "discontinuities=(\d+)", &m)
                discont := Integer(m[1])
        }
    }
    if FileExist(PendingOut) {
        if noScroll {
            ShowTip("没有检测到滚动：所有帧内容完全相同，输出只是一张单帧截图。`n"
                . "常见原因：滚轮没滚到可滚动内容（把鼠标移到列表/正文上再滚），或目标窗口没拿到焦点。`n"
                . PendingOut "`n（帧保留在 " PendingTemp "）", 8000)
        } else if noOverlap {
            ShowTip("拼不起来：相邻两帧完全没有重叠。`n"
                . "原因是你两次截图之间滚得太多（超过了选框高度），画面中间那段没被拍到，补不回来。`n"
                . "办法：① 选框拉高一点（至少 600px）② 每次少滚一点/滚慢一点 ③ 重截一次。`n"
                . "本次结果（只能保守续接，会重复）在：" PendingOut, 9000)
        } else if KeepFrames {
            msg := "已保存并复制到剪贴板，可直接 Ctrl+V：`n" PendingOut "`n（调试：帧保留在 " PendingTemp "）"
            if (discont > 0)
                msg := "已保存并复制到剪贴板，但有 " discont " 处接缝没对齐（滚太快/选区太矮），`n"
                    . "这些位置是直接续接的，可能重复一小段。`n" PendingOut "`n（调试：帧保留在 " PendingTemp "）"
            ShowTip(msg, 5000)
        } else {
            DirDelete(PendingTemp, true)
            ShowTip("已保存并复制到剪贴板，可直接 Ctrl+V：`n" PendingOut, 4000)
        }
    } else {
        ShowTip("拼接失败，帧保留在：" PendingTemp, 5000)
    }
    PendingTemp := ""
    PendingOut := ""
    HUDClear()
}

CancelAll() {
    global
    InMode := false
    Dragging := false
    Locked := false
    SnapPending := false
    StaleCount := 0
    SetTimer(SnapAfterSettle, 0)
    SetTimer(UpdateBand, 0)
    BandHide()
    ShowTip()
    HUDClear()
    if FrameDir != "" && DirExist(FrameDir)
        DirDelete(FrameDir, true)
    FrameDir := ""
}

ShowTip(text := "", ms := 0) {
    ToolTip text
    if ms
        SetTimer(() => ToolTip(), -ms)
}

HUD() {
    global
    if !DebugHUD
        return
    ToolTip("[LongShot] mode=" (InMode ? 1 : 0) " drag=" (Dragging ? 1 : 0)
        " lock=" (Locked ? 1 : 0) " ticks=" TickCount " frames=" FrameCount
        " busy=" (Busy ? 1 : 0), 10, 10, 2)
}

HUDClear() {
    ToolTip(, , , 2)
}

BandShow(x, y, w, h, color) {
    global BandGuis
    if BandGuis.Length = 0 {
        Loop 4 {
            ; +E0x80000(WS_EX_LAYERED) +E0x20(WS_EX_TRANSPARENT)：必须组合使用才能真正穿透鼠标命中测试
            ; 否则选区边框会挡住光标处的滚轮消息，导致页面滚不动
            gg := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 +E0x80000 +Disabled")
            DllCall("SetLayeredWindowAttributes", "ptr", gg.Hwnd, "uint", 0, "uchar", 255, "uint", 2)
            BandGuis.Push(gg)
        }
    }
    t := 2
    specs := [[x, y, w, t], [x, y + h - t, w, t], [x, y, t, h], [x + w - t, y, t, h]]
    for i, gg in BandGuis {
        gg.BackColor := color
        gg.Show(Format("x{} y{} w{} h{} NoActivate", specs[i][1], specs[i][2], specs[i][3], specs[i][4]))
    }
    ; 自检：读回边框像素，确认框真的显示在屏幕上
    CoordMode "Pixel", "Screen"
    pc := "ERR"
    try pc := PixelGetColor(x + (w // 2), y + 1)
    try FileAppend(Format("band {1} {2}x{3} @({4},{5}) want={6} pixel={7}`n"
        , A_TickCount, w, h, x, y, color, pc), A_Temp "\LongShot_band.log", "UTF-8")
}

BandHide() {
    global BandGuis
    for gg in BandGuis
        gg.Hide()
}

PicturesDir() {
    try
        return ComObject("Shell.Application").NameSpace(0x27).Self.Path
    catch {
        return EnvGet("USERPROFILE") "\Pictures"
    }
}

GdipStartup() {
    si := Buffer(24, 0)
    NumPut("uint", 1, si, 0)
    DllCall("gdiplus\GdiplusStartup", "ptr*", &token := 0, "ptr", si, "ptr", 0)
}

PngEncoder() {
    static b := 0
    if !IsObject(b) {
        b := Buffer(16)
        hex := "06 F4 7C 55 04 1A D3 11 9A 73 00 00 F8 1E F3 2E"
        i := 0
        for hb in StrSplit(hex, " ") {
            NumPut("uchar", Integer("0x" hb), b, i)
            i++
        }
    }
    return b
}

CaptureRect(x, y, w, h, file) {
    hdcS := DllCall("GetDC", "ptr", 0, "ptr")
    hdcM := DllCall("CreateCompatibleDC", "ptr", hdcS, "ptr")
    hbm := DllCall("CreateCompatibleBitmap", "ptr", hdcS, "int", w, "int", h, "ptr")
    obm := DllCall("SelectObject", "ptr", hdcM, "ptr", hbm, "ptr")
    DllCall("gdi32\BitBlt", "ptr", hdcM, "int", 0, "int", 0, "int", w, "int", h
        , "ptr", hdcS, "int", x, "int", y, "uint", 0x00CC0020)
    DllCall("SelectObject", "ptr", hdcM, "ptr", obm)
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "ptr", hbm, "ptr", 0, "ptr*", &pBit := 0)
    DllCall("DeleteObject", "ptr", hbm)
    DllCall("DeleteDC", "ptr", hdcM)
    DllCall("ReleaseDC", "ptr", 0, "ptr", hdcS)
    if !pBit
        return false
    DllCall("gdiplus\GdipSaveImageToFile", "ptr", pBit, "wstr", file, "ptr", PngEncoder(), "ptr", 0)
    DllCall("gdiplus\GdipDisposeImage", "ptr", pBit)
    return true
}
