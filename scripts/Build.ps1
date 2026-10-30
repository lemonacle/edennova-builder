# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param([switch]$PrepareOnly, [string]$DataRoot, [switch]$NoOpenFolder)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repo = Split-Path $PSScriptRoot -Parent
$config = Get-Content (Join-Path $repo 'builder.json') -Raw | ConvertFrom-Json
$local = @{}
$localFile = Join-Path $repo 'local.settings.json'
if (Test-Path $localFile) {
    $obj = Get-Content $localFile -Raw | ConvertFrom-Json
    foreach ($property in $obj.PSObject.Properties) { $local[$property.Name] = $property.Value }
}
if ($DataRoot -and $local.dataRoot -and ([IO.Path]::GetFullPath($DataRoot) -ne [IO.Path]::GetFullPath($local.dataRoot))) {
    # A deliberately separate data directory has its own signing identity.
    $local.Remove('expectedCertificate')
}
if (-not $DataRoot) {
    if ($local.dataRoot) { $DataRoot = $local.dataRoot }
    else { $DataRoot = Join-Path $repo '.local' }
}
$DataRoot = [IO.Path]::GetFullPath($DataRoot)
$logDir = Join-Path $repo 'logs'
$outputDir = Join-Path $repo 'output'
New-Item -ItemType Directory -Force $DataRoot,$logDir,$outputDir | Out-Null
$logPath = Join-Path $logDir ('build-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
$mappedDrive = $null
$locationPushed = $false
$buildLock = $null
$gradle = $null
$transcribing = $false

function Say([string]$Message) { Write-Host "`n== $Message ==" -ForegroundColor Cyan }
function Write-Utf8([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}
function Run([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Exe" }
}
function Fetch([string]$Url, [string]$Path, [string]$Hash, [string]$Algorithm = 'SHA256') {
    if (Test-Path $Path) {
        if ((Get-FileHash $Path -Algorithm $Algorithm).Hash -eq $Hash) { return }
        throw "Cached download has the wrong hash: $Path. Move it aside and retry."
    }
    Write-Host "Downloading $(Split-Path $Path -Leaf)..."
    $temporary = "$Path.partial"
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $temporary
    if ((Get-FileHash $temporary -Algorithm $Algorithm).Hash -ne $Hash) {
        throw "Download verification failed: $Url. The file was not executed."
    }
    Move-Item -LiteralPath $temporary -Destination $Path
}
function Replace-Once([string]$Text, [string]$Before, [string]$After) {
    if (($Text.Split(@($Before), [StringSplitOptions]::None)).Count -ne 2) {
        throw "Upstream build configuration changed; expected one occurrence of: $Before"
    }
    return $Text.Replace($Before, $After)
}
function Assert-UnderRoot([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($script:root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Working path is outside the builder data directory: $Path"
    }
}

try {
    Start-Transcript -Path $logPath | Out-Null
    $transcribing = $true
    $buildLock = [IO.File]::Open((Join-Path $DataRoot 'builder.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell on x64 Windows.' }
    if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'This builder currently supports x64 Windows PCs.' }

    # A short alias avoids native Windows compiler path-length failures.
    $existing = @(subst)
    foreach ($letter in @('N','O','P','Q','R','S','T','U','V','W','X','Y','Z')) {
        $match = $existing | Where-Object { $_ -like ($letter + ':\: => *') }
        if ($match -and (($match -replace '^.:\\: => ', '').TrimEnd('\') -eq $DataRoot.TrimEnd('\'))) {
            $root = $letter + ':\'; break
        }
        if (-not (Test-Path ($letter + ':\'))) {
            Run 'subst.exe' @(($letter + ':'), $DataRoot)
            $mappedDrive = $letter + ':'
            $root = $letter + ':\'; break
        }
    }
    if (-not $root) { throw 'No free drive letter N: through Z: is available.' }
    Say "Preparing $($config.nightlyName)"
    Write-Host "Source: $($config.sourceUrl)"
    Write-Host "Data stays here: $DataRoot"
    Write-Host "Full log: $logPath"
    $tools = Join-Path $root 'build-tools'
    $downloads = Join-Path $root 'downloads'
    New-Item -ItemType Directory -Force $tools,$downloads | Out-Null

    # All executable bootstrap downloads have pinned upstream checksums.
    $gitRoot = Join-Path $tools 'portable-git'
    $git = Join-Path $gitRoot 'cmd/git.exe'
    $patchExe = Join-Path $gitRoot 'usr/bin/patch.exe'
    if (-not (Test-Path $git) -or -not (Test-Path $patchExe)) {
        $archive = Join-Path $downloads 'portable-git.7z.exe'
        Fetch $config.gitUrl $archive $config.gitSha256
        $extractor = Start-Process -FilePath $archive -ArgumentList @('-y', ('-o"' + $gitRoot + '"')) -Wait -PassThru -WindowStyle Hidden
        if ($extractor.ExitCode -ne 0) { throw "Portable Git extraction failed: $($extractor.ExitCode)" }
    }
    if (-not (Test-Path $patchExe)) { throw 'Portable Git did not supply patch.exe.' }
    $javaRoot = Join-Path $tools 'java'
    $java = Get-ChildItem $javaRoot -Directory -ErrorAction SilentlyContinue | Where-Object Name -Like 'jdk-17*' | Select-Object -First 1
    if (-not $java -or -not (Test-Path (Join-Path $java.FullName 'bin/java.exe'))) {
        $archive = Join-Path $downloads 'jdk17.zip'
        Fetch $config.jdkUrl $archive $config.jdkSha256
        Expand-Archive $archive $javaRoot -Force
        $java = Get-ChildItem $javaRoot -Directory | Where-Object Name -Like 'jdk-17*' | Select-Object -First 1
    }
    $env:JAVA_HOME = $java.FullName
    $env:PATH = "$env:JAVA_HOME\bin;$gitRoot\cmd;$gitRoot\usr\bin;$env:PATH"
    $sdk = Join-Path $tools 'android-sdk'
    $androidCli = Join-Path $sdk 'cmdline-tools/latest/bin/android.exe'
    if (-not (Test-Path $androidCli)) {
        $archive = Join-Path $downloads 'android-commandline.zip'
        Fetch $config.sdkToolsUrl $archive $config.sdkToolsSha1 'SHA1'
        $staging = Join-Path $tools ('sdk-extract-' + [guid]::NewGuid().ToString('N'))
        Expand-Archive $archive $staging
        New-Item -ItemType Directory -Force (Join-Path $sdk 'cmdline-tools') | Out-Null
        Move-Item -LiteralPath (Join-Path $staging 'cmdline-tools') -Destination (Join-Path $sdk 'cmdline-tools/latest')
    }
    $env:ANDROID_HOME = $sdk
    $env:ANDROID_SDK_ROOT = $sdk
    $env:GRADLE_USER_HOME = Join-Path $tools 'gradle-cache'
    $packages = @(
        @{ id = "platforms;android-$($config.platform)"; path = "platforms/android-$($config.platform)/android.jar" },
        @{ id = "build-tools;$($config.buildTools)"; path = "build-tools/$($config.buildTools)/apksigner.bat" },
        @{ id = "ndk;$($config.ndk)"; path = "ndk/$($config.ndk)/source.properties" },
        @{ id = "cmake;$($config.cmake)"; path = "cmake/$($config.cmake)/bin/cmake.exe" }
    )
    foreach ($package in $packages) {
        if (-not (Test-Path (Join-Path $sdk $package.path))) {
            Say "Installing Android $($package.id)"
            Run $androidCli @('--no-metrics', "--sdk=$sdk", 'sdk', 'install', $package.id)
            if (-not (Test-Path (Join-Path $sdk $package.path))) { throw "SDK package installation incomplete: $($package.id)" }
        }
    }
    $shaderCompiler = Join-Path $tools 'glslang/bin/glslang.exe'
    if (-not (Test-Path $shaderCompiler)) {
        $archive = Join-Path $downloads 'glslang.zip'
        Fetch $config.glslangUrl $archive $config.glslangSha256
        Expand-Archive $archive (Join-Path $tools 'glslang') -Force
    }
    Say 'Checking the shader compiler'
    Run $shaderCompiler @('--version')
    $env:PATH = "$(Join-Path $sdk ('cmake/' + $config.cmake + '/bin'));$env:PATH"

    Say 'Preparing a separate source copy'
    $source = Join-Path $root ('sources/' + $config.revision)
    Assert-UnderRoot $source
    $patchPath = Join-Path $repo 'patches/in-place-text-patches.patch'
    $patchHash = (Get-FileHash $patchPath).Hash
    if (-not (Test-Path $source)) {
        $archive = Join-Path $downloads 'eden-nightly.zip'
        $manualArchive = Join-Path $repo 'source-download/eden-nightly.zip'
        if (Test-Path $manualArchive) {
            if ((Get-FileHash $manualArchive).Hash -ne $config.sourceSha256) { throw 'Manual source ZIP is not the exact pinned archive. See README.' }
            Copy-Item -LiteralPath $manualArchive -Destination $archive -Force
        }
        Fetch $config.sourceUrl $archive $config.sourceSha256
        $staging = Join-Path $root ('source-extract-' + [guid]::NewGuid().ToString('N'))
        Expand-Archive $archive $staging
        $extracted = Join-Path $staging ('mirror-' + $config.revision)
        if (-not (Test-Path (Join-Path $extracted 'CMakeLists.txt'))) { throw 'Unexpected source archive layout.' }
        New-Item -ItemType Directory -Force (Split-Path $source) | Out-Null
        Move-Item -LiteralPath $extracted -Destination $source
    }
    # Prevent git apply from finding a parent repository when using an archive.
    if (-not (Test-Path (Join-Path $source '.git'))) { Run $git @('-C', $source, 'init', '--quiet') }
    $marker = Join-Path $source '.edennova-prepared.json'
    $gradlePath = Join-Path $source 'src/android/app/build.gradle.kts'
    $gradleText = Get-Content $gradlePath -Raw
    if (-not (Test-Path $marker)) {
        Run $git @('-C', $source, 'apply', '--check', $patchPath)
        # Validate all branding edits before mutating source files.
        $gradleText = Replace-Once $gradleText 'applicationId = "dev.eden.eden_emulator"' 'applicationId = "dev.eden.edennova"'
        $gradleText = Replace-Once $gradleText 'versionName = getGitVersion()' 'versionName = "EdenNova-local"'
        $gradleText = Replace-Once $gradleText 'versionCode = autoVersion' 'versionCode = 34007367'
        $gradleText = Replace-Once $gradleText 'manifestPlaceholders += mapOf("appNameBase" to "Eden")' 'manifestPlaceholders += mapOf("appNameBase" to "EdenNova")'
        $gradleText = Replace-Once $gradleText 'resValue("string", "app_name", "Eden$suffix")' 'resValue("string", "app_name", "$currentName$suffix")'
        Run $git @('-C', $source, 'apply', $patchPath)
        Write-Utf8 $gradlePath $gradleText
        Write-Utf8 $marker (@{ revision = $config.revision; patchSha256 = $patchHash } | ConvertTo-Json)
    } else {
        $prepared = Get-Content $marker -Raw | ConvertFrom-Json
        if ($prepared.revision -ne $config.revision -or $prepared.patchSha256 -ne $patchHash) { throw 'Prepared source does not match this builder. Use a new data folder.' }
        Run $git @('-C', $source, 'apply', '--reverse', '--check', $patchPath)
    }
    Write-Utf8 (Join-Path $source 'GIT-COMMIT') $config.revision
    Write-Utf8 (Join-Path $source 'GIT-REFSPEC') 'edennova-local'
    Write-Utf8 (Join-Path $source 'GIT-TAG') ($config.revision.Substring(0,10))
    if ($gradleText -notmatch ('ndkVersion = "' + [regex]::Escape($config.ndk) + '"')) { throw 'Upstream NDK requirement changed. Update the builder manifest first.' }

    Say 'Preparing the local signing key'
    $signing = Join-Path $root 'signing'
    New-Item -ItemType Directory -Force $signing | Out-Null
    $keyFile = Join-Path $signing 'edennova.keystore'
    $keySettings = Join-Path $signing 'key.json'
    if ((Test-Path $keyFile) -ne (Test-Path $keySettings)) { throw 'Signing backup is incomplete. Restore both edennova.keystore and key.json. A replacement key would not update your app.' }
    if (-not (Test-Path $keyFile)) {
        $randomBytes = New-Object byte[] 32
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($randomBytes); $rng.Dispose()
        $key = @{ alias = 'edennova'; password = [Convert]::ToBase64String($randomBytes) }
        Write-Utf8 $keySettings ($key | ConvertTo-Json)
        $env:EDENNOVA_KEY_PASSWORD = $key.password
        Run (Join-Path $env:JAVA_HOME 'bin/keytool.exe') @('-genkeypair','-keystore',$keyFile,'-storetype','PKCS12','-alias',$key.alias,'-storepass:env','EDENNOVA_KEY_PASSWORD','-keypass:env','EDENNOVA_KEY_PASSWORD','-keyalg','RSA','-keysize','3072','-validity','10000','-dname','CN=EdenNova Local Build')
    }
    $key = Get-Content $keySettings -Raw | ConvertFrom-Json
    $env:ANDROID_KEYSTORE_FILE = $keyFile
    $env:ANDROID_KEYSTORE_PASS = $key.password
    $env:ANDROID_KEY_ALIAS = $key.alias
    $env:EDENNOVA_KEY_PASSWORD = $key.password
    $cert = Join-Path $signing 'certificate.der'
    Run (Join-Path $env:JAVA_HOME 'bin/keytool.exe') @('-exportcert','-keystore',$keyFile,'-alias',$key.alias,'-storepass:env','EDENNOVA_KEY_PASSWORD','-file',$cert)
    $certHash = (Get-FileHash $cert).Hash.ToLowerInvariant()
    if ($local.expectedCertificate -and $certHash -ne $local.expectedCertificate) { throw 'Signing certificate differs from the installed EdenNova. Stopping instead of making an incompatible update.' }

    $lastVersionFile = Join-Path $signing 'last-version-code.txt'
    $version = [long][math]::Floor(([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1451606400) / 10)
    $version = [math]::Max($version, 34007367)
    if (Test-Path $lastVersionFile) { $version = [math]::Max($version, ([long](Get-Content $lastVersionFile) + 1)) }
    $versionName = 'EdenNova-' + $config.revision.Substring(0,10) + '-memory2'
    $gradleText = [regex]::Replace($gradleText, 'versionName = "EdenNova-[^"]+"', ('versionName = "' + $versionName + '"'))
    $gradleText = [regex]::Replace($gradleText, 'versionCode = \d+', ('versionCode = ' + $version))
    Write-Utf8 $gradlePath $gradleText
    Write-Utf8 (Join-Path $source 'src/android/local.properties') ('sdk.dir=' + $sdk.Replace('\','/'))
    if ($PrepareOnly) { Say 'Preparation verified. No APK was compiled.'; exit 0 }

    Say 'Compiling EdenNova (the first build takes the longest)'
    $env:CMAKE_BUILD_PARALLEL_LEVEL = '4'
    $gradle = Join-Path $source 'src/android/gradlew.bat'
    $argsCmake = '-PYUZU_ANDROID_ARGS=-DENABLE_UPDATE_CHECKER=OFF -DGLSLANGVALIDATOR=' + $shaderCompiler.Replace('\','/') + ' -DPATCH_EXE=' + $patchExe.Replace('\','/')
    Push-Location (Join-Path $source 'src/android'); $locationPushed = $true
    Run $gradle @('assembleMainlineRelease', $argsCmake, '--console=plain', '--max-workers=4', '-Dorg.gradle.jvmargs=-Xmx4g -XX:MaxMetaspaceSize=1g -Dfile.encoding=UTF-8')
    Pop-Location; $locationPushed = $false

    Say 'Verifying the APK and update identity'
    $apk = Join-Path $source 'src/android/app/build/outputs/apk/mainline/release/app-mainline-release.apk'
    $signer = Join-Path $sdk ('build-tools/' + $config.buildTools + '/apksigner.bat')
    $signature = & $signer verify --verbose --print-certs $apk
    if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed.' }
    if (($signature -join "`n") -notmatch [regex]::Escape($certHash)) { throw 'APK was signed with an unexpected key.' }
    $aapt = Join-Path $sdk ('build-tools/' + $config.buildTools + '/aapt.exe')
    $metadata = & $aapt dump badging $apk
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read APK metadata.' }
    $metadataText = $metadata -join "`n"
    if ($metadataText -notmatch "package: name='dev.eden.edennova' versionCode='$version'" -or $metadataText -notmatch "application-label:'EdenNova'" -or $metadataText -notmatch "native-code: 'arm64-v8a'" -or $metadataText -notmatch "sdkVersion:'33'") { throw 'APK identity or device compatibility verification failed.' }
    $finalApk = Join-Path $outputDir ($versionName + '.apk')
    Copy-Item -LiteralPath $apk -Destination $finalApk -Force
    $apkHash = (Get-FileHash $finalApk).Hash.ToLowerInvariant()
    Write-Utf8 ($finalApk + '.sha256') ($apkHash + '  ' + (Split-Path $finalApk -Leaf) + "`n")
    Write-Utf8 (Join-Path $outputDir 'build-info.json') (@{ revision = $config.revision; nightly = $config.nightlyName; package = 'dev.eden.edennova'; versionCode = $version; versionName = $versionName; certificateSha256 = $certHash; apkSha256 = $apkHash; patchSha256 = $patchHash.ToLowerInvariant(); deviceTested = $false } | ConvertTo-Json)
    Write-Utf8 (Join-Path $outputDir 'signature.txt') ($signature -join "`n")
    Write-Utf8 (Join-Path $outputDir 'apk-metadata.txt') $metadataText
    Write-Utf8 $lastVersionFile ([string]$version)
    Say 'SUCCESS - EdenNova APK is ready'
    Write-Host $finalApk
    Write-Host "Keep a backup of $DataRoot\signing for future updates."
    Write-Host 'Transfer the APK to your Android device and open it to install. Do not uninstall EdenNova first.'
    if (-not $NoOpenFolder) { Start-Process explorer.exe -ArgumentList ('"' + $outputDir + '"') }
} catch {
    Write-Host "`nBUILD STOPPED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Log: $logPath"
    exit 1
} finally {
    if ($locationPushed) { Pop-Location }
    if ($gradle) { & $gradle --stop 2>&1 | Out-Host }
    $env:ANDROID_KEYSTORE_PASS = $null
    $env:EDENNOVA_KEY_PASSWORD = $null
    if ($buildLock) { $buildLock.Dispose() }
    if ($mappedDrive) { & subst.exe $mappedDrive /D }
    if ($transcribing) { Stop-Transcript | Out-Null }
}
