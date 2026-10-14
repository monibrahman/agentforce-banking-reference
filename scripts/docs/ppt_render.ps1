param([string]$PptPath, [string]$OutDir)
# Exports every slide of a .pptx to PNG through PowerPoint (COM), for the visual layout check.
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$app = New-Object -ComObject PowerPoint.Application
try {
    $pres = $app.Presentations.Open($PptPath, $true, $false, $false)   # read-only, untitled, no window
    $i = 0
    foreach ($slide in $pres.Slides) {
        $i++
        $slide.Export((Join-Path $OutDir ('slide_{0:D2}.png' -f $i)), 'PNG', 1600, 900)
    }
    "slides: $i"
    $pres.Close()
} finally {
    $app.Quit()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($app) | Out-Null
}
