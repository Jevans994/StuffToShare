##############################
# Authored by: Jesse Ev
# Git: Jevans994 - url: https://github.com/Jevans994/StuffToShare/tree/main/HP%20Bloatware%20Removal%20-%20Cleaned
# Create date: 15/10/2025
# Purpose: Creates a Masterlist of HP apps to be removed, Determines the correct method for uninstall
# and removes the applications - The list order matters, removing from top to bottom as some apps have
# dependacies. 
#
# This script is verbose enough to remove MOST applications if added to the list, and is designed to be
# Run manually as an admin OR if packaged can be deployed via intune
#
# Dependancy files - There is a file called UninstallHPCO.iss that is required to be in the same directory
# as the running script, this handles the uninstall for HP Connection Optimizer if present. 
################################

$LogPath = "$($env:ProgramData)\HP\RemoveHPBloatware"
if (-not (Test-Path $LogPath)) {
    New-Item -Path $LogPath -ItemType Directory -Force
}
Start-Transcript -Path "$($LogPath)\RemoveHPBloatware.log" -Force

# --- MASTER APPLICATION LIST ---
# Add any HP application name to this list. The script will figure out how to uninstall it.
# Wildcards (*) are supported.
$AllBloatwarePatterns = @(
    # Win32 Programs
    "HP Client Security Manager", #Security Dependancy for Wolf Leave this at the top
    "HP Connection Optimizer",
    "HP Documentation",
    "HP MAC Address Manager",
    "HP Notifications",
    "HP Wolf Security", #Security Wolf apps must be uninstalled in this order
    "HP Wolf Security - Console", #Security Wolf apps must be uninstalled in this order
    "HP Security Update Service", #Security Wolf apps must be uninstalled in this order
    "HP Wolf Security Application Support*", #Security Wolf apps must be uninstalled in this order - Sure Sense Support app can crash explorer
    "HP System Default Settings",
    "HP Sure Click*",
    "HP Sure Run Module",
    "HP Sure Recover",
    "HP Sure Sense*",
    

    # Appx / Provisioned Appx Packages - Just for organisation, still in the same list
    "HPJumpStarts",
    "HPPCHardwareDiagnosticsWindows",
    "HPPowerManager",
    "HPPrivacySettings",
    "HPSupportAssistant",
    "HPSureShieldAI",
    "HPSystemInformation",
    "HPQuickDrop",
    "HPWorkWell",
    "myHP",
    "HPDesktopSupportUtilities",
    "HPQuickTouch",
    "HPEasyClean",
)
# --- FUNCTIONS ---
# Searches for uninstallation reg keys
Function Get-InstalledSoftware {
    $RegistryPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    Get-ItemProperty -Path $RegistryPaths | Where-Object { $_.DisplayName -and $_.UninstallString } | Select-Object DisplayName, UninstallString
}
# --- DISCOVERY PHASE --- 
#Get all installed apps and packages of each type
Write-Host "Discovering all installed software..."
$AllInstalledSoftware = Get-InstalledSoftware
$AllInstalledAppx = Get-AppxPackage -AllUsers
$AllProvisionedAppx = Get-AppxProvisionedPackage -Online

$ProgramsToUninstall = @()
$AppxToUninstall = @()
$ProvisionedToUninstall = @()
#Assignes them to the right App type
Write-Host "Building uninstall list based on master order..."
foreach ($Pattern in $AllBloatwarePatterns) {
    # We use a trick with the regex pattern for "HP Wolf Security" to exclude the console
    $regexPattern = if ($Pattern -eq "HP Wolf Security") { "^HP Wolf Security(?!.*Console)$" } else { $Pattern }
    
    $ProgramsToUninstall += $AllInstalledSoftware | Where-Object { $_.DisplayName -match $regexPattern }
    $AppxToUninstall += $AllInstalledAppx | Where-Object { $_.Name -like "*$Pattern*" }
    $ProvisionedToUninstall += $AllProvisionedAppx | Where-Object { $_.DisplayName -like "*$Pattern*" }
}

# --- REMOVAL PHASE --- 
# ROBUST UNINSTALLER LOOPS

# 1. Remove Provisioned Appx Packages (must be done first)
ForEach ($Package in $ProvisionedToUninstall) {
    Write-Host "Attempting to remove provisioned package: [$($Package.DisplayName)]..."
    Try {
        Remove-AppxProvisionedPackage -PackageName $Package.PackageName -Online -ErrorAction Stop
        Write-Host "Successfully removed provisioned package: [$($Package.DisplayName)]" -ForegroundColor Green
    } Catch { Write-Warning "Failed to remove provisioned package: [$($Package.DisplayName)]" }
}

# 2. Remove Installed Appx Packages
ForEach ($Package in $AppxToUninstall) {
    Write-Host "Attempting to remove Appx package: [$($Package.Name)]..."
    Try {
        Remove-AppxPackage -Package $Package.PackageFullName -AllUsers -ErrorAction Stop
        Write-Host "Successfully removed Appx package: [$($Package.Name)]" -ForegroundColor Green
    } Catch { Write-Warning "Failed to remove Appx package: [$($Package.Name)]" }
}

# 3. Universal Uninstall Loop for Win32 Programs
Write-Host "Starting universal uninstall loop for Win32 programs..."
ForEach ($Program in $ProgramsToUninstall) {
    Write-Host "Attempting to uninstall: [$($Program.DisplayName)]..."
    
    $UninstallCommand = $Program.UninstallString
    $FilePath, $Arguments = "", ""

    if ($UninstallCommand.StartsWith('"')) {
        $FilePath = $UninstallCommand.Split('"')[1]
        $Arguments = $UninstallCommand.Substring($FilePath.Length + 3).Trim()
    } else {
        $SplitCommand = $UninstallCommand.Split(' ', 2)
        $FilePath = $SplitCommand[0]
        if ($SplitCommand.Count -gt 1) { $Arguments = $SplitCommand[1] }
    }
    # --- APP SPECIFIC UNINSTALLERS ---
    #Connection optimizer is problematic and requires a specific uninstall command 
    if ($Program.DisplayName -eq "HP Connection Optimizer") {
        $ResponseFilePath = Join-Path $PSScriptRoot "UninstallHPCO.iss"
        if (Test-Path $ResponseFilePath){
             $Arguments = "/s /f1`"$ResponseFilePath`""
        } else {
             Write-Warning "Response file for HP Connection Optimizer not found. Attempting generic silent uninstall."
             $Arguments += " /s"
        }
    }
    # --- END APP SPECIFIC UNINSTALLERS ---

    # --- GENERIC UNINSTALLERS ---
    elseif ($FilePath -like "*msiexec.exe*") {
        $Arguments = ($Arguments -replace "/I", "/X") + " /qn /norestart"
    }
    elseif ($FilePath -like "*setup.exe*") {
        $Arguments += " /s"
    }

    Write-Host "  -> Executing: `"$FilePath`" with arguments: `"$Arguments`""
    
    Try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru -ErrorAction Stop
        if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
            Write-Host "Successfully uninstalled: [$($Program.DisplayName)]" -ForegroundColor Green
        } else {
            Write-Warning "Uninstallation for [$($Program.DisplayName)] finished with a non-zero exit code: $($process.ExitCode)."
        }
    } Catch {
        Write-Warning "An error occurred while trying to uninstall [$($Program.DisplayName)]. Error: $_"
    }

    # Verify Explorer is running after each uninstall - SureClick or Wolf Security can crash this and 
    # Fails to restart it 
    $explorer = Get-Process -Name "explorer" -ErrorAction SilentlyContinue
    if (-not $explorer -or -not $explorer.Responding -or $explorer.MainWindowHandle -eq 0) {
        Write-Warning "Explorer.exe has crashed or is not responding. Restarting shell..."
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Invoke-WmiMethod -Class Win32_Process -Name Create -ArgumentList "explorer.exe"
        Start-Sleep -Seconds 5
    }
    #Some HP's MSI's indicate its complete and task moves PRIOR to it actually completing
    Write-Host "Pausing for 15 seconds to allow Windows Installer to finish..."
    Start-Sleep -Seconds 15
}

# --- FINAL VERIFICATION ---
Write-Host "Performing final verification check..."

# Re-run discovery on our master list to see what's left or failed to uninstall
$RemainingPrograms = @()
$RemainingAppx = @()
$RemainingProvisioned = @()

$AllInstalledSoftware_Check = Get-InstalledSoftware
$AllInstalledAppx_Check = Get-AppxPackage -AllUsers
$AllProvisionedAppx_Check = Get-AppxProvisionedPackage -Online

foreach ($Pattern in $AllBloatwarePatterns) {
    $RemainingPrograms += $AllInstalledSoftware_Check | Where-Object { $_.DisplayName -like $Pattern }
    $RemainingAppx += $AllInstalledAppx_Check | Where-Object { $_.Name -like "*$Pattern*" }
    $RemainingProvisioned += $AllProvisionedAppx_Check | Where-Object { $_.DisplayName -like "*$Pattern*" }
}
#If any apps specified in the master list still exist
if ($RemainingPrograms -or $RemainingAppx -or $RemainingProvisioned) {
    Write-Warning "WARNING: HP Bloatware still detected."
    if ($RemainingPrograms) { Write-Host "Remaining Programs: $($RemainingPrograms.DisplayName -join ', ')" }
    if ($RemainingAppx) { Write-Host "Remaining Appx Packages: $($RemainingAppx.Name -join ', ')" }
    if ($RemainingProvisioned) { Write-Host "Remaining Provisioned Packages: $($RemainingProvisioned.DisplayName -join ', ')" }
}
#else All apps removed, tags the logging directory with a file used for intune detection
else {
    Write-Host "SUCCESS: No HP bloatware apps detected." -ForegroundColor Green
    # Intune tag, remove if your not deploying this via intune its not needed.
    New-Item -Path "$($LogPath)\RemoveHPBloatware.tag" -ItemType File -Force
}


Stop-Transcript
