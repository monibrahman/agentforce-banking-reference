param([string]$DocPath, [string]$PdfPath)
# Opens the .docx in Word, updates the TOC and all fields (PAGE/NUMPAGES), saves, and exports a PDF for the layout check.
$ErrorActionPreference = 'Stop'
$word = New-Object -ComObject Word.Application
$word.Visible = $false
$word.DisplayAlerts = 0
try {
    $doc = $word.Documents.Open($DocPath, $false, $false)
    $doc.Repaginate()
    foreach ($toc in $doc.TablesOfContents) { $toc.Update() }
    $doc.Fields.Update() | Out-Null
    foreach ($s in $doc.Sections) {
        foreach ($h in $s.Headers) { $h.Range.Fields.Update() | Out-Null }
        foreach ($f in $s.Footers) { $f.Range.Fields.Update() | Out-Null }
    }
    foreach ($toc in $doc.TablesOfContents) { $toc.Update() }   # again, after page numbers settle
    $doc.Save()
    $doc.ExportAsFixedFormat($PdfPath, 17)   # wdExportFormatPDF
    "pages: " + $doc.ComputeStatistics(2)    # wdStatisticPages
    $doc.Close($false)
} finally {
    $word.Quit()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($word) | Out-Null
}
