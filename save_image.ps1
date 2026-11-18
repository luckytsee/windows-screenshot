param([string]$OutFile)
Add-Type -AssemblyName System.Windows.Forms
$img = [System.Windows.Forms.Clipboard]::GetImage()
if ($null -ne $img) {
    $img.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Output "OK"
} else {
    Write-Output "NO_IMAGE"
}
