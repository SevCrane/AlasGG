<#
.SYNOPSIS
Safely merge the upstream master branch into this fork's dev branch.

.DESCRIPTION
The default behavior is local-only: verify a clean worktree, fetch remotes,
fast-forward local dev from origin/dev, then merge upstream/master into dev.
Conflicts or failed tests stop the script before anything is pushed.

Use -PushDev to publish dev. Use -PromoteMaster to merge the already-published
dev commit into master and push it, so master is never promoted from an
unpublished or untested dev state.

.EXAMPLE
.\dev_tools\sync_upstream.ps1

Fetch and merge upstream/master into dev, without pushing.

.EXAMPLE
.\dev_tools\sync_upstream.ps1 -RunTests -PushDev

Run the configured tests, then push dev only if they pass.

.EXAMPLE
.\dev_tools\sync_upstream.ps1 -RunTests -PushDev -PromoteMaster

Run tests, push dev, merge dev into master, and push master.
#>
[CmdletBinding()]
param(
    [string]$Upstream = 'upstream',
    [string]$UpstreamBranch = 'master',
    [string]$Origin = 'origin',
    [string]$DevBranch = 'dev',
    [string]$MasterBranch = 'master',
    [switch]$RunTests,
    [string]$TestCommand = 'python -m pytest tests',
    [switch]$PushDev,
    [switch]$PromoteMaster,
    [switch]$SkipFetch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "OK: $Message" -ForegroundColor Green
}

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$GitArgs)

    & git @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Get-Commit {
    param([Parameter(Mandatory = $true)][string]$Revision)

    $commit = & git rev-parse --verify $Revision
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit)) {
        throw "Unable to resolve Git revision '$Revision'."
    }
    return $commit.Trim()
}

function Test-GitAncestor {
    param(
        [Parameter(Mandatory = $true)][string]$Ancestor,
        [Parameter(Mandatory = $true)][string]$Descendant
    )

    & git merge-base --is-ancestor $Ancestor $Descendant 2>$null
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        return $true
    }
    if ($exitCode -eq 1) {
        return $false
    }
    throw "git merge-base failed while checking '$Ancestor' and '$Descendant'."
}

function Assert-CleanWorktree {
    param([string]$Activity = 'operation')

    $status = @(& git status --porcelain)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to read Git status.'
    }
    if ($status.Count -gt 0) {
        $status | ForEach-Object { Write-Host "  $_" }
        throw "The worktree is not clean. Commit or stash changes before $Activity."
    }
}

function Assert-Remote {
    param([Parameter(Mandatory = $true)][string]$Remote)

    & git remote get-url $Remote *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Git remote '$Remote' does not exist."
    }
}

function Assert-RemoteRef {
    param([Parameter(Mandatory = $true)][string]$Ref)

    & git show-ref --verify --quiet "refs/remotes/$Ref"
    if ($LASTEXITCODE -ne 0) {
        throw "Remote ref '$Ref' does not exist after fetch."
    }
}

function Invoke-Merge {
    param([Parameter(Mandatory = $true)][string]$Ref)

    & git merge --no-edit $Ref
    if ($LASTEXITCODE -eq 0) {
        return
    }

    $conflicts = @(& git diff --name-only --diff-filter=U)
    if ($conflicts.Count -gt 0) {
        Write-Host "Conflicting files:" -ForegroundColor Yellow
        $conflicts | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        throw "Merge stopped with conflicts. Resolve them, commit the merge, then rerun the script."
    }

    throw "git merge $Ref failed with exit code $LASTEXITCODE."
}

$repoRoot = & git rev-parse --show-toplevel
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'This script must be run inside a Git repository.'
}
$repoRoot = $repoRoot.Trim()
Push-Location $repoRoot

try {
    Assert-Remote -Remote $Upstream
    Assert-Remote -Remote $Origin
    Assert-CleanWorktree -Activity 'starting the merge'

    if ($PromoteMaster -and -not $RunTests) {
        throw 'Refusing to promote master without -RunTests. Validate dev first, then rerun with -RunTests -PushDev -PromoteMaster.'
    }

    if (-not $SkipFetch) {
        Write-Step "Fetching $Upstream and $Origin"
        Invoke-Git -GitArgs @('fetch', $Upstream, '--prune')
        Invoke-Git -GitArgs @('fetch', $Origin, '--prune')
    }
    else {
        Write-Host 'Skipping fetch as requested.' -ForegroundColor DarkGray
    }

    $upstreamRef = "$Upstream/$UpstreamBranch"
    $originDevRef = "$Origin/$DevBranch"
    $originMasterRef = "$Origin/$MasterBranch"
    Assert-RemoteRef -Ref $upstreamRef
    Assert-RemoteRef -Ref $originDevRef
    Assert-RemoteRef -Ref $originMasterRef

    & git show-ref --verify --quiet "refs/heads/$DevBranch"
    if ($LASTEXITCODE -ne 0) {
        throw "Local branch '$DevBranch' does not exist."
    }

    Write-Step "Switching to $DevBranch"
    Invoke-Git -GitArgs @('switch', $DevBranch)
    Assert-CleanWorktree -Activity "switching to $DevBranch"

    Write-Step "Fast-forwarding $DevBranch from $originDevRef"
    Invoke-Git -GitArgs @('merge', '--ff-only', $originDevRef)

    $beforeMerge = Get-Commit -Revision 'HEAD'
    if (Test-GitAncestor -Ancestor $upstreamRef -Descendant $DevBranch) {
        Write-Ok "$upstreamRef is already contained in $DevBranch."
    }
    else {
        Write-Step "Merging $upstreamRef into $DevBranch"
        Invoke-Merge -Ref $upstreamRef
    }

    $afterMerge = Get-Commit -Revision 'HEAD'
    if ($beforeMerge -ne $afterMerge) {
        Invoke-Git -GitArgs @('diff', '--check', "$beforeMerge..$afterMerge")
        Write-Ok "Created merge commit $afterMerge."
    }
    else {
        Write-Ok 'No new upstream changes were merged.'
    }

    if ($RunTests) {
        if ([string]::IsNullOrWhiteSpace($TestCommand)) {
            throw 'TestCommand must not be empty when -RunTests is used.'
        }
        Write-Step "Running tests: $TestCommand"
        Invoke-Expression $TestCommand
        if ($LASTEXITCODE -ne 0) {
            throw "Tests failed with exit code $LASTEXITCODE. Nothing was pushed."
        }
        Assert-CleanWorktree -Activity 'pushing dev'
        Write-Ok 'Tests passed.'
    }
    else {
        Write-Warning 'Tests were not run. Use -RunTests before publishing dev.'
    }

    if ($PushDev) {
        $localDev = Get-Commit -Revision $DevBranch
        $remoteDev = Get-Commit -Revision $originDevRef
        if ($localDev -ne $remoteDev) {
            Write-Step "Pushing $DevBranch to $Origin"
            Invoke-Git -GitArgs @('push', $Origin, "${DevBranch}:${DevBranch}")
        }
        else {
            Write-Ok "$DevBranch is already up to date on $Origin."
        }
    }

    if ($PromoteMaster) {
        $localDev = Get-Commit -Revision $DevBranch
        $remoteDev = Get-Commit -Revision $originDevRef
        if ($localDev -ne $remoteDev) {
            throw "Refusing to promote master: local $DevBranch is not the same commit as $originDevRef. Run with -PushDev after validation."
        }

        Write-Step "Switching to $MasterBranch"
        Invoke-Git -GitArgs @('switch', $MasterBranch)
        Assert-CleanWorktree -Activity "switching to $MasterBranch"

        Write-Step "Fast-forwarding $MasterBranch from $originMasterRef"
        Invoke-Git -GitArgs @('merge', '--ff-only', $originMasterRef)

        if (Test-GitAncestor -Ancestor $DevBranch -Descendant $MasterBranch) {
            Write-Ok "$MasterBranch already contains $DevBranch."
        }
        else {
            Write-Step "Merging $DevBranch into $MasterBranch"
            Invoke-Merge -Ref $DevBranch
        }

        Write-Step "Pushing $MasterBranch to $Origin"
        Invoke-Git -GitArgs @('push', $Origin, "${MasterBranch}:${MasterBranch}")
    }

    Write-Ok 'Upstream sync completed successfully.'
}
finally {
    Pop-Location
}
