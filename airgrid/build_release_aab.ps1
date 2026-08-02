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

    # ── ABI guard ────────────────────────────────────────────────────────────
    # A Gradle init script that pins abiFilters can silently strip an ABI from
    # the bundle. Nothing in the build fails when that happens; the upload
    # succeeds and 32-bit devices simply stop being served. This was a live
    # hazard while the project was built on an aarch64 Linux box, which needed
    # exactly such a script to link at all. Verify the artifact rather than
    # trusting the environment that produced it.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($artifact.FullName)
    try {
      $abis = $zip.Entries |
        Where-Object { $_.FullName -match '(^|/)lib/([^/]+)/' } |
        ForEach-Object { [regex]::Match($_.FullName, '(^|/)lib/([^/]+)/').Groups[2].Value } |
        Sort-Object -Unique
    }
    finally {
      $zip.Dispose()
    }

    Write-Host "AAB ABIs: $($abis -join ', ')"

    $requiredAbis = @('arm64-v8a', 'armeabi-v7a')
    $missingAbis = $requiredAbis | Where-Object { $abis -notcontains $_ }
    if ($missingAbis) {
      throw ("AAB is missing required ABI(s): {0}. Present: {1}. " -f
        ($missingAbis -join ', '), ($abis -join ', ')) +
        'Do not upload this bundle. Check for a Gradle init script pinning ' +
        'abiFilters (~/.gradle/init.d/) or an ndk.abiFilters block in ' +
        'android/app/build.gradle.'
    }
    Write-Host 'ABI check passed: 32-bit and 64-bit ARM both present.'
  } else {
    Write-Warning "AAB not found at $aabPath"
  }
}
finally {
  Pop-Location
}
