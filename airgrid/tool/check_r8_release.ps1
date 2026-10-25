<#
.SYNOPSIS
  Checks the R8 output of the last release build for the things that would
  fail silently at runtime rather than at build time.

.DESCRIPTION
  Run from the airgrid/ directory after `flutter build apk --release` or
  `flutter build appbundle --release`. Exits 1 on the first problem.

  Checks:
    1. R8 reported no missing classes (missing_rules.txt absent or empty).
    2. The merged configuration contains the Tink protobuf field rule that
       keeps EncryptedSharedPreferences readable, and the app's own rules
       file was merged at all.
    3. The classes the app cannot run without survived shrinking, by name,
       in mapping.txt. These are the plugin entry points and the secure
       storage stack; losing any of them is a wiped identity or a dead
       plugin, not a crash.

  Re-run this after any AGP, Flutter, flutter_secure_storage, Tink or
  Play Billing upgrade, and after touching android/gradle.properties.
#>
[CmdletBinding()]
param(
    [string] $MappingDir = "build/app/outputs/mapping/release"
)

$ErrorActionPreference = "Stop"
$failed = $false

function Fail([string] $message) {
    Write-Host "FAIL  $message" -ForegroundColor Red
    $script:failed = $true
}

function Pass([string] $message) {
    Write-Host "ok    $message"
}

if (-not (Test-Path $MappingDir)) {
    Fail "$MappingDir not found. Build a release first."
    exit 1
}

# 1. No missing classes.
$missing = Join-Path $MappingDir "missing_rules.txt"
if ((Test-Path $missing) -and ((Get-Content $missing | Measure-Object -Line).Lines -gt 0)) {
    Fail "R8 reported missing classes; see $missing"
} else {
    Pass "no missing_rules.txt"
}

# 2. Merged configuration carries the rules that matter.
$configuration = Join-Path $MappingDir "configuration.txt"
$config = Get-Content $configuration -Raw
$requiredRules = @(
    @{ Name = "Tink shaded protobuf field rule";
       Pattern = "-keepclassmembers class \* extends com\.google\.crypto\.tink\.shaded\.protobuf\.GeneratedMessageLite" },
    @{ Name = "app proguard-rules.pro merged";
       Pattern = "app\\proguard-rules\.pro|app/proguard-rules\.pro" },
    @{ Name = "Flutter plugin keep rule";
       Pattern = "io\.flutter\.embedding\.engine\.plugins\.FlutterPlugin" }
)
foreach ($rule in $requiredRules) {
    if ($config -match $rule.Pattern) { Pass $rule.Name } else { Fail "$($rule.Name) is not in $configuration" }
}

# 3. Load-bearing classes survived, by original name.
$mapping = Join-Path $MappingDir "mapping.txt"
$kept = Get-Content $mapping | Where-Object { $_ -match "^[A-Za-z]" } | ForEach-Object { ($_ -split " -> ")[0] }
$keptSet = @{}
foreach ($k in $kept) { $keptSet[$k] = $true }

$mustSurvive = @(
    "io.flutter.plugins.GeneratedPluginRegistrant",
    "com.it_nomads.fluttersecurestorage.FlutterSecureStoragePlugin",
    "androidx.security.crypto.EncryptedSharedPreferences",
    "com.google.crypto.tink.integration.android.AndroidKeysetManager",
    "com.google.crypto.tink.aead.AesGcmKeyManager",
    "com.google.crypto.tink.daead.AesSivKeyManager",
    "com.pkmnapps.nearby_connections.NearbyConnectionsPlugin",
    "io.flutter.plugins.inapppurchase.InAppPurchasePlugin",
    "com.android.billingclient.api.BillingClientImpl",
    "com.tekartik.sqflite.SqflitePlugin",
    "com.airgrid.airgrid.MainActivity",
    "com.airgrid.airgrid.NearbyForegroundService"
)
foreach ($class in $mustSurvive) {
    if ($keptSet.ContainsKey($class)) { Pass $class } else { Fail "$class is not in $mapping (stripped or renamed away)" }
}

if ($failed) {
    Write-Host ""
    Write-Host "R8 release check FAILED." -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "R8 release check passed."
exit 0
