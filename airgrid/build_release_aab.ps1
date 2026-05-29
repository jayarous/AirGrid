param(
  [string]$VersionName,
  [int]$BuildNumber,
  [switch]$NoClean,
  [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$pubspecPath = Join-Path $repoRoot 'pubspec.yaml'

if (-not (Test-Path $pubspecPath)) {
  throw "Could not find pubspec.yaml at $pubspecPath"
}

$pubspecContent = Get-Content -Raw -Path $pubspecPath
$versionPattern = '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$'
$match = [regex]::Match($pubspecContent, $versionPattern)

if (-not $match.Success) {
  throw 'Could not parse version from pubspec.yaml. Expected format: version: x.y.z+n'
}

$currentVersionName = $match.Groups[1].Value
$currentBuildNumber = [int]$match.Groups[2].Value

function Increment-PatchVersion([string]$versionName) {
  $parts = $versionName.Split('.')
  if ($parts.Count -ne 3) {
    throw "Invalid semantic version '$versionName'. Expected x.y.z"
  }

  $major = [int]$parts[0]
  $minor = [int]$parts[1]
  $patch = [int]$parts[2]
  return "$major.$minor.$($patch + 1)"
}

if (-not $PSBoundParameters.ContainsKey('VersionName')) {
  $VersionName = Increment-PatchVersion $currentVersionName
}

if (-not $PSBoundParameters.ContainsKey('BuildNumber')) {
  $BuildNumber = $currentBuildNumber + 1
}

$newVersion = "$VersionName+$BuildNumber"
$newPubspecContent = [regex]::Replace(
  $pubspecContent,
  $versionPattern,
  "version: $newVersion",
  1
)

Set-Content -Path $pubspecPath -Value $newPubspecContent
Write-Host "Updated pubspec version: $currentVersionName+$currentBuildNumber -> $newVersion"

Push-Location $repoRoot
try {
  if (-not $NoBuild) {
    if (-not $NoClean) {
      flutter clean
    }

    flutter pub get
    flutter build appbundle --release
  }

  $aabPath = Join-Path $repoRoot 'build\app\outputs\bundle\release\app-release.aab'
  if (Test-Path $aabPath) {
    $artifact = Get-Item $aabPath
    Write-Host "AAB artifact: $($artifact.FullName)"
    Write-Host "AAB size: $($artifact.Length) bytes"
    Write-Host "AAB last modified: $($artifact.LastWriteTime)"
  } else {
    Write-Warning "AAB not found at $aabPath"
  }
}
finally {
  Pop-Location
}
