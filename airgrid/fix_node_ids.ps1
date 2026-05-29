#!/usr/bin/env pwsh
# Fix all hardcoded node IDs in mesh_service_test.dart

$file = "test/domain/mesh_service_test.dart"
$content = Get-Content $file -Raw

# Replace all hardcoded node IDs with UUID-generating constants
$replacements = @{
    "'remote-node'" = "_remoteNodeId"
    "'local-node'" = "_localNodeId"
    '"remote-node"' = "_remoteNodeId"
    '"local-node"' = "_localNodeId"
    "'peer-node-1'" = "testNodeId('peer-1')"
    "'peer-node-2'" = "testNodeId('peer-2')"
    "'mixed-node'" = "testNodeId('mixed')"
    "'node-ka'" = "testNodeId('ka')"
    "'node-abc'" = "testNodeId('abc')"
    "'node-xyz'" = "testNodeId('xyz')"
}

foreach ($key in $replacements.Keys) {
    $content = $content -replace [regex]::Escape($key), $replacements[$key]
}

# Handle const keyword before arrays
$content = $content -replace 'const \[_remoteNodeId\]', '[$_remoteNodeId]'
$content = $content -replace 'const \[_localNodeId\]', '[$_localNodeId]'

$content | Set-Content $file -NoNewline

Write-Host "Fixed node IDs in $file"
