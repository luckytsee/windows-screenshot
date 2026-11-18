#Requires AutoHotkey v2.0
#SingleInstance Force
SendMode "Input"
SetKeyDelay -1

ScriptDir := A_ScriptDir

#HotIf WinActive("ahk_class CabinetWClass") || WinActive("ahk_class ExploreWClass") || WinActive("ahk_class Progman") || WinActive("ahk_class WorkerW")
$^v:: PasteHandler()
#HotIf

PasteHandler() {
    ; 剪贴板里是文件 → 保持 Windows 原本的粘贴行为
    if DllCall("IsClipboardFormatAvailable", "UInt", 15)  ; CF_HDROP
        return Send("^v")
    ; 剪贴板里没有图片 → 也保持原行为（比如粘贴文本会走 Explorer 的"粘贴快捷方式"等）
    hasBitmap := DllCall("IsClipboardFormatAvailable", "UInt", 2)   ; CF_BITMAP
        || DllCall("IsClipboardFormatAvailable", "UInt", 8)        ; CF_DIB
        || DllCall("IsClipboardFormatAvailable", "UInt", 17)       ; CF_DIBV5
    if !hasBitmap
        return Send("^v")

    folder := ExplorerFolder()
    if (folder = "")
        return Send("^v")

    name := "Screenshot_" . FormatTime(, "yyyyMMdd_HHmmss") . ".png"
    file := folder "\" name
    if FileExist(file)
        file := folder "\" . "Screenshot_" . FormatTime(, "yyyyMMdd_HHmmss") . "_" . A_MSec . ".png"

    ps := ScriptDir "\save_image.ps1"
    ToolTip("Saving image...")
    try {
        RunWait('powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "' ps '" -OutFile "' file '"', , "Hide")
    } catch as e {
        ToolTip()
        return Send("^v")
    }
    ToolTip()
    if FileExist(file) {
        ToolTip("Saved: " name)
        SetTimer(() => ToolTip(), -1500)
    } else {
        ToolTip("Failed to save image")
        SetTimer(() => ToolTip(), -1500)
    }
}

; 获取当前 Explorer 窗口打开的文件夹路径；桌面则返回桌面路径
ExplorerFolder() {
    hwnd := WinExist("A")
    if WinActive("ahk_class Progman") || WinActive("ahk_class WorkerW")
        return A_Desktop
    try {
        for window in ComObject("Shell.Application").Windows {
            if (window.hwnd = hwnd)
                return window.Document.Folder.Self.Path
        }
    } catch {
    }
    return ""
}
