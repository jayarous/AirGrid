#!/usr/bin/env pwsh
# Fix remaining hardcoded node IDs in mesh_service_test.dart

$file = "test/domain/mesh_service_test.dart"
$content = Get-Content $file -Raw

# Replace remaining hardcoded node IDs
$replacements = @{
    "'peer-nc'" = "testNodeId('peer-nc')"
    "'peer-encrypted'" = "testNodeId('peer-encrypted')"
    '"peer-nc"' = "testNodeId('peer-nc')"
    '"peer-encrypted"' = "testNodeId('peer-encrypted')"
}

foreach ($key in $replacements.Keys) {
    $content = $content -replace [regex]::Escape($key), $replacements[$key]
}

$content | Set-Content $file -NoNewline

Write-Host "Fixed remaining node IDs in $file"
