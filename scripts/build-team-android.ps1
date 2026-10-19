[CmdletBinding()]
param(
    [ValidateRange(1, 2100000000)]
    [int]$BuildNumber,
    [string]$UpdateFeedUrl = "",
    [string]$ReleaseNotes = "Omni Gears app update."
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ($ReleaseNotes.Length -gt 8000) { throw 'Release notes must be at most 8000 characters.' }
if ($UpdateFeedUrl) {
    $taskFeedUri = $null
    if (-not [Uri]::TryCreate($UpdateFeedUrl, [UriKind]::Absolute, [ref]$taskFeedUri) -or
        $taskFeedUri.Scheme -ne 'https' -or $taskFeedUri.UserInfo -or $taskFeedUri.Fragment) {
        throw 'UpdateFeedUrl must be an HTTPS address without embedded credentials or a fragment.'
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'android/key.properties'))) {
    throw 'Restore android/key.properties and the original team signing key from the private backup before building. Do not generate a replacement key for an existing app.'
}

$flutterCommand = Join-Path $projectRoot '.fvm/flutter_sdk/bin/flutter.bat'
if (-not (Test-Path -LiteralPath $flutterCommand)) {
    $flutterCommand = (Get-Command flutter -ErrorAction Stop).Source
}

Push-Location $projectRoot
try {
    $flutterArguments = @('--suppress-analytics', '--no-version-check', 'build', 'apk', '--release')
    if ($PSBoundParameters.ContainsKey('BuildNumber')) {
        $flutterArguments += "--build-number=$BuildNumber"
    }
    New-Item -ItemType Directory -Path 'build' -Force | Out-Null
    $taskDefines = @{ OMNI_UPDATE_FEED_URL = $UpdateFeedUrl } | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path $projectRoot 'build/omni-update-defines.json'), $taskDefines)
    $flutterArguments += '--dart-define-from-file=build/omni-update-defines.json'
    & $flutterCommand @flutterArguments
    if ($LASTEXITCODE -ne 0) { throw 'Android release build failed.' }

    $sdkLine = Get-Content -LiteralPath 'android/local.properties' |
        Where-Object { $_.StartsWith('sdk.dir=') } | Select-Object -First 1
    if (-not $sdkLine) { throw 'Android SDK path missing from android/local.properties.' }
    $sdkDirectory = $sdkLine.Substring(8).Replace('\\', '\').Replace('\:', ':')
    $buildTools = Get-ChildItem -LiteralPath (Join-Path $sdkDirectory 'build-tools') -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if (-not $buildTools) { throw 'Android SDK build tools are missing.' }

    $apk = Join-Path $projectRoot 'build/app/outputs/flutter-apk/app-release.apk'
    $signature = & (Join-Path $buildTools.FullName 'apksigner.bat') verify --verbose --print-certs $apk
    if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed.' }
    $signatureText = $signature -join "`n"
    $expectedSigningDigest = '56a4d068a74d6e220d9fca2de66fa2cb849f1c938a51931cca15e6bcb8bf781f'
    if ($signatureText -notmatch "Signer #1 certificate SHA-256 digest: $expectedSigningDigest(?:\r?\n|$)") {
        throw 'The APK was not signed with the original team certificate. Restore the original signing backup.'
    }

    $badging = & (Join-Path $buildTools.FullName 'aapt.exe') dump badging $apk
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the release APK.' }
    $badgingText = $badging -join "`n"
    if ($badgingText -notmatch "package: name='inventree.inventree_app.team' versionCode='(\d+)' versionName='([^']+)'") {
        throw 'The release APK does not have the expected team application ID.'
    }
    $actualBuild = $Matches[1]
    $actualVersion = $Matches[2]
    if ($badgingText -notmatch "sdkVersion:'(\d+)'") { throw 'Cannot inspect the minimum Android version.' }
    $actualMinSdk = [int]$Matches[1]
    if ($badgingText -notmatch "application-label:'Omni Gears'" -or $badgingText -match 'application-debuggable') {
        throw 'The APK must be a non-debuggable Omni Gears release.'
    }
    if ($badgingText -notmatch "launchable-activity: name='inventree.inventree_app.MainActivity'") {
        throw 'The team APK does not point to the expected launch activity.'
    }

    $releaseDirectory = Join-Path $projectRoot 'build/team-release'
    New-Item -ItemType Directory -Path $releaseDirectory -Force | Out-Null
    $fileName = "Omni-Gears-$actualVersion+$actualBuild.apk"
    $destination = Join-Path $releaseDirectory $fileName
    Copy-Item -LiteralPath $apk -Destination $destination -Force
    $checksum = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    [System.IO.File]::WriteAllText("$destination.sha256", "$checksum  $fileName`n")
    $taskManifest = [ordered]@{
        schemaVersion = 1
        packageId = 'inventree.inventree_app.team'
        version = $actualVersion
        buildNumber = [int]$actualBuild
        minSdk = $actualMinSdk
        apkUrl = $fileName
        sha256 = $checksum.ToLowerInvariant()
        sizeBytes = (Get-Item -LiteralPath $destination).Length
        releaseNotes = $ReleaseNotes
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path $releaseDirectory 'latest.json'), $taskManifest)
    $taskServerDirectory = Join-Path $projectRoot 'build/update-server'
    $taskPublicDirectory = Join-Path $taskServerDirectory 'public'
    New-Item -ItemType Directory -Path $taskPublicDirectory -Force | Out-Null
    Copy-Item -LiteralPath $destination -Destination $taskPublicDirectory -Force
    Copy-Item -LiteralPath (Join-Path $releaseDirectory 'latest.json') -Destination $taskPublicDirectory -Force
    Copy-Item -LiteralPath (Join-Path $projectRoot 'deploy/app-updates/compose.yaml') -Destination $taskServerDirectory -Force
    Copy-Item -LiteralPath (Join-Path $projectRoot 'deploy/app-updates/nginx.conf') -Destination $taskServerDirectory -Force
    $taskServerBundle = Join-Path $releaseDirectory "Omni-Gears-Update-Server-$actualVersion+$actualBuild.zip"
    Compress-Archive -LiteralPath @(
        (Join-Path $taskServerDirectory 'compose.yaml'),
        (Join-Path $taskServerDirectory 'nginx.conf'),
        $taskPublicDirectory
    ) -DestinationPath $taskServerBundle -CompressionLevel NoCompression -Force
    $instructions = @"
Omni Gears $actualVersion (build $actualBuild)

1. Copy $fileName to a private folder that your team can access.
2. On the Android phone or tablet, download the APK and open it.
3. If Android asks, allow the browser or Files app to install unknown apps.
4. Tap Install, then open Omni Gears.
5. Connect to your InvenTree server and sign in with your own account.
   Use the company network or VPN if the server is only available internally.

This is a separate app from public InvenTree and existing development installs.
Set up its server profile once on each device. Existing apps keep their own data.
If you already installed our InvenTree Team release, install this APK over it.
Your settings are retained and the app is renamed to Omni Gears.

Updates: Omni Gears can check for a newer version when you open the app.
Once your administrator has configured an update address, tap Update to download
the installer. On Android 8+, allow Omni Gears to install updates when prompted,
then return and tap Install update. Android asks you to confirm installation.
You can also check manually from Settings > About > App updates.
Until an update server is configured, download newer APKs from Teams as before.

Updates require the same signing key and a higher build number. Keep the app
installed to preserve its local settings.

Share only this APK, its checksum and these instructions. Signing keys and
passwords are private administrator files and are not included in this folder.

Application ID: inventree.inventree_app.team
SHA256: $checksum
"@
    [System.IO.File]::WriteAllText((Join-Path $releaseDirectory 'INSTALL.txt'), $instructions)
    Write-Output "Verified signed team installer: $destination"
    Write-Output "SHA256: $checksum"
    Write-Output "Update server files: $taskServerDirectory"
    if (-not $UpdateFeedUrl) {
        Write-Output 'No default update address configured. Set it in App updates, or provide -UpdateFeedUrl on the next build.'
    }
} finally {
    Pop-Location
}
