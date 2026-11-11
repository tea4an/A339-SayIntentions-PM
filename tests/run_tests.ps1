# A339 PM tests without X-Plane : the bridge parser against tests\bridge_phrases*.tsv (bridge_phrases.tsv : A339 items,
# bridge_phrases_A321.tsv : A321 items), then tests\check_release.py (items, codes, Checklist Tuner collections, release
# archive). Windows PowerShell 5.1 or PowerShell 7.
#   powershell -File tests\run_tests.ps1            exit code 0 = all passed
#   powershell -File tests\run_tests.ps1 -Update    rewrite the expected results (review the diff before committing)
param([switch]$Update)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$bridge = Join-Path $root "src\A339_pm\si_bridge.ps1"
$shell = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh" } else { "powershell" }
$failed = 0

# 1. the bridge : every phrase gives the expected result, with that aircraft's items
foreach ($cases in Get-ChildItem $PSScriptRoot -Filter "bridge_phrases*.tsv" | Sort-Object Name) {
    $aircraft = if ($cases.BaseName -match "_(A\d+)$") { $Matches[1] } else { "A339" }
    $lines = Get-Content $cases.FullName -Encoding UTF8
    $tests = @($lines | Where-Object { $_.Trim() -ne "" -and -not $_.StartsWith("#") } | ForEach-Object {
        $i = $_.LastIndexOf("`t"); @{ phrase = $_.Substring(0, $i); expected = $_.Substring($i + 1) } })
    $inputs = Join-Path ([IO.Path]::GetTempPath()) "a339pm_test_inputs.txt"
    [IO.File]::WriteAllLines($inputs, [string[]]@($tests | ForEach-Object { $_.phrase }), (New-Object Text.UTF8Encoding $false))
    $results = @(& $shell -NoProfile -ExecutionPolicy Bypass -File $bridge -Aircraft $aircraft -Test $inputs -Tsv)
    Remove-Item $inputs
    if ($results.Count -ne $tests.Count) { Write-Host "bridge $aircraft : $($results.Count) results for $($tests.Count) phrases" -ForegroundColor Red; exit 1 }

    if ($Update) {
        $header = @($lines | Where-Object { $_.StartsWith("#") })
        [IO.File]::WriteAllLines($cases.FullName, [string[]]($header + $results), (New-Object Text.UTF8Encoding $false))
        Write-Host "bridge $aircraft : $($results.Count) expected results rewritten - review the diff"
        continue
    }
    $bad = 0
    for ($k = 0; $k -lt $tests.Count; $k++) {
        $got = $results[$k].Substring($results[$k].LastIndexOf("`t") + 1)
        if ($got -ne $tests[$k].expected) {
            $bad++
            Write-Host ("FAIL  {0} '{1}'`n      expected: {2}`n      got:      {3}" -f $aircraft, $tests[$k].phrase, $tests[$k].expected, $got) -ForegroundColor Red
        }
    }
    $failed += $bad
    Write-Host ("bridge {0}: {1} phrases, {2} failed" -f $aircraft, $tests.Count, $bad) -ForegroundColor $(if ($bad) { "Red" } else { "Green" })
}

# 2. items, codes, collections, archive
$python = @("python", "py", "python3") | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
if ($python) {
    & $python (Join-Path $PSScriptRoot "check_release.py")
    if ($LASTEXITCODE -ne 0) { $failed++ }
} else { Write-Host "check_release.py skipped: no Python" -ForegroundColor Yellow }

if ($failed) { exit 1 }
