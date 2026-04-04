$ErrorActionPreference = 'Stop'

$Repo = 'Doist/doist-os'
$TargetDir = if ($env:DOIST_OS_DIR) { $env:DOIST_OS_DIR } else { Join-Path $HOME 'doist-os' }
$LogFile = Join-Path $env:TEMP ("doist-bootstrap-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-Stage($message) {
    Write-Host ""
    Write-Host "==> $message"
}

function Fail($message) {
    Write-Host ""
    Write-Host "Bootstrap failed: $message"
    Write-Host "Log file: $LogFile"
    if (Test-Path $LogFile) {
        Write-Host "Last output:"
        Get-Content $LogFile -Tail 25 | ForEach-Object { Write-Host $_ }
    }
    exit 1
}

function Run-Quiet {
    param(
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter()][string[]]$Args = @()
    )

    Write-Host "  - $Step"
    "[$(Get-Date -Format s)] $Command $($Args -join ' ')" | Out-File -FilePath $LogFile -Append

    & $Command @Args *>> $LogFile
    if ($LASTEXITCODE -ne 0) {
        Fail $Step
    }
}

function Ensure-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (Get-Command $CommandName -ErrorAction SilentlyContinue) {
        Write-Host "  - $Label already installed"
        return
    }

    Run-Quiet -Step "Installing $Label" -Command "winget" -Args @(
        "install", "--id", $PackageId, "--exact", "--silent",
        "--accept-package-agreements", "--accept-source-agreements"
    )
}

function Ensure-GhAuth {
    # If GH_TOKEN is set, check whether it's actually valid before trusting it.
    # gh will always prefer GH_TOKEN over stored credentials, so an invalid token
    # will cause the clone to fail even if the user has logged in interactively.
    if ($env:GH_TOKEN) {
        "[$(Get-Date -Format s)] GH_TOKEN is set - verifying it is valid" | Out-File -FilePath $LogFile -Append
        & gh auth status 2>> $LogFile | Out-Null
        if ($LASTEXITCODE -ne 0) {
            "[$(Get-Date -Format s)] GH_TOKEN is invalid - unsetting and falling back to interactive login" | Out-File -FilePath $LogFile -Append
            Write-Host "  - GH_TOKEN is set but invalid, ignoring it" -ForegroundColor Yellow
            $env:GH_TOKEN = $null
        }
    }

    # Check whether we have working credentials (token or interactive)
    & gh auth status 2>> $LogFile | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  - GitHub CLI already authenticated"
        return
    }

    # Not authenticated - kick off the browser flow
    Write-Host "  - Starting GitHub login in your browser"
    "[$(Get-Date -Format s)] gh auth login --web --git-protocol https --hostname github.com" | Out-File -FilePath $LogFile -Append
    & gh auth login --web --git-protocol https --hostname github.com
    if ($LASTEXITCODE -ne 0) {
        Fail "GitHub authentication failed"
    }

    # Verify the login actually worked before proceeding
    & gh auth status 2>> $LogFile | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Fail "GitHub authentication could not be verified after login"
    }

    Write-Host "  - GitHub CLI authenticated successfully"
}

function Clone-Repo {
    if (Test-Path (Join-Path $TargetDir '.git')) {
        Write-Host "  - Repo already cloned at $TargetDir"
        Run-Quiet -Step "Pulling latest changes" -Command "git" -Args @("-C", $TargetDir, "pull", "--rebase", "origin", "main")
        return
    }

    if (Test-Path $TargetDir) {
        Fail "Target path exists but is not a git repo: $TargetDir"
    }

    Run-Quiet -Step "Cloning $Repo into $TargetDir" -Command "gh" -Args @("repo", "clone", $Repo, $TargetDir)
}

New-Item -ItemType File -Path $LogFile -Force | Out-Null

Write-Host "Doist OS bootstrap"
Write-Host "Log file: $LogFile"

Write-Stage "Preparing Windows prerequisites"
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Fail "winget is required but was not found"
}

Ensure-WingetPackage -CommandName "git" -PackageId "Git.Git" -Label "Git"
Ensure-WingetPackage -CommandName "gh" -PackageId "GitHub.cli" -Label "GitHub CLI"

Write-Stage "Accessing private repository"
Ensure-GhAuth
Clone-Repo

Write-Stage "Running repository setup"
$SetupScript = Join-Path $TargetDir "scripts\setup.ps1"
if (-not (Test-Path $SetupScript)) {
    Fail "Missing setup script at $SetupScript"
}

Write-Host "  - Running Doist OS setup script"
try {
    Push-Location -Path $TargetDir
    & $SetupScript
    if ($LASTEXITCODE -ne 0) {
        Fail "Repository setup script failed"
    }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "Bootstrap complete."
Write-Host "Repository: $TargetDir"