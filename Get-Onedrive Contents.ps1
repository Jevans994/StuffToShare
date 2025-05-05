###################################################
# Script Author : u/No_Flight_375
# Create Date : 18/04/2025
# Last updated : 29/04/2025
# !Warning! : MUST be run from device with certificate installed that correpsonds with application in tenant 
# MUST be run in application context as even Global admin user lacks permissions to access this information 
# Purpose : Gets the Onedrive/Sharepoint Files and Folders for ALL groups in our org (Helps to audit how Teams storage is being used) then due to the size 
# A csv is created PER GROUP at the export path. Due to restrictions placed on Get-Mggroup we MUST use a Get request directly from the URI per site
#
# As this application uses App authentication it can be run unattended and on schedule should regular auditing be required
####################################################

# Connect to Microsoft Graph (if not already connected)
# For reference https://learn.microsoft.com/en-us/graph/auth-register-app-v2 Ensure correct api Permissions set
Connect-MgGraph `
    -ClientId "Client ID Here" `
    -TenantId "Tenant ID Here" `
    -CertificateThumbprint "Certificate thumbprint here"

# Constants
$ExportPath = ".\GroupDrives"
$NoDriveGroups = @()
# Flagfall for a 90day threshold 
$InactiveThreshold = (Get-Date).AddDays(-90) # <---- Change number here if you have a differnet number of days 

# Create export folder if it doesnt exist - Default path is the script directory 
if (-not (Test-Path -Path $ExportPath)) {
    New-Item -ItemType Directory -Path $ExportPath
}

# Get all M365 groups (with -All for retrieving all groups)
$Groups = Get-MgGroup -GroupId -All

# Recursive function to list files/folders
function Get-DriveItems {
    param (
        [string]$DriveId,
        [string]$ItemId = "root",
        [string]$CurrentPath = ""
    )
    $Results = @()

    $Uri = "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$ItemId/children"
    $Items = Invoke-MgGraphRequest -Method GET -Uri $Uri

    foreach ($Item in $Items.value) {
        $Path = if ($CurrentPath -eq "") { $Item.name } else { "$CurrentPath\$($Item.name)" }

        $Results += [PSCustomObject]@{
            Name             = $Item.name
            Path             = $Path
            Type             = $Item.folder -ne $null ? "Folder" : "File"
            CreatedDateTime  = $Item.createdDateTime
            LastModifiedDate = $Item.lastModifiedDateTime
            InactiveOver90d  = ([datetime]$Item.lastModifiedDateTime -lt $InactiveThreshold)
        }

        if ($Item.folder -ne $null) {
            $Results += Get-DriveItems -DriveId $DriveId -ItemId $Item.id -CurrentPath $Path
        }
    }

    return $Results
}

# Loop through groups with progress
$TotalGroups = $Groups.Count
$CurrentIndex = 0

foreach ($Group in $Groups) {
    $CurrentIndex++
    $GroupName = $Group.displayName -replace '[\\/:*?"<>|]', "-"  # Sanitize filename

    # Progress bar... Cause it can take a while and its nice to see it happeneing
    Write-Progress -Activity "Processing Groups" `
                   -Status "Processing $GroupName ($CurrentIndex of $TotalGroups)" `
                   -PercentComplete (($CurrentIndex / $TotalGroups) * 100)

    try {
        $Drive = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$($Group.id)/drive"
        $DriveId = $Drive.id

        $DriveContents = Get-DriveItems -DriveId $DriveId

        if ($DriveContents.Count -eq 0) {
            $NoDriveGroups += $GroupName
        } else {
            $CsvPath = Join-Path $ExportPath "$GroupName.csv"
            $DriveContents | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
        }

    } catch {
        Write-Warning "Could not retrieve drive for group: $GroupName ($($Group.id))"
        $NoDriveGroups += $GroupName
    }
}

# Finalize
$NoDriveGroups | Sort-Object | Set-Content -Path "$ExportPath\NoOneDrive.csv"
Write-Progress -Activity "Processing Groups" -Completed
Write-Host "Export complete. Check the '$ExportPath' folder for results."
