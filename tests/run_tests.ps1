# A339 PM tests without X-Plane : the bridge parser against tests\bridge_phrases.tsv, then tests\check_release.py
# (items, codes, Checklist Tuner collection, release archive). Windows PowerShell 5.1 or PowerShell 7.
#   powershell -File tests\run_tests.ps1            exit code 0 = all passed
#   powershell -File tests\run_tests.ps1 -Update    rewrite the expected results (review the diff before committing)
param([switch]$Update)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$bridge = Join-Path $root "src\A339_pm\si_bridge.ps1"
$cases = Join-Path $PSScriptRoot "bridge_phrases.tsv"
$failed = 0

# 1. the bridge : every phrase gives the expected result
$lines = Get-Content $cases -Encoding UTF8
$tests = @($lines | Where-Object { $_.Trim() -ne "" -and -not $_.StartsWith("#") } | ForEach-Object {
    $i = $_.LastIndexOf("`t"); @{ phrase = $_.Substring(0, $i); expected = $_.Substring($i + 1) } })
$inputs = Join-Path ([IO.Path]::GetTempPath()) "a339pm_test_inputs.txt"
[IO.File]::WriteAllLines($inputs, [string[]]@($tests | ForEach-Object { $_.phrase }), (New-Object Text.UTF8Encoding $false))
$shell = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh" } else { "powershell" }
$results = @(& $shell -NoProfile -ExecutionPolicy Bypass -File $bridge -Test $inputs -Tsv)
Remove-Item $inputs
if ($results.Count -ne $tests.Count) { Write-Host "bridge: $($results.Count) results for $($tests.Count) phrases" -ForegroundColor Red; exit 1 }

if ($Update) {
    $header = @($lines | Where-Object { $_.StartsWith("#") })
    [IO.File]::WriteAllLines($cases, [string[]]($header + $results), (New-Object Text.UTF8Encoding $false))
    Write-Host "bridge: $($results.Count) expected results rewritten - review the diff"
} else {
    for ($k = 0; $k -lt $tests.Count; $k++) {
        $got = $results[$k].Substring($results[$k].LastIndexOf("`t") + 1)
        if ($got -ne $tests[$k].expected) {
            $failed++
            Write-Host ("FAIL  '{0}'`n      expected: {1}`n      got:      {2}" -f $tests[$k].phrase, $tests[$k].expected, $got) -ForegroundColor Red
        }
    }
    Write-Host ("bridge: {0} phrases, {1} failed" -f $tests.Count, $failed) -ForegroundColor $(if ($failed) { "Red" } else { "Green" })
}

# 2. items, codes, collection, archive
$python = @("python", "py", "python3") | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
if ($python) {
    & $python (Join-Path $PSScriptRoot "check_release.py")
    if ($LASTEXITCODE -ne 0) { $failed++ }
} else { Write-Host "check_release.py skipped: no Python" -ForegroundColor Yellow }

if ($failed) { exit 1 }
