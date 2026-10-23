# Run from any directory. Only the reviewed vendor folder is included.
$ErrorActionPreference = 'Stop'
$vendorFolder = Join-Path $PSScriptRoot 'print-order-r2'
$vendorArchive = Join-Path $PSScriptRoot 'SimpleLay_vendor_first_print_R2.zip'
$requiredFiles = @(
    '01_left_shell_r2.stl', '02_panel_clip.stl', 'README.md',
    'preview_interior.png', 'simplelay_box.scad', 'vendor-first-print-2026-10-23.scad'
)
foreach ($vendorFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $vendorFolder $vendorFile) -PathType Leaf)) {
        throw "Missing vendor file: $vendorFile"
    }
}
$actualFiles = @(Get-ChildItem -LiteralPath $vendorFolder -Force)
if ($actualFiles.Count -ne $requiredFiles.Count -or
    @($actualFiles | Where-Object { $_.PSIsContainer -or $_.Name -notin $requiredFiles }).Count -ne 0) {
    throw 'Unexpected file in vendor folder; inspect before sending.'
}
Compress-Archive -LiteralPath $vendorFolder -DestinationPath $vendorArchive -Force
Write-Output "Vendor archive ready: $vendorArchive"
