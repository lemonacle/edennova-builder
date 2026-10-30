# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param([string]$PristineSource, [string]$Git = 'git')
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Build.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }

# Exercise the same guarded edit function used by the builder, without running setup.
$functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Replace-Once' }, $true)
Invoke-Expression $functionAst.Extent.Text
if ((Replace-Once 'before VALUE after' 'VALUE' 'NEW') -ne 'before NEW after') { throw 'Exact edit failed.' }
foreach ($unexpected in @('missing', 'VALUE and VALUE')) {
    $rejected = $false
    try { $null = Replace-Once $unexpected 'VALUE' 'NEW' } catch { $rejected = $true }
    if (-not $rejected) { throw 'Changed upstream layout was not rejected.' }
}
Write-Host 'PASS: PowerShell syntax and fail-closed branding edits.'

$allowed = @('.gitattributes','.gitignore','Build EdenNova.cmd','LICENSE','README.md','builder.json','docs/MAINTAINING.md','docs/MEMORY-FIX.md','patches/in-place-text-patches.patch','scripts/Build.ps1','scripts/Test-Builder.ps1')
$tracked = & $Git -C $repo ls-files
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect tracked repository files.' }
foreach ($file in $tracked) {
    if ($file -notin $allowed) { throw "Unexpected tracked file: $file" }
}
$privatePaths = @('local.settings.json','.local/signing/edennova.keystore','.local/signing/key.json','output/EdenNova.apk','logs/build.txt','source-download/eden-nightly.zip','.clean-setup-test/sources/test.cpp')
foreach ($file in $privatePaths) {
    & $Git -C $repo check-ignore --quiet $file
    if ($LASTEXITCODE -ne 0) { throw "Private artifact is not ignored: $file" }
}
Write-Host 'PASS: publication allowlist excludes keys, downloaded source, APKs, local settings, and logs.'

if ($PristineSource) {
    $temp = Join-Path $repo ('.test-runs/' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $temp | Out-Null
    $files = @('src/core/loader/nso.cpp','src/core/file_sys/patch_manager.cpp','src/core/file_sys/patch_manager.h','src/core/file_sys/ips_layer.cpp','src/core/file_sys/ips_layer.h')
    foreach ($file in $files) {
        $destination = Join-Path $temp $file
        New-Item -ItemType Directory -Force (Split-Path $destination) | Out-Null
        Copy-Item -LiteralPath (Join-Path $PristineSource $file) -Destination $destination
    }
    & $Git -C $temp init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Test repository setup failed.' }
    $patch = Join-Path $repo 'patches/in-place-text-patches.patch'
    & $Git -C $temp apply --check $patch
    if ($LASTEXITCODE -ne 0) { throw 'Patch does not apply to the pinned pristine source.' }
    & $Git -C $temp apply $patch
    if ($LASTEXITCODE -ne 0) { throw 'Patch application failed.' }
    & $Git -C $temp apply --reverse --check $patch
    if ($LASTEXITCODE -ne 0) { throw 'Prepared-source validation failed.' }
    & $Git -C $temp apply --reverse $patch
    if ($LASTEXITCODE -ne 0) { throw 'Reverse patch failed.' }
    foreach ($file in $files) {
        if ((Get-FileHash (Join-Path $temp $file)).Hash -ne (Get-FileHash (Join-Path $PristineSource $file)).Hash) { throw "Patch round trip changed pristine source: $file" }
    }
    # Simulate incompatible upstream source and require rejection.
    $loader = Join-Path $temp 'src/core/loader/nso.cpp'
    $text = [IO.File]::ReadAllText($loader).Replace('pi_header', 'changed_upstream_image')
    [IO.File]::WriteAllText($loader, $text)
    $priorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $null = & $Git -C $temp apply --check $patch 2>&1
    $rejectionCode = $LASTEXITCODE
    $ErrorActionPreference = $priorPreference
    if ($rejectionCode -eq 0) { throw 'Unexpectedly accepted incompatible upstream source.' }
    Write-Host 'PASS: patch application, repeat-build validation, exact reversal, and incompatible-source rejection.'
}
