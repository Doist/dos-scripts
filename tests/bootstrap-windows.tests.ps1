# Standalone tests: parse the real installer, load functions, never run its main flow.
$ErrorActionPreference = 'Stop'
$source = Get-Content (Join-Path $PSScriptRoot '../install/bootstrap-windows.ps1') -Raw
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}
$repoAssignment = $ast.EndBlock.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$Repo'
}
. ([scriptblock]::Create($repoAssignment.Extent.Text))
$RealRunQuiet = ${function:Run-Quiet}
function Fail($message) { throw $message }
function Run-Quiet {
    param($Step, $Command, [Alias('Args')][string[]]$CommandArgs)
    $script:Recorded = @($Command) + $CommandArgs
}
function Assert-Equal($actual, $expected) {
    if ($actual -cne $expected) { throw "Expected '$expected', got '$actual'" }
}
function Assert-Fails($action, $pattern) {
    $caught = $false
    try { & $action } catch {
        if ($_.Exception.Message -notmatch $pattern) { throw }
        $caught = $true
    }
    if (-not $caught) { throw "Expected failure matching $pattern" }
}
function New-Checkout($path, $remote = 'https://github.com/Doist/doist-os.git') {
    & git init -q -b main $path
    if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
    & git -C $path remote add origin $remote
    if ($LASTEXITCODE -ne 0) { throw 'git remote add failed' }
}

$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $fixture | Out-Null
$originalNew = $env:TODOIST_OS_DIR
$originalOld = $env:DOIST_OS_DIR
try {
    $env:TODOIST_OS_DIR = $null
    $env:DOIST_OS_DIR = $null
    Assert-Equal (Select-TargetDir -HomeDirectory $fixture) (Join-Path $fixture 'todoist-os')
    Assert-Equal $Repo 'Doist/todoist-os'

    foreach ($relative in @('doist-os', 'todoist-os', 'Documents/doist-os', 'Documents/todoist-os')) {
        $path = Join-Path $fixture $relative
        New-Checkout $path
        Assert-Equal (Select-TargetDir -HomeDirectory $fixture) $path
        Remove-Item $path -Recurse -Force
    }
    $old = Join-Path $fixture 'doist-os'
    $new = Join-Path $fixture 'todoist-os'
    New-Checkout $old
    New-Checkout $new
    Assert-Fails { Select-TargetDir -HomeDirectory $fixture } 'Multiple workspace checkouts'
    $env:DOIST_OS_DIR = $old
    Assert-Equal (Select-TargetDir -HomeDirectory $fixture) $old
    $env:TODOIST_OS_DIR = $new
    Assert-Equal (Select-TargetDir -HomeDirectory $fixture) $new

    # Verify the real advanced function forwards arguments, then keep network
    # operations stubbed in the remaining clone/pull checks.
    $LogFile = Join-Path $fixture 'run-quiet.log'
    & $RealRunQuiet -Step 'Inspect fixture checkout' -Command 'git' -Args @('-C', $new, 'rev-parse', '--show-toplevel')
    $loggedPath = (Get-Content $LogFile | Select-Object -Last 1).Replace('\', '/')
    $expectedPath = (& git -C $new rev-parse --show-toplevel).Replace('\', '/')
    Assert-Equal $loggedPath $expectedPath

    $script:Recorded = @()
    Clone-Repo
    Assert-Equal ($Recorded -join '|') (@('git', '-C', $new, 'pull', '--rebase', 'origin', 'main') -join '|')

    $env:TODOIST_OS_DIR = Join-Path $fixture 'new custom'
    Clone-Repo
    Assert-Equal ($Recorded -join '|') (@('gh', 'repo', 'clone', 'Doist/todoist-os', $env:TODOIST_OS_DIR) -join '|')

    $env:TODOIST_OS_DIR = $new
    Set-Content (Join-Path $new 'personal.txt') 'keep'
    $script:Recorded = @()
    Assert-Fails { Clone-Repo } 'Commit or stash'
    Assert-Equal $Recorded.Count 0
    Remove-Item (Join-Path $new 'personal.txt')
    & git -C $new symbolic-ref HEAD refs/heads/work
    Assert-Fails { Clone-Repo } 'Switch the target checkout to main'
    & git -C $new symbolic-ref HEAD refs/heads/main
    & git -C $new remote set-url origin https://github.com/someone/other.git
    Assert-Fails { Clone-Repo } 'not the TodoistOS upstream'
    Assert-Equal $Recorded.Count 0

    $env:TODOIST_OS_DIR = Join-Path $fixture 'not-a-repo'
    New-Item -ItemType Directory -Path $env:TODOIST_OS_DIR | Out-Null
    Assert-Fails { Clone-Repo } 'not a git repo'
    Write-Host 'Windows installer selection and upgrade checks passed.'
} finally {
    $env:TODOIST_OS_DIR = $originalNew
    $env:DOIST_OS_DIR = $originalOld
    Remove-Item $fixture -Recurse -Force
}
