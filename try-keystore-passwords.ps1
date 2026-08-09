# Offline password tester for your own upload keystore.
#
# Why this is worth a few minutes: PKCS12 password checking is a purely local MAC
# verification. No network, no rate limit, no lockout. Testing twenty candidates
# takes seconds — against a multi-day round trip with Google for another key reset.
#
# Passwords are typed as masked input and never written to disk, never echoed, and
# never included in the output. On a match the script prints only the certificate
# fingerprint, which is the thing you actually need to see.
#
# Usage:  powershell -ExecutionPolicy Bypass -File .\try-keystore-passwords.ps1
# Then type one candidate per prompt. Press Enter on an empty prompt to stop.

param(
    [string]$Keystore = "C:\Users\jayar\.android-keys\airgrid-upload-new.jks",
    [string]$Keytool  = "C:\Program Files\Microsoft\jdk-17.0.18.8-hotspot\bin\keytool.exe"
)

$ErrorActionPreference = 'Continue'
$TARGET = 'F6:C3:ED:19:D4:6A:FD:30:B2:23:31:43:4C:64:D7:19:0A:8D:6E:2F'

if (-not (Test-Path $Keystore)) { Write-Host "Keystore not found: $Keystore" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $Keytool))  { Write-Host "keytool not found: $Keytool"  -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "Keystore: $Keystore"
Write-Host "Looking for a certificate with SHA1: $TARGET"
Write-Host "Type each candidate and press Enter. Empty input stops."
Write-Host ""

function Test-StorePassword {
    param([string]$Plain)
    # 2>&1 is intentional here: keytool writes its failure to stderr and we only
    # want to know whether it succeeded, not show the user the noise.
    $null = & $Keytool -list -keystore $Keystore -storepass $Plain 2>&1
    return ($LASTEXITCODE -eq 0)
}

$attempt = 0
while ($true) {
    $attempt++
    $secure = Read-Host -Prompt "Candidate $attempt (Enter to stop)" -AsSecureString
    $bstr  = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

    if ([string]::IsNullOrEmpty($plain)) {
        Write-Host ""
        Write-Host "Stopped after $($attempt - 1) candidate(s). No match." -ForegroundColor Yellow
        Write-Host "If you have exhausted your ideas, the answer is a fresh key plus a"
        Write-Host "second upload key reset. Do not revert to the old A4:3F key."
        break
    }

    if (Test-StorePassword -Plain $plain) {
        Write-Host ""
        Write-Host "MATCH on candidate $attempt." -ForegroundColor Green
        Write-Host "Certificate details:" -ForegroundColor Green

        $details = & $Keytool -list -v -keystore $Keystore -storepass $plain 2>$null
        $alias = ($details | Select-String -Pattern '^Alias name:').Line
        $sha1  = ($details | Select-String -Pattern 'SHA1:').Line
        if ($alias) { Write-Host "  $($alias.Trim())" }
        if ($sha1)  { Write-Host "  $($sha1.Trim())" }

        if ($sha1 -and $sha1 -match [regex]::Escape($TARGET)) {
            Write-Host ""
            Write-Host "This IS the key Play expects. You are unblocked." -ForegroundColor Green
            Write-Host "Next: put this password and the alias into"
            Write-Host "  airgrid\android\key.properties"
            Write-Host "with storeFile pointing at this keystore, then rebuild."
            Write-Host "Record the password in your password manager NOW, before anything else."
        } else {
            Write-Host ""
            Write-Host "Password is correct, but this is NOT the certificate Play expects." -ForegroundColor Yellow
            Write-Host "The real upload key is therefore somewhere else, or gone."
        }

        $plain = $null
        break
    }

    Write-Host "  no" -ForegroundColor DarkGray
    $plain = $null
}

Write-Host ""
