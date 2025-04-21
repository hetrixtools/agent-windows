#
#	HetrixTools Server Monitoring Agent - Install Script
#	Copyright 2015 - 2024 @  HetrixTools
#	For support, please open a ticket on our website https://hetrixtools.com
#
#
#		DISCLAIMER OF WARRANTY
#
#	The Software is provided "AS IS" and "WITH ALL FAULTS," without warranty of any kind, 
#	including without limitation the warranties of merchantability, fitness for a particular purpose and non-infringement. 
#	HetrixTools makes no warranty that the Software is free of defects or is suitable for any particular purpose. 
#	In no event shall HetrixTools be responsible for loss or damages arising from the installation or use of the Software, 
#	including but not limited to any indirect, punitive, special, incidental or consequential damages of any character including, 
#	without limitation, damages for loss of goodwill, work stoppage, computer failure or malfunction, or any and all other commercial damages or losses. 
#	The entire risk as to the quality and performance of the Software is borne by you, the user.
#
#		END OF DISCLAIMER OF WARRANTY

# Script path
$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path

# Branch
$BRANCH = "main"

# Check if the operating system is 64-bit
$is64BitOS = ([Environment]::Is64BitOperatingSystem)
# Check if the current PowerShell process is 32-bit
$is32BitProcess = -not ([Environment]::Is64BitProcess)
if ($is64BitOS -and $is32BitProcess) {
    Write-Host "Please run this script in a 64-bit PowerShell session."
    exit
}

# Check if the script is running with elevated privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $isAdmin) {
    Write-Host "Please run this script as an Administrator."
    exit
}

# Make sure older versions of PowerShell are configured to allow TLS 1.2
# OSVersion needs to be considered to prevent downgrading stronger SystemDefault on newer versions of Windows Server
$commonSecurityProtocols = [Net.SecurityProtocolType]::Tls12
if ([System.Environment]::OSVersion.Version.Build -lt 17763 -and [Net.ServicePointManager]::SecurityProtocol -lt $commonSecurityProtocols) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $commonSecurityProtocols
}

# Installation folder
$folderPath = "C:\Program Files\HetrixTools"

# Get the Server ID
$SID = $args[0]
if ([string]::IsNullOrWhiteSpace($SID)) {
    # Try to reuse Server ID from existing v2 agent installation
    $existingConfig = "$folderPath\hetrixtools.cfg"
    if (Test-Path -Path $existingConfig) {
        foreach ($line in Get-Content $existingConfig) {
            if ($line -match "^\s*SID\s*=\s*([a-z0-9]{32})\s*$") {
                $SID = $Matches[1]
                break
            }
        }
    }
    # Try to reuse Server ID from existing v1 agent installation
    $existingSID = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\HetrixToolsAgent\Parameters"
    if ([string]::IsNullOrWhiteSpace($SID) -and (Test-Path -Path $existingSID)) {
        $SID = (Get-ItemProperty -Path $existingSID -Name 'sid').sid
    }
}

# Make sure the SID is plausible
Write-Host "Checking Server ID (SID)..."
if ($SID -match "^[a-z0-9]{32}$") {
    Write-Host "Server ID: $SID" -ForegroundColor Cyan
}
else {
    Write-Host "Error: Server ID is empty." -ForegroundColor Yellow
    exit
}
Write-Host "... done."

# Check if the folder exists
Write-Host "Checking installation folder..."
if (-Not (Test-Path -Path $folderPath)) {
    # Create the folder if it does not exist
    New-Item -Path $folderPath -ItemType Directory
} else {
    Write-Host "Folder already exists: $folderPath"
    # Delete the old agent
    Write-Host "Deleting the old agent..."
    Remove-Item -Path $folderPath -Recurse
    Write-Host "... done."
    # Create the folder
    Write-Host "Creating the folder..."
    New-Item -Path $folderPath -ItemType Directory
}
Write-Host "... done."

# Download the agent
$items = @(
    [PSCustomObject] @{
        description = "agent"
        source = "https://raw.githubusercontent.com/hetrixtools/agent-windows/$BRANCH/hetrixtools_agent.ps1"
        target = "$folderPath\hetrixtools_agent.ps1"
    },
    [PSCustomObject] @{
        description = "config file"
        source = "https://raw.githubusercontent.com/hetrixtools/agent-windows/$BRANCH/hetrixtools.cfg"
        target = "$folderPath\hetrixtools.cfg"
    }
)
$wc = New-Object System.Net.WebClient
foreach ($item in $items) {
    Write-Host "Downloading the ${$item.description}..."
    $wc.DownloadFile($item.source, $item.target)
    if (Test-Path -Path $item.target) {
        Write-Host "... done."
    }
    else {
        Write-Host "... failed." -ForegroundColor Yellow
        exit
    }
}

# Insert the Server ID into the config file
Write-Host "Inserting the Server ID into the config file..."
(Get-Content "$folderPath\hetrixtools.cfg") | ForEach-Object { $_ -replace "SID=", "SID=$SID" } | Set-Content "$folderPath\hetrixtools.cfg"

# Check if any processes/services need to be monitored
Write-Host "Checking if any processes/services need to be monitored..."
if ($null -ne $args[1] -and $args[1] -ne "0") {
    # Insert the processes/services into the config file
    Write-Host "Inserting the processes/services into the config file..."
    # Split the string into an array and filter out empty elements
    $processesString = ($args[1].Split(",") | Where-Object { $_.Trim() -ne "" }) -join ","
    (Get-Content "$folderPath\hetrixtools.cfg") | ForEach-Object { $_ -replace "CheckServices=", "CheckServices=$processesString" } | Set-Content "$folderPath\hetrixtools.cfg"
}
Write-Host "... done."

# Check if Drive Health Monitoring is enabled
Write-Host "Checking if Drive Health Monitoring is enabled..."
if ($args[2] -eq "1") {
    # Insert the Drive Health Monitoring into the config file
    Write-Host "Inserting the Drive Health Monitoring into the config file..."
    (Get-Content "$folderPath\hetrixtools.cfg") | ForEach-Object { $_ -replace "CheckDriveHealth=0", "CheckDriveHealth=1" } | Set-Content "$folderPath\hetrixtools.cfg"
}
Write-Host "... done."

# Create the scheduled task
Write-Host "Checking the scheduled task..."
$taskName = "HetrixTools Server Monitoring Agent"
$processName = "powershell.exe"
$scriptName = "hetrixtools_agent.ps1"
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Host "The scheduled task already exists..."
    # Find the processes matching the script being executed by the scheduled task
    Write-Host "Finding any running processes executed by the existing scheduled task..."
    $processes = Get-Process | Where-Object {
        $_.ProcessName -like "powershell*" -or $_.ProcessName -like "pwsh*"
    }
    foreach ($process in $processes) {
        try {
            $cmdLine = (Get-WmiObject Win32_Process -Filter "ProcessId = $($process.Id)").CommandLine
            if ($cmdLine -like "*$scriptName*") {
                Write-Host "Found process $($process.Id)"
                try {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                    Write-Host "Terminated process $($process.Id)"
                } catch {
                    Write-Host "Failed to terminate process $($process.Id)"
                }
            }
        } catch {
            Write-Host "Error accessing command line for process $($process.Id)."
        }
    }
    Write-Host "Deleting the existing scheduled task..."
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
Write-Host "... done."

Write-Host "Creating the new scheduled task..."
# Calculate the next full minute
$currentTime = Get-Date
$nextFullMinute = $currentTime.AddMinutes(1).Date.AddHours($currentTime.Hour).AddMinutes($currentTime.Minute)
# Define task action
$taskAction = New-ScheduledTaskAction -Execute $processName -Argument "-ExecutionPolicy Bypass -File `"$folderPath\hetrixtools_agent.ps1`""
# Define task trigger to start at the next full minute and repeat every minute
$taskTrigger = New-ScheduledTaskTrigger -Once -At $nextFullMinute -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 9999)
# Define task principal
$taskPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
# Define task settings with parallel execution and execution time limit
$taskSettings = New-ScheduledTaskSettingsSet -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances Parallel
# Register the scheduled task
Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $taskTrigger -Settings $taskSettings -Principal $taskPrincipal
# Set the execution time limit explicitly using Set-ScheduledTask
$task = Get-ScheduledTask -TaskName $taskName
$task.Settings.ExecutionTimeLimit = "PT2M"
Set-ScheduledTask -TaskName $taskName -TaskPath "\" -Settings $task.Settings

# Check if agent is ready to replace v1 agent and/or to confirm installation
$taskExecutionTimeLimit = (Get-ScheduledTask -TaskName $taskName).Settings.ExecutionTimeLimit
if ($taskExecutionTimeLimit -eq $task.Settings.ExecutionTimeLimit) {
    Write-Host "... done."
}
else {
    Write-Host "... failed." -ForegroundColor Yellow
    exit
}

# Find and uninstall v1 agent
Write-Host "Checking for old agent..."
$processName = "HetrixToolsAgent.exe"
$processes = Get-WmiObject Win32_Process | Where-Object { $_.Name -eq $processName }
$paths = @()
if ($processes) {
    foreach ($process in $processes) {
        $processPath = $process.ExecutablePath
        if ($processPath) {
            Write-Host "Found process $($process.ProcessId) running from path $processPath"
            $paths += $processPath.Trim()
        } else {
            Write-Host "Unable to retrieve the path for the process $($process.ProcessId)."
        }
    }
    $uniquePaths = $paths | Select-Object -Unique
    if ($uniquePaths.Count -eq 1) {
        $finalPath = $uniquePaths
        Write-Host "The unique path for all instances is $finalPath"
        Write-Host "Uninstalling the old agent..."
        & "$finalPath" stop
        & "$finalPath" remove
        & taskkill /IM "HetrixToolsAgent.exe" /F
    } else {
        Write-Host "Error: Cannot uninstall the old agent because there are multiple instances running from different paths."
        Write-Host "Please manually uninstall the old agent and then re-run this install script again."
        exit 1
    }
}
Write-Host "... done."

# Start the scheduled task
$currentSecond = (Get-Date).Second
if ($currentSecond -ge 2 -and $currentSecond -le 50) {
    Write-Host "Starting the scheduled task..."
    Start-ScheduledTask -TaskName $taskName
    Write-Host "... done."
}

# Confirm installation
Write-Host "Letting HetrixTools know the installation has been completed..."
# Create a custom object with all the data
$Data = [PSCustomObject]@{
    version = 'install'
    SID = $SID
}
# Convert the object to JSON
$Data = $Data | ConvertTo-Json
# Send the data
$APIURL = "https://sm.hetrixtools.net/win/"
$Headers = @{
    'Content-Type' = 'application/json'
}
$MaxRetries = 3
$Timeout = 15
$RetryCount = 0
$Success = $false
while ($RetryCount -lt $MaxRetries -and -not $Success) {
    try {
        $Response = Invoke-RestMethod -Uri $APIURL -Method Post -Headers $Headers -Body $Data -TimeoutSec $Timeout
        $Success = $true
    } catch {
        $RetryCount++
        if ($RetryCount -ne $MaxRetries) {
            Start-Sleep -Seconds 1
        }
    }
}
Write-Host "... done."

Write-Host "Installation completed successfully."