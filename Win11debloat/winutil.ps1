<#
.NOTES
    Author         : Chris Titus @christitustech
    Runspace Author: @DeveloperDurp
    GitHub         : https://github.com/ChrisTitusTech
    Version        : 25.03.05
#>

param (
    [switch]$Debug,
    [string]$Config,
    [switch]$Run
)

# Set DebugPreference based on the -Debug switch
if ($Debug) {
    $DebugPreference = "Continue"
}

if ($Config) {
    $PARAM_CONFIG = $Config
}

$PARAM_RUN = $false
# Handle the -Run switch
if ($Run) {
    Write-Host "Running config file tasks..."
    $PARAM_RUN = $true
}

# Load DLLs
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

# Variable to sync between runspaces
$sync = [Hashtable]::Synchronized(@{})
$sync.PSScriptRoot = $PSScriptRoot
$sync.version = "25.03.05"
$sync.configs = @{}
$sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
$sync.ProcessRunning = $false
$sync.selectedApps = [System.Collections.Generic.List[string]]::new()
$sync.ShowOnlySeleced = $false
$sync.currentTab = "Install"
$sync.ShowOnlySelected = $false
$sync.selectedAppsStackPanel
$sync.selectedAppsPopup


if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "Winutil needs to be run as Administrator. Attempting to relaunch."
    $argList = @()

    $PSBoundParameters.GetEnumerator() | ForEach-Object {
        $argList += if ($_.Value -is [switch] -and $_.Value) {
            "-$($_.Key)"
        } elseif ($_.Value -is [array]) {
            "-$($_.Key) $($_.Value -join ',')"
        } elseif ($_.Value) {
            "-$($_.Key) '$($_.Value)'"
        }
    }

    $script = if ($PSCommandPath) {
        "& { & `'$($PSCommandPath)`' $($argList -join ' ') }"
    } else {
        "&([ScriptBlock]::Create((irm https://github.com/ChrisTitusTech/winutil/releases/latest/download/winutil.ps1))) $($argList -join ' ')"
    }

    $powershellCmd = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    $processCmd = if (Get-Command wt.exe -ErrorAction SilentlyContinue) { "wt.exe" } else { "$powershellCmd" }

    if ($processCmd -eq "wt.exe") {
        Start-Process $processCmd -ArgumentList "$powershellCmd -ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    } else {
        Start-Process $processCmd -ArgumentList "-ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    }

    break
}

$dateTime = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

$logdir = "$env:localappdata\evolveos\logs"
[System.IO.Directory]::CreateDirectory("$logdir") | Out-Null
Start-Transcript -Path "$logdir\evolveos_$dateTime.log" -Append -NoClobber | Out-Null

# Set PowerShell window title
$Host.UI.RawUI.WindowTitle = $myInvocation.MyCommand.Definition + "(Admin)"
clear-host
function Invoke-Microwin {
    <#
        .DESCRIPTION
        Invoke MicroWin routines...
    #>


    if($sync.ProcessRunning) {
        $msg = "GetIso process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    # Define the constants for Windows API
Add-Type @"
using System;
using System.Runtime.InteropServices;

public class PowerManagement {
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern EXECUTION_STATE SetThreadExecutionState(EXECUTION_STATE esFlags);

    [FlagsAttribute]
    public enum EXECUTION_STATE : uint {
        ES_SYSTEM_REQUIRED = 0x00000001,
        ES_DISPLAY_REQUIRED = 0x00000002,
        ES_CONTINUOUS = 0x80000000,
    }
}
"@

    # Prevent the machine from sleeping
    [PowerManagement]::SetThreadExecutionState([PowerManagement]::EXECUTION_STATE::ES_CONTINUOUS -bor [PowerManagement]::EXECUTION_STATE::ES_SYSTEM_REQUIRED -bor [PowerManagement]::EXECUTION_STATE::ES_DISPLAY_REQUIRED)

    # Ask the user where to save the file
    $SaveDialog = New-Object System.Windows.Forms.SaveFileDialog
    $SaveDialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    $SaveDialog.Filter = "ISO images (*.iso)|*.iso"
    $SaveDialog.ShowDialog() | Out-Null

    if ($SaveDialog.FileName -eq "") {
        Write-Host "No file name for the target image was specified"
        Set-WinUtilTaskbaritem -state "Error" -value 1 -overlay "warning"
        return
    }

    Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"

    Write-Host "Target ISO location: $($SaveDialog.FileName)"

    $index = $sync.MicrowinWindowsFlavors.SelectedValue.Split(":")[0].Trim()
    Write-Host "Index chosen: '$index' from $($sync.MicrowinWindowsFlavors.SelectedValue)"

    $copyToUSB = $sync.WPFMicrowinCopyToUsb.IsChecked
    $injectDrivers = $sync.MicrowinInjectDrivers.IsChecked
    $importDrivers = $sync.MicrowinImportDrivers.IsChecked

    $importVirtIO = $sync.MicrowinCopyVirtIO.IsChecked

    $mountDir = $sync.MicrowinMountDir.Text
    $scratchDir = $sync.MicrowinScratchDir.Text

    # Detect if the Windows image is an ESD file and convert it to WIM
    if (-not (Test-Path -Path "$mountDir\sources\install.wim" -PathType Leaf) -and (Test-Path -Path "$mountDir\sources\install.esd" -PathType Leaf)) {
        Write-Host "Exporting Windows image to a WIM file, keeping the index we want to work on. This can take several minutes, depending on the performance of your computer..."
        Export-WindowsImage -SourceImagePath $mountDir\sources\install.esd -SourceIndex $index -DestinationImagePath $mountDir\sources\install.wim -CompressionType "Max"
        if ($?) {
            Remove-Item -Path "$mountDir\sources\install.esd" -Force
            # Since we've already exported the image index we wanted, switch to the first one
            $index = 1
        } else {
            $msg = "The export process has failed and MicroWin processing cannot continue"
            Write-Host "Failed to export the image"
            [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            Set-WinUtilTaskbaritem -state "Error" -value 1 -overlay "warning"
            return
        }
    }

    $imgVersion = (Get-WindowsImage -ImagePath $mountDir\sources\install.wim -Index $index).Version
    Write-Host "The Windows Image Build Version is: $imgVersion"

    # Detect image version to avoid performing MicroWin processing on Windows 8 and earlier
    if ((Microwin-TestCompatibleImage $imgVersion $([System.Version]::new(10,0,10240,0))) -eq $false) {
        $msg = "This image is not compatible with MicroWin processing. Make sure it isn't a Windows 8 or earlier image."
        $dlg_msg = $msg + "`n`nIf you want more information, the version of the image selected is $($imgVersion)`n`nIf an image has been incorrectly marked as incompatible, report an issue to the developers."
        Write-Host $msg
        [System.Windows.MessageBox]::Show($dlg_msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Exclamation)
        Set-WinUtilTaskbaritem -state "Error" -value 1 -overlay "warning"
        return
    }

    # Detect whether the image to process contains Windows 10 and show warning
    if ((Microwin-TestCompatibleImage $imgVersion $([System.Version]::new(10,0,21996,1))) -eq $false) {
        $msg = "Windows 10 has been detected in the image you want to process. While you can continue, Windows 10 is not a recommended target for MicroWin, and you may not get the full experience."
        $dlg_msg = $msg
        Write-Host $msg
        [System.Windows.MessageBox]::Show($dlg_msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Exclamation)
    }

    $mountDirExists = Test-Path $mountDir
    $scratchDirExists = Test-Path $scratchDir
    if (-not $mountDirExists -or -not $scratchDirExists) {
        Write-Error "Required directories '$mountDirExists' '$scratchDirExists' and do not exist."
        Set-WinUtilTaskbaritem -state "Error" -value 1 -overlay "warning"
        return
    }

    try {

        Write-Host "Mounting Windows image. This may take a while."
        Mount-WindowsImage -ImagePath "$mountDir\sources\install.wim" -Index $index -Path "$scratchDir"
        if ($?) {
            Write-Host "The Windows image has been mounted successfully. Continuing processing..."
        } else {
            Write-Host "Could not mount image. Exiting..."
            Set-WinUtilTaskbaritem -state "Error" -value 1 -overlay "warning"
            return
        }

        if ($importDrivers) {
            Write-Host "Exporting drivers from active installation..."
            if (Test-Path "$env:TEMP\DRV_EXPORT") {
                Remove-Item "$env:TEMP\DRV_EXPORT" -Recurse -Force
            }
            if (($injectDrivers -and (Test-Path "$($sync.MicrowinDriverLocation.Text)"))) {
                Write-Host "Using specified driver source..."
                dism /english /online /export-driver /destination="$($sync.MicrowinDriverLocation.Text)" | Out-Host
                if ($?) {
                    # Don't add exported drivers yet, that is run later
                    Write-Host "Drivers have been exported successfully."
                } else {
                    Write-Host "Failed to export drivers."
                }
            } else {
                New-Item -Path "$env:TEMP\DRV_EXPORT" -ItemType Directory -Force
                dism /english /online /export-driver /destination="$env:TEMP\DRV_EXPORT" | Out-Host
                if ($?) {
                    Write-Host "Adding exported drivers..."
                    dism /english /image="$scratchDir" /add-driver /driver="$env:TEMP\DRV_EXPORT" /recurse | Out-Host
                } else {
                    Write-Host "Failed to export drivers. Continuing without importing them..."
                }
                if (Test-Path "$env:TEMP\DRV_EXPORT") {
                    Remove-Item "$env:TEMP\DRV_EXPORT" -Recurse -Force
                }
            }
        }

        if ($injectDrivers) {
            $driverPath = $sync.MicrowinDriverLocation.Text
            if (Test-Path $driverPath) {
                Write-Host "Adding Windows Drivers image($scratchDir) drivers($driverPath) "
                dism /English /image:$scratchDir /add-driver /driver:$driverPath /recurse | Out-Host
            } else {
                Write-Host "Path to drivers is invalid continuing without driver injection"
            }
        }

        if ($importVirtIO) {
            Write-Host "Copying VirtIO drivers..."
            Microwin-CopyVirtIO
        }

        Write-Host "Remove Features from the image"
        Microwin-RemoveFeatures -UseCmdlets $true
        Write-Host "Removing features complete!"
        Write-Host "Removing OS packages"
        Microwin-RemovePackages -UseCmdlets $true
        Write-Host "Removing Appx Bloat"
        Microwin-RemoveProvisionedPackages -UseCmdlets $true

        # Detect Windows 11 24H2 and add dependency to FileExp to prevent Explorer look from going back - thanks @WitherOrNot and @thecatontheceiling
        if ((Microwin-TestCompatibleImage $imgVersion $([System.Version]::new(10,0,26100,1))) -eq $true) {
            try {
                if (Test-Path "$scratchDir\Windows\SystemApps\MicrosoftWindows.Client.FileExp_cw5n1h2txyewy\appxmanifest.xml" -PathType Leaf) {
                    # Found the culprit. Do the following:
                    # 1. Take ownership of the file, from TrustedInstaller to Administrators
                    takeown /F "$scratchDir\Windows\SystemApps\MicrosoftWindows.Client.FileExp_cw5n1h2txyewy\appxmanifest.xml" /A
                    # 2. Set ACLs so that we can write to it
                    icacls "$scratchDir\Windows\SystemApps\MicrosoftWindows.Client.FileExp_cw5n1h2txyewy\appxmanifest.xml" /grant "$(Microwin-GetLocalizedUsers -admins $true):(M)" | Out-Host
                    # 3. Open the file and do the modification
                    $appxManifest = Get-Content -Path "$scratchDir\Windows\SystemApps\MicrosoftWindows.Client.FileExp_cw5n1h2txyewy\appxmanifest.xml"
                    $originalLine = $appxManifest[13]
                    $dependency = "`n        <PackageDependency Name=`"Microsoft.WindowsAppRuntime.CBS`" MinVersion=`"1.0.0.0`" Publisher=`"CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US`" />"
                    $appxManifest[13] = "$originalLine$dependency"
                    Set-Content -Path "$scratchDir\Windows\SystemApps\MicrosoftWindows.Client.FileExp_cw5n1h2txyewy\appxmanifest.xml" -Value $appxManifest -Force -Encoding utf8
                }
            }
            catch {
                # Do nothing
            }
        }

        Microwin-RemoveFileOrDirectory -pathToDelete "$($scratchDir)\Windows\System32\LogFiles\WMI\RtBackup" -Directory
        Microwin-RemoveFileOrDirectory -pathToDelete "$($scratchDir)\Windows\DiagTrack" -Directory
        Microwin-RemoveFileOrDirectory -pathToDelete "$($scratchDir)\Windows\InboxApps" -Directory
        Microwin-RemoveFileOrDirectory -pathToDelete "$($scratchDir)\Windows\System32\LocationNotificationWindows.exe"
        Microwin-RemoveFileOrDirectory -pathToDelete "$($scratchDir)\Program Files (x86)\Windows Media Player" -Directory
        Microwin-RemoveFileOrDirectory -pathToDelete "$($scratchDir)\Program Files\Windows Media Player" -Directory
        Microwin-RemoveFileOrDirectory -pathToDelete "$($scratchDir)\Program Files (x86)\Windows Mail" -Directory
        Microwin-RemoveFileOrDirectory -pathToDelete "$($scratchDir)\Program Files\Windows Mail" -Directory
        Microwin-RemoveFileOrDirectory -pathToDelete "$($scratchDir)\Program Files (x86)\Internet Explorer" -Directory
        Microwin-RemoveFileOrDirectory -pathToDelete "$($scratchDir)\Program Files\Internet Explorer" -Directory
        Microwin-RemoveFileOrDirectory -pathToDelete "$($scratchDir)\Windows\GameBarPresenceWriter"
        Microwin-RemoveFileOrDirectory -pathToDelete "$($scratchDir)\Windows\System32\OneDriveSetup.exe"
        Microwin-RemoveFileOrDirectory -pathToDelete "$($scratchDir)\Windows\System32\OneDrive.ico"
        Microwin-RemoveFileOrDirectory -pathToDelete "$($scratchDir)\Windows\SystemApps" -mask "*narratorquickstart*" -Directory
        Microwin-RemoveFileOrDirectory -pathToDelete "$($scratchDir)\Windows\SystemApps" -mask "*ParentalControls*" -Directory
        Write-Host "Removal complete!"

        Write-Host "Create unattend.xml"

        if ($sync.MicrowinUserName.Text -eq "")
        {
            Microwin-NewUnattend -userName "User"
        }
        else
        {
            if ($sync.MicrowinUserPassword.Password -eq "")
            {
                Microwin-NewUnattend -userName "$($sync.MicrowinUserName.Text)"
            }
            else
            {
                Microwin-NewUnattend -userName "$($sync.MicrowinUserName.Text)" -userPassword "$($sync.MicrowinUserPassword.Password)"
            }
        }
        Write-Host "Done Create unattend.xml"
        Write-Host "Copy unattend.xml file into the ISO"
        New-Item -ItemType Directory -Force -Path "$($scratchDir)\Windows\Panther"
        Copy-Item "$env:temp\unattend.xml" "$($scratchDir)\Windows\Panther\unattend.xml" -force
        New-Item -ItemType Directory -Force -Path "$($scratchDir)\Windows\System32\Sysprep"
        Copy-Item "$env:temp\unattend.xml" "$($scratchDir)\Windows\System32\Sysprep\unattend.xml" -force
        Copy-Item "$env:temp\unattend.xml" "$($scratchDir)\unattend.xml" -force
        Write-Host "Done Copy unattend.xml"

        Write-Host "Create FirstRun"
        Microwin-NewFirstRun
        Write-Host "Done create FirstRun"
        Write-Host "Copy FirstRun.ps1 into the ISO"
        Copy-Item "$env:temp\FirstStartup.ps1" "$($scratchDir)\Windows\FirstStartup.ps1" -force
        Write-Host "Done copy FirstRun.ps1"

        Write-Host "Copy link to evolveos.ps1 into the ISO"
        $desktopDir = "$($scratchDir)\Windows\Users\Default\Desktop"
        New-Item -ItemType Directory -Force -Path "$desktopDir"
        dism /English /image:$($scratchDir) /set-profilepath:"$($scratchDir)\Windows\Users\Default"

        Write-Host "Copy checkinstall.cmd into the ISO"
        Microwin-NewCheckInstall
        Copy-Item "$env:temp\checkinstall.cmd" "$($scratchDir)\Windows\checkinstall.cmd" -force
        Write-Host "Done copy checkinstall.cmd"

        Write-Host "Creating a directory that allows to bypass Wifi setup"
        New-Item -ItemType Directory -Force -Path "$($scratchDir)\Windows\System32\OOBE\BYPASSNRO"

        Write-Host "Loading registry"
        reg load HKLM\zCOMPONENTS "$($scratchDir)\Windows\System32\config\COMPONENTS"
        reg load HKLM\zDEFAULT "$($scratchDir)\Windows\System32\config\default"
        reg load HKLM\zNTUSER "$($scratchDir)\Users\Default\ntuser.dat"
        reg load HKLM\zSOFTWARE "$($scratchDir)\Windows\System32\config\SOFTWARE"
        reg load HKLM\zSYSTEM "$($scratchDir)\Windows\System32\config\SYSTEM"

        Write-Host "Disabling Teams"
        reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Communications" /v "ConfigureChatAutoInstall" /t REG_DWORD /d 0 /f   >$null 2>&1
        reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat" /v ChatIcon /t REG_DWORD /d 2 /f                             >$null 2>&1
        reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarMn" /t REG_DWORD /d 0 /f        >$null 2>&1
        reg query "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Communications" /v "ConfigureChatAutoInstall"                      >$null 2>&1
        # Write-Host Error code $LASTEXITCODE
        Write-Host "Done disabling Teams"

        Write-Host "Fix Windows Volume Mixer Issue"
        reg add "HKLM\zNTUSER\Software\Microsoft\Internet Explorer\LowRegistry\Audio\PolicyConfig\PropertyStore" /f

        Write-Host "Bypassing system requirements (system image)"
        reg add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v "SV1" /t REG_DWORD /d 0 /f
        reg add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v "SV2" /t REG_DWORD /d 0 /f
        reg add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache" /v "SV1" /t REG_DWORD /d 0 /f
        reg add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache" /v "SV2" /t REG_DWORD /d 0 /f
        reg add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassCPUCheck" /t REG_DWORD /d 1 /f
        reg add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassRAMCheck" /t REG_DWORD /d 1 /f
        reg add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassSecureBootCheck" /t REG_DWORD /d 1 /f
        reg add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassStorageCheck" /t REG_DWORD /d 1 /f
        reg add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassTPMCheck" /t REG_DWORD /d 1 /f
        reg add "HKLM\zSYSTEM\Setup\MoSetup" /v "AllowUpgradesWithUnsupportedTPMOrCPU" /t REG_DWORD /d 1 /f

        # Prevent Windows Update Installing so called Expedited Apps - 24H2 and newer
        if ((Microwin-TestCompatibleImage $imgVersion $([System.Version]::new(10,0,26100,1))) -eq $true) {
            @(
                'EdgeUpdate',
                'DevHomeUpdate',
                'OutlookUpdate',
                'CrossDeviceUpdate'
            ) | ForEach-Object {
                Write-Host "Removing Windows Expedited App: $_"

                # Copied here After Installation (Online)
                # reg delete "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\$_" /f | Out-Null

                # When in Offline Image
                reg delete "HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\$_" /f | Out-Null
            }
        }

        reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Search" /v "SearchboxTaskbarMode" /t REG_DWORD /d 0 /f
        Write-Host "Setting all services to start manually"
        reg add "HKLM\zSOFTWARE\CurrentControlSet\Services" /v Start /t REG_DWORD /d 3 /f
        # Write-Host $LASTEXITCODE

        Write-Host "Enabling Local Accounts on OOBE"
        reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v "BypassNRO" /t REG_DWORD /d "1" /f

        Write-Host "Disabling Sponsored Apps"
        reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "OemPreInstalledAppsEnabled" /t REG_DWORD /d 0 /f
        reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "PreInstalledAppsEnabled" /t REG_DWORD /d 0 /f
        reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "SilentInstalledAppsEnabled" /t REG_DWORD /d 0 /f
        reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableWindowsConsumerFeatures" /t REG_DWORD /d 1 /f
        reg add "HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start" /v "ConfigureStartPins" /t REG_SZ /d '{\"pinnedList\": [{}]}' /f
        Write-Host "Done removing Sponsored Apps"

        Write-Host "Disabling Reserved Storage"
        reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" /v "ShippedWithReserves" /t REG_DWORD /d 0 /f

        Write-Host "Changing theme to dark. This only works on Activated Windows"
        reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "AppsUseLightTheme" /t REG_DWORD /d 0 /f
        reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v "SystemUsesLightTheme" /t REG_DWORD /d 0 /f

        if ((Microwin-TestCompatibleImage $imgVersion $([System.Version]::new(10,0,21996,1))) -eq $false) {
            # We're dealing with Windows 10. Configure sane desktop settings. NOTE: even though stuff to disable News and Interests is there,
            # it doesn't seem to work, and I don't want to waste more time dealing with an operating system that will lose support in a year (2025)

            # I invite anyone to work on improving stuff for News and Interests, but that won't be me!

            Write-Host "Disabling Search Highlights..."
            reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Feeds\DSB" /v "ShowDynamicContent" /t REG_DWORD /d 0 /f
            reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" /v "IsDynamicSearchBoxEnabled" /t REG_DWORD /d 0 /f
            reg add "HKLM\zSOFTWARE\Policies\Microsoft\Dsh" /v "AllowNewsAndInterests" /t REG_DWORD /d 0 /f
            reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" /v "TraySearchBoxVisible" /t REG_DWORD /d 1 /f
        }

    } catch {
        Write-Error "An unexpected error occurred: $_"
    } finally {
        Write-Host "Unmounting Registry..."
        reg unload HKLM\zCOMPONENTS
        reg unload HKLM\zDEFAULT
        reg unload HKLM\zNTUSER
        reg unload HKLM\zSOFTWARE
        reg unload HKLM\zSYSTEM

        Write-Host "Cleaning up image..."
        dism /English /image:$scratchDir /Cleanup-Image /StartComponentCleanup /ResetBase
        Write-Host "Cleanup complete."

        Write-Host "Unmounting image..."
        Dismount-WindowsImage -Path "$scratchDir" -Save
    }

    try {

        Write-Host "Exporting image into $mountDir\sources\install2.wim"
        Export-WindowsImage -SourceImagePath "$mountDir\sources\install.wim" -SourceIndex $index -DestinationImagePath "$mountDir\sources\install2.wim" -CompressionType "Max"
        Write-Host "Remove old '$mountDir\sources\install.wim' and rename $mountDir\sources\install2.wim"
        Remove-Item "$mountDir\sources\install.wim"
        Rename-Item "$mountDir\sources\install2.wim" "$mountDir\sources\install.wim"

        if (-not (Test-Path -Path "$mountDir\sources\install.wim")) {
            Write-Error "Something went wrong and '$mountDir\sources\install.wim' doesn't exist. Please report this bug to the devs"
            Set-WinUtilTaskbaritem -state "Error" -value 1 -overlay "warning"
            return
        }
        Write-Host "Windows image completed. Continuing with boot.wim."

        # Next step boot image
        Write-Host "Mounting boot image $mountDir\sources\boot.wim into $scratchDir"
        Mount-WindowsImage -ImagePath "$mountDir\sources\boot.wim" -Index 2 -Path "$scratchDir"

        if ($injectDrivers) {
            $driverPath = $sync.MicrowinDriverLocation.Text
            if (Test-Path $driverPath) {
                Write-Host "Adding Windows Drivers image($scratchDir) drivers($driverPath) "
                dism /English /image:$scratchDir /add-driver /driver:$driverPath /recurse | Out-Host
            } else {
                Write-Host "Path to drivers is invalid continuing without driver injection"
            }
        }

        Write-Host "Loading registry..."
        reg load HKLM\zCOMPONENTS "$($scratchDir)\Windows\System32\config\COMPONENTS" >$null
        reg load HKLM\zDEFAULT "$($scratchDir)\Windows\System32\config\default" >$null
        reg load HKLM\zNTUSER "$($scratchDir)\Users\Default\ntuser.dat" >$null
        reg load HKLM\zSOFTWARE "$($scratchDir)\Windows\System32\config\SOFTWARE" >$null
        reg load HKLM\zSYSTEM "$($scratchDir)\Windows\System32\config\SYSTEM" >$null
        Write-Host "Bypassing system requirements on the setup image"
        reg add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v "SV1" /t REG_DWORD /d 0 /f
        reg add "HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v "SV2" /t REG_DWORD /d 0 /f
        reg add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache" /v "SV1" /t REG_DWORD /d 0 /f
        reg add "HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache" /v "SV2" /t REG_DWORD /d 0 /f
        reg add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassCPUCheck" /t REG_DWORD /d 1 /f
        reg add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassRAMCheck" /t REG_DWORD /d 1 /f
        reg add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassSecureBootCheck" /t REG_DWORD /d 1 /f
        reg add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassStorageCheck" /t REG_DWORD /d 1 /f
        reg add "HKLM\zSYSTEM\Setup\LabConfig" /v "BypassTPMCheck" /t REG_DWORD /d 1 /f
        reg add "HKLM\zSYSTEM\Setup\MoSetup" /v "AllowUpgradesWithUnsupportedTPMOrCPU" /t REG_DWORD /d 1 /f
        # Fix Computer Restarted Unexpectedly Error on New Bare Metal Install
        reg add "HKLM\zSYSTEM\Setup\Status\ChildCompletion" /v "setup.exe" /t REG_DWORD /d 3 /f
    } catch {
        Write-Error "An unexpected error occurred: $_"
    } finally {
        Write-Host "Unmounting Registry..."
        reg unload HKLM\zCOMPONENTS
        reg unload HKLM\zDEFAULT
        reg unload HKLM\zNTUSER
        reg unload HKLM\zSOFTWARE
        reg unload HKLM\zSYSTEM

        Write-Host "Unmounting image..."
        Dismount-WindowsImage -Path "$scratchDir" -Save

        Write-Host "Creating ISO image"

        # if we downloaded oscdimg from github it will be in the temp directory so use it
        # if it is not in temp it is part of ADK and is in global PATH so just set it to oscdimg.exe
        $oscdimgPath = Join-Path $env:TEMP 'oscdimg.exe'
        $oscdImgFound = Test-Path $oscdimgPath -PathType Leaf
        if (!$oscdImgFound) {
            $oscdimgPath = "oscdimg.exe"
        }

        Write-Host "[INFO] Using oscdimg.exe from: $oscdimgPath"

        $oscdimgProc = Start-Process -FilePath "$oscdimgPath" -ArgumentList "-m -o -u2 -udfver102 -bootdata:2#p0,e,b`"$mountDir\boot\etfsboot.com`"#pEF,e,b`"$mountDir\efi\microsoft\boot\efisys.bin`" `"$mountDir`" `"$($SaveDialog.FileName)`"" -Wait -PassThru -NoNewWindow

        $LASTEXITCODE = $oscdimgProc.ExitCode

        Write-Host "OSCDIMG Error Level : $($oscdimgProc.ExitCode)"

        if ($copyToUSB) {
            Write-Host "Copying target ISO to the USB drive"
            Microwin-CopyToUSB("$($SaveDialog.FileName)")
            if ($?) { Write-Host "Done Copying target ISO to USB drive!" } else { Write-Host "ISO copy failed." }
        }

        Write-Host " _____                       "
        Write-Host "(____ \                      "
        Write-Host " _   \ \ ___  ____   ____    "
        Write-Host "| |   | / _ \|  _ \ / _  )   "
        Write-Host "| |__/ / |_| | | | ( (/ /    "
        Write-Host "|_____/ \___/|_| |_|\____)   "

        # Check if the ISO was successfully created - CTT edit
        if ($LASTEXITCODE -eq 0) {
            Write-Host "`n`nPerforming Cleanup..."
                Remove-Item -Recurse -Force "$($scratchDir)"
                Remove-Item -Recurse -Force "$($mountDir)"
            $msg = "Done. ISO image is located here: $($SaveDialog.FileName)"
            Write-Host $msg
            Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
            [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        } else {
            Write-Host "ISO creation failed. The "$($mountDir)" directory has not been removed."
            try {
                # This creates a new Win32 exception from which we can extract a message in the system language.
                # Now, this will NOT throw an exception
                $exitCode = New-Object System.ComponentModel.Win32Exception($LASTEXITCODE)
                Write-Host "Reason: $($exitCode.Message)"
            } catch {
                # Could not get error description from Windows APIs
            }
        }

        $sync.MicrowinOptionsPanel.Visibility = 'Collapsed'

        #$sync.MicrowinFinalIsoLocation.Text = "$env:temp\microwin.iso"
        $sync.MicrowinFinalIsoLocation.Text = "$($SaveDialog.FileName)"
        # Allow the machine to sleep again (optional)
        [PowerManagement]::SetThreadExecutionState(0)
        $sync.ProcessRunning = $false
    }
}
function Invoke-MicrowinGetIso {
    <#
    .DESCRIPTION
    Function to get the path to Iso file for MicroWin, unpack that isom=, read basic information and populate the UI Options
    #>

    Write-Host "Invoking WPFGetIso"

    if($sync.ProcessRunning) {
        $msg = "GetIso process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $sync.BusyMessage.Visibility="Visible"
    $sync.BusyText.Text="N Busy"



    Write-Host "         _                     __    __  _         "
    Write-Host "  /\/\  (_)  ___  _ __   ___  / / /\ \ \(_) _ __   "
    Write-Host " /    \ | | / __|| '__| / _ \ \ \/  \/ /| || '_ \  "
    Write-Host "/ /\/\ \| || (__ | |   | (_) | \  /\  / | || | | | "
    Write-Host "\/    \/|_| \___||_|    \___/   \/  \/  |_||_| |_| "

    $oscdimgPath = Join-Path $env:TEMP 'oscdimg.exe'
    $oscdImgFound = [bool] (Get-Command -ErrorAction Ignore -Type Application oscdimg.exe) -or (Test-Path $oscdimgPath -PathType Leaf)
    Write-Host "oscdimg.exe on system: $oscdImgFound"

    if (!$oscdImgFound) {
        $downloadFromGitHub = $sync.WPFMicrowinDownloadFromGitHub.IsChecked
        $sync.BusyMessage.Visibility="Hidden"

        if (!$downloadFromGitHub) {
            # only show the message to people who did check the box to download from github, if you check the box
            # you consent to downloading it, no need to show extra dialogs
            [System.Windows.MessageBox]::Show("oscdimge.exe is not found on the system, winutil will now attempt do download and install it using choco. This might take a long time.")
            # the step below needs choco to download oscdimg
            # Install Choco if not already present
            Install-WinUtilChoco
            $chocoFound = [bool] (Get-Command -ErrorAction Ignore -Type Application choco)
            Write-Host "choco on system: $chocoFound"
            if (!$chocoFound) {
                [System.Windows.MessageBox]::Show("choco.exe is not found on the system, you need choco to download oscdimg.exe")
                return
            }

            Start-Process -Verb runas -FilePath powershell.exe -ArgumentList "choco install windows-adk-oscdimg"
            [System.Windows.MessageBox]::Show("oscdimg is installed, now close, reopen PowerShell terminal and re-launch winutil.ps1")
            return
        } else {
            [System.Windows.MessageBox]::Show("oscdimge.exe is not found on the system, winutil will now attempt do download and install it from github. This might take a long time.")
            Microwin-GetOscdimg -oscdimgPath $oscdimgPath
            $oscdImgFound = Test-Path $oscdimgPath -PathType Leaf
            if (!$oscdImgFound) {
                $msg = "oscdimg was not downloaded can not proceed"
                [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
                return
            } else {
                Write-Host "oscdimg.exe was successfully downloaded from github"
            }
        }
    }

    if ($sync["ISOmanual"].IsChecked) {
        # Open file dialog to let user choose the ISO file
        [System.Reflection.Assembly]::LoadWithPartialName("System.windows.forms") | Out-Null
        $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
        $openFileDialog.initialDirectory = $initialDirectory
        $openFileDialog.filter = "ISO files (*.iso)| *.iso"
        $openFileDialog.ShowDialog() | Out-Null
        $filePath = $openFileDialog.FileName

        if ([string]::IsNullOrEmpty($filePath)) {
            Write-Host "No ISO is chosen"
            $sync.BusyMessage.Visibility="Hidden"
            return
        }
    } elseif ($sync["ISOdownloader"].IsChecked) {
        # Create folder browsers for user-specified locations
        [System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") | Out-Null
        $isoDownloaderFBD = New-Object System.Windows.Forms.FolderBrowserDialog
        $isoDownloaderFBD.Description = "Please specify the path to download the ISO file to:"
        $isoDownloaderFBD.ShowNewFolderButton = $true
        if ($isoDownloaderFBD.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK)
        {
            return
        }

        # Grab the location of the selected path
        $targetFolder = $isoDownloaderFBD.SelectedPath

        # Auto download newest ISO
        # Credit: https://github.com/pbatard/Fido
        $fidopath = "$env:temp\Fido.ps1"
        $originalLocation = $PSScriptRoot

        Invoke-WebRequest "https://github.com/pbatard/Fido/raw/master/Fido.ps1" -OutFile $fidopath

        Set-Location -Path $env:temp
        # Detect if the first option ("System language") has been selected and get a Fido-approved language from the current culture
        $lang = if ($sync["ISOLanguage"].SelectedIndex -eq 0) {
            Microwin-GetLangFromCulture -langName (Get-Culture).Name
        } else {
            $sync["ISOLanguage"].SelectedItem
        }

        & $fidopath -Win 'Windows 11' -Rel $sync["ISORelease"].SelectedItem -Arch "x64" -Lang $lang -Ed "Windows 11 Home/Pro/Edu"
        if (-not $?)
        {
            Write-Host "Could not download the ISO file. Look at the output of the console for more information."
            $msg = "The ISO file could not be downloaded"
            [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
        }
        Set-Location $originalLocation
        # Use the FullName property to only grab the file names. Using this property is necessary as, without it, you're passing the usual output of Get-ChildItem
        # to the variable, and let's be honest, that does NOT exist in the file system
        $filePath = (Get-ChildItem -Path "$env:temp" -Filter "Win11*.iso").FullName | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $fileName = [IO.Path]::GetFileName("$filePath")

        if (($targetFolder -ne "") -and (Test-Path "$targetFolder"))
        {
            try
            {
                # "Let it download to $env:TEMP and then we **move** it to the file path." - CodingWonders
                $destinationFilePath = "$targetFolder\$fileName"
                Write-Host "Moving ISO file. Please wait..."
                Move-Item -Path "$filePath" -Destination "$destinationFilePath" -Force
                $filePath = $destinationFilePath
            }
            catch
            {
                Write-Host "Unable to move the ISO file to the location you specified. The downloaded ISO is in the `"$env:TEMP`" folder"
                Write-Host "Error information: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    Write-Host "File path $($filePath)"
    if (-not (Test-Path -Path "$filePath" -PathType Leaf)) {
        $msg = "File you've chosen doesn't exist"
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        return
    }

    Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"

    # Detect the file size of the ISO and compare it with the free space of the system drive
    $isoSize = (Get-Item -Path "$filePath").Length
    Write-Debug "Size of ISO file: $($isoSize) bytes"
    # Use this procedure to get the free space of the drive depending on where the user profile folder is stored.
    # This is done to guarantee a dynamic solution, as the installation drive may be mounted to a letter different than C
    $driveSpace = (Get-Volume -DriveLetter ([IO.Path]::GetPathRoot([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)).Replace(":\", "").Trim())).SizeRemaining
    Write-Debug "Free space on installation drive: $($driveSpace) bytes"
    if ($driveSpace -lt ($isoSize * 2)) {
        # It's not critical and we _may_ continue. Output a warning
        Write-Warning "You may not have enough space for this operation. Proceed at your own risk."
    }
    elseif ($driveSpace -lt $isoSize) {
        # It's critical and we can't continue. Output an error
        Write-Host "You don't have enough space for this operation. You need at least $([Math]::Round(($isoSize / ([Math]::Pow(1024, 2))) * 2, 2)) MB of free space to copy the ISO files to a temp directory and to be able to perform additional operations."
        Set-WinUtilTaskbaritem -state "Error" -value 1 -overlay "warning"
        return
    } else {
        Write-Host "You have enough space for this operation."
    }

    try {
        Write-Host "Mounting Iso. Please wait."
        $mountedISO = Mount-DiskImage -PassThru "$filePath"
        Write-Host "Done mounting Iso `"$($mountedISO.ImagePath)`""
        $driveLetter = (Get-Volume -DiskImage $mountedISO).DriveLetter
        Write-Host "Iso mounted to '$driveLetter'"
    } catch {
        # @ChrisTitusTech  please copy this wiki and change the link below to your copy of the wiki
        Write-Error "Failed to mount the image. Error: $($_.Exception.Message)"
        Write-Error "This is NOT winutil's problem, your ISO might be corrupt, or there is a problem on the system"
        Write-Host "Please refer to this wiki for more details: https://christitustech.github.io/winutil/KnownIssues/#troubleshoot-errors-during-microwin-usage" -ForegroundColor Red
        Set-WinUtilTaskbaritem -state "Error" -value 1 -overlay "warning"
        return
    }
    # storing off values in hidden fields for further steps
    # there is probably a better way of doing this, I don't have time to figure this out
    $sync.MicrowinIsoDrive.Text = $driveLetter

    $mountedISOPath = (Split-Path -Path "$filePath")
     if ($sync.MicrowinScratchDirBox.Text.Trim() -eq "Scratch") {
        $sync.MicrowinScratchDirBox.Text =""
    }

    $UseISOScratchDir = $sync.WPFMicrowinISOScratchDir.IsChecked

    if ($UseISOScratchDir) {
        $sync.MicrowinScratchDirBox.Text=$mountedISOPath
    }

    if( -Not $sync.MicrowinScratchDirBox.Text.EndsWith('\') -And  $sync.MicrowinScratchDirBox.Text.Length -gt 1) {

         $sync.MicrowinScratchDirBox.Text = Join-Path   $sync.MicrowinScratchDirBox.Text.Trim() '\'

    }

    # Detect if the folders already exist and remove them
    if (($sync.MicrowinMountDir.Text -ne "") -and (Test-Path -Path $sync.MicrowinMountDir.Text)) {
        try {
            Write-Host "Deleting temporary files from previous run. Please wait..."
            Remove-Item -Path $sync.MicrowinMountDir.Text -Recurse -Force
            Remove-Item -Path $sync.MicrowinScratchDir.Text -Recurse -Force
        } catch {
            Write-Host "Could not delete temporary files. You need to delete those manually."
        }
    }

    Write-Host "Setting up mount dir and scratch dirs"
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $randomNumber = Get-Random -Minimum 1 -Maximum 9999
    $randomMicrowin = "Microwin_${timestamp}_${randomNumber}"
    $randomMicrowinScratch = "MicrowinScratch_${timestamp}_${randomNumber}"
    $sync.BusyText.Text=" - Mounting"
    Write-Host "Mounting Iso. Please wait."
    if ($sync.MicrowinScratchDirBox.Text -eq "") {
        $mountDir = Join-Path $env:TEMP $randomMicrowin
        $scratchDir = Join-Path $env:TEMP $randomMicrowinScratch
    } else {
        $scratchDir = $sync.MicrowinScratchDirBox.Text+"Scratch"
        $mountDir = $sync.MicrowinScratchDirBox.Text+"micro"
    }

    $sync.MicrowinMountDir.Text = $mountDir
    $sync.MicrowinScratchDir.Text = $scratchDir
    Write-Host "Done setting up mount dir and scratch dirs"
    Write-Host "Scratch dir is $scratchDir"
    Write-Host "Image dir is $mountDir"

    try {

        #$data = @($driveLetter, $filePath)
        New-Item -ItemType Directory -Force -Path "$($mountDir)" | Out-Null
        New-Item -ItemType Directory -Force -Path "$($scratchDir)" | Out-Null
        Write-Host "Copying Windows image. This will take awhile, please don't use UI or cancel this step!"

        # xcopy we can verify files and also not copy files that already exist, but hard to measure
        # xcopy.exe /E /I /H /R /Y /J $DriveLetter":" $mountDir >$null
        $totalTime = Measure-Command { Copy-Files "$($driveLetter):" "$mountDir" -Recurse -Force }
        Write-Host "Copy complete! Total Time: $($totalTime.Minutes) minutes, $($totalTime.Seconds) seconds"

        $wimFile = "$mountDir\sources\install.wim"
        Write-Host "Getting image information $wimFile"

        if ((-not (Test-Path -Path "$wimFile" -PathType Leaf)) -and (-not (Test-Path -Path "$($wimFile.Replace(".wim", ".esd").Trim())" -PathType Leaf))) {
            $msg = "Neither install.wim nor install.esd exist in the image, this could happen if you use unofficial Windows images. Please don't use shady images from the internet, use only official images. Here are instructions how to download ISO images if the Microsoft website is not showing the link to download and ISO. https://www.techrepublic.com/article/how-to-download-a-windows-10-iso-file-without-using-the-media-creation-tool/"
            Write-Host $msg
            [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            Set-WinUtilTaskbaritem -state "Error" -value 1 -overlay "warning"
            throw
        }
        elseif ((-not (Test-Path -Path $wimFile -PathType Leaf)) -and (Test-Path -Path $wimFile.Replace(".wim", ".esd").Trim() -PathType Leaf)) {
            Write-Host "Install.esd found on the image. It needs to be converted to a WIM file in order to begin processing"
            $wimFile = $wimFile.Replace(".wim", ".esd").Trim()
        }
        $sync.MicrowinWindowsFlavors.Items.Clear()
        Get-WindowsImage -ImagePath $wimFile | ForEach-Object {
            $imageIdx = $_.ImageIndex
            $imageName = $_.ImageName
            $sync.MicrowinWindowsFlavors.Items.Add("$imageIdx : $imageName")
        }
        $sync.MicrowinWindowsFlavors.SelectedIndex = 0
        Write-Host "Finding suitable Pro edition. This can take some time. Do note that this is an automatic process that might not select the edition you want."
        Get-WindowsImage -ImagePath $wimFile | ForEach-Object {
            if ((Get-WindowsImage -ImagePath $wimFile -Index $_.ImageIndex).EditionId -eq "Professional") {
                # We have found the Pro edition
                $sync.MicrowinWindowsFlavors.SelectedIndex = $_.ImageIndex - 1
            }
        }
        Get-Volume $driveLetter | Get-DiskImage | Dismount-DiskImage
        Write-Host "Selected value '$($sync.MicrowinWindowsFlavors.SelectedValue)'....."

        $sync.MicrowinOptionsPanel.Visibility = 'Visible'
    } catch {
        Write-Host "Dismounting bad image..."
        Get-Volume $driveLetter | Get-DiskImage | Dismount-DiskImage
        Remove-Item -Recurse -Force "$($scratchDir)"
        Remove-Item -Recurse -Force "$($mountDir)"
    }

    Write-Host "Done reading and unpacking ISO"
    Write-Host ""
    Write-Host "*********************************"
    Write-Host "Check the UI for further steps!!!"

    $sync.BusyMessage.Visibility="Hidden"
    $sync.ProcessRunning = $false
    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
}
class ErroredPackage {
    [string]$PackageName
    [string]$ErrorMessage
    ErroredPackage() { $this.Init(@{} )}
    # Constructor for packages that have errored out
    ErroredPackage([string]$pkgName, [string]$reason) {
        $this.PackageName = $pkgName
        $this.ErrorMessage = $reason
    }
}
function Microwin-CopyToUSB([string]$fileToCopy) {
    foreach ($volume in Get-Volume) {
        if ($volume -and $volume.FileSystemLabel -ieq "ventoy") {
            $destinationPath = "$($volume.DriveLetter):\"
            #Copy-Item -Path $fileToCopy -Destination $destinationPath -Force
            # Get the total size of the file
            $totalSize = (Get-Item "$fileToCopy").length

            Copy-Item -Path "$fileToCopy" -Destination "$destinationPath" -Verbose -Force -Recurse -Container -PassThru |
                ForEach-Object {
                    # Calculate the percentage completed
                    $completed = ($_.BytesTransferred / $totalSize) * 100

                    # Display the progress bar
                    Write-Progress -Activity "Copying File" -Status "Progress" -PercentComplete $completed -CurrentOperation ("{0:N2} MB / {1:N2} MB" -f ($_.BytesTransferred / 1MB), ($totalSize / 1MB))
                }

            Write-Host "File copied to Ventoy drive $($volume.DriveLetter)"

            # Detect if config files are present, move them if they are, and configure the Ventoy drive to not bypass the requirements
            $customVentoyConfig = @'
{
    "control":[
        { "VTOY_WIN11_BYPASS_CHECK": "0" },
        { "VTOY_WIN11_BYPASS_NRO": "0" }
    ],
    "control_legacy":[
        { "VTOY_WIN11_BYPASS_CHECK": "0" },
        { "VTOY_WIN11_BYPASS_NRO": "0" }
    ],
    "control_uefi":[
        { "VTOY_WIN11_BYPASS_CHECK": "0" },
        { "VTOY_WIN11_BYPASS_NRO": "0" }
    ],
    "control_ia32":[
        { "VTOY_WIN11_BYPASS_CHECK": "0" },
        { "VTOY_WIN11_BYPASS_NRO": "0" }
    ],
    "control_aa64":[
        { "VTOY_WIN11_BYPASS_CHECK": "0" },
        { "VTOY_WIN11_BYPASS_NRO": "0" }
    ],
    "control_mips":[
        { "VTOY_WIN11_BYPASS_CHECK": "0" },
        { "VTOY_WIN11_BYPASS_NRO": "0" }
    ]
}
'@

            try {
                Write-Host "Writing custom Ventoy configuration. Please wait..."
                if (Test-Path -Path "$($volume.DriveLetter):\ventoy\ventoy.json" -PathType Leaf) {
                    Write-Host "A Ventoy configuration file exists. Moving it..."
                    Move-Item -Path "$($volume.DriveLetter):\ventoy\ventoy.json" -Destination "$($volume.DriveLetter):\ventoy\ventoy.json.old" -Force
                    Write-Host "Existing Ventoy configuration has been moved to `"ventoy.json.old`". Feel free to put your config back into the `"ventoy.json`" file."
                }
                if (-not (Test-Path -Path "$($volume.DriveLetter):\ventoy")) {
                    New-Item -Path "$($volume.DriveLetter):\ventoy" -ItemType Directory -Force | Out-Null
                }
                $customVentoyConfig | Out-File -FilePath "$($volume.DriveLetter):\ventoy\ventoy.json" -Encoding utf8 -Force
                Write-Host "The Ventoy drive has been successfully configured."
            } catch {
                Write-Host "Could not configure Ventoy drive. Error: $($_.Exception.Message)`n"
                Write-Host "Be sure to add the following configuration to the Ventoy drive by either creating a `"ventoy.json`" file in the `"ventoy`" directory (create it if it doesn't exist) or by editing an existing one: `n`n$customVentoyConfig`n"
                Write-Host "Failure to do this will cause conflicts with your target ISO file."
            }
            return
        }
    }
    Write-Host "Ventoy USB Key is not inserted"
}
function Microwin-CopyVirtIO {
    <#
        .SYNOPSIS
            Downloads and copies the VirtIO Guest Tools drivers to the target MicroWin ISO
        .NOTES
            A network connection must be available and the servers of Fedora People must be up. Automatic driver installation will not be added yet - I want this implementation to be reliable.
    #>

    try {
        Write-Host "Checking existing files..."
        if (Test-Path -Path "$($env:TEMP)\virtio.iso" -PathType Leaf) {
            Write-Host "VirtIO ISO has been detected. Deleting..."
            Remove-Item -Path "$($env:TEMP)\virtio.iso" -Force
        }
        Write-Host "Getting latest VirtIO drivers. Please wait. This can take some time, depending on your network connection speed and the speed of the servers..."
        Start-BitsTransfer -Source "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso" -Destination "$($env:TEMP)\virtio.iso" -DisplayName "Downloading VirtIO drivers..."
        # Do everything else if the VirtIO ISO exists
        if (Test-Path -Path "$($env:TEMP)\virtio.iso" -PathType Leaf) {
            Write-Host "Mounting ISO. Please wait."
            $virtIO_ISO = Mount-DiskImage -PassThru "$($env:TEMP)\virtio.iso"
            $driveLetter = (Get-Volume -DiskImage $virtIO_ISO).DriveLetter
            # Create new directory for VirtIO on ISO
            New-Item -Path "$mountDir\VirtIO" -ItemType Directory | Out-Null
            $totalTime = Measure-Command { Copy-Files "$($driveLetter):" "$mountDir\VirtIO" -Recurse -Force }
            Write-Host "VirtIO contents have been successfully copied. Time taken: $($totalTime.Minutes) minutes, $($totalTime.Seconds) seconds`n"
            Get-Volume $driveLetter | Get-DiskImage | Dismount-DiskImage
            Remove-Item -Path "$($env:TEMP)\virtio.iso" -Force -ErrorAction SilentlyContinue
            Write-Host "To proceed with installation of the MicroWin image in QEMU/Proxmox VE:"
            Write-Host "1. Proceed with Setup until you reach the disk selection screen, in which you won't see any drives"
            Write-Host "2. Click `"Load Driver`" and click Browse"
            Write-Host "3. In the folder selection dialog, point to this path:`n`n    `"D:\VirtIO\vioscsi\w11\amd64`" (replace amd64 with ARM64 if you are using Windows on ARM, and `"D:`" with the drive letter of the ISO)`n"
            Write-Host "4. Select all drivers that will appear in the list box and click OK"
        } else {
            throw "Could not download VirtIO drivers"
        }
    } catch {
        Write-Host "We could not download and/or prepare the VirtIO drivers. Error information: $_`n"
        Write-Host "You will need to download these drivers manually. Location: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
    }
}
function Microwin-GetLangFromCulture {

    param (
        [Parameter(Mandatory, Position = 0)] [string]$langName
    )

    switch -Wildcard ($langName)
    {
        "ar*" { return "Arabic" }
        "pt-BR" { return "Brazilian Portuguese" }
        "bg*" { return "Bulgarian" }
        {($_ -eq "zh-CH") -or ($_ -like "zh-Hans*") -or ($_ -eq "zh-SG") -or ($_ -eq "zh-CHS")} { return "Chinese (Simplified)" }
        {($_ -eq "zh") -or ($_ -eq "zh-Hant") -or ($_ -eq "zh-HK") -or ($_ -eq "zh-MO") -or ($_ -eq "zh-TW") -or ($_ -eq "zh-CHT")} { return "Chinese (Traditional)" }
        "hr*" { return "Croatian" }
        "cs*" { return "Czech" }
        "da*" { return "Danish" }
        "nl*" { return "Dutch" }
        "en-US" { return "English" }
        {($_ -like "en*") -and ($_ -ne "en-US")} { return "English International" }
        "et*" { return "Estonian" }
        "fi*" { return "Finnish" }
        {($_ -like "fr*") -and ($_ -ne "fr-CA")} { return "French" }
        "fr-CA" { return "French Canadian" }
        "de*" { return "German" }
        "el*" { return "Greek" }
        "he*" { return "Hebrew" }
        "hu*" { return "Hungarian" }
        "it*" { return "Italian" }
        "ja*" { return "Japanese" }
        "ko*" { return "Korean" }
        "lv*" { return "Latvian" }
        "lt*" { return "Lituanian" }
        "nb*" { return "Norwegian" }
        "pl*" { return "Polish" }
        {($_ -like "pt*") -and ($_ -ne "pt-BR")} { return "Portuguese" }
        "ro*" { return "Romanian" }
        "ru*" { return "Russian" }
        "sr-Latn*" { return "Serbian Latin" }
        "sk*" { return "Slovak" }
        "sl*" { return "Slovenian" }
        {($_ -like "es*") -and ($_ -ne "es-MX")} { return "Spanish" }
        "es-MX" { return "Spanish (Mexico)" }
        "sv*" { return "Swedish" }
        "th*" { return "Thai" }
        "tr*" { return "Turkish" }
        "uk*" { return "Ukrainian" }
        default { return "English" }
    }
}
function Microwin-GetLocalizedUsers
{
    <#
        .SYNOPSIS
            Gets a localized user group representation for ICACLS commands (Port from DISMTools PE Helper)
        .PARAMETER admins
            Determines whether to get a localized user group representation for the Administrators user group
        .OUTPUTS
            A string containing the localized user group
        .EXAMPLE
            Microwin-GetLocalizedUsers -admins $true
    #>
    param (
        [Parameter(Mandatory = $true, Position = 0)] [bool]$admins
    )
    if ($admins) {
        return (Get-LocalGroup | Where-Object { $_.SID.Value -like "S-1-5-32-544" }).Name
    } else {
        return (Get-LocalGroup | Where-Object { $_.SID.Value -like "S-1-5-32-545" }).Name
    }
}
function Microwin-GetOscdimg {
    <#
        .DESCRIPTION
        This function will download oscdimg file from github Release folders and put it into env:temp folder

        .EXAMPLE
        Microwin-GetOscdimg
    #>

    param(
        [Parameter(Mandatory, position=0)]
        [string]$oscdimgPath
    )

    $oscdimgPath = "$env:TEMP\oscdimg.exe"
    $downloadUrl = "https://github.com/ChrisTitusTech/winutil/raw/main/releases/oscdimg.exe"
    Invoke-RestMethod -Uri $downloadUrl -OutFile $oscdimgPath
    $hashResult = Get-FileHash -Path $oscdimgPath -Algorithm SHA256
    $sha256Hash = $hashResult.Hash

    Write-Host "[INFO] oscdimg.exe SHA-256 Hash: $sha256Hash"

    $expectedHash = "AB9E161049D293B544961BFDF2D61244ADE79376D6423DF4F60BF9B147D3C78D"  # Replace with the actual expected hash
    if ($sha256Hash -eq $expectedHash) {
        Write-Host "Hashes match. File is verified."
    } else {
        Write-Host "Hashes do not match. File may be corrupted or tampered with."
    }
}
function Microwin-NewCheckInstall {

    # using here string to embedd firstrun
    $checkInstall = @'
    @echo off
    if exist "%HOMEDRIVE%\windows\cpu.txt" (
        echo %HOMEDRIVE%\windows\cpu.txt exists
    ) else (
        echo %HOMEDRIVE%\windows\cpu.txt does not exist
    )
    if exist "%HOMEDRIVE%\windows\SerialNumber.txt" (
        echo %HOMEDRIVE%\windows\SerialNumber.txt exists
    ) else (
        echo %HOMEDRIVE%\windows\SerialNumber.txt does not exist
    )
    if exist "%HOMEDRIVE%\unattend.xml" (
        echo %HOMEDRIVE%\unattend.xml exists
    ) else (
        echo %HOMEDRIVE%\unattend.xml does not exist
    )
    if exist "%HOMEDRIVE%\Windows\Setup\Scripts\SetupComplete.cmd" (
        echo %HOMEDRIVE%\Windows\Setup\Scripts\SetupComplete.cmd exists
    ) else (
        echo %HOMEDRIVE%\Windows\Setup\Scripts\SetupComplete.cmd does not exist
    )
    if exist "%HOMEDRIVE%\Windows\Panther\unattend.xml" (
        echo %HOMEDRIVE%\Windows\Panther\unattend.xml exists
    ) else (
        echo %HOMEDRIVE%\Windows\Panther\unattend.xml does not exist
    )
    if exist "%HOMEDRIVE%\Windows\System32\Sysprep\unattend.xml" (
        echo %HOMEDRIVE%\Windows\System32\Sysprep\unattend.xml exists
    ) else (
        echo %HOMEDRIVE%\Windows\System32\Sysprep\unattend.xml does not exist
    )
    if exist "%HOMEDRIVE%\Windows\FirstStartup.ps1" (
        echo %HOMEDRIVE%\Windows\FirstStartup.ps1 exists
    ) else (
        echo %HOMEDRIVE%\Windows\FirstStartup.ps1 does not exist
    )
    if exist "%HOMEDRIVE%\Windows\winutil.ps1" (
        echo %HOMEDRIVE%\Windows\winutil.ps1 exists
    ) else (
        echo %HOMEDRIVE%\Windows\winutil.ps1 does not exist
    )
    if exist "%HOMEDRIVE%\Windows\LogSpecialize.txt" (
        echo %HOMEDRIVE%\Windows\LogSpecialize.txt exists
    ) else (
        echo %HOMEDRIVE%\Windows\LogSpecialize.txt does not exist
    )
    if exist "%HOMEDRIVE%\Windows\LogAuditUser.txt" (
        echo %HOMEDRIVE%\Windows\LogAuditUser.txt exists
    ) else (
        echo %HOMEDRIVE%\Windows\LogAuditUser.txt does not exist
    )
    if exist "%HOMEDRIVE%\Windows\LogOobeSystem.txt" (
        echo %HOMEDRIVE%\Windows\LogOobeSystem.txt exists
    ) else (
        echo %HOMEDRIVE%\Windows\LogOobeSystem.txt does not exist
    )
    if exist "%HOMEDRIVE%\windows\csup.txt" (
        echo %HOMEDRIVE%\windows\csup.txt exists
    ) else (
        echo %HOMEDRIVE%\windows\csup.txt does not exist
    )
    if exist "%HOMEDRIVE%\windows\LogFirstRun.txt" (
        echo %HOMEDRIVE%\windows\LogFirstRun.txt exists
    ) else (
        echo %HOMEDRIVE%\windows\LogFirstRun.txt does not exist
    )
'@
    $checkInstall | Out-File -FilePath "$env:temp\checkinstall.cmd" -Force -Encoding Ascii
}
function Microwin-NewFirstRun {

    # using here string to embedd firstrun
    $firstRun = @'
    # Set the global error action preference to continue
    $ErrorActionPreference = "Continue"
    function Remove-RegistryValue {
        param (
            [Parameter(Mandatory = $true)]
            [string]$RegistryPath,

            [Parameter(Mandatory = $true)]
            [string]$ValueName
        )

        # Check if the registry path exists
        if (Test-Path -Path $RegistryPath) {
            $registryValue = Get-ItemProperty -Path $RegistryPath -Name $ValueName -ErrorAction SilentlyContinue

            # Check if the registry value exists
            if ($registryValue) {
                # Remove the registry value
                Remove-ItemProperty -Path $RegistryPath -Name $ValueName -Force
                Write-Host "Registry value '$ValueName' removed from '$RegistryPath'."
            } else {
                Write-Host "Registry value '$ValueName' not found in '$RegistryPath'."
            }
        } else {
            Write-Host "Registry path '$RegistryPath' not found."
        }
    }

    "FirstStartup has worked" | Out-File -FilePath "$env:HOMEDRIVE\windows\LogFirstRun.txt" -Append -NoClobber

    $taskbarPath = "$env:AppData\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    # Delete all files on the Taskbar
    Get-ChildItem -Path $taskbarPath -File | Remove-Item -Force
    Remove-RegistryValue -RegistryPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband" -ValueName "FavoritesRemovedChanges"
    Remove-RegistryValue -RegistryPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband" -ValueName "FavoritesChanges"
    Remove-RegistryValue -RegistryPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband" -ValueName "Favorites"

    # Delete Edge Icon from the desktop
    $edgeShortcutFiles = Get-ChildItem -Path $desktopPath -Filter "*Edge*.lnk"
    # Check if Edge shortcuts exist on the desktop
    if ($edgeShortcutFiles) {
        foreach ($shortcutFile in $edgeShortcutFiles) {
            # Remove each Edge shortcut
            Remove-Item -Path $shortcutFile.FullName -Force
            Write-Host "Edge shortcut '$($shortcutFile.Name)' removed from the desktop."
        }
    }
    Remove-Item -Path "$env:USERPROFILE\Desktop\*.lnk"
    Remove-Item -Path "$env:HOMEDRIVE\Users\Default\Desktop\*.lnk"

    try
    {
        if ((Get-WindowsOptionalFeature -Online | Where-Object { $_.FeatureName -like "Recall" }).Count -gt 0)
        {
            Disable-WindowsOptionalFeature -Online -FeatureName "Recall" -Remove
        }
    }
    catch
    {

    }

    # Get BCD entries and set bootmgr timeout accordingly
    try
    {
        # Check if the number of occurrences of "path" is 2 - this fixes the Boot Manager screen issue (#2562)
        if ((bcdedit | Select-String "path").Count -eq 2)
        {
            # Set bootmgr timeout to 0
            bcdedit /set `{bootmgr`} timeout 0
        }
    }
    catch
    {

    }

'@
    $firstRun | Out-File -FilePath "$env:temp\FirstStartup.ps1" -Force
}
function Microwin-NewUnattend {

    param (
        [Parameter(Mandatory, Position = 0)] [string]$userName,
        [Parameter(Position = 1)] [string]$userPassword
    )

    $unattend = @'
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend"
            xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <#REPLACEME#>
        <settings pass="auditUser">
            <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                <RunSynchronous>
                    <RunSynchronousCommand wcm:action="add">
                        <Order>1</Order>
                        <CommandLine>CMD /C echo LAU GG&gt;C:\Windows\LogAuditUser.txt</CommandLine>
                        <Description>StartMenu</Description>
                    </RunSynchronousCommand>
                </RunSynchronous>
            </component>
        </settings>
        <settings pass="oobeSystem">
            <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                <UserAccounts>
                    <LocalAccounts>
                        <LocalAccount wcm:action="add">
                            <Name>USER-REPLACEME</Name>
                            <Group>Administrators</Group>
                            <Password>
                                <Value>PW-REPLACEME</Value>
                                <PlainText>PT-STATUS</PlainText>
                            </Password>
                        </LocalAccount>
                    </LocalAccounts>
                </UserAccounts>
                <AutoLogon>
                    <Username>USER-REPLACEME</Username>
                    <Enabled>true</Enabled>
                    <LogonCount>1</LogonCount>
                    <Password>
                        <Value>PW-REPLACEME</Value>
                        <PlainText>PT-STATUS</PlainText>
                    </Password>
                </AutoLogon>
                <OOBE>
                    <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                    <SkipUserOOBE>true</SkipUserOOBE>
                    <SkipMachineOOBE>true</SkipMachineOOBE>
                    <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                    <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                    <HideEULAPage>true</HideEULAPage>
                    <ProtectYourPC>3</ProtectYourPC>
                </OOBE>
                <FirstLogonCommands>
                    <SynchronousCommand wcm:action="add">
                        <Order>1</Order>
                        <CommandLine>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoLogonCount /t REG_DWORD /d 0 /f</CommandLine>
                    </SynchronousCommand>
                    <SynchronousCommand wcm:action="add">
                        <Order>2</Order>
                        <CommandLine>cmd.exe /c echo 23&gt;c:\windows\csup.txt</CommandLine>
                    </SynchronousCommand>
                    <SynchronousCommand wcm:action="add">
                        <Order>3</Order>
                        <CommandLine>CMD /C echo GG&gt;C:\Windows\LogOobeSystem.txt</CommandLine>
                    </SynchronousCommand>
                    <SynchronousCommand wcm:action="add">
                        <Order>4</Order>
                        <CommandLine>powershell -ExecutionPolicy Bypass -File c:\windows\FirstStartup.ps1</CommandLine>
                    </SynchronousCommand>
                </FirstLogonCommands>
            </component>
        </settings>
    </unattend>
'@
    $specPass = @'
<settings pass="specialize">
        <component name="Microsoft-Windows-SQMApi" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <CEIPEnabled>0</CEIPEnabled>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ConfigureChatAutoInstall>false</ConfigureChatAutoInstall>
        </component>
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>reg.exe load "HKU\DefaultUser" "C:\Users\Default\NTUSER.DAT"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Runonce" /v "UninstallCopilot" /t REG_SZ /d "powershell.exe -NoProfile -Command \"Get-AppxPackage -Name 'Microsoft.Windows.Ai.Copilot.Provider' | Remove-AppxPackage;\"" /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <Path>reg.exe add "HKU\DefaultUser\Software\Policies\Microsoft\Windows\WindowsCopilot" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>5</Order>
                    <Path>reg.exe unload "HKU\DefaultUser"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>6</Order>
                    <Path>reg.exe delete "HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate" /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>7</Order>
                    <Path>reg.exe load "HKU\DefaultUser" "C:\Users\Default\NTUSER.DAT"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>8</Order>
                    <Path>reg.exe add "HKU\DefaultUser\Software\Microsoft\Notepad" /v ShowStoreBanner /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>9</Order>
                    <Path>reg.exe unload "HKU\DefaultUser"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>10</Order>
                    <Path>cmd.exe /c "del "C:\Users\Default\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\OneDrive.lnk""</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>11</Order>
                    <Path>cmd.exe /c "del "C:\Windows\System32\OneDriveSetup.exe""</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>12</Order>
                    <Path>cmd.exe /c "del "C:\Windows\SysWOW64\OneDriveSetup.exe""</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>13</Order>
                    <Path>reg.exe load "HKU\DefaultUser" "C:\Users\Default\NTUSER.DAT"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>14</Order>
                    <Path>reg.exe delete "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Run" /v OneDriveSetup /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>15</Order>
                    <Path>reg.exe unload "HKU\DefaultUser"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>16</Order>
                    <Path>reg.exe delete "HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate" /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>17</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Communications" /v ConfigureChatAutoInstall /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>18</Order>
                    <Path>powershell.exe -NoProfile -Command "$xml = [xml]::new(); $xml.Load('C:\Windows\Panther\unattend.xml'); $sb = [scriptblock]::Create( $xml.unattend.Extensions.ExtractScript ); Invoke-Command -ScriptBlock $sb -ArgumentList $xml;"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>19</Order>
                    <Path>powershell.exe -NoProfile -Command "Get-Content -LiteralPath 'C:\Windows\Temp\Microwin-RemovePackages.ps1' -Raw | Invoke-Expression;"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>20</Order>
                    <Path>powershell.exe -NoProfile -Command "Get-Content -LiteralPath 'C:\Windows\Temp\remove-caps.ps1' -Raw | Invoke-Expression;"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>21</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start" /v ConfigureStartPins /t REG_SZ /d "{ \"pinnedList\": [] }" /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>22</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start" /v ConfigureStartPins_ProviderSet /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>23</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start" /v ConfigureStartPins_WinningProvider /t REG_SZ /d B5292708-1619-419B-9923-E5D9F3925E71 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>24</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\providers\B5292708-1619-419B-9923-E5D9F3925E71\default\Device\Start" /v ConfigureStartPins /t REG_SZ /d "{ \"pinnedList\": [] }" /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>25</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\providers\B5292708-1619-419B-9923-E5D9F3925E71\default\Device\Start" /v ConfigureStartPins_LastWrite /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>26</Order>
                    <Path>net.exe accounts /maxpwage:UNLIMITED</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>27</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>28</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>29</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Dsh" /v AllowNewsAndInterests /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>30</Order>
                    <Path>reg.exe load "HKU\DefaultUser" "C:\Users\Default\NTUSER.DAT"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>31</Order>
                    <Path>reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "ContentDeliveryAllowed" /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>32</Order>
                    <Path>reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "FeatureManagementEnabled" /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>33</Order>
                    <Path>reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "OEMPreInstalledAppsEnabled" /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>34</Order>
                    <Path>reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "PreInstalledAppsEnabled" /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>35</Order>
                    <Path>reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "PreInstalledAppsEverEnabled" /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>36</Order>
                    <Path>reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "SilentInstalledAppsEnabled" /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>37</Order>
                    <Path>reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "SoftLandingEnabled" /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>38</Order>
                    <Path>reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "SubscribedContentEnabled" /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>39</Order>
                    <Path>reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "SubscribedContent-310093Enabled" /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>40</Order>
                    <Path>reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "SubscribedContent-338387Enabled" /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>41</Order>
                    <Path>reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "SubscribedContent-338388Enabled" /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>42</Order>
                    <Path>reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "SubscribedContent-338389Enabled" /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>43</Order>
                    <Path>reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "SubscribedContent-338393Enabled" /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>44</Order>
                    <Path>reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "SubscribedContent-353698Enabled" /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>45</Order>
                    <Path>reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "SystemPaneSuggestionsEnabled" /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>46</Order>
                    <Path>reg.exe unload "HKU\DefaultUser"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>47</Order>
                    <Path>reg.exe add "HKLM\Software\Policies\Microsoft\Windows\CloudContent" /v "DisableWindowsConsumerFeatures" /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>48</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\BitLocker" /v "PreventDeviceEncryption" /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>49</Order>
                    <Path>reg.exe load "HKU\DefaultUser" "C:\Users\Default\NTUSER.DAT"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>50</Order>
                    <Path>reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Runonce" /v "ClassicContextMenu" /t REG_SZ /d "reg.exe add \"HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32\" /ve /f" /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>51</Order>
                    <Path>reg.exe unload "HKU\DefaultUser"</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
'@
    if ((Microwin-TestCompatibleImage $imgVersion $([System.Version]::new(10,0,22000,1))) -eq $false) {
        # Replace the placeholder text with an empty string to make it valid for Windows 10 Setup
        $unattend = $unattend.Replace("<#REPLACEME#>", "").Trim()
    } else {
        # Replace the placeholder text with the Specialize pass
        $unattend = $unattend.Replace("<#REPLACEME#>", $specPass).Trim()
    }

    # User password in Base64. According to Microsoft, this is the way you can hide this sensitive information.
    # More information can be found here: https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/wsim/hide-sensitive-data-in-an-answer-file
    # Yeah, I know this is not the best way to protect this kind of data, but we all know how Microsoft is - "the Apple of security" (in a sense, it takes them
    # an eternity to implement basic security features right. Just look at the NTLM and Kerberos situation!)

    $b64pass = ""

    # Replace default User and Password values with the provided parameters
    $unattend = $unattend.Replace("USER-REPLACEME", $userName).Trim()
    try {
        # I want to play it safe here - I don't want encoding mismatch problems like last time

        # NOTE: "Password" needs to be appended to the password specified by the user. Otherwise, a parse error will occur when processing oobeSystem.
        # This will not be added to the actual password stored in the target system's SAM file - only the provided password
        $b64pass = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes("$($userPassword)Password"))
    } catch {
        $b64pass = ""
    }
    if ($b64pass -ne "") {
        # If we could encode the password with Base64, put it in the answer file and indicate that it's NOT in plain text
        $unattend = $unattend.Replace("PW-REPLACEME", $b64pass).Trim()
        $unattend = $unattend.Replace("PT-STATUS", "false").Trim()
        $b64pass = ""
    } else {
        $unattend = $unattend.Replace("PW-REPLACEME", $userPassword).Trim()
        $unattend = $unattend.Replace("PT-STATUS", "true").Trim()
    }

    # Save unattended answer file with UTF-8 encoding
    $unattend | Out-File -FilePath "$env:temp\unattend.xml" -Force -Encoding utf8
}
function Microwin-RemoveFeatures() {
    <#
        .SYNOPSIS
            Removes certain features from ISO image

        .PARAMETER UseCmdlets
            Determines whether or not to use the DISM cmdlets for processing.
            - If true, DISM cmdlets will be used
            - If false, calls to the DISM executable will be made whilst selecting bits and pieces from the output as a string (that was how MicroWin worked before
              the DISM conversion to cmdlets)

        .EXAMPLE
            Microwin-RemoveFeatures -UseCmdlets $true
    #>
    param (
        [Parameter(Mandatory = $true, Position = 0)] [bool]$UseCmdlets
    )
    try {
        if ($UseCmdlets) {
            $featlist = (Get-WindowsOptionalFeature -Path "$scratchDir")

            $featlist = $featlist | Where-Object {
                $_.FeatureName -NotLike "*Defender*" -AND
                $_.FeatureName -NotLike "*Printing*" -AND
                $_.FeatureName -NotLike "*TelnetClient*" -AND
                $_.FeatureName -NotLike "*PowerShell*" -AND
                $_.FeatureName -NotLike "*NetFx*" -AND
                $_.FeatureName -NotLike "*Media*" -AND
                $_.FeatureName -NotLike "*NFS*" -AND
                $_.FeatureName -NotLike "*SearchEngine*" -AND
                $_.FeatureName -NotLike "*RemoteDesktop*" -AND
                $_.State -ne "Disabled"
            }
        } else {
            $featList = dism /english /image="$scratchDir" /get-features | Select-String -Pattern "Feature Name : " -CaseSensitive -SimpleMatch
            if ($?) {
                $featList = $featList -split "Feature Name : " | Where-Object {$_}
                # Exclude the same items. Note: for now, this doesn't exclude those features that are disabled.
                # This will appear in the future
                $featList = $featList | Where-Object {
                    $_ -NotLike "*Defender*" -AND
                    $_ -NotLike "*Printing*" -AND
                    $_ -NotLike "*TelnetClient*" -AND
                    $_ -NotLike "*PowerShell*" -AND
                    $_ -NotLike "*NetFx*" -AND
                    $_ -NotLike "*Media*" -AND
                    $_ -NotLike "*NFS*" -AND
                    $_ -NotLike "*SearchEngine*" -AND
                    $_ -NotLike "*RemoteDesktop*"
                }
            } else {
                Write-Host "Features could not be obtained with DISM. MicroWin processing will continue, but features will be skipped."
                return
            }
        }

        if ($UseCmdlets) {
            foreach ($feature in $featList) {
                $status = "Removing feature $($feature.FeatureName)"
                Write-Progress -Activity "Removing features" -Status $status -PercentComplete ($counter++/$featlist.Count*100)
                Write-Debug "Removing feature $($feature.FeatureName)"
                Disable-WindowsOptionalFeature -Path "$scratchDir" -FeatureName $($feature.FeatureName) -Remove  -ErrorAction SilentlyContinue -NoRestart
            }
        } else {
            foreach ($feature in $featList) {
                $status = "Removing feature $feature"
                Write-Progress -Activity "Removing features" -Status $status -PercentComplete ($counter++/$featlist.Count*100)
                Write-Debug "Removing feature $feature"
                dism /english /image="$scratchDir" /disable-feature /featurename=$feature /remove /quiet /norestart | Out-Null
                if ($? -eq $false) {
                    Write-Host "Feature $feature could not be disabled."
                }
            }
        }
        Write-Progress -Activity "Removing features" -Status "Ready" -Completed
        Write-Host "You can re-enable the disabled features at any time, using either Windows Update or the SxS folder in <installation media>\Sources."
    } catch {
        Write-Host "Unable to get information about the features. A fallback will be used..."
        Write-Host "Error information: $($_.Exception.Message)" -ForegroundColor Yellow
        Microwin-RemoveFeatures -UseCmdlets $false
    }
}
function Microwin-RemoveFileOrDirectory([string]$pathToDelete, [string]$mask = "", [switch]$Directory = $false) {
    if(([string]::IsNullOrEmpty($pathToDelete))) { return }
    if (-not (Test-Path -Path "$($pathToDelete)")) { return }

    $yesNo = Get-LocalizedYesNo
    Write-Host "[INFO] In Your local takeown expects '$($yesNo[0])' as a Yes answer."

    $itemsToDelete = [System.Collections.ArrayList]::new()

    if ($mask -eq "") {
        Write-Debug "Adding $($pathToDelete) to array."
        [void]$itemsToDelete.Add($pathToDelete)
    } else {
        Write-Debug "Adding $($pathToDelete) to array and mask is $($mask)"
        if ($Directory) { $itemsToDelete = Get-ChildItem $pathToDelete -Include $mask -Recurse -Directory } else { $itemsToDelete = Get-ChildItem $pathToDelete -Include $mask -Recurse }
    }

    foreach($itemToDelete in $itemsToDelete) {
        $status = "Deleting $($itemToDelete)"
        Write-Progress -Activity "Removing Items" -Status $status -PercentComplete ($counter++/$itemsToDelete.Count*100)

        if (Test-Path -Path "$($itemToDelete)" -PathType Container) {
            $status = "Deleting directory: $($itemToDelete)"

            takeown /r /d $yesNo[0] /a /f "$($itemToDelete)"
            icacls "$($itemToDelete)" /q /c /t /reset
            icacls $itemToDelete /setowner "*S-1-5-32-544"
            icacls $itemToDelete /grant "*S-1-5-32-544:(OI)(CI)F" /t /c /q
            Remove-Item -Force -Recurse "$($itemToDelete)"
        }
        elseif (Test-Path -Path "$($itemToDelete)" -PathType Leaf) {
            $status = "Deleting file: $($itemToDelete)"

            takeown /a /f "$($itemToDelete)"
            icacls "$($itemToDelete)" /q /c /t /reset
            icacls "$($itemToDelete)" /setowner "*S-1-5-32-544"
            icacls "$($itemToDelete)" /grant "*S-1-5-32-544:(OI)(CI)F" /t /c /q
            Remove-Item -Force "$($itemToDelete)"
        }
    }
    Write-Progress -Activity "Removing Items" -Status "Ready" -Completed
}
function Microwin-RemovePackages {
    <#
        .SYNOPSIS
            Removes certain packages from ISO image

        .PARAMETER UseCmdlets
            Determines whether or not to use the DISM cmdlets for processing.
            - If true, DISM cmdlets will be used
            - If false, calls to the DISM executable will be made whilst selecting bits and pieces from the output as a string (that was how MicroWin worked before
              the DISM conversion to cmdlets)

        .EXAMPLE
            Microwin-RemovePackages -UseCmdlets $true
    #>
    param (
        [Parameter(Mandatory = $true, Position = 0)] [bool]$UseCmdlets
    )
    try {
        if ($useCmdlets) {
            $pkglist = (Get-WindowsPackage -Path "$scratchDir").PackageName

            $pkglist = $pkglist | Where-Object {
                    $_ -NotLike "*ApplicationModel*" -AND
                    $_ -NotLike "*indows-Client-LanguagePack*" -AND
                    $_ -NotLike "*LanguageFeatures-Basic*" -AND
                    $_ -NotLike "*Package_for_ServicingStack*" -AND
                    $_ -NotLike "*DotNet*" -AND
                    $_ -NotLike "*Notepad*" -AND
                    $_ -NotLike "*WMIC*" -AND
                    $_ -NotLike "*Ethernet*" -AND
                    $_ -NotLike "*Wifi*" -AND
                    $_ -NotLike "*FodMetadata*" -AND
                    $_ -NotLike "*Foundation*" -AND
                    $_ -NotLike "*LanguageFeatures*" -AND
                    $_ -NotLike "*VBSCRIPT*" -AND
                    $_ -NotLike "*License*" -AND
                    $_ -NotLike "*Hello-Face*" -AND
                    $_ -NotLike "*ISE*" -AND
                    $_ -NotLike "*OpenSSH*"
                }
        } else {
            $pkgList = dism /english /image="$scratchDir" /get-packages | Select-String -Pattern "Package Identity : " -CaseSensitive -SimpleMatch
            if ($?) {
                $pkgList = $pkgList -split "Package Identity : " | Where-Object {$_}
                # Exclude the same items.
                $pkgList = $pkgList | Where-Object {
                    $_ -NotLike "*ApplicationModel*" -AND
                    $_ -NotLike "*indows-Client-LanguagePack*" -AND
                    $_ -NotLike "*LanguageFeatures-Basic*" -AND
                    $_ -NotLike "*Package_for_ServicingStack*" -AND
                    $_ -NotLike "*DotNet*" -AND
                    $_ -NotLike "*Notepad*" -AND
                    $_ -NotLike "*WMIC*" -AND
                    $_ -NotLike "*Ethernet*" -AND
                    $_ -NotLike "*Wifi*" -AND
                    $_ -NotLike "*FodMetadata*" -AND
                    $_ -NotLike "*Foundation*" -AND
                    $_ -NotLike "*LanguageFeatures*" -AND
                    $_ -NotLike "*VBSCRIPT*" -AND
                    $_ -NotLike "*License*" -AND
                    $_ -NotLike "*Hello-Face*" -AND
                    $_ -NotLike "*ISE*" -AND
                    $_ -NotLike "*OpenSSH*"
                }
            } else {
                Write-Host "Packages could not be obtained with DISM. MicroWin processing will continue, but packages will be skipped."
                return
            }
        }

        if ($UseCmdlets) {
            $failedCount = 0

            $erroredPackages = [System.Collections.Generic.List[ErroredPackage]]::new()

            foreach ($pkg in $pkglist) {
                try {
                    $status = "Removing $pkg"
                    Write-Progress -Activity "Removing Packages" -Status $status -PercentComplete ($counter++/$pkglist.Count*100)
                    Remove-WindowsPackage -Path "$scratchDir" -PackageName $pkg -NoRestart -ErrorAction SilentlyContinue
                } catch {
                    # This can happen if the package that is being removed is a permanent one
                    $erroredPackages.Add([ErroredPackage]::new($pkg, $_.Exception.Message))
                    $failedCount += 1
                    continue
                }
            }
        } else {
            foreach ($package in $pkgList) {
                $status = "Removing package $package"
                Write-Progress -Activity "Removing Packages" -Status $status -PercentComplete ($counter++/$pkglist.Count*100)
                Write-Debug "Removing package $package"
                dism /english /image="$scratchDir" /remove-package /packagename=$package /remove /quiet /norestart | Out-Null
                if ($? -eq $false) {
                    Write-Host "Package $package could not be removed."
                }
            }
        }
        Write-Progress -Activity "Removing Packages" -Status "Ready" -Completed
        if ($UseCmdlets -and $failedCount -gt 0)
        {
            Write-Host "$failedCount package(s) could not be removed. Your image will still work fine, however. Below is information on what packages failed to be removed and why."
            if ($erroredPackages.Count -gt 0)
            {
                $erroredPackages = $erroredPackages | Sort-Object -Property ErrorMessage

                $previousErroredPackage = $erroredPackages[0]
                $counter = 0
                Write-Host ""
                Write-Host "- $($previousErroredPackage.ErrorMessage)"
                foreach ($erroredPackage in $erroredPackages) {
                    if ($erroredPackage.ErrorMessage -ne $previousErroredPackage.ErrorMessage) {
                        Write-Host ""
                        $counter = 0
                        Write-Host "- $($erroredPackage.ErrorMessage)"
                    }
                    $counter += 1
                    Write-Host "  $counter) $($erroredPackage.PackageName)"
                    $previousErroredPackage = $erroredPackage
                }
                Write-Host ""
            }
        }
    } catch {
        Write-Host "Unable to get information about the packages. A fallback will be used..."
        Write-Host "Error information: $($_.Exception.Message)" -ForegroundColor Yellow
        Microwin-RemovePackages -UseCmdlets $false
    }
}
function Microwin-RemoveProvisionedPackages() {
    <#
        .SYNOPSIS
        Removes AppX packages from a Windows image during MicroWin processing

        .PARAMETER UseCmdlets
            Determines whether or not to use the DISM cmdlets for processing.
            - If true, DISM cmdlets will be used
            - If false, calls to the DISM executable will be made whilst selecting bits and pieces from the output as a string (that was how MicroWin worked before
              the DISM conversion to cmdlets)

        .EXAMPLE
        Microwin-RemoveProvisionedPackages
    #>
    param (
        [Parameter(Mandatory = $true, Position = 0)] [bool]$UseCmdlets
    )
    try
    {
        if ($UseCmdlets) {
            $appxProvisionedPackages = Get-AppxProvisionedPackage -Path "$($scratchDir)" | Where-Object {
                    $_.PackageName -NotLike "*AppInstaller*" -AND
                    $_.PackageName -NotLike "*Store*" -and
                    $_.PackageName -NotLike "*Notepad*" -and
                    $_.PackageName -NotLike "*Printing*" -and
                    $_.PackageName -NotLike "*YourPhone*" -and
                    $_.PackageName -NotLike "*Xbox*" -and
                    $_.PackageName -NotLike "*WindowsTerminal*" -and
                    $_.PackageName -NotLike "*Calculator*" -and
                    $_.PackageName -NotLike "*Photos*" -and
                    $_.PackageName -NotLike "*VCLibs*" -and
                    $_.PackageName -NotLike "*Paint*" -and
                    $_.PackageName -NotLike "*Gaming*" -and
                    $_.PackageName -NotLike "*Extension*" -and
                    $_.PackageName -NotLike "*SecHealthUI*" -and
                    $_.PackageName -NotLike "*ScreenSketch*"
            }
        } else {
            $appxProvisionedPackages = dism /english /image="$scratchDir" /get-provisionedappxpackages | Select-String -Pattern "PackageName : " -CaseSensitive -SimpleMatch
            if ($?) {
                $appxProvisionedPackages = $appxProvisionedPackages -split "PackageName : " | Where-Object {$_}
                # Exclude the same items.
                $appxProvisionedPackages = $appxProvisionedPackages | Where-Object {
                    $_ -NotLike "*AppInstaller*" -AND
                    $_ -NotLike "*Store*" -and
                    $_ -NotLike "*Notepad*" -and
                    $_ -NotLike "*Printing*" -and
                    $_ -NotLike "*YourPhone*" -and
                    $_ -NotLike "*Xbox*" -and
                    $_ -NotLike "*WindowsTerminal*" -and
                    $_ -NotLike "*Calculator*" -and
                    $_ -NotLike "*Photos*" -and
                    $_ -NotLike "*VCLibs*" -and
                    $_ -NotLike "*Paint*" -and
                    $_ -NotLike "*Gaming*" -and
                    $_ -NotLike "*Extension*" -and
                    $_ -NotLike "*SecHealthUI*" -and
                    $_ -NotLike "*ScreenSketch*"
                }
            } else {
                Write-Host "AppX packages could not be obtained with DISM. MicroWin processing will continue, but AppX packages will be skipped."
                return
            }
        }

        $counter = 0
        if ($UseCmdlets) {
            foreach ($appx in $appxProvisionedPackages) {
                $status = "Removing Provisioned $($appx.PackageName)"
                Write-Progress -Activity "Removing Provisioned Apps" -Status $status -PercentComplete ($counter++/$appxProvisionedPackages.Count*100)
                try {
                    Remove-AppxProvisionedPackage -Path "$scratchDir" -PackageName $appx.PackageName -ErrorAction SilentlyContinue
                } catch {
                    Write-Host "Application $($appx.PackageName) could not be removed"
                    continue
                }
            }
        } else {
            foreach ($appx in $appxProvisionedPackages) {
                $status = "Removing Provisioned $appx"
                Write-Progress -Activity "Removing Provisioned Apps" -Status $status -PercentComplete ($counter++/$appxProvisionedPackages.Count*100)
                dism /english /image="$scratchDir" /remove-provisionedappxpackage /packagename=$appx /quiet /norestart | Out-Null
                if ($? -eq $false) {
                    Write-Host "AppX package $appx could not be removed."
                }
            }
        }
        Write-Progress -Activity "Removing Provisioned Apps" -Status "Ready" -Completed
    }
    catch
    {
        Write-Host "Unable to get information about the AppX packages. A fallback will be used..."
        Write-Host "Error information: $($_.Exception.Message)" -ForegroundColor Yellow
        Microwin-RemoveProvisionedPackages -UseCmdlets $false
    }
}
function Microwin-TestCompatibleImage() {
    <#
        .SYNOPSIS
            Checks the version of a Windows image and determines whether or not it is compatible with a specific feature depending on a desired version

        .PARAMETER Name
            imgVersion - The version of the Windows image
            desiredVersion - The version to compare the image version with
    #>

    param
    (
    [Parameter(Mandatory, position=0)]
    [string]$imgVersion,

    [Parameter(Mandatory, position=1)]
    [Version]$desiredVersion
    )

    try {
        $version = [Version]$imgVersion
        return $version -ge $desiredVersion
    } catch {
        return $False
    }
}
    function Add-SelectedAppsMenuItem {
        <#
        .SYNOPSIS
            This is a helper function that generates and adds the Menu Items to the Selected Apps Popup.

        .Parameter name
            The actual Name of an App like "Chrome" or "Brave"
            This name is contained in the "Content" property inside the applications.json
        .PARAMETER key
            The key which identifies an app object in applications.json
            For Chrome this would be "WPFInstallchrome" because "WPFInstall" is prepended automatically for each key in applications.json
        #>

        param ([string]$name, [string]$key)

        $selectedAppGrid = New-Object Windows.Controls.Grid

        $selectedAppGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width = "*"}))
        $selectedAppGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width = "30"}))

        # Sets the name to the Content as well as the Tooltip, because the parent Popup Border has a fixed width and text could "overflow".
        # With the tooltip, you can still read the whole entry on hover
        $selectedAppLabel = New-Object Windows.Controls.Label
        $selectedAppLabel.Content = $name
        $selectedAppLabel.ToolTip = $name
        $selectedAppLabel.HorizontalAlignment = "Left"
        $selectedAppLabel.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
        [System.Windows.Controls.Grid]::SetColumn($selectedAppLabel, 0)
        $selectedAppGrid.Children.Add($selectedAppLabel)

        $selectedAppRemoveButton = New-Object Windows.Controls.Button
        $selectedAppRemoveButton.FontFamily = "Segoe MDL2 Assets"
        $selectedAppRemoveButton.Content = [string]([char]0xE711)
        $selectedAppRemoveButton.HorizontalAlignment = "Center"
        $selectedAppRemoveButton.Tag = $key
        $selectedAppRemoveButton.ToolTip = "Remove the App from Selection"
        $selectedAppRemoveButton.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
        $selectedAppRemoveButton.SetResourceReference([Windows.Controls.Control]::StyleProperty, "HoverButtonStyle")

        # Highlight the Remove icon on Hover
        $selectedAppRemoveButton.Add_MouseEnter({ $this.Foreground = "Red" })
        $selectedAppRemoveButton.Add_MouseLeave({ $this.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor") })
        $selectedAppRemoveButton.Add_Click({
            $sync.($this.Tag).isChecked = $false # On click of the remove button, we only have to uncheck the corresponding checkbox. This will kick of all neccessary changes to update the UI
        })
        [System.Windows.Controls.Grid]::SetColumn($selectedAppRemoveButton, 1)
        $selectedAppGrid.Children.Add($selectedAppRemoveButton)
        # Add new Element to Popup
        $sync.selectedAppsstackPanel.Children.Add($selectedAppGrid)
    }
function Copy-Files {
    <#

        .DESCRIPTION
            Copies the contents of a given ISO file to a given destination
        .PARAMETER Path
            The source of the files to copy
        .PARAMETER Destination
            The destination to copy the files to
        .PARAMETER Recurse
            Determines whether or not to copy all files of the ISO file, including those in subdirectories
        .PARAMETER Force
            Determines whether or not to overwrite existing files
        .EXAMPLE
            Copy-Files "D:" "C:\ISOFile" -Recurse -Force

    #>
    param (
        [string]$Path,
        [string]$Destination,
        [switch]$Recurse = $false,
        [switch]$Force = $false
    )

    try {

        $files = Get-ChildItem -Path $path -Recurse:$recurse
        Write-Host "Copy $($files.Count) file(s) from $path to $destination"

        foreach ($file in $files) {
            $status = "Copying file {0} of {1}: {2}" -f $counter, $files.Count, $file.Name
            Write-Progress -Activity "Copy disc image files" -Status $status -PercentComplete ($counter++/$files.count*100)
            $restpath = $file.FullName -Replace $path, ''

            if ($file.PSIsContainer -eq $true) {
                Write-Debug "Creating $($destination + $restpath)"
                New-Item ($destination+$restpath) -Force:$force -Type Directory -ErrorAction SilentlyContinue
            } else {
                Write-Debug "Copy from $($file.FullName) to $($destination+$restpath)"
                Copy-Item $file.FullName ($destination+$restpath) -ErrorAction SilentlyContinue -Force:$force
                Set-ItemProperty -Path ($destination+$restpath) -Name IsReadOnly -Value $false
            }
        }
        Write-Progress -Activity "Copy disc image files" -Status "Ready" -Completed
    } catch {
        Write-Host "Unable to Copy all the files due to an unhandled exception" -ForegroundColor Yellow
        Write-Host "Error information: $($_.Exception.Message)`n" -ForegroundColor Yellow
        Write-Host "Additional information:" -ForegroundColor Yellow
        Write-Host $PSItem.Exception.StackTrace
        # Write possible suggestions
        Write-Host "`nIf you are using an antivirus, try configuring exclusions"
    }
}
function Find-AppsByNameOrDescription {
    <#
        .SYNOPSIS
            Searches through the Apps on the Install Tab and hides all entries that do not match the string

        .PARAMETER SearchString
            The string to be searched for
    #>
    param(
        [Parameter(Mandatory=$false)]
        [string]$SearchString = ""
    )
    # Reset the visibility if the search string is empty or the search is cleared
    if ([string]::IsNullOrWhiteSpace($SearchString)) {
            Set-CategoryVisibility -Category "*"
            return
    }
    $sync.ItemsControl.Items | ForEach-Object {
        # Hide all CategoryWrapPanel and ToggleButton
        $_.Visibility = [Windows.Visibility]::Collapsed
        if ($_.Tag -like "CategoryWrapPanel_*") {
            # Search for Apps that match the search string
            $_.Children | Foreach-Object {
                if ($sync.configs.applicationsHashtable.$($_.Tag).Content -like "*$SearchString*") {
                    # Show the App and the parent CategoryWrapPanel if the string is found
                    $_.Visibility = [Windows.Visibility]::Visible
                    $_.parent.Visibility = [Windows.Visibility]::Visible
                }
                else {
                    $_.Visibility = [Windows.Visibility]::Collapsed
                }
            }
        }
    }
}
function Get-LocalizedYesNo {
    <#
    .SYNOPSIS
    This function runs choice.exe and captures its output to extract yes no in a localized Windows

    .DESCRIPTION
    The function retrieves the output of the command 'cmd /c "choice <nul 2>nul"' and converts the default output for Yes and No
    in the localized format, such as "Yes=<first character>, No=<second character>".

    .EXAMPLE
    $yesNoArray = Get-LocalizedYesNo
    Write-Host "Yes=$($yesNoArray[0]), No=$($yesNoArray[1])"
    #>

    # Run choice and capture its options as output
    # The output shows the options for Yes and No as "[Y,N]?" in the (partitially) localized format.
    # eg. English: [Y,N]?
    # Dutch: [Y,N]?
    # German: [J,N]?
    # French: [O,N]?
    # Spanish: [S,N]?
    # Italian: [S,N]?
    # Russian: [Y,N]?

    $line = cmd /c "choice <nul 2>nul"
    $charactersArray = @()
    $regexPattern = '([a-zA-Z])'
    $charactersArray = [regex]::Matches($line, $regexPattern) | ForEach-Object { $_.Groups[1].Value }

    Write-Debug "According to takeown.exe local Yes is $charactersArray[0]"
    # Return the array of characters
    return $charactersArray

  }
Function Get-WinUtilCheckBoxes {

    <#

    .SYNOPSIS
        Finds all checkboxes that are checked on the specific tab and inputs them into a script.

    .PARAMETER unCheck
        Whether to uncheck the checkboxes that are checked. Defaults to true

    .OUTPUTS
        A List containing the name of each checked checkbox

    .EXAMPLE
        Get-WinUtilCheckBoxes "WPFInstall"

    #>

    Param(
        [boolean]$unCheck = $false
    )

    $Output = @{
        Install      = @()
        WPFTweaks     = @()
        WPFFeature    = @()
        WPFInstall    = @()
    }

    $CheckBoxes = $sync.GetEnumerator() | Where-Object { $_.Value -is [System.Windows.Controls.CheckBox] }

    # First check and add WPFTweaksRestorePoint if checked
    $RestorePoint = $CheckBoxes | Where-Object { $_.Key -eq 'WPFTweaksRestorePoint' -and $_.Value.IsChecked -eq $true }
    if ($RestorePoint) {
        $Output["WPFTweaks"] = @('WPFTweaksRestorePoint')
        Write-Debug "Adding WPFTweaksRestorePoint as first in WPFTweaks"

        if ($unCheck) {
            $RestorePoint.Value.IsChecked = $false
        }
    }

    foreach ($CheckBox in $CheckBoxes) {
        if ($CheckBox.Key -eq 'WPFTweaksRestorePoint') { continue }  # Skip since it's already handled

        $group = if ($CheckBox.Key.StartsWith("WPFInstall")) { "Install" }
                elseif ($CheckBox.Key.StartsWith("WPFTweaks")) { "WPFTweaks" }
                elseif ($CheckBox.Key.StartsWith("WPFFeature")) { "WPFFeature" }
        if ($group) {
            if ($CheckBox.Value.IsChecked -eq $true) {
                $feature = switch ($group) {
                    "Install" {
                        # Get the winget value
                        [PsCustomObject]@{
                            winget="$($sync.configs.applications.$($CheckBox.Name).winget)";
                            choco="$($sync.configs.applications.$($CheckBox.Name).choco)";
                        }

                    }
                    default {
                        $CheckBox.Name
                    }
                }

                if (-not $Output.ContainsKey($group)) {
                    $Output[$group] = @()
                }
                if ($group -eq "Install") {
                    $Output["WPFInstall"] += $CheckBox.Name
                    Write-Debug "Adding: $($CheckBox.Name) under: WPFInstall"
                }

                Write-Debug "Adding: $($feature) under: $($group)"
                $Output[$group] += $feature

                if ($unCheck) {
                    $CheckBox.Value.IsChecked = $false
                }
            }
        }
    }
    return  $Output
}
function Get-WinUtilInstallerProcess {
    <#

    .SYNOPSIS
        Checks if the given process is running

    .PARAMETER Process
        The process to check

    .OUTPUTS
        Boolean - True if the process is running

    #>

    param($Process)

    if ($Null -eq $Process) {
        return $false
    }
    if (Get-Process -Id $Process.Id -ErrorAction SilentlyContinue) {
        return $true
    }
    return $false
}
Function Get-WinUtilToggleStatus {
    <#

    .SYNOPSIS
        Pulls the registry keys for the given toggle switch and checks whether the toggle should be checked or unchecked

    .PARAMETER ToggleSwitch
        The name of the toggle to check

    .OUTPUTS
        Boolean to set the toggle's status to

    #>

    Param($ToggleSwitch)

    $ToggleSwitchReg = $sync.configs.tweaks.$ToggleSwitch.registry

    try {
        if (($ToggleSwitchReg.path -imatch "hku") -and !(Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
            $null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)
            if (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue) {
                Write-Debug "HKU drive created successfully"
            } else {
                Write-Debug "Failed to create HKU drive"
            }
        }
    } catch {
        Write-Error "An error occurred regarding the HKU Drive: $_"
        return $false
    }

    if ($ToggleSwitchReg) {
        $count = 0

        foreach ($regentry in $ToggleSwitchReg) {
            try {
                if (!(Test-Path $regentry.Path)) {
                    New-Item -Path $regentry.Path -Force | Out-Null
                }
                $regstate = (Get-ItemProperty -path $regentry.Path).$($regentry.Name)
                if ($regstate -eq $regentry.Value) {
                    $count += 1
                    Write-Debug "$($regentry.Name) is true (state: $regstate, value: $($regentry.Value), original: $($regentry.OriginalValue))"
                } else {
                    Write-Debug "$($regentry.Name) is false (state: $regstate, value: $($regentry.Value), original: $($regentry.OriginalValue))"
                }
                if (!$regstate) {
                    switch ($regentry.DefaultState) {
                        "true" {
                            $regstate = $regentry.Value
                            $count += 1
                        }
                        "false" {
                            $regstate = $regentry.OriginalValue
                        }
                        default {
                            Write-Error "Entry for $($regentry.Name) does not exist and no DefaultState is defined."
                            $regstate = $regentry.OriginalValue
                        }
                    }
                }
            } catch {
                Write-Error "An unexpected error occurred: $_"
            }
        }

        if ($count -eq $ToggleSwitchReg.Count) {
            Write-Debug "$($ToggleSwitchReg.Name) is true (count: $count)"
            return $true
        } else {
            Write-Debug "$($ToggleSwitchReg.Name) is false (count: $count)"
            return $false
        }
    } else {
        return $false
    }
}
function Get-WinUtilVariables {

    <#
    .SYNOPSIS
        Gets every form object of the provided type

    .OUTPUTS
        List containing every object that matches the provided type
    #>
    param (
        [Parameter()]
        [string[]]$Type
    )
    $keys = ($sync.keys).where{ $_ -like "WPF*" }
    if ($Type) {
        $output = $keys | ForEach-Object {
            try {
                $objType = $sync["$psitem"].GetType().Name
                if ($Type -contains $objType) {
                    Write-Output $psitem
                }
            } catch {
                <#I am here so errors don't get outputted for a couple variables that don't have the .GetType() attribute#>
            }
        }
        return $output
    }
    return $keys
}
function Get-WPFObjectName {
    <#
        .SYNOPSIS
            This is a helper function that generates an objectname with the prefix WPF that can be used as a Powershell Variable after compilation.
            To achieve this, all characters that are not a-z, A-Z or 0-9 are simply removed from the name.

        .PARAMETER type
            The type of object for which the name should be generated. (e.g. Label, Button, CheckBox...)

        .PARAMETER name
            The name or description to be used for the object. (invalid characters are removed)

        .OUTPUTS
            A string that can be used as a object/variable name in powershell.
            For example: WPFLabelMicrosoftTools

        .EXAMPLE
            Get-WPFObjectName -type Label -name "Microsoft Tools"
    #>

    param(
        [Parameter(Mandatory, position=0)]
        [string]$type,

        [Parameter(position=1)]
        [string]$name
    )

    $Output = $("WPF"+$type+$name) -replace '[^a-zA-Z0-9]', ''
    return $Output
}
function Initialize-InstallAppEntry {
    <#
        .SYNOPSIS
            Creates the app entry to be placed on the isntall tab for a given app
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Element into which the Apps should be placed
        .PARAMETER AppKey
            The Key of the app inside the $sync.configs.applicationsHashtable
    #>
        param(
            [Windows.Controls.WrapPanel]$TargetElement,
            $AppKey
        )
        $App = $sync.configs.applicationsHashtable.$AppKey
        # Create the outer Border for the application type
        $border = New-Object Windows.Controls.Border
        $border.BorderBrush = [Windows.Media.Brushes]::Gray
        $border.SetResourceReference([Windows.Controls.Control]::BorderThicknessProperty, "AppTileBorderThickness")
        $border.CornerRadius = 5
        $border.SetResourceReference([Windows.Controls.Control]::PaddingProperty, "AppTileMargins")
        $border.SetResourceReference([Windows.Controls.Control]::WidthProperty, "AppTileWidth")
        $border.VerticalAlignment = "Top"
        $border.SetResourceReference([Windows.Controls.Control]::MarginProperty, "AppTileMargins")
        $border.Cursor = [System.Windows.Input.Cursors]::Hand
        $border.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
        $border.Tag = $Appkey
        $border.ToolTip = $App.description
        $border.Add_MouseUp({
            $childCheckbox = ($this.Child.Children | Where-Object {$_.Template.TargetType -eq [System.Windows.Controls.Checkbox]})[0]
            $childCheckBox.isChecked = -not $childCheckbox.IsChecked
        })
        $border.Add_MouseEnter({
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallHighlightedColor")
            }
        })
        $border.Add_MouseLeave({
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
            }
        })
        # Create a DockPanel inside the Border
        $dockPanel = New-Object Windows.Controls.DockPanel
        $dockPanel.LastChildFill = $true
        $border.Child = $dockPanel

        # Create the CheckBox, vertically centered
        $checkBox = New-Object Windows.Controls.CheckBox
        $checkBox.Name = $AppKey
        $checkBox.Background = "Transparent"
        $checkBox.HorizontalAlignment = "Left"
        $checkBox.VerticalAlignment = "Center"
        $checkBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "AppTileMargins")
        $checkBox.SetResourceReference([Windows.Controls.Control]::StyleProperty, "CollapsedCheckBoxStyle")
        $checkbox.Add_Checked({
            Invoke-WPFSelectedAppsUpdate -type "Add" -checkbox $this
            $borderElement = $this.Parent.Parent
            $borderElement.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallSelectedColor")
        })

        $checkbox.Add_Unchecked({
            Invoke-WPFSelectedAppsUpdate -type "Remove" -checkbox $this
            $borderElement = $this.Parent.Parent
            $borderElement.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
        })
        $sync.$($checkBox.Name) = $checkBox
        # Create a StackPanel for the image and name
        $imageAndNamePanel = New-Object Windows.Controls.StackPanel
        $imageAndNamePanel.Orientation = "Horizontal"
        $imageAndNamePanel.VerticalAlignment = "Center"

        # Create the Image and set a placeholder
        $image = New-Object Windows.Controls.Image
        # $image.Name = "wpfapplogo" + $App.Name
        $image.Width = 40
        $image.Height = 40
        $image.Margin = New-Object Windows.Thickness(0, 0, 10, 0)
        $image.Source = $noimage  # Ensure $noimage is defined in your script

        # Clip the image corners
        $image.Clip = New-Object Windows.Media.RectangleGeometry
        $image.Clip.Rect = New-Object Windows.Rect(0, 0, $image.Width, $image.Height)
        $image.Clip.RadiusX = 5
        $image.Clip.RadiusY = 5
        $image.SetResourceReference([Windows.Controls.Control]::VisibilityProperty, "AppTileCompactVisibility")

        $imageAndNamePanel.Children.Add($image) | Out-Null

        # Create the TextBlock for the application name
        $appName = New-Object Windows.Controls.TextBlock
        $appName.Text = $App.Content
        $appName.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "AppTileFontSize")
        $appName.FontWeight = [Windows.FontWeights]::Bold
        $appName.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
        $appName.VerticalAlignment = "Center"
        $appName.SetResourceReference([Windows.Controls.Control]::MarginProperty, "AppTileMargins")
        $appName.Background = "Transparent"
        $imageAndNamePanel.Children.Add($appName) | Out-Null

        # Add the image and name panel to the Checkbox
        $checkBox.Content = $imageAndNamePanel

        # Add the checkbox to the DockPanel
        [Windows.Controls.DockPanel]::SetDock($checkBox, [Windows.Controls.Dock]::Left)
        $dockPanel.Children.Add($checkBox) | Out-Null

        # Create the StackPanel for the buttons and dock it to the right
        $buttonPanel = New-Object Windows.Controls.StackPanel
        $buttonPanel.Orientation = "Horizontal"
        $buttonPanel.HorizontalAlignment = "Right"
        $buttonPanel.VerticalAlignment = "Center"
        $buttonPanel.SetResourceReference([Windows.Controls.Control]::MarginProperty, "AppTileMargins")
        $buttonPanel.SetResourceReference([Windows.Controls.Control]::VisibilityProperty, "AppTileCompactVisibility")
        [Windows.Controls.DockPanel]::SetDock($buttonPanel, [Windows.Controls.Dock]::Right)

        # Create the "Install" button
        $installButton = New-Object Windows.Controls.Button
        $installButton.Width = 45
        $installButton.Height = 35
        $installButton.Margin = New-Object Windows.Thickness(0, 0, 10, 0)

        $installIcon = New-Object Windows.Controls.TextBlock
        $installIcon.Text = [char]0xE118  # Install Icon
        $installIcon.FontFamily = "Segoe MDL2 Assets"
        $installIcon.FontSize = 20
        $installIcon.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
        $installIcon.Background = "Transparent"
        $installIcon.HorizontalAlignment = "Center"
        $installIcon.VerticalAlignment = "Center"

        $installButton.Content = $installIcon
        $installButton.ToolTip = "Install or Upgrade the application"
        $buttonPanel.Children.Add($installButton) | Out-Null

        # Add Click event for the "Install" button
        $installButton.Add_Click({
            $appKey = $this.Parent.Parent.Parent.Tag
            $appObject = $sync.configs.applicationsHashtable.$appKey
            Invoke-WPFInstall -PackagesToInstall $appObject
        })

        # Create the "Uninstall" button
        $uninstallButton = New-Object Windows.Controls.Button
        $uninstallButton.Width = 45
        $uninstallButton.Height = 35

        $uninstallIcon = New-Object Windows.Controls.TextBlock
        $uninstallIcon.Text = [char]0xE74D  # Uninstall Icon
        $uninstallIcon.FontFamily = "Segoe MDL2 Assets"
        $uninstallIcon.FontSize = 20
        $uninstallIcon.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
        $uninstallIcon.Background = "Transparent"
        $uninstallIcon.HorizontalAlignment = "Center"
        $uninstallIcon.VerticalAlignment = "Center"

        $uninstallButton.Content = $uninstallIcon
        $buttonPanel.Children.Add($uninstallButton) | Out-Null

        $uninstallButton.ToolTip = "Uninstall the application"
        $uninstallButton.Add_Click({
            $appKey = $this.Parent.Parent.Parent.Tag
            $appObject = $sync.configs.applicationsHashtable.$appKey
            Invoke-WPFUnInstall -PackagesToUninstall $appObject
        })

        # Create the "Info" button
        $infoButton = New-Object Windows.Controls.Button
        $infoButton.Width = 45
        $infoButton.Height = 35
        $infoButton.Margin = New-Object Windows.Thickness(10, 0, 0, 0)

        $infoIcon = New-Object Windows.Controls.TextBlock
        $infoIcon.Text = [char]0xE946  # Info Icon
        $infoIcon.FontFamily = "Segoe MDL2 Assets"
        $infoIcon.FontSize = 20
        $infoIcon.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
        $infoIcon.Background = "Transparent"
        $infoIcon.HorizontalAlignment = "Center"
        $infoIcon.VerticalAlignment = "Center"

        $infoButton.Content = $infoIcon
        $infoButton.ToolTip = "Open the application's website in your default browser"
        $buttonPanel.Children.Add($infoButton) | Out-Null

        $infoButton.Add_Click({
            $appKey = $this.Parent.Parent.Parent.Tag
            $appObject = $sync.configs.applicationsHashtable.$appKey
            Start-Process $appObject.link
        })

        # Add the button panel to the DockPanel
        $dockPanel.Children.Add($buttonPanel) | Out-Null

        # Add the border to the corresponding Category
        $TargetElement.Children.Add($border) | Out-Null
    }
    function Initialize-InstallAppArea {
        <#
            .SYNOPSIS
                Creates a [Windows.Controls.ScrollViewer] containing a [Windows.Controls.ItemsControl] which is setup to use Virtualization to only load the visible elements for performance reasons.
                This is used as the parent object for all category and app entries on the install tab
                Used to as part of the Install Tab UI generation

            .PARAMETER TargetElement
                The element to which the AppArea shoud be added

        #>
        param($TargetElement)
        $scrollViewer = New-Object Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalAlignment = 'Stretch'
        $scrollViewer.VerticalAlignment = 'Stretch'
        $scrollViewer.CanContentScroll = $true

        $itemsControl = New-Object Windows.Controls.ItemsControl
        $itemsControl.HorizontalAlignment = 'Stretch'
        $itemsControl.VerticalAlignment = 'Stretch'

        $itemsPanelTemplate = New-Object Windows.Controls.ItemsPanelTemplate
        $factory = New-Object Windows.FrameworkElementFactory ([Windows.Controls.VirtualizingStackPanel])
        $itemsPanelTemplate.VisualTree = $factory
        $itemsControl.ItemsPanel = $itemsPanelTemplate

        $itemsControl.SetValue([Windows.Controls.VirtualizingStackPanel]::IsVirtualizingProperty, $true)
        $itemsControl.SetValue([Windows.Controls.VirtualizingStackPanel]::VirtualizationModeProperty, [Windows.Controls.VirtualizationMode]::Recycling)

        $scrollViewer.Content = $itemsControl

        [Windows.Controls.DockPanel]::SetDock($scrollViewer, [Windows.Controls.Dock]::Bottom)
        $null = $TargetElement.Children.Add($scrollViewer)
        return $itemsControl
    }
function Initialize-InstallAppsMainElement {
    <#
        .SYNOPSIS
            Clears the given WPF Grid and creates a [Windows.Controls.Border] containing a [Windows.Controls.StackPanel]
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetGridName
            The WPF Grid name
        .OUTPUTS
            Returns the created [Windows.Controls.StackPanel] element
    #>
    param(
        [Parameter(Mandatory)]
        [string]$TargetGridName
    )
    $targetGrid = $sync.Form.FindName($TargetGridName)
    $null = $targetGrid.Children.Clear()

    $Border = New-Object Windows.Controls.Border
    $Border.VerticalAlignment = "Stretch"
    $Border.SetResourceReference([Windows.Controls.Control]::StyleProperty, "BorderStyle")

    $dockPanel = New-Object Windows.Controls.DockPanel
    $Border.Child = $dockPanel

    $null = $targetGrid.Children.Add($Border)

    return $dockPanel
}
function Initialize-InstallCategoryAppList {
    <#
        .SYNOPSIS
            Clears the Target Element and sets up a "Loading" message. This is done, because loading of all apps can take a bit of time in some scenarios
            Iterates through all Categories and Apps and adds them to the UI
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Element into which the Categories and Apps should be placed
        .PARAMETER Apps
            The Hashtable of Apps to be added to the UI
            The Categories are also extracted from the Apps Hashtable

    #>
        param(
            $TargetElement,
            $Apps
        )
        function Add-Category {
            param(
                [string]$Category,
                [Windows.Controls.ItemsControl]$TargetElement
            )

            $toggleButton = New-Object Windows.Controls.Primitives.ToggleButton
            $toggleButton.Content = "$Category"
            $toggleButton.Tag = "CategoryToggleButton"
            $toggleButton.Cursor = [System.Windows.Input.Cursors]::Hand
            $toggleButton.SetResourceReference([Windows.Controls.Control]::StyleProperty, "CategoryToggleButtonStyle")
            $sync.Buttons.Add($toggleButton)
            $toggleButton.Add_Checked({
                # Clear the search bar when a category is clicked
                $sync.SearchBar.Text = ""
                Set-CategoryVisibility -Category $this.Content -overrideState Expand
            })
            $toggleButton.Add_Unchecked({
                Set-CategoryVisibility -Category $this.Content -overrideState Collapse
            })
            $null = $TargetElement.Items.Add($toggleButton)
        }

        $loadingLabel = New-Object Windows.Controls.Label
        $loadingLabel.Content = "Loading, please wait..."
        $loadingLabel.HorizontalAlignment = "Center"
        $loadingLabel.VerticalAlignment = "Center"
        $loadingLabel.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSizeHeading")
        $loadingLabel.FontWeight = [Windows.FontWeights]::Bold
        $loadingLabel.Foreground = [Windows.Media.Brushes]::Gray
        $sync.LoadingLabel = $loadingLabel

        $TargetElement.Items.Clear()
        $null = $TargetElement.Items.Add($sync.LoadingLabel)
        # Use the Dispatcher to make sure the Loading message is shown before the logic loading the apps starts, and only is removed when the loading is complete and the apps are added to the UI
        $TargetElement.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{

            $TargetElement.Items.Clear() # Remove the loading message
            $categories = $Apps.Values | Select-Object -ExpandProperty category -Unique | Sort-Object
            foreach ($category in $categories) {
                Add-Category -Category $category -TargetElement $TargetElement
                $wrapPanel = New-Object Windows.Controls.WrapPanel
                $wrapPanel.Orientation = "Horizontal"
                $wrapPanel.HorizontalAlignment = "Stretch"
                $wrapPanel.VerticalAlignment = "Center"
                $wrapPanel.Margin = New-Object Windows.Thickness(0, 0, 0, 20)
                $wrapPanel.Visibility = [Windows.Visibility]::Collapsed
                $wrapPanel.Tag = "CategoryWrapPanel_$category"
                $null = $TargetElement.Items.Add($wrapPanel)
                $Apps.Keys | Where-Object { $Apps.$_.Category -eq $category } | Sort-Object | ForEach-Object {
                    Initialize-InstallAppEntry -TargetElement $wrapPanel -AppKey $_
                }
            }
        })
    }
function Initialize-InstallHeader {
    <#
        .SYNOPSIS
            Creates the Multi Selection Header Elements on the Install Tab
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Parent Element into which the Header should be placed
    #>
    param($TargetElement)
    function New-WPFButton {
        param (
            [string]$Name,
            [string]$Content
        )
        $button = New-Object Windows.Controls.Button
        $button.Name = $Name
        $button.Content = $Content
        $button.Margin = New-Object Windows.Thickness(2)
        $button.HorizontalAlignment = "Stretch"
        return $button
    }

    $wrapPanelTop = New-Object Windows.Controls.WrapPanel
    $wrapPanelTop.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "MainBackgroundColor")
    $wrapPanelTop.HorizontalAlignment = "Left"
    $wrapPanelTop.VerticalAlignment = "Top"
    $wrapPanelTop.Orientation = "Horizontal"
    $wrapPanelTop.SetResourceReference([Windows.Controls.Control]::MarginProperty, "TabContentMargin")
    $buttonConfigs = @(
        @{Name="WPFInstall"; Content="Install/Upgrade Selected"},
        @{Name="WPFInstallUpgrade"; Content="Upgrade All"},
        @{Name="WPFUninstall"; Content="Uninstall Selected"}
    )

    foreach ($config in $buttonConfigs) {
        $button = New-WPFButton -Name $config.Name -Content $config.Content
        $null = $wrapPanelTop.Children.Add($button)
        $sync[$config.Name] = $button
    }

    $selectedAppsButton = New-Object Windows.Controls.Button
    $selectedAppsButton.Name = "WPFselectedAppsButton"
    $selectedAppsButton.Content = "Selected Apps: 0"
    $selectedAppsButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSizeHeading")
    $selectedAppsButton.SetResourceReference([Windows.Controls.Control]::MarginProperty, "TabContentMargin")
    $selectedAppsButton.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
    $selectedAppsButton.HorizontalAlignment = "Center"
    $selectedAppsButton.VerticalAlignment = "Center"

    $selectedAppsPopup = New-Object Windows.Controls.Primitives.Popup
    $selectedAppsPopup.IsOpen = $false
    $selectedAppsPopup.PlacementTarget = $selectedAppsButton
    $selectedAppsPopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
    $selectedAppsPopup.AllowsTransparency = $true

    $selectedAppsBorder = New-Object Windows.Controls.Border
    $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "MainBackgroundColor")
    $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BorderBrushProperty, "MainForegroundColor")
    $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BorderThicknessProperty, "ButtonBorderThickness")
    $selectedAppsBorder.Width = 200
    $selectedAppsBorder.Padding = 5
    $selectedAppsPopup.Child = $selectedAppsBorder
    $sync.selectedAppsPopup = $selectedAppsPopup

    $sync.selectedAppsstackPanel = New-Object Windows.Controls.StackPanel
    $selectedAppsBorder.Child = $sync.selectedAppsstackPanel

    # Toggle selectedAppsPopup open/close with button
    $selectedAppsButton.Add_Click({
        $sync.selectedAppsPopup.IsOpen = -not $sync.selectedAppsPopup.IsOpen
    })
    # Close selectedAppsPopup when mouse leaves both button and selectedAppsPopup
    $selectedAppsButton.Add_MouseLeave({
        if (-not $sync.selectedAppsPopup.IsMouseOver) {
            $sync.selectedAppsPopup.IsOpen = $false
        }
    })
    $selectedAppsPopup.Add_MouseLeave({
        if (-not $selectedAppsButton.IsMouseOver) {
            $sync.selectedAppsPopup.IsOpen = $false
        }
    })

    $null = $wrapPanelTop.Children.Add($selectedAppsButton)
    $sync.$($selectedAppsButton.Name) = $selectedAppsButton

    [Windows.Controls.DockPanel]::SetDock($wrapPanelTop, [Windows.Controls.Dock]::Top)
    $null = $TargetElement.Children.Add($wrapPanelTop)
}
function Install-WinUtilChoco {

    <#

    .SYNOPSIS
        Installs Chocolatey if it is not already installed

    #>

    try {
        Write-Host "Checking if Chocolatey is Installed..."

        if((Test-WinUtilPackageManager -choco) -eq "installed") {
            return
        }
        # Install logic taken from https://chocolatey.org/install#individual
        Write-Host "Seems Chocolatey is not installed, installing now."
        Set-ExecutionPolicy Bypass -Scope Process -Force;
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072;
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

    } catch {
        Write-Host "===========================================" -Foregroundcolor Red
        Write-Host "--     Chocolatey failed to install     ---" -Foregroundcolor Red
        Write-Host "===========================================" -Foregroundcolor Red
    }

}
function Install-WinUtilProgramChoco {
    <#
    .SYNOPSIS
    Manages the installation or uninstallation of a list of Chocolatey packages.

    .PARAMETER Programs
    A string array containing the programs to be installed or uninstalled.

    .PARAMETER Action
    Specifies the action to perform: "Install" or "Uninstall". The default value is "Install".

    .DESCRIPTION
    This function processes a list of programs to be managed using Chocolatey. Depending on the specified action, it either installs or uninstalls each program in the list, updating the taskbar progress accordingly. After all operations are completed, temporary output files are cleaned up.

    .EXAMPLE
    Install-WinUtilProgramChoco -Programs @("7zip","chrome") -Action "Uninstall"
    #>

    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]]$Programs,

        [Parameter(Position = 1)]
        [String]$Action = "Install"
    )

    function Initialize-OutputFile {
        <#
        .SYNOPSIS
        Initializes an output file by removing any existing file and creating a new, empty file at the specified path.

        .PARAMETER filePath
        The full path to the file to be initialized.

        .DESCRIPTION
        This function ensures that the specified file is reset by removing any existing file at the provided path and then creating a new, empty file. It is useful when preparing a log or output file for subsequent operations.

        .EXAMPLE
        Initialize-OutputFile -filePath "C:\temp\output.txt"
        #>

        param ($filePath)
        Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
        New-Item -ItemType File -Path $filePath | Out-Null
    }

    function Invoke-ChocoCommand {
        <#
        .SYNOPSIS
        Executes a Chocolatey command with the specified arguments and returns the exit code.

        .PARAMETER arguments
        The arguments to be passed to the Chocolatey command.

        .DESCRIPTION
        This function runs a specified Chocolatey command by passing the provided arguments to the `choco` executable. It waits for the process to complete and then returns the exit code, allowing the caller to determine success or failure based on the exit code.

        .RETURNS
        [int]
        The exit code of the Chocolatey command.

        .EXAMPLE
        $exitCode = Invoke-ChocoCommand -arguments "install 7zip -y"
        #>

        param ($arguments)
        return (Start-Process -FilePath "choco" -ArgumentList $arguments -Wait -PassThru).ExitCode
    }

    function Test-UpgradeNeeded {
        <#
        .SYNOPSIS
        Checks if an upgrade is needed for a Chocolatey package based on the content of a log file.

        .PARAMETER filePath
        The path to the log file that contains the output of a Chocolatey install command.

        .DESCRIPTION
        This function reads the specified log file and checks for keywords that indicate whether an upgrade is needed. It returns a boolean value indicating whether the terms "reinstall" or "already installed" are present, which suggests that the package might need an upgrade.

        .RETURNS
        [bool]
        True if the log file indicates that an upgrade is needed; otherwise, false.

        .EXAMPLE
        $isUpgradeNeeded = Test-UpgradeNeeded -filePath "C:\temp\install-output.txt"
        #>

        param ($filePath)
        return Get-Content -Path $filePath | Select-String -Pattern "reinstall|already installed" -Quiet
    }

    function Update-TaskbarProgress {
        <#
        .SYNOPSIS
        Updates the taskbar progress based on the current installation progress.

        .PARAMETER currentIndex
        The current index of the program being installed or uninstalled.

        .PARAMETER totalPrograms
        The total number of programs to be installed or uninstalled.

        .DESCRIPTION
        This function calculates the progress of the installation or uninstallation process and updates the taskbar accordingly. The taskbar is set to "Normal" if all programs have been processed, otherwise, it is set to "Error" as a placeholder.

        .EXAMPLE
        Update-TaskbarProgress -currentIndex 3 -totalPrograms 10
        #>

        param (
            [int]$currentIndex,
            [int]$totalPrograms
        )
        $progressState = if ($currentIndex -eq $totalPrograms) { "Normal" } else { "Error" }
        $sync.form.Dispatcher.Invoke([action] { Set-WinUtilTaskbaritem -state $progressState -value ($currentIndex / $totalPrograms) })
    }

    function Install-ChocoPackage {
        <#
        .SYNOPSIS
        Installs a Chocolatey package and optionally upgrades it if needed.

        .PARAMETER Program
        A string containing the name of the Chocolatey package to be installed.

        .PARAMETER currentIndex
        The current index of the program in the list of programs to be managed.

        .PARAMETER totalPrograms
        The total number of programs to be installed.

        .DESCRIPTION
        This function installs a Chocolatey package by running the `choco install` command. If the installation output indicates that an upgrade might be needed, the function will attempt to upgrade the package. The taskbar progress is updated after each package is processed.

        .EXAMPLE
        Install-ChocoPackage -Program $Program -currentIndex 0 -totalPrograms 5
        #>

        param (
            [string]$Program,
            [int]$currentIndex,
            [int]$totalPrograms
        )

        $installOutputFile = "$env:TEMP\Install-WinUtilProgramChoco.install-command.output.txt"
        Initialize-OutputFile $installOutputFile

        Write-Host "Starting installation of $Program with Chocolatey."

        try {
            $installStatusCode = Invoke-ChocoCommand "install $Program -y --log-file $installOutputFile"
            if ($installStatusCode -eq 0) {

                if (Test-UpgradeNeeded $installOutputFile) {
                    $upgradeStatusCode = Invoke-ChocoCommand "upgrade $Program -y"
                    Write-Host "$Program was" $(if ($upgradeStatusCode -eq 0) { "upgraded successfully." } else { "not upgraded." })
                }
                else {
                    Write-Host "$Program installed successfully."
                }
            }
            else {
                Write-Host "Failed to install $Program."
            }
        }
        catch {
            Write-Host "Failed to install $Program due to an error: $_"
        }
        finally {
            Update-TaskbarProgress $currentIndex $totalPrograms
        }
    }

    function Uninstall-ChocoPackage {
        <#
        .SYNOPSIS
        Uninstalls a Chocolatey package and any related metapackages.

        .PARAMETER Program
        A string containing the name of the Chocolatey package to be uninstalled.

        .PARAMETER currentIndex
        The current index of the program in the list of programs to be managed.

        .PARAMETER totalPrograms
        The total number of programs to be uninstalled.

        .DESCRIPTION
        This function uninstalls a Chocolatey package and any related metapackages (e.g., .install or .portable variants). It updates the taskbar progress after processing each package.

        .EXAMPLE
        Uninstall-ChocoPackage -Program $Program -currentIndex 0 -totalPrograms 5
        #>

        param (
            [string]$Program,
            [int]$currentIndex,
            [int]$totalPrograms
        )

        $uninstallOutputFile = "$env:TEMP\Install-WinUtilProgramChoco.uninstall-command.output.txt"
        Initialize-OutputFile $uninstallOutputFile

        Write-Host "Searching for metapackages of $Program (.install or .portable)"
        $chocoPackages = ((choco list | Select-String -Pattern "$Program(\.install|\.portable)?").Matches.Value) -join " "
        if ($chocoPackages) {
            Write-Host "Starting uninstallation of $chocoPackages with Chocolatey."
            try {
                $uninstallStatusCode = Invoke-ChocoCommand "uninstall $chocoPackages -y"
                Write-Host "$Program" $(if ($uninstallStatusCode -eq 0) { "uninstalled successfully." } else { "failed to uninstall." })
            }
            catch {
                Write-Host "Failed to uninstall $Program due to an error: $_"
            }
            finally {
                Update-TaskbarProgress $currentIndex $totalPrograms
            }
        }
        else {
            Write-Host "$Program is not installed."
        }
    }

    $totalPrograms = $Programs.Count
    if ($totalPrograms -le 0) {
        throw "Parameter 'Programs' must have at least one item."
    }

    Write-Host "==========================================="
    Write-Host "--   Configuring Chocolatey packages   ---"
    Write-Host "==========================================="

    for ($currentIndex = 0; $currentIndex -lt $totalPrograms; $currentIndex++) {
        $Program = $Programs[$currentIndex]
        Set-WinUtilProgressBar -label "$Action $($Program)" -percent ($currentIndex / $totalPrograms * 100)
        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -value ($currentIndex / $totalPrograms)})

        switch ($Action) {
            "Install" {
                Install-ChocoPackage -Program $Program -currentIndex $currentIndex -totalPrograms $totalPrograms
            }
            "Uninstall" {
                Uninstall-ChocoPackage -Program $Program -currentIndex $currentIndex -totalPrograms $totalPrograms
            }
            default {
                throw "Invalid action parameter value: '$Action'."
            }
        }
    }
    Set-WinUtilProgressBar -label "$($Action)ation done" -percent 100
    # Cleanup Output Files
    $outputFiles = @("$env:TEMP\Install-WinUtilProgramChoco.install-command.output.txt", "$env:TEMP\Install-WinUtilProgramChoco.uninstall-command.output.txt")
    foreach ($filePath in $outputFiles) {
        Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
    }
}

Function Install-WinUtilProgramWinget {
    <#
    .SYNOPSIS
    Runs the designated action on the provided programs using Winget

    .PARAMETER Programs
    A list of programs to process

    .PARAMETER action
    The action to perform on the programs, can be either 'Install' or 'Uninstall'

    .NOTES
    The triple quotes are required any time you need a " in a normal script block.
    The winget Return codes are documented here: https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-actionr/winget/returnCodes.md
    #>

    param(
        [Parameter(Mandatory, Position=0)]$Programs,

        [Parameter(Mandatory, Position=1)]
        [ValidateSet("Install", "Uninstall")]
        [String]$Action
    )

    Function Invoke-Winget {
    <#
    .SYNOPSIS
    Invokes the winget.exe with the provided arguments and return the exit code

    .PARAMETER wingetId
    The Id of the Program that Winget should Install/Uninstall

    .PARAMETER scope
    Determines the installation mode. Can be "user" or "machine" (For more info look at the winget documentation)

    .PARAMETER credential
    The PSCredential Object of the user that should be used to run winget

    .NOTES
    Invoke Winget uses the public variable $Action defined outside the function to determine if a Program should be installed or removed
    #>
        param (
            [string]$wingetId,
            [string]$scope = "",
            [PScredential]$credential = $null
        )

        $commonArguments = "--id $wingetId --silent"
        $arguments = if ($Action -eq "Install") {
            "install $commonArguments --accept-source-agreements --accept-package-agreements $(if ($scope) {" --scope $scope"})"
        } else {
            "uninstall $commonArguments"
        }

        $processParams = @{
            FilePath = "winget"
            ArgumentList = $arguments
            Wait = $true
            PassThru = $true
            NoNewWindow = $true
        }

        if ($credential) {
            $processParams.credential = $credential
        }

        return (Start-Process @processParams).ExitCode
    }

    Function Invoke-Install {
    <#
    .SYNOPSIS
    Contains the Install Logic and return code handling from winget

    .PARAMETER Program
    The Winget ID of the Program that should be installed
    #>
        param (
            [string]$Program
        )
        $status = Invoke-Winget -wingetId $Program
        if ($status -eq 0) {
            Write-Host "$($Program) installed successfully."
            return $true
        } elseif ($status -eq -1978335189) {
            Write-Host "$($Program) No applicable update found"
            return $true
        }

        Write-Host "Attempt installation of $($Program) with User scope"
        $status = Invoke-Winget -wingetId $Program -scope "user"
        if ($status -eq 0) {
            Write-Host "$($Program) installed successfully with User scope."
            return $true
        } elseif ($status -eq -1978335189) {
            Write-Host "$($Program) No applicable update found"
            return $true
        }

        $userChoice = [System.Windows.MessageBox]::Show("Do you want to attempt $($Program) installation with specific user credentials? Select 'Yes' to proceed or 'No' to skip.", "User credential Prompt", [System.Windows.MessageBoxButton]::YesNo)
        if ($userChoice -eq 'Yes') {
            $getcreds = Get-Credential
            $status = Invoke-Winget -wingetId $Program -credential $getcreds
            if ($status -eq 0) {
                Write-Host "$($Program) installed successfully with User prompt."
                return $true
            }
        } else {
            Write-Host "Skipping installation with specific user credentials."
        }

        Write-Host "Failed to install $($Program)."
        return $false
    }

    Function Invoke-Uninstall {
        <#
        .SYNOPSIS
        Contains the Uninstall Logic and return code handling from winget

        .PARAMETER Program
        The Winget ID of the Program that should be uninstalled
        #>
        param (
            [psobject]$Program
        )

        try {
            $status = Invoke-Winget -wingetId $Program
            if ($status -eq 0) {
                Write-Host "$($Program) uninstalled successfully."
                return $true
            } else {
                Write-Host "Failed to uninstall $($Program)."
                return $false
            }
        } catch {
            Write-Host "Failed to uninstall $($Program) due to an error: $_"
            return $false
        }
    }

    $count = $Programs.Count
    $failedPackages = @()

    Write-Host "==========================================="
    Write-Host "--    Configuring winget packages       ---"
    Write-Host "==========================================="

    for ($i = 0; $i -lt $count; $i++) {
        $Program = $Programs[$i]
        $result = $false
        Set-WinUtilProgressBar -label "$Action $($Program)" -percent ($i / $count * 100)
        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -value ($i / $count)})

        $result = switch ($Action) {
            "Install" {Invoke-Install -Program $Program}
            "Uninstall" {Invoke-Uninstall -Program $Program}
            default {throw "[Install-WinUtilProgramWinget] Invalid action: $Action"}
        }

        if (-not $result) {
            $failedPackages += $Program
        }
    }

    Set-WinUtilProgressBar -label "$($Action)ation done" -percent 100
    return $failedPackages
}
function Install-WinUtilWinget {
    <#

    .SYNOPSIS
        Installs Winget if it is not already installed.

    .DESCRIPTION
        This function will download the latest version of Winget and install it. If Winget is already installed, it will do nothing.
    #>
    $isWingetInstalled = Test-WinUtilPackageManager -winget

    try {
        if ($isWingetInstalled -eq "installed") {
            Write-Host "`nWinget is already installed.`r" -ForegroundColor Green
            return
        } elseif ($isWingetInstalled -eq "outdated") {
            Write-Host "`nWinget is Outdated. Continuing with install.`r" -ForegroundColor Yellow
        } else {
            Write-Host "`nWinget is not Installed. Continuing with install.`r" -ForegroundColor Red
        }


        # Gets the computer's information
        if ($null -eq $sync.ComputerInfo) {
            $ComputerInfo = Get-ComputerInfo -ErrorAction Stop
        } else {
            $ComputerInfo = $sync.ComputerInfo
        }

        if (($ComputerInfo.WindowsVersion) -lt "1809") {
            # Checks if Windows Version is too old for Winget
            Write-Host "Winget is not supported on this version of Windows (Pre-1809)" -ForegroundColor Red
            return
        }

        Write-Host "Attempting to install/update Winget`r"
        try {
            $wingetCmd = Get-Command winget -ErrorAction Stop
            Write-Information "Attempting to update WinGet using WinGet..."
            $result = Start-Process -FilePath "`"$($wingetCmd.Source)`"" -ArgumentList "install -e --accept-source-agreements --accept-package-agreements Microsoft.AppInstaller" -Wait -NoNewWindow -PassThru
            if ($result.ExitCode -ne 0) {
                throw "WinGet update failed with exit code: $($result.ExitCode)"
            }
            Write-Output "Refreshing Environment Variables...`n"
            $ENV:PATH = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            return
        } catch {
            Write-Information "WinGet not found or update failed. Attempting to install from Microsoft Store..."
        }
        try {
            Write-Host "Attempting to repair WinGet using Repair-WinGetPackageManager..." -ForegroundColor Yellow

            # Check if Windows version supports Repair-WinGetPackageManager (24H2 and above)
            if ([System.Environment]::OSVersion.Version.Build -ge 26100) {
                Repair-WinGetPackageManager -Force -Latest -Verbose
                # Verify if repair was successful
                $wingetCmd = Get-Command winget -ErrorAction Stop
                Write-Host "WinGet repair successful!" -ForegroundColor Green
            } else {
                Write-Host "Repair-WinGetPackageManager is only available on Windows 24H2 and above. Your version doesn't support this method." -ForegroundColor Yellow
                throw "Windows version not supported for repair method"
            }

            Write-Output "Refreshing Environment Variables...`n"
            $ENV:PATH = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            return

        } catch {
            Write-Error "All installation methods failed. Unable to install WinGet."
            throw
        }
    } catch {
        Write-Error "An error occurred during WinGet installation: $_"
        throw
    }
}
function Invoke-WinUtilAssets {
  param (
      $type,
      $Size,
      [switch]$render
  )

  # Create the Viewbox and set its size
  $LogoViewbox = New-Object Windows.Controls.Viewbox
  $LogoViewbox.Width = $Size
  $LogoViewbox.Height = $Size

  # Create a Canvas to hold the paths
  $canvas = New-Object Windows.Controls.Canvas
  $canvas.Width = 100
  $canvas.Height = 100

  # Define a scale factor for the content inside the Canvas
  $scaleFactor = $Size / 100

  # Apply a scale transform to the Canvas content
  $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
  $canvas.LayoutTransform = $scaleTransform

  switch ($type) {
      'logo' {
          $LogoPathData1 = @"
M 18.00,14.00
C 18.00,14.00 45.00,27.74 45.00,27.74
45.00,27.74 57.40,34.63 57.40,34.63
57.40,34.63 59.00,43.00 59.00,43.00
59.00,43.00 59.00,83.00 59.00,83.00
55.35,81.66 46.99,77.79 44.72,74.79
41.17,70.10 42.01,59.80 42.00,54.00
42.00,51.62 42.20,48.29 40.98,46.21
38.34,41.74 25.78,38.60 21.28,33.79
16.81,29.02 18.00,20.20 18.00,14.00 Z
"@
          $LogoPath1 = New-Object Windows.Shapes.Path
          $LogoPath1.Data = [Windows.Media.Geometry]::Parse($LogoPathData1)
          $LogoPath1.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0567ff")

          $LogoPathData2 = @"
M 107.00,14.00
C 109.01,19.06 108.93,30.37 104.66,34.21
100.47,37.98 86.38,43.10 84.60,47.21
83.94,48.74 84.01,51.32 84.00,53.00
83.97,57.04 84.46,68.90 83.26,72.00
81.06,77.70 72.54,81.42 67.00,83.00
67.00,83.00 67.00,43.00 67.00,43.00
67.00,43.00 67.99,35.63 67.99,35.63
67.99,35.63 80.00,28.26 80.00,28.26
80.00,28.26 107.00,14.00 107.00,14.00 Z
"@
          $LogoPath2 = New-Object Windows.Shapes.Path
          $LogoPath2.Data = [Windows.Media.Geometry]::Parse($LogoPathData2)
          $LogoPath2.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0567ff")

          $LogoPathData3 = @"
M 19.00,46.00
C 21.36,47.14 28.67,50.71 30.01,52.63
31.17,54.30 30.99,57.04 31.00,59.00
31.04,65.41 30.35,72.16 33.56,78.00
38.19,86.45 46.10,89.04 54.00,93.31
56.55,94.69 60.10,97.20 63.00,97.22
65.50,97.24 68.77,95.36 71.00,94.25
76.42,91.55 84.51,87.78 88.82,83.68
94.56,78.20 95.96,70.59 96.00,63.00
96.01,60.24 95.59,54.63 97.02,52.39
98.80,49.60 103.95,47.87 107.00,47.00
107.00,47.00 107.00,67.00 107.00,67.00
106.90,87.69 96.10,93.85 80.00,103.00
76.51,104.98 66.66,110.67 63.00,110.52
60.33,110.41 55.55,107.53 53.00,106.25
46.21,102.83 36.63,98.57 31.04,93.68
16.88,81.28 19.00,62.88 19.00,46.00 Z
"@
          $LogoPath3 = New-Object Windows.Shapes.Path
          $LogoPath3.Data = [Windows.Media.Geometry]::Parse($LogoPathData3)
          $LogoPath3.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#a3a4a6")

          $canvas.Children.Add($LogoPath1) | Out-Null
          $canvas.Children.Add($LogoPath2) | Out-Null
          $canvas.Children.Add($LogoPath3) | Out-Null
      }
      'checkmark' {
          $canvas.Width = 512
          $canvas.Height = 512

          $scaleFactor = $Size / 2.54
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 1.27,0 A 1.27,1.27 0 1,0 1.27,2.54 A 1.27,1.27 0 1,0 1.27,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#39ba00")

          # Define the checkmark path
          $checkmarkPathData = "M 0.873 1.89 L 0.41 1.391 A 0.17 0.17 0 0 1 0.418 1.151 A 0.17 0.17 0 0 1 0.658 1.16 L 1.016 1.543 L 1.583 1.013 A 0.17 0.17 0 0 1 1.599 1 L 1.865 0.751 A 0.17 0.17 0 0 1 2.105 0.759 A 0.17 0.17 0 0 1 2.097 0.999 L 1.282 1.759 L 0.999 2.022 L 0.874 1.888 Z"
          $checkmarkPath = New-Object Windows.Shapes.Path
          $checkmarkPath.Data = [Windows.Media.Geometry]::Parse($checkmarkPathData)
          $checkmarkPath.Fill = [Windows.Media.Brushes]::White

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($checkmarkPath) | Out-Null
      }
      'warning' {
          $canvas.Width = 512
          $canvas.Height = 512

          # Define a scale factor for the content inside the Canvas
          $scaleFactor = $Size / 512  # Adjust scaling based on the canvas size
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 256,0 A 256,256 0 1,0 256,512 A 256,256 0 1,0 256,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#f41b43")

          # Define the exclamation mark path
          $exclamationPathData = "M 256 307.2 A 35.89 35.89 0 0 1 220.14 272.74 L 215.41 153.3 A 35.89 35.89 0 0 1 251.27 116 H 260.73 A 35.89 35.89 0 0 1 296.59 153.3 L 291.86 272.74 A 35.89 35.89 0 0 1 256 307.2 Z"
          $exclamationPath = New-Object Windows.Shapes.Path
          $exclamationPath.Data = [Windows.Media.Geometry]::Parse($exclamationPathData)
          $exclamationPath.Fill = [Windows.Media.Brushes]::White

          # Get the bounds of the exclamation mark path
          $exclamationBounds = $exclamationPath.Data.Bounds

          # Calculate the center position for the exclamation mark path
          $exclamationCenterX = ($canvas.Width - $exclamationBounds.Width) / 2 - $exclamationBounds.X
          $exclamationPath.SetValue([Windows.Controls.Canvas]::LeftProperty, $exclamationCenterX)

          # Define the rounded rectangle at the bottom (dot of exclamation mark)
          $roundedRectangle = New-Object Windows.Shapes.Rectangle
          $roundedRectangle.Width = 80
          $roundedRectangle.Height = 80
          $roundedRectangle.RadiusX = 30
          $roundedRectangle.RadiusY = 30
          $roundedRectangle.Fill = [Windows.Media.Brushes]::White

          # Calculate the center position for the rounded rectangle
          $centerX = ($canvas.Width - $roundedRectangle.Width) / 2
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::LeftProperty, $centerX)
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::TopProperty, 324.34)

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($exclamationPath) | Out-Null
          $canvas.Children.Add($roundedRectangle) | Out-Null
      }
      default {
          Write-Host "Invalid type: $type"
      }
  }

  # Add the Canvas to the Viewbox
  $LogoViewbox.Child = $canvas

  if ($render) {
      # Measure and arrange the canvas to ensure proper rendering
      $canvas.Measure([Windows.Size]::new($canvas.Width, $canvas.Height))
      $canvas.Arrange([Windows.Rect]::new(0, 0, $canvas.Width, $canvas.Height))
      $canvas.UpdateLayout()

      # Initialize RenderTargetBitmap correctly with dimensions
      $renderTargetBitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($canvas.Width, $canvas.Height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)

      # Render the canvas to the bitmap
      $renderTargetBitmap.Render($canvas)

      # Create a BitmapFrame from the RenderTargetBitmap
      $bitmapFrame = [Windows.Media.Imaging.BitmapFrame]::Create($renderTargetBitmap)

      # Create a PngBitmapEncoder and add the frame
      $bitmapEncoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
      $bitmapEncoder.Frames.Add($bitmapFrame)

      # Save to a memory stream
      $imageStream = New-Object System.IO.MemoryStream
      $bitmapEncoder.Save($imageStream)
      $imageStream.Position = 0

      # Load the stream into a BitmapImage
      $bitmapImage = [Windows.Media.Imaging.BitmapImage]::new()
      $bitmapImage.BeginInit()
      $bitmapImage.StreamSource = $imageStream
      $bitmapImage.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
      $bitmapImage.EndInit()

      return $bitmapImage
  } else {
      return $LogoViewbox
  }
}
Function Invoke-WinUtilCurrentSystem {

    <#

    .SYNOPSIS
        Checks to see what tweaks have already been applied and what programs are installed, and checks the according boxes

    .EXAMPLE
        Get-WinUtilCheckBoxes "WPFInstall"

    #>

    param(
        $CheckBox
    )
    if ($CheckBox -eq "choco") {
        $apps = (choco list | Select-String -Pattern "^\S+").Matches.Value
        $filter = Get-WinUtilVariables -Type Checkbox | Where-Object {$psitem -like "WPFInstall*"}
        $sync.GetEnumerator() | Where-Object {$psitem.Key -in $filter} | ForEach-Object {
            $dependencies = @($sync.configs.applications.$($psitem.Key).choco -split ";")
            if ($dependencies -in $apps) {
                Write-Output $psitem.name
            }
        }
    }

    if ($checkbox -eq "winget") {

        $originalEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
        $Sync.InstalledPrograms = winget list -s winget | Select-Object -skip 3 | ConvertFrom-String -PropertyNames "Name", "Id", "Version", "Available" -Delimiter '\s{2,}'
        [Console]::OutputEncoding = $originalEncoding

        $filter = Get-WinUtilVariables -Type Checkbox | Where-Object {$psitem -like "WPFInstall*"}
        $sync.GetEnumerator() | Where-Object {$psitem.Key -in $filter} | ForEach-Object {
            $dependencies = @($sync.configs.applications.$($psitem.Key).winget -split ";")

            if ($dependencies[-1] -in $sync.InstalledPrograms.Id) {
                Write-Output $psitem.name
            }
        }
    }

    if($CheckBox -eq "tweaks") {

        if(!(Test-Path 'HKU:\')) {$null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)}
        $ScheduledTasks = Get-ScheduledTask

        $sync.configs.tweaks | Get-Member -MemberType NoteProperty | ForEach-Object {

            $Config = $psitem.Name
            #WPFEssTweaksTele
            $registryKeys = $sync.configs.tweaks.$Config.registry
            $scheduledtaskKeys = $sync.configs.tweaks.$Config.scheduledtask
            $serviceKeys = $sync.configs.tweaks.$Config.service

            if($registryKeys -or $scheduledtaskKeys -or $serviceKeys) {
                $Values = @()


                Foreach ($tweaks in $registryKeys) {
                    Foreach($tweak in $tweaks) {

                        if(test-path $tweak.Path) {
                            $actualValue = Get-ItemProperty -Name $tweak.Name -Path $tweak.Path -ErrorAction SilentlyContinue | Select-Object -ExpandProperty $($tweak.Name)
                            $expectedValue = $tweak.Value
                            if ($expectedValue -notlike $actualValue) {
                                $values += $False
                            }
                        } else {
                            $values += $False
                        }
                    }
                }

                Foreach ($tweaks in $scheduledtaskKeys) {
                    Foreach($tweak in $tweaks) {
                        $task = $ScheduledTasks | Where-Object {$($psitem.TaskPath + $psitem.TaskName) -like "\$($tweak.name)"}

                        if($task) {
                            $actualValue = $task.State
                            $expectedValue = $tweak.State
                            if ($expectedValue -ne $actualValue) {
                                $values += $False
                            }
                        }
                    }
                }

                Foreach ($tweaks in $serviceKeys) {
                    Foreach($tweak in $tweaks) {
                        $Service = Get-Service -Name $tweak.Name

                        if($Service) {
                            $actualValue = $Service.StartType
                            $expectedValue = $tweak.StartupType
                            if ($expectedValue -ne $actualValue) {
                                $values += $False
                            }
                        }
                    }
                }

                if($values -notcontains $false) {
                    Write-Output $Config
                }
            }
        }
    }
}
function Invoke-WinUtilExplorerUpdate {
    <#
    .SYNOPSIS
        Refreshes the Windows Explorer
    #>

    param (
        [string]$action = "refresh"
    )

    if ($action -eq "refresh") {
        Invoke-WPFRunspace -DebugPreference $DebugPreference -ScriptBlock {
            # Send the WM_SETTINGCHANGE message to all windows
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = false)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint Msg,
        IntPtr wParam,
        string lParam,
        uint fuFlags,
        uint uTimeout,
        out IntPtr lpdwResult);
}
"@

            $HWND_BROADCAST = [IntPtr]0xffff
            $WM_SETTINGCHANGE = 0x1A
            $SMTO_ABORTIFHUNG = 0x2
            $timeout = 100

            # Send the broadcast message to all windows
            [Win32]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [IntPtr]::Zero, "ImmersiveColorSet", $SMTO_ABORTIFHUNG, $timeout, [ref]([IntPtr]::Zero))
        }
    } elseif ($action -eq "restart") {
        # Restart the Windows Explorer
        taskkill.exe /F /IM "explorer.exe"
        Start-Process "explorer.exe"
    }
}
function Invoke-WinUtilFeatureInstall {
    <#

    .SYNOPSIS
        Converts all the values from the tweaks.json and routes them to the appropriate function

    #>

    param(
        $CheckBox
    )

    $x = 0

    $CheckBox | ForEach-Object {
        if($sync.configs.feature.$psitem.feature) {
            Foreach( $feature in $sync.configs.feature.$psitem.feature ) {
                try {
                    Write-Host "Installing $feature"
                    Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
                } catch {
                    if ($psitem.Exception.Message -like "*requires elevation*") {
                        Write-Warning "Unable to Install $feature due to permissions. Are you running as admin?"
                        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Error" })
                    } else {

                        Write-Warning "Unable to Install $feature due to unhandled exception"
                        Write-Warning $psitem.Exception.StackTrace
                    }
                }
            }
        }
        if($sync.configs.feature.$psitem.InvokeScript) {
            Foreach( $script in $sync.configs.feature.$psitem.InvokeScript ) {
                try {
                    $Scriptblock = [scriptblock]::Create($script)

                    Write-Host "Running Script for $psitem"
                    Invoke-Command $scriptblock -ErrorAction stop
                } catch {
                    if ($psitem.Exception.Message -like "*requires elevation*") {
                        Write-Warning "Unable to Install $feature due to permissions. Are you running as admin?"
                        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Error" })
                    } else {
                        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Error" })
                        Write-Warning "Unable to Install $feature due to unhandled exception"
                        Write-Warning $psitem.Exception.StackTrace
                    }
                }
            }
        }
        $X++
        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -value ($x/$CheckBox.Count) })
    }
}
function Invoke-WinUtilGPU {
    $gpuInfo = Get-CimInstance Win32_VideoController

    # GPUs to blacklist from using Demanding Theming
    $lowPowerGPUs = (
        "*NVIDIA GeForce*M*",
        "*NVIDIA GeForce*Laptop*",
        "*NVIDIA GeForce*GT*",
        "*AMD Radeon(TM)*",
        "*Intel(R) HD Graphics*",
        "*UHD*"

    )

    foreach ($gpu in $gpuInfo) {
        foreach ($gpuPattern in $lowPowerGPUs) {
            if ($gpu.Name -like $gpuPattern) {
                return $false
            }
        }
    }
    return $true
}
function Invoke-WinUtilInstallPSProfile {
    <#
    .SYNOPSIS
        Backs up your original profile then installs and applies the CTT PowerShell profile.
    #>

    Invoke-WPFRunspace -ArgumentList $PROFILE -DebugPreference $DebugPreference -ScriptBlock {
        # Remap the automatic built-in $PROFILE variable to the parameter named $PSProfile.
        param ($PSProfile)

        function Invoke-PSSetup {
            # Define the URL used to download Chris Titus Tech's PowerShell profile.
            $url = "https://raw.githubusercontent.com/ChrisTitusTech/powershell-profile/main/Microsoft.PowerShell_profile.ps1"

            # Get the file hash for the user's current PowerShell profile.
            $OldHash = Get-FileHash $PSProfile -ErrorAction SilentlyContinue

            # Download Chris Titus Tech's PowerShell profile to the 'TEMP' folder.
            Invoke-RestMethod $url -OutFile "$env:TEMP/Microsoft.PowerShell_profile.ps1"

            # Get the file hash for Chris Titus Tech's PowerShell profile.
            $NewHash = Get-FileHash "$env:TEMP/Microsoft.PowerShell_profile.ps1"

            # Store the file hash of Chris Titus Tech's PowerShell profile.
            if (!(Test-Path "$PSProfile.hash")) {
                $NewHash.Hash | Out-File "$PSProfile.hash"
            }

            # Check if the new profile's hash doesn't match the old profile's hash.
            if ($NewHash.Hash -ne $OldHash.Hash) {
                # Check if oldprofile.ps1 exists and use it as a profile backup source.
                if (Test-Path "$env:USERPROFILE\oldprofile.ps1") {
                    Write-Host "===> Backup File Exists... <===" -ForegroundColor Yellow
                    Write-Host "===> Moving Backup File... <===" -ForegroundColor Yellow
                    Copy-Item "$env:USERPROFILE\oldprofile.ps1" "$PSProfile.bak"
                    Write-Host "===> Profile Backup: Done. <===" -ForegroundColor Yellow
                } else {
                    # If oldprofile.ps1 does not exist use $PSProfile as a profile backup source.
                    # Check if the profile backup file has not already been created on the disk.
                    if ((Test-Path $PSProfile) -and (-not (Test-Path "$PSProfile.bak"))) {
                        # Let the user know their PowerShell profile is being backed up.
                        Write-Host "===> Backing Up Profile... <===" -ForegroundColor Yellow

                        # Copy the user's current PowerShell profile to the backup file path.
                        Copy-Item -Path $PSProfile -Destination "$PSProfile.bak"

                        # Let the user know the profile backup has been completed successfully.
                        Write-Host "===> Profile Backup: Done. <===" -ForegroundColor Yellow
                    }
                }

                # Let the user know Chris Titus Tech's PowerShell profile is being installed.
                Write-Host "===> Installing Profile... <===" -ForegroundColor Yellow

                # Start a new hidden PowerShell instance because setup.ps1 does not work in runspaces.
                Start-Process -FilePath "pwsh" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -Command `"Invoke-Expression (Invoke-WebRequest `'https://github.com/ChrisTitusTech/powershell-profile/raw/main/setup.ps1`')`"" -WindowStyle Hidden -Wait

                # Let the user know Chris Titus Tech's PowerShell profile has been installed successfully.
                Write-Host "Profile has been installed. Please restart your shell to reflect the changes!" -ForegroundColor Magenta

                # Let the user know Chris Titus Tech's PowerShell profile has been setup successfully.
                Write-Host "===> Finished Profile Setup <===" -ForegroundColor Yellow
            } else {
                # Let the user know Chris Titus Tech's PowerShell profile is already fully up-to-date.
                Write-Host "Profile is up to date" -ForegroundColor Magenta
            }
        }

        # Check if PowerShell Core is currently installed as a program and is available as a command.
        if (Get-Command "pwsh" -ErrorAction SilentlyContinue) {
            # Check if the version of PowerShell Core currently in use is version 7 or higher.
            if ($PSVersionTable.PSVersion.Major -ge 7) {
                # Invoke the PowerShell Profile setup script to install Chris Titus Tech's PowerShell Profile.
                Invoke-PSSetup
            } else {
                # Let the user know that PowerShell 7 is installed but is not currently in use.
                Write-Host "This profile requires Powershell 7, which is currently installed but not used!" -ForegroundColor Red

                # Load the necessary .NET library required to use Windows Forms to show dialog boxes.
                Add-Type -AssemblyName System.Windows.Forms

                # Display the message box asking if the user wants to install PowerShell 7 or not.
                $question = [System.Windows.Forms.MessageBox]::Show(
                    "Profile requires Powershell 7, which is currently installed but not used! Do you want to install the profile for Powershell 7?",
                    "Question",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question
                )

                # Proceed with the installation and setup of the profile as the user pressed the 'Yes' button.
                if ($question -eq [System.Windows.Forms.DialogResult]::Yes) {
                    Invoke-PSSetup
                } else {
                    # Let the user know the setup of the profile will not proceed as they pressed the 'No' button.
                    Write-Host "Not proceeding with the profile setup!" -ForegroundColor Magenta
                }
            }
        } else {
            # Let the user know that the profile requires PowerShell Core but it is not currently installed.
            Write-Host "This profile requires Powershell Core, which is currently not installed!" -ForegroundColor Red
        }
    }
}
function Invoke-WinUtilScript {
    <#

    .SYNOPSIS
        Invokes the provided scriptblock. Intended for things that can't be handled with the other functions.

    .PARAMETER Name
        The name of the scriptblock being invoked

    .PARAMETER scriptblock
        The scriptblock to be invoked

    .EXAMPLE
        $Scriptblock = [scriptblock]::Create({"Write-output 'Hello World'"})
        Invoke-WinUtilScript -ScriptBlock $scriptblock -Name "Hello World"

    #>
    param (
        $Name,
        [scriptblock]$scriptblock
    )

    try {
        Write-Host "Running Script for $name"
        Invoke-Command $scriptblock -ErrorAction Stop
    } catch [System.Management.Automation.CommandNotFoundException] {
        Write-Warning "The specified command was not found."
        Write-Warning $PSItem.Exception.message
    } catch [System.Management.Automation.RuntimeException] {
        Write-Warning "A runtime exception occurred."
        Write-Warning $PSItem.Exception.message
    } catch [System.Security.SecurityException] {
        Write-Warning "A security exception occurred."
        Write-Warning $PSItem.Exception.message
    } catch [System.UnauthorizedAccessException] {
        Write-Warning "Access denied. You do not have permission to perform this operation."
        Write-Warning $PSItem.Exception.message
    } catch {
        # Generic catch block to handle any other type of exception
        Write-Warning "Unable to run script for $name due to unhandled exception"
        Write-Warning $psitem.Exception.StackTrace
    }

}
Function Invoke-WinUtilSponsors {
    <#
    .SYNOPSIS
        Lists Sponsors from ChrisTitusTech
    .DESCRIPTION
        Lists Sponsors from ChrisTitusTech
    .EXAMPLE
        Invoke-WinUtilSponsors
    .NOTES
        This function is used to list sponsors from ChrisTitusTech
    #>
    try {
        # Define the URL and headers
        $url = "https://github.com/sponsors/ChrisTitusTech"
        $headers = @{
            "User-Agent" = "Chrome/58.0.3029.110"
        }

        # Fetch the webpage content
        try {
            $html = Invoke-RestMethod -Uri $url -Headers $headers
        } catch {
            Write-Output $_.Exception.Message
            exit
        }

        # Use regex to extract the content between "Current sponsors" and "Past sponsors"
        $currentSponsorsPattern = '(?s)(?<=Current sponsors).*?(?=Past sponsors)'
        $currentSponsorsHtml = [regex]::Match($html, $currentSponsorsPattern).Value

        # Use regex to extract the sponsor usernames from the alt attributes in the "Current Sponsors" section
        $sponsorPattern = '(?<=alt="@)[^"]+'
        $sponsors = [regex]::Matches($currentSponsorsHtml, $sponsorPattern) | ForEach-Object { $_.Value }

        # Exclude "ChrisTitusTech" from the sponsors
        $sponsors = $sponsors | Where-Object { $_ -ne "ChrisTitusTech" }

        # Return the sponsors
        return $sponsors
    } catch {
        Write-Error "An error occurred while fetching or processing the sponsors: $_"
        return $null
    }
}
function Invoke-WinUtilSSHServer {
    <#
    .SYNOPSIS
        Enables OpenSSH server to remote into your windows device
    #>

    # Get the latest version of OpenSSH Server
    $FeatureName = Get-WindowsCapability -Online | Where-Object { $_.Name -like "OpenSSH.Server*" }

    # Install the OpenSSH Server feature if not already installed
    if ($FeatureName.State -ne "Installed") {
        Write-Host "Enabling OpenSSH Server"
        Add-WindowsCapability -Online -Name $FeatureName.Name
    }

    # Sets up the OpenSSH Server service
    Write-Host "Starting the services"
    Start-Service -Name sshd
    Set-Service -Name sshd -StartupType Automatic

    # Sets up the ssh-agent service
    Start-Service 'ssh-agent'
    Set-Service -Name 'ssh-agent' -StartupType 'Automatic'

    # Confirm the required services are running
    $SSHDaemonService = Get-Service -Name sshd
    $SSHAgentService = Get-Service -Name 'ssh-agent'

    if ($SSHDaemonService.Status -eq 'Running') {
        Write-Host "OpenSSH Server is running."
    } else {
        try {
            Write-Host "OpenSSH Server is not running. Attempting to restart..."
            Restart-Service -Name sshd -Force
            Write-Host "OpenSSH Server has been restarted successfully."
        } catch {
            Write-Host "Failed to restart OpenSSH Server: $_"
        }
    }
    if ($SSHAgentService.Status -eq 'Running') {
        Write-Host "ssh-agent is running."
    } else {
        try {
            Write-Host "ssh-agent is not running. Attempting to restart..."
            Restart-Service -Name sshd -Force
            Write-Host "ssh-agent has been restarted successfully."
        } catch {
            Write-Host "Failed to restart ssh-agent : $_"
        }
    }

    #Adding Firewall rule for port 22
    Write-Host "Setting up firewall rules"
    $firewallRule = (Get-NetFirewallRule -Name 'sshd').Enabled
    if ($firewallRule) {
        Write-Host "Firewall rule for OpenSSH Server (sshd) already exists."
    } else {
        New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
        Write-Host "Firewall rule for OpenSSH Server created and enabled."
    }

    # Check for the authorized_keys file
    $sshFolderPath = "$env:HOMEDRIVE\$env:HOMEPATH\.ssh"
    $authorizedKeysPath = "$sshFolderPath\authorized_keys"

    if (-not (Test-Path -Path $sshFolderPath)) {
        Write-Host "Creating ssh directory..."
        New-Item -Path $sshFolderPath -ItemType Directory -Force
    }

    if (-not (Test-Path -Path $authorizedKeysPath)) {
        Write-Host "Creating authorized_keys file..."
        New-Item -Path $authorizedKeysPath -ItemType File -Force
        Write-Host "authorized_keys file created at $authorizedKeysPath."
    } else {
        Write-Host "authorized_keys file already exists at $authorizedKeysPath."
    }
    Write-Host "OpenSSH server was successfully enabled."
    Write-Host "The config file can be located at C:\ProgramData\ssh\sshd_config "
    Write-Host "Add your public keys to this file -> $authorizedKeysPath"
}
function Invoke-WinutilThemeChange {
    <#
    .SYNOPSIS
        Toggles between light and dark themes for a Windows utility application.

    .DESCRIPTION
        This function toggles the theme of the user interface between 'Light' and 'Dark' modes,
        modifying various UI elements such as colors, margins, corner radii, font families, etc.
        If the '-init' switch is used, it initializes the theme based on the system's current dark mode setting.

    .PARAMETER init
        A switch parameter. If set to $true, the function initializes the theme based on the system?s current dark mode setting.

    .EXAMPLE
        Invoke-WinutilThemeChange
        # Toggles the theme between 'Light' and 'Dark'.

    .EXAMPLE
        Invoke-WinutilThemeChange -init
        # Initializes the theme based on the system's dark mode and applies the shared theme.
    #>
    param (
        [switch]$init = $false,
        [string]$theme
    )

    function Set-WinutilTheme {
        <#
        .SYNOPSIS
            Applies the specified theme to the application's user interface.

        .DESCRIPTION
            This internal function applies the given theme by setting the relevant properties
            like colors, font families, corner radii, etc., in the UI. It uses the
            'Set-ThemeResourceProperty' helper function to modify the application's resources.

        .PARAMETER currentTheme
            The name of the theme to be applied. Common values are "Light", "Dark", or "shared".
        #>
        param (
            [string]$currentTheme
        )

        function Set-ThemeResourceProperty {
            <#
            .SYNOPSIS
                Sets a specific UI property in the application's resources.

            .DESCRIPTION
                This helper function sets a property (e.g., color, margin, corner radius) in the
                application's resources, based on the provided type and value. It includes
                error handling to manage potential issues while setting a property.

            .PARAMETER Name
                The name of the resource property to modify (e.g., "MainBackgroundColor", "ButtonBackgroundMouseoverColor").

            .PARAMETER Value
                The value to assign to the resource property (e.g., "#FFFFFF" for a color).

            .PARAMETER Type
                The type of the resource, such as "ColorBrush", "CornerRadius", "GridLength", or "FontFamily".
            #>
            param($Name, $Value, $Type)
            try {
                # Set the resource property based on its type
                $sync.Form.Resources[$Name] = switch ($Type) {
                    "ColorBrush" { [Windows.Media.SolidColorBrush]::new($Value) }
                    "Color" {
                        # Convert hex string to RGB values
                        $hexColor = $Value.TrimStart("#")
                        $r = [Convert]::ToInt32($hexColor.Substring(0,2), 16)
                        $g = [Convert]::ToInt32($hexColor.Substring(2,2), 16)
                        $b = [Convert]::ToInt32($hexColor.Substring(4,2), 16)
                        [Windows.Media.Color]::FromRgb($r, $g, $b)
                    }
                    "CornerRadius" { [System.Windows.CornerRadius]::new($Value) }
                    "GridLength" { [System.Windows.GridLength]::new($Value) }
                    "Thickness" {
                        # Parse the Thickness value (supports 1, 2, or 4 inputs)
                        $values = $Value -split ","
                        switch ($values.Count) {
                            1 { [System.Windows.Thickness]::new([double]$values[0]) }
                            2 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1]) }
                            4 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1], [double]$values[2], [double]$values[3]) }
                        }
                    }
                    "FontFamily" { [Windows.Media.FontFamily]::new($Value) }
                    "Double" { [double]$Value }
                    default { $Value }
                }
            }
            catch {
                # Log a warning if there's an issue setting the property
                Write-Warning "Failed to set property $($Name): $_"
            }
        }

        # Retrieve all theme properties from the theme configuration
        $themeProperties = $sync.configs.themes.$currentTheme.PSObject.Properties
        foreach ($_ in $themeProperties) {
            # Apply properties that deal with colors
            if ($_.Name -like "*color*") {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "ColorBrush"
                # For certain color properties, also set complementary values (e.g., BorderColor -> CBorderColor) This is required because e.g DropShadowEffect requires a <Color> and not a <SolidColorBrush> object
                if ($_.Name -in @("BorderColor", "ButtonBackgroundMouseoverColor")) {
                    Set-ThemeResourceProperty -Name "C$($_.Name)" -Value $_.Value -Type "Color"
                }
            }
            # Apply corner radius properties
            elseif ($_.Name -like "*Radius*") {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "CornerRadius"
            }
            # Apply row height properties
            elseif ($_.Name -like "*RowHeight*") {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "GridLength"
            }
            # Apply thickness or margin properties
            elseif (($_.Name -like "*Thickness*") -or ($_.Name -like "*margin")) {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "Thickness"
            }
            # Apply font family properties
            elseif ($_.Name -like "*FontFamily*") {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "FontFamily"
            }
            # Apply any other properties as doubles (numerical values)
            else {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "Double"
            }
        }
    }

    $LightPreferencePath = "$env:LOCALAPPDATA\winutil\LightTheme.ini"
    $DarkPreferencePath = "$env:LOCALAPPDATA\winutil\DarkTheme.ini"

    if ($init) {
        Set-WinutilTheme -currentTheme "shared"
        if (Test-Path $LightPreferencePath) {
            $theme = "Light"
        }
        elseif (Test-Path $DarkPreferencePath) {
            $theme = "Dark"
        }
        else {
            $theme = "Auto"
        }
    }

    switch ($theme) {
        "Auto" {
            $systemUsesDarkMode = Get-WinUtilToggleStatus WPFToggleDarkMode
            if ($systemUsesDarkMode) {
                Set-WinutilTheme  -currentTheme "Dark"
            }
            else{
                Set-WinutilTheme  -currentTheme "Light"
            }


            $themeButtonIcon = [char]0xF08C
            Remove-Item $LightPreferencePath -Force -ErrorAction SilentlyContinue
            Remove-Item $DarkPreferencePath -Force -ErrorAction SilentlyContinue
        }
        "Dark" {
            Set-WinutilTheme  -currentTheme $theme
            $themeButtonIcon = [char]0xE708
            $null = New-Item $DarkPreferencePath -Force
            Remove-Item $LightPreferencePath -Force -ErrorAction SilentlyContinue
           }
        "Light" {
            Set-WinutilTheme  -currentTheme $theme
            $themeButtonIcon = [char]0xE706
            $null = New-Item $LightPreferencePath -Force
            Remove-Item $DarkPreferencePath -Force -ErrorAction SilentlyContinue
        }
    }

    # Update the theme selector button with the appropriate icon
    $ThemeButton = $sync.Form.FindName("ThemeButton")
    $ThemeButton.Content = [string]$themeButtonIcon
}
function Invoke-WinUtilTweaks {
    <#

    .SYNOPSIS
        Invokes the function associated with each provided checkbox

    .PARAMETER CheckBox
        The checkbox to invoke

    .PARAMETER undo
        Indicates whether to undo the operation contained in the checkbox

    .PARAMETER KeepServiceStartup
        Indicates whether to override the startup of a service with the one given from WinUtil,
        or to keep the startup of said service, if it was changed by the user, or another program, from its default value.
    #>

    param(
        $CheckBox,
        $undo = $false,
        $KeepServiceStartup = $true
    )

    if ($Checkbox -contains "Toggle") {
        $CheckBox = $sync.configs.tweaks.$CheckBox
    }

    Write-Debug "Tweaks: $($CheckBox)"
    if($undo) {
        $Values = @{
            Registry = "OriginalValue"
            ScheduledTask = "OriginalState"
            Service = "OriginalType"
            ScriptType = "UndoScript"
        }

    } else {
        $Values = @{
            Registry = "Value"
            ScheduledTask = "State"
            Service = "StartupType"
            OriginalService = "OriginalType"
            ScriptType = "InvokeScript"
        }
    }
    if($sync.configs.tweaks.$CheckBox.ScheduledTask) {
        $sync.configs.tweaks.$CheckBox.ScheduledTask | ForEach-Object {
            Write-Debug "$($psitem.Name) and state is $($psitem.$($values.ScheduledTask))"
            Set-WinUtilScheduledTask -Name $psitem.Name -State $psitem.$($values.ScheduledTask)
        }
    }
    if($sync.configs.tweaks.$CheckBox.service) {
        Write-Debug "KeepServiceStartup is $KeepServiceStartup"
        $sync.configs.tweaks.$CheckBox.service | ForEach-Object {
            $changeservice = $true

        # The check for !($undo) is required, without it the script will throw an error for accessing unavailable memeber, which's the 'OriginalService' Property
            if($KeepServiceStartup -AND !($undo)) {
                try {
                    # Check if the service exists
                    $service = Get-Service -Name $psitem.Name -ErrorAction Stop
                    if(!($service.StartType.ToString() -eq $psitem.$($values.OriginalService))) {
                        Write-Debug "Service $($service.Name) was changed in the past to $($service.StartType.ToString()) from it's original type of $($psitem.$($values.OriginalService)), will not change it to $($psitem.$($values.service))"
                        $changeservice = $false
                    }
                } catch [System.ServiceProcess.ServiceNotFoundException] {
                    Write-Warning "Service $($psitem.Name) was not found"
                }
            }

            if($changeservice) {
                Write-Debug "$($psitem.Name) and state is $($psitem.$($values.service))"
                Set-WinUtilService -Name $psitem.Name -StartupType $psitem.$($values.Service)
            }
        }
    }
    if($sync.configs.tweaks.$CheckBox.registry) {
        $sync.configs.tweaks.$CheckBox.registry | ForEach-Object {
            Write-Debug "$($psitem.Name) and state is $($psitem.$($values.registry))"
            if (($psitem.Path -imatch "hku") -and !(Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
                $null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)
                if (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue) {
                    Write-Debug "HKU drive created successfully"
                } else {
                    Write-Debug "Failed to create HKU drive"
                }
            }
            Set-WinUtilRegistry -Name $psitem.Name -Path $psitem.Path -Type $psitem.Type -Value $psitem.$($values.registry)
        }
    }
    if($sync.configs.tweaks.$CheckBox.$($values.ScriptType)) {
        $sync.configs.tweaks.$CheckBox.$($values.ScriptType) | ForEach-Object {
            Write-Debug "$($psitem) and state is $($psitem.$($values.ScriptType))"
            $Scriptblock = [scriptblock]::Create($psitem)
            Invoke-WinUtilScript -ScriptBlock $scriptblock -Name $CheckBox
        }
    }

    if(!$undo) {
        if($sync.configs.tweaks.$CheckBox.appx) {
            $sync.configs.tweaks.$CheckBox.appx | ForEach-Object {
                Write-Debug "UNDO $($psitem.Name)"
                Remove-WinUtilAPPX -Name $psitem
            }
        }

    }
}
function Invoke-WinUtilUninstallPSProfile {
    <#
    .SYNOPSIS
        # Uninstalls the CTT PowerShell profile then restores the original profile.
    #>

    Invoke-WPFRunspace -ArgumentList $PROFILE -DebugPreference $DebugPreference -ScriptBlock {
        # Remap the automatic built-in $PROFILE variable to the parameter named $PSProfile.
        param ($PSProfile)

        # Helper function used to uninstall a specific Nerd Fonts font package.
        function Uninstall-NerdFonts {
            # Define the parameters block for the Uninstall-NerdFonts function.
            param (
                [string]$FontsPath = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts",
                [string]$FontFamilyName = "CaskaydiaCoveNerdFont"
            )

            # Get the list of installed fonts as specified by the FontFamilyName parameter.
            $Fonts = Get-ChildItem $FontsPath -Recurse -Filter "*.ttf" | Where-Object { $_.Name -match $FontFamilyName }

            # Check if the specified fonts are currently installed on the system.
            if ($Fonts) {
                # Let the user know that the Nerd Fonts are currently being uninstalled.
                Write-Host "===> Uninstalling: Nerd Fonts... <===" -ForegroundColor Yellow

                # Loop over the font files and remove each installed font file one-by-one.
                $Fonts | ForEach-Object {
                    # Check if the font file exists on the disk before attempting to remove it.
                    if (Test-Path "$($_.FullName)") {
                        # Remove the found font files from the disk; uninstalling the font.
                        Remove-Item "$($_.FullName)"
                    }
                }
            }

            # Let the user know that the Nerd Fonts package has been uninstalled from the system.
            if (-not $Fonts) {
                Write-Host "===> Successfully Uninstalled: Nerd Fonts. <===" -ForegroundColor Yellow
            }

        }

        # Helper function used to uninstall a specific Nerd Fonts font corresponding registry keys.
        function Uninstall-NerdFontRegKeys {
            # Define the parameters block for the Uninstall-NerdFontsRegKey function.
            param (
                [string]$FontsRegPath = "HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts",
                [string]$FontFamilyName = "CaskaydiaCove"
            )

            try {
                # Get all properties (font registrations) from the registry path
                $registryProperties = Get-ItemProperty -Path $FontsRegPath

                # Filter and remove properties that match the font family name
                $registryProperties.PSObject.Properties |
                Where-Object { $_.Name -match $FontFamilyName } |
                ForEach-Object {
                    If ($_.Name -like "*$FontFamilyName*") {
                        Remove-ItemProperty -path $FontsRegPath -Name $_.Name -ErrorAction SilentlyContinue
                    }
                }
            } catch {
                Write-Host "Error removing registry keys: $($_.exception.message)" -ForegroundColor Red
            }
        }

        # Check if Chris Titus Tech's PowerShell profile is currently available in the PowerShell profile folder.
        if (Test-Path $PSProfile -PathType Leaf) {
            # Set the GitHub repo path used for looking up the name of Chris Titus Tech's powershell-profile repo.
            $GitHubRepoPath = "ChrisTitusTech/powershell-profile"

            # Get the unique identifier used to test for the presence of Chris Titus Tech's PowerShell profile.
            $PSProfileIdentifier = (Invoke-RestMethod "https://api.github.com/repos/$GitHubRepoPath").full_name

            # Check if Chris Titus Tech's PowerShell profile is currently installed in the PowerShell profile folder.
            if ((Get-Content $PSProfile) -match $PSProfileIdentifier) {
                # Attempt to uninstall Chris Titus Tech's PowerShell profile from the PowerShell profile folder.
                try {
                    # Get the content of the backup PowerShell profile and store it in-memory.
                    $PSProfileContent = Get-Content "$PSProfile.bak"

                    # Store the flag used to check if OhMyPosh is in use by the backup PowerShell profile.
                    $OhMyPoshInUse = $PSProfileContent -match "oh-my-posh init"

                    # Check if OhMyPosh is not currently in use by the backup PowerShell profile.
                    if (-not $OhMyPoshInUse) {
                        # If OhMyPosh is currently installed attempt to uninstall it from the system.
                        if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
                            # Let the user know that OhMyPosh is currently being uninstalled from their system.
                            Write-Host "===> Uninstalling: OhMyPosh... <===" -ForegroundColor Yellow

                            # Attempt to uninstall OhMyPosh from the system with the WinGet package manager.
                            winget uninstall -e --id JanDeDobbeleer.OhMyPosh
                        }
                    } else {
                        # Let the user know that the uninstallation of OhMyPosh has been skipped because it is in use.
                        Write-Host "===> Skipped Uninstall: OhMyPosh In-Use. <===" -ForegroundColor Yellow
                    }
                } catch {
                    # Let the user know that an error was encountered when uninstalling OhMyPosh.
                    Write-Host "Failed to uninstall OhMyPosh. Error: $_" -ForegroundColor Red
                }

                # Attempt to uninstall the specified Nerd Fonts package from the system.
                try {
                    # Specify the directory that the specified font package will be uninstalled from.
                    [string]$FontsPath = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"

                    # Specify the name of the font package that is to be uninstalled from the system.
                    [string]$FontFamilyName = "CaskaydiaCoveNerdFont"

                    # Call the function used to uninstall the specified Nerd Fonts package from the system.
                    Uninstall-NerdFonts -FontsPath $FontsPath -FontFamilyName $FontFamilyName

                } catch {
                    # Let the user know that an error was encountered when uninstalling Nerd Fonts.
                    Write-Host "Failed to uninstall Nerd Fonts. Error: $_" -ForegroundColor Red
                }

                # Attempt to uninstall the specified Nerd Fonts registry keys from the system.
                try {
                    # Specify the registry path that the specified font registry keys will be uninstalled from.
                    [string]$FontsRegPath = "HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"

                    # Specify the name of the font registry keys that is to be uninstalled from the system.
                    [string]$FontFamilyName = "CaskaydiaCove"

                    # Call the function used to uninstall the specified Nerd Fonts registry keys from the system.
                    Uninstall-NerdFontRegKeys -FontsPath $FontsRegPath -FontFamilyName $FontFamilyName

                } catch {
                    # Let the user know that an error was encountered when uninstalling Nerd Font registry keys.
                    Write-Host "Failed to uninstall Nerd Font Registry Keys. Error: $_" -ForegroundColor Red
                }

                # Attempt to uninstall the Terminal-Icons PowerShell module from the system.
                try {
                    # Get the content of the backup PowerShell profile and store it in-memory.
                    $PSProfileContent = Get-Content "$PSProfile.bak"

                    # Store the flag used to check if Terminal-Icons is in use by the backup PowerShell profile.
                    $TerminalIconsInUse = $PSProfileContent -match "Import-Module" -and $PSProfileContent -match "Terminal-Icons"

                    # Check if Terminal-Icons is not currently in use by the backup PowerShell profile.
                    if (-not $TerminalIconsInUse) {
                        # If Terminal-Icons is currently installed attempt to uninstall it from the system.
                        if (Get-Module -ListAvailable Terminal-Icons) {
                            # Let the user know that Terminal-Icons is currently being uninstalled from their system.
                            Write-Host "===> Uninstalling: Terminal-Icons... <===" -ForegroundColor Yellow

                            # Attempt to uninstall Terminal-Icons from the system with Uninstall-Module.
                            Uninstall-Module -Name Terminal-Icons
                        }
                    } else {
                        # Let the user know that the uninstallation of Terminal-Icons has been skipped because it is in use.
                        Write-Host "===> Skipped Uninstall: Terminal-Icons In-Use. <===" -ForegroundColor Yellow
                    }
                } catch {
                    # Let the user know that an error was encountered when uninstalling Terminal-Icons.
                    Write-Host "Failed to uninstall Terminal-Icons. Error: $_" -ForegroundColor Red
                }

                # Attempt to uninstall the Zoxide application from the system.
                try {
                    # Get the content of the backup PowerShell profile and store it in-memory.
                    $PSProfileContent = Get-Content "$PSProfile.bak"

                    # Store the flag used to check if Zoxide is in use by the backup PowerShell profile.
                    $ZoxideInUse = $PSProfileContent -match "zoxide init"

                    # Check if Zoxide is not currently in use by the backup PowerShell profile.
                    if (-not $ZoxideInUse) {
                        # If Zoxide is currently installed attempt to uninstall it from the system.
                        if (Get-Command zoxide -ErrorAction SilentlyContinue) {
                            # Let the user know that Zoxide is currently being uninstalled from their system.
                            Write-Host "===> Uninstalling: Zoxide... <===" -ForegroundColor Yellow

                            # Attempt to uninstall Zoxide from the system with the WinGet package manager.
                            winget uninstall -e --id ajeetdsouza.zoxide
                        }
                    } else {
                        # Let the user know that the uninstallation of Zoxide been skipped because it is in use.
                        Write-Host "===> Skipped Uninstall: Zoxide In-Use. <===" -ForegroundColor Yellow
                    }
                } catch {
                    # Let the user know that an error was encountered when uninstalling Zoxide.
                    Write-Host "Failed to uninstall Zoxide. Error: $_" -ForegroundColor Red
                }

                # Attempt to uninstall the CTT PowerShell profile from the system.
                try {
                    # Try and remove the CTT PowerShell Profile file from the disk with Remove-Item.
                    Remove-Item $PSProfile

                    # Let the user know that the CTT PowerShell profile has been uninstalled from the system.
                    Write-Host "Profile has been uninstalled. Please restart your shell to reflect the changes!" -ForegroundColor Magenta
                } catch {
                    # Let the user know that an error was encountered when uninstalling the profile.
                    Write-Host "Failed to uninstall profile. Error: $_" -ForegroundColor Red
                }

                # Attempt to move the user's original PowerShell profile backup back to its original location.
                try {
                    # Check if the backup PowerShell profile exists before attempting to restore the backup.
                    if (Test-Path "$PSProfile.bak") {
                        # Restore the backup PowerShell profile and move it to its original location.
                        Move-Item "$PSProfile.bak" $PSProfile

                        # Let the user know that their PowerShell profile backup has been successfully restored.
                        Write-Host "===> Restored Profile Backup. <===" -ForegroundColor Yellow
                    }
                } catch {
                    # Let the user know that an error was encountered when restoring the profile backup.
                    Write-Host "Failed to restore profile backup. Error: $_" -ForegroundColor Red
                }

                # Silently cleanup the oldprofile.ps1 file that was created when the CTT PowerShell profile was installed.
                Remove-Item "$env:USERPROFILE\oldprofile.ps1" | Out-Null
            } else {
                # Let the user know that the CTT PowerShell profile is not installed and that the uninstallation was skipped.
                Write-Host "===> Chris Titus Tech's PowerShell Profile Not Found. Skipped Uninstallation. <===" -ForegroundColor Magenta
            }
        } else {
            # Let the user know that no PowerShell profile was found and that the uninstallation was skipped.
            Write-Host "===> No PowerShell Profile Found. Skipped Uninstallation. <===" -ForegroundColor Magenta
        }
    }
}

function Remove-WinUtilAPPX {
    <#

    .SYNOPSIS
        Removes all APPX packages that match the given name

    .PARAMETER Name
        The name of the APPX package to remove

    .EXAMPLE
        Remove-WinUtilAPPX -Name "Microsoft.Microsoft3DViewer"

    #>
    param (
        $Name
    )

    try {
        Write-Host "Removing $Name"
        Get-AppxPackage "*$Name*" | Remove-AppxPackage -ErrorAction SilentlyContinue
        Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like "*$Name*" | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
    } catch [System.Exception] {
        if ($psitem.Exception.Message -like "*The requested operation requires elevation*") {
            Write-Warning "Unable to uninstall $name due to a Security Exception"
        } else {
            Write-Warning "Unable to uninstall $name due to unhandled exception"
            Write-Warning $psitem.Exception.StackTrace
        }
    } catch {
        Write-Warning "Unable to uninstall $name due to unhandled exception"
        Write-Warning $psitem.Exception.StackTrace
    }
}
function Set-CategoryVisibility {
    <#
        .SYNOPSIS
            Used to expand or collapse categories and corresponding apps on the install tab

        .PARAMETER Category
            Can eigther be a specific category name like "Browsers" OR "*" to affect all categories at once

        .PARAMETER overrideState
            "Expand" => expands the corresponding elements
            "Collapse" => collapses the corresponding elements
            N/A => if compactView is active expand, otherwise collapse elements
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Category,
        [ValidateSet("Expand", "Collapse")]
        [string]$overrideState
    )

    switch ($overrideState) {
        "Expand"    {$state = $true}
        "Collapse"  {$state = $false}
        default     {$state = $sync.CompactView}
    }

    # If all the Categories are affected, update the Checked state of the ToggleButtons.
    # Otherwise, the state is not synced when toggling between the display modes
    if  ($category -eq "*") {
        $items = $sync.ItemsControl.Items | Where-Object {($_.Tag -like "CategoryWrapPanel_*")}
        $sync.ItemsControl.Items | Where-Object {($_.Tag -eq "CategoryToggleButton")} | Foreach-Object { $_.Visibility = [Windows.Visibility]::Visible; $_.IsChecked = $state }

    } else {
        $items = $sync.ItemsControl.Items | Where-Object {($_.Tag -eq "CategoryWrapPanel_$Category")}
    }

    $elementVisibility = if ($state -eq $true) {[Windows.Visibility]::Visible} else {[Windows.Visibility]::Collapsed}
    $items | ForEach-Object {
        $_.Visibility = $elementVisibility
        }
    $items.Children | ForEach-Object {
        $_.Visibility = $elementVisibility
    }
}
function Set-WinUtilDNS {
    <#

    .SYNOPSIS
        Sets the DNS of all interfaces that are in the "Up" state. It will lookup the values from the DNS.Json file

    .PARAMETER DNSProvider
        The DNS provider to set the DNS server to

    .EXAMPLE
        Set-WinUtilDNS -DNSProvider "google"

    #>
    param($DNSProvider)
    if($DNSProvider -eq "Default") {return}
    try {
        $Adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
        Write-Host "Ensuring DNS is set to $DNSProvider on the following interfaces"
        Write-Host $($Adapters | Out-String)

        Foreach ($Adapter in $Adapters) {
            if($DNSProvider -eq "DHCP") {
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ResetServerAddresses
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses ("$($sync.configs.dns.$DNSProvider.Primary)", "$($sync.configs.dns.$DNSProvider.Secondary)")
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses ("$($sync.configs.dns.$DNSProvider.Primary6)", "$($sync.configs.dns.$DNSProvider.Secondary6)")
            }
        }
    } catch {
        Write-Warning "Unable to set DNS Provider due to an unhandled exception"
        Write-Warning $psitem.Exception.StackTrace
    }
}
function Set-WinUtilProgressbar{
    <#
    .SYNOPSIS
        This function is used to Update the Progress Bar displayed in the winutil GUI.
        It will be automatically hidden if the user clicks something and no process is running
    .PARAMETER Label
        The Text to be overlayed onto the Progress Bar
    .PARAMETER PERCENT
        The percentage of the Progress Bar that should be filled (0-100)
    .PARAMETER Hide
        If provided, the Progress Bar and the label will be hidden
    #>
    param(
        [string]$Label,
        [ValidateRange(0,100)]
        [int]$Percent,
        $Hide
    )
    if ($hide) {
        $sync.form.Dispatcher.Invoke([action]{$sync.ProgressBarLabel.Visibility = "Collapsed"})
        $sync.form.Dispatcher.Invoke([action]{$sync.ProgressBar.Visibility = "Collapsed"})
    } else {
        $sync.form.Dispatcher.Invoke([action]{$sync.ProgressBarLabel.Visibility = "Visible"})
        $sync.form.Dispatcher.Invoke([action]{$sync.ProgressBar.Visibility = "Visible"})
    }
    $sync.form.Dispatcher.Invoke([action]{$sync.ProgressBarLabel.Content.Text = $label})
    $sync.form.Dispatcher.Invoke([action]{$sync.ProgressBarLabel.Content.ToolTip = $label})
    $sync.form.Dispatcher.Invoke([action]{ $sync.ProgressBar.Value = $percent})

}
function Set-WinUtilRegistry {
    <#

    .SYNOPSIS
        Modifies the registry based on the given inputs

    .PARAMETER Name
        The name of the key to modify

    .PARAMETER Path
        The path to the key

    .PARAMETER Type
        The type of value to set the key to

    .PARAMETER Value
        The value to set the key to

    .EXAMPLE
        Set-WinUtilRegistry -Name "PublishUserActivities" -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Type "DWord" -Value "0"

    #>
    param (
        $Name,
        $Path,
        $Type,
        $Value
    )

    try {
        if(!(Test-Path 'HKU:\')) {New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS}

        If (!(Test-Path $Path)) {
            Write-Host "$Path was not found, Creating..."
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }

        if ($Value -ne "<RemoveEntry>") {
            Write-Host "Set $Path\$Name to $Value"
            Set-ItemProperty -Path $Path -Name $Name -Type $Type -Value $Value -Force -ErrorAction Stop | Out-Null
        }
        else{
            Write-Host "Remove $Path\$Name"
            Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction Stop | Out-Null
        }
    } catch [System.Security.SecurityException] {
        Write-Warning "Unable to set $Path\$Name to $Value due to a Security Exception"
    } catch [System.Management.Automation.ItemNotFoundException] {
        Write-Warning $psitem.Exception.ErrorRecord
    } catch [System.UnauthorizedAccessException] {
       Write-Warning $psitem.Exception.Message
    } catch {
        Write-Warning "Unable to set $Name due to unhandled exception"
        Write-Warning $psitem.Exception.StackTrace
    }
}
function Set-WinUtilScheduledTask {
    <#

    .SYNOPSIS
        Enables/Disables the provided Scheduled Task

    .PARAMETER Name
        The path to the Scheduled Task

    .PARAMETER State
        The State to set the Task to

    .EXAMPLE
        Set-WinUtilScheduledTask -Name "Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -State "Disabled"

    #>
    param (
        $Name,
        $State
    )

    try {
        if($State -eq "Disabled") {
            Write-Host "Disabling Scheduled Task $Name"
            Disable-ScheduledTask -TaskName $Name -ErrorAction Stop
        }
        if($State -eq "Enabled") {
            Write-Host "Enabling Scheduled Task $Name"
            Enable-ScheduledTask -TaskName $Name -ErrorAction Stop
        }
    } catch [System.Exception] {
        if($psitem.Exception.Message -like "*The system cannot find the file specified*") {
            Write-Warning "Scheduled Task $name was not Found"
        } else {
            Write-Warning "Unable to set $Name due to unhandled exception"
            Write-Warning $psitem.Exception.Message
        }
    } catch {
        Write-Warning "Unable to run script for $name due to unhandled exception"
        Write-Warning $psitem.Exception.StackTrace
    }
}
Function Set-WinUtilService {
    <#

    .SYNOPSIS
        Changes the startup type of the given service

    .PARAMETER Name
        The name of the service to modify

    .PARAMETER StartupType
        The startup type to set the service to

    .EXAMPLE
        Set-WinUtilService -Name "HomeGroupListener" -StartupType "Manual"

    #>
    param (
        $Name,
        $StartupType
    )
    try {
        Write-Host "Setting Service $Name to $StartupType"

        # Check if the service exists
        $service = Get-Service -Name $Name -ErrorAction Stop

        # Service exists, proceed with changing properties
        $service | Set-Service -StartupType $StartupType -ErrorAction Stop
    } catch [System.ServiceProcess.ServiceNotFoundException] {
        Write-Warning "Service $Name was not found"
    } catch {
        Write-Warning "Unable to set $Name due to unhandled exception"
        Write-Warning $_.Exception.Message
    }

}
function Set-WinUtilTaskbaritem {
    <#

    .SYNOPSIS
        Modifies the Taskbaritem of the WPF Form

    .PARAMETER value
        Value can be between 0 and 1, 0 being no progress done yet and 1 being fully completed
        Value does not affect item without setting the state to 'Normal', 'Error' or 'Paused'
        Set-WinUtilTaskbaritem -value 0.5

    .PARAMETER state
        State can be 'None' > No progress, 'Indeterminate' > inf. loading gray, 'Normal' > Gray, 'Error' > Red, 'Paused' > Yellow
        no value needed:
        - Set-WinUtilTaskbaritem -state "None"
        - Set-WinUtilTaskbaritem -state "Indeterminate"
        value needed:
        - Set-WinUtilTaskbaritem -state "Error"
        - Set-WinUtilTaskbaritem -state "Normal"
        - Set-WinUtilTaskbaritem -state "Paused"

    .PARAMETER overlay
        Overlay icon to display on the taskbar item, there are the presets 'None', 'logo' and 'checkmark' or you can specify a path/link to an image file.
        CTT logo preset:
        - Set-WinUtilTaskbaritem -overlay "logo"
        Checkmark preset:
        - Set-WinUtilTaskbaritem -overlay "checkmark"
        Warning preset:
        - Set-WinUtilTaskbaritem -overlay "warning"
        No overlay:
        - Set-WinUtilTaskbaritem -overlay "None"
        Custom icon (needs to be supported by WPF):
        - Set-WinUtilTaskbaritem -overlay "C:\path\to\icon.png"

    .PARAMETER description
        Description to display on the taskbar item preview
        Set-WinUtilTaskbaritem -description "This is a description"
    #>
    param (
        [string]$state,
        [double]$value,
        [string]$overlay,
        [string]$description
    )

    if ($value) {
        $sync["Form"].taskbarItemInfo.ProgressValue = $value
    }

    if ($state) {
        switch ($state) {
            'None' { $sync["Form"].taskbarItemInfo.ProgressState = "None" }
            'Indeterminate' { $sync["Form"].taskbarItemInfo.ProgressState = "Indeterminate" }
            'Normal' { $sync["Form"].taskbarItemInfo.ProgressState = "Normal" }
            'Error' { $sync["Form"].taskbarItemInfo.ProgressState = "Error" }
            'Paused' { $sync["Form"].taskbarItemInfo.ProgressState = "Paused" }
            default { throw "[Set-WinUtilTaskbarItem] Invalid state" }
        }
    }

    if ($overlay) {
        switch ($overlay) {
            'logo' {
                $sync["Form"].taskbarItemInfo.Overlay = $sync["logorender"]
            }
            'checkmark' {
                $sync["Form"].taskbarItemInfo.Overlay = $sync["checkmarkrender"]
            }
            'warning' {
                $sync["Form"].taskbarItemInfo.Overlay = $sync["warningrender"]
            }
            'None' {
                $sync["Form"].taskbarItemInfo.Overlay = $null
            }
            default {
                if (Test-Path $overlay) {
                    $sync["Form"].taskbarItemInfo.Overlay = $overlay
                }
            }
        }
    }

    if ($description) {
        $sync["Form"].taskbarItemInfo.Description = $description
    }
}
function Show-CustomDialog {
    <#
    .SYNOPSIS
    Displays a custom dialog box with an image, heading, message, and an OK button.

    .DESCRIPTION
    This function creates a custom dialog box with the specified message and additional elements such as an image, heading, and an OK button. The dialog box is designed with a green border, rounded corners, and a black background.

    .PARAMETER Title
    The Title to use for the dialog window's Title Bar, this will not be visible by the user, as window styling is set to None.

    .PARAMETER Message
    The message to be displayed in the dialog box.

    .PARAMETER Width
    The width of the custom dialog window.

    .PARAMETER Height
    The height of the custom dialog window.

    .PARAMETER FontSize
    The Font Size of message shown inside custom dialog window.

    .PARAMETER HeaderFontSize
    The Font Size for the Header of custom dialog window.

    .PARAMETER LogoSize
    The Size of the Logo used inside the custom dialog window.

    .PARAMETER ForegroundColor
    The Foreground Color of dialog window title & message.

    .PARAMETER BackgroundColor
    The Background Color of dialog window.

    .PARAMETER BorderColor
    The Color for dialog window border.

    .PARAMETER ButtonBackgroundColor
    The Background Color for Buttons in dialog window.

    .PARAMETER ButtonForegroundColor
    The Foreground Color for Buttons in dialog window.

    .PARAMETER ShadowColor
    The Color used when creating the Drop-down Shadow effect for dialog window.

    .PARAMETER LogoColor
    The Color of WinUtil Text found next to WinUtil's Logo inside dialog window.

    .PARAMETER LinkForegroundColor
    The Foreground Color for Links inside dialog window.

    .PARAMETER LinkHoverForegroundColor
    The Foreground Color for Links when the mouse pointer hovers over them inside dialog window.

    .PARAMETER EnableScroll
    A flag indicating whether to enable scrolling if the content exceeds the window size.

    .EXAMPLE
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels.
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    .EXAMPLE
    $foregroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $backgroundColor = New-Object System.Windows.Media.SolidColorBrush("#1e1e1e")
    $linkForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $linkHoverForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#005289")
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200 -ForegroundColor $foregroundColor -BackgroundColor $backgroundColor -LinkForegroundColor $linkForegroundColor -LinkHoverForegroundColor $linkHoverForegroundColor

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels, with a link foreground (and general foreground) colors of '#0088e5', background color of '#1e1e1e', and Link Color on Hover of '005289', all of which are in Hexadecimal (the '#' Symbol is required by SolidColorBrush Constructor).
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    #>
    param(
        [string]$Title,
        [string]$Message,
        [int]$Width = $sync.Form.Resources.CustomDialogWidth,
        [int]$Height = $sync.Form.Resources.CustomDialogHeight,

        [System.Windows.Media.FontFamily]$FontFamily = $sync.Form.Resources.FontFamily,
        [int]$FontSize = $sync.Form.Resources.CustomDialogFontSize,
        [int]$HeaderFontSize = $sync.Form.Resources.CustomDialogFontSizeHeader,
        [int]$LogoSize = $sync.Form.Resources.CustomDialogLogoSize,

        [System.Windows.Media.Color]$ShadowColor = "#AAAAAAAA",
        [System.Windows.Media.SolidColorBrush]$LogoColor = $sync.Form.Resources.LabelboxForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BorderColor = $sync.Form.Resources.BorderColor,
        [System.Windows.Media.SolidColorBrush]$ForegroundColor = $sync.Form.Resources.MainForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BackgroundColor = $sync.Form.Resources.MainBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonForegroundColor = $sync.Form.Resources.ButtonInstallForegroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonBackgroundColor = $sync.Form.Resources.ButtonInstallBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkForegroundColor = $sync.Form.Resources.LinkForegroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkHoverForegroundColor = $sync.Form.Resources.LinkHoverForegroundColor,

        [bool]$EnableScroll = $false
    )

    # Create a custom dialog window
    $dialog = New-Object Windows.Window
    $dialog.Title = $Title
    $dialog.Height = $Height
    $dialog.Width = $Width
    $dialog.Margin = New-Object Windows.Thickness(10)  # Add margin to the entire dialog box
    $dialog.WindowStyle = [Windows.WindowStyle]::None  # Remove title bar and window controls
    $dialog.ResizeMode = [Windows.ResizeMode]::NoResize  # Disable resizing
    $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterScreen  # Center the window
    $dialog.Foreground = $ForegroundColor
    $dialog.Background = $BackgroundColor
    $dialog.FontFamily = $FontFamily
    $dialog.FontSize = $FontSize

    # Create a Border for the green edge with rounded corners
    $border = New-Object Windows.Controls.Border
    $border.BorderBrush = $BorderColor
    $border.BorderThickness = New-Object Windows.Thickness(1)  # Adjust border thickness as needed
    $border.CornerRadius = New-Object Windows.CornerRadius(10)  # Adjust the radius for rounded corners

    # Create a drop shadow effect
    $dropShadow = New-Object Windows.Media.Effects.DropShadowEffect
    $dropShadow.Color = $shadowColor
    $dropShadow.Direction = 270
    $dropShadow.ShadowDepth = 5
    $dropShadow.BlurRadius = 10

    # Apply drop shadow effect to the border
    $dialog.Effect = $dropShadow

    $dialog.Content = $border

    # Create a grid for layout inside the Border
    $grid = New-Object Windows.Controls.Grid
    $border.Child = $grid

    # Uncomment the following line to show gridlines
    #$grid.ShowGridLines = $true

    # Add the following line to set the background color of the grid
    $grid.Background = [Windows.Media.Brushes]::Transparent
    # Add the following line to make the Grid stretch
    $grid.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $grid.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Add the following line to make the Border stretch
    $border.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $border.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Set up Row Definitions
    $row0 = New-Object Windows.Controls.RowDefinition
    $row0.Height = [Windows.GridLength]::Auto

    $row1 = New-Object Windows.Controls.RowDefinition
    $row1.Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)

    $row2 = New-Object Windows.Controls.RowDefinition
    $row2.Height = [Windows.GridLength]::Auto

    # Add Row Definitions to Grid
    $grid.RowDefinitions.Add($row0)
    $grid.RowDefinitions.Add($row1)
    $grid.RowDefinitions.Add($row2)

    # Add StackPanel for horizontal layout with margins
    $stackPanel = New-Object Windows.Controls.StackPanel
    $stackPanel.Margin = New-Object Windows.Thickness(10)  # Add margins around the stack panel
    $stackPanel.Orientation = [Windows.Controls.Orientation]::Horizontal
    $stackPanel.HorizontalAlignment = [Windows.HorizontalAlignment]::Left  # Align to the left
    $stackPanel.VerticalAlignment = [Windows.VerticalAlignment]::Top  # Align to the top

    $grid.Children.Add($stackPanel)
    [Windows.Controls.Grid]::SetRow($stackPanel, 0)  # Set the row to the second row (0-based index)

    # Add SVG path to the stack panel
    $stackPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size $LogoSize))

    # Add "Winutil" text
    $winutilTextBlock = New-Object Windows.Controls.TextBlock
    $winutilTextBlock.Text = "EvolveOS"
    $winutilTextBlock.FontSize = $HeaderFontSize
    $winutilTextBlock.Foreground = $LogoColor
    $winutilTextBlock.Margin = New-Object Windows.Thickness(10, 10, 10, 5)  # Add margins around the text block
    $stackPanel.Children.Add($winutilTextBlock)
    # Add TextBlock for information with text wrapping and margins
    $messageTextBlock = New-Object Windows.Controls.TextBlock
    $messageTextBlock.FontSize = $FontSize
    $messageTextBlock.TextWrapping = [Windows.TextWrapping]::Wrap  # Enable text wrapping
    $messageTextBlock.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
    $messageTextBlock.VerticalAlignment = [Windows.VerticalAlignment]::Top
    $messageTextBlock.Margin = New-Object Windows.Thickness(10)  # Add margins around the text block

    # Define the Regex to find hyperlinks formatted as HTML <a> tags
    $regex = [regex]::new('<a href="([^"]+)">([^<]+)</a>')
    $lastPos = 0

    # Iterate through each match and add regular text and hyperlinks
    foreach ($match in $regex.Matches($Message)) {
        # Add the text before the hyperlink, if any
        $textBefore = $Message.Substring($lastPos, $match.Index - $lastPos)
        if ($textBefore.Length -gt 0) {
            $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textBefore)))
        }

        # Create and add the hyperlink
        $hyperlink = New-Object Windows.Documents.Hyperlink
        $hyperlink.NavigateUri = New-Object System.Uri($match.Groups[1].Value)
        $hyperlink.Inlines.Add($match.Groups[2].Value)
        $hyperlink.TextDecorations = [Windows.TextDecorations]::None  # Remove underline
        $hyperlink.Foreground = $LinkForegroundColor

        $hyperlink.Add_Click({
            param($sender, $args)
            Start-Process $sender.NavigateUri.AbsoluteUri
        })
        $hyperlink.Add_MouseEnter({
            param($sender, $args)
            $sender.Foreground = $LinkHoverForegroundColor
            $sender.FontSize = ($FontSize + ($FontSize / 4))
            $sender.FontWeight = "SemiBold"
        })
        $hyperlink.Add_MouseLeave({
            param($sender, $args)
            $sender.Foreground = $LinkForegroundColor
            $sender.FontSize = $FontSize
            $sender.FontWeight = "Normal"
        })

        $messageTextBlock.Inlines.Add($hyperlink)

        # Update the last position
        $lastPos = $match.Index + $match.Length
    }

    # Add any remaining text after the last hyperlink
    if ($lastPos -lt $Message.Length) {
        $textAfter = $Message.Substring($lastPos)
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textAfter)))
    }

    # If no matches, add the entire message as a run
    if ($regex.Matches($Message).Count -eq 0) {
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($Message)))
    }

    # Create a ScrollViewer if EnableScroll is true
    if ($EnableScroll) {
        $scrollViewer = New-Object System.Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalScrollBarVisibility = 'Disabled'
        $scrollViewer.Content = $messageTextBlock
        $grid.Children.Add($scrollViewer)
        [Windows.Controls.Grid]::SetRow($scrollViewer, 1)  # Set the row to the second row (0-based index)
    } else {
        $grid.Children.Add($messageTextBlock)
        [Windows.Controls.Grid]::SetRow($messageTextBlock, 1)  # Set the row to the second row (0-based index)
    }

    # Add OK button
    $okButton = New-Object Windows.Controls.Button
    $okButton.Content = "OK"
    $okButton.FontSize = $FontSize
    $okButton.Width = 80
    $okButton.Height = 30
    $okButton.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $okButton.VerticalAlignment = [Windows.VerticalAlignment]::Bottom
    $okButton.Margin = New-Object Windows.Thickness(0, 0, 0, 10)
    $okButton.Background = $buttonBackgroundColor
    $okButton.Foreground = $buttonForegroundColor
    $okButton.BorderBrush = $BorderColor
    $okButton.Add_Click({
        $dialog.Close()
    })
    $grid.Children.Add($okButton)
    [Windows.Controls.Grid]::SetRow($okButton, 2)  # Set the row to the third row (0-based index)

    # Handle Escape key press to close the dialog
    $dialog.Add_KeyDown({
        if ($_.Key -eq 'Escape') {
            $dialog.Close()
        }
    })

    # Set the OK button as the default button (activated on Enter)
    $okButton.IsDefault = $true

    # Show the custom dialog
    $dialog.ShowDialog()
}
function Show-OnlyCheckedApps {
    <#
        .SYNOPSIS
            Toggle between showing only the actively selected apps on the Install Tab and hiding everything else and displaying every app.
            If no apps are selected, dont do anything
        .PARAMETER appKeys
            Expects a List of appKeys that are selected at the moment
            If not provided, or empty, the function exits without any visual change to the ui
        .EXAMPLE
            Show-OnlyCheckedApps -appKeys $sync.SelectedApps
            Show-OnlyCheckedApps -appKeys ("WPFInstallChrome", "WPFInstall7zip")
    #>
    param (
        [Parameter(Mandatory=$false)]
        [String[]]$appKeys
    )
    # If no apps are selected, do not allow switching to show only selected
    if (($false -eq $sync.ShowOnlySelected) -and ($appKeys.Length -eq 0)) {
        Write-Host "No apps selected"
        $sync.wpfselectedfilter.IsChecked = $false
        return
    }
    $sync.ShowOnlySelected = -not $sync.ShowOnlySelected
    if ($sync.ShowOnlySelected) {
        $sync.Buttons | Where-Object {$_.Name -like "ShowSelectedAppsButton"} | ForEach-Object {
            $_.Content = "Show All"
        }

        $sync.ItemsControl.Items | Foreach-Object {
            # Search for App Container and set them to visible
            if ($_.Tag -like "CategoryWrapPanel_*") {
                $_.Visibility = [Windows.Visibility]::Visible
                # Iterate through all the apps in the container and set them to visible if they are in the appKeys array
                $_.Children | ForEach-Object {
                    if ($appKeys -contains $_.Tag) {
                        $_.Visibility = [Windows.Visibility]::Visible
                    }
                    else {
                        $_.Visibility = [Windows.Visibility]::Collapsed
                    }
                }
            }
            else {
                # Set all other items to collapsed
                $_.Visibility = [Windows.Visibility]::Collapsed
            }
        }
    } else {
        $sync.Buttons | Where-Object {$_.Name -like "ShowSelectedAppsButton"} | ForEach-Object {
            $_.Content = "Show Selected"
        }
        Set-CategoryVisibility -Category "*"
    }
}
function Test-WinUtilPackageManager {
    <#

    .SYNOPSIS
        Checks if Winget and/or Choco are installed

    .PARAMETER winget
        Check if Winget is installed

    .PARAMETER choco
        Check if Chocolatey is installed

    #>

    Param(
        [System.Management.Automation.SwitchParameter]$winget,
        [System.Management.Automation.SwitchParameter]$choco
    )

    $status = "not-installed"

    if ($winget) {
        # Check if Winget is available while getting it's Version if it's available
        $wingetExists = $true
        try {
            $wingetInfo = winget --info
            # Extract the package version from the output
            $wingetVersionFull = ($wingetInfo | Select-String -Pattern 'Microsoft\.DesktopAppInstaller v\d+\.\d+\.\d+\.\d+').Matches.Value
            if ($wingetVersionFull) {
                $wingetVersionFull = $wingetVersionFull.Split(' ')[-1].TrimStart('v')
            } else {
                # Fallback in case the pattern isn't found
                $wingetVersionFull = ($wingetInfo | Select-String -Pattern 'Package Manager v\d+\.\d+\.\d+').Matches.Value.Split(' ')[-1]
            }
        } catch [System.Management.Automation.CommandNotFoundException], [System.Management.Automation.ApplicationFailedException] {
            Write-Warning "Winget was not found due to un-availablity reasons"
            $wingetExists = $false
        } catch {
            Write-Warning "Winget was not found due to un-known reasons, The Stack Trace is:`n$($psitem.Exception.StackTrace)"
            $wingetExists = $false
        }

        # If Winget is available, Parse it's Version and give proper information to Terminal Output.
    # If it isn't available, the return of this funtion will be "not-installed", indicating that
        # Winget isn't installed/available on The System.
    if ($wingetExists) {
            # Check if Preview Version
            if ($wingetVersionFull.Contains("-preview")) {
                $wingetVersion = $wingetVersionFull.Trim("-preview")
                $wingetPreview = $true
            } else {
                $wingetVersion = $wingetVersionFull
                $wingetPreview = $false
            }

            # Check if Winget's Version is too old.
            $wingetCurrentVersion = [System.Version]::Parse($wingetVersion.Trim('v'))
            # Grabs the latest release of Winget from the Github API for version check process.
            $response = winget search -e Microsoft.AppInstaller --accept-source-agreements
            $wingetLatestVersion = ($response | Select-String -Pattern '\d+\.\d+\.\d+\.\d+').Matches.Value
            Write-Host "Latest Search Version: $wingetLatestVersion" -ForegroundColor White
            Write-Host "Current Installed Version: $wingetCurrentVersion" -ForegroundColor White
            $wingetOutdated = $wingetCurrentVersion -lt [System.Version]::Parse($wingetLatestVersion)
            Write-Host "===========================================" -ForegroundColor Green
            Write-Host "---        Winget is installed          ---" -ForegroundColor Green
            Write-Host "===========================================" -ForegroundColor Green

            if (!$wingetPreview) {
                Write-Host "    - Winget is a release version." -ForegroundColor Green
            } else {
                Write-Host "    - Winget is a preview version. Unexpected problems may occur." -ForegroundColor Yellow
            }

            if (!$wingetOutdated) {
                Write-Host "    - Winget is Up to Date" -ForegroundColor Green
                $status = "installed"
            } else {
                Write-Host "    - Winget is Out of Date" -ForegroundColor Red
                $status = "outdated"
            }
        } else {
            Write-Host "===========================================" -ForegroundColor Red
            Write-Host "---      Winget is not installed        ---" -ForegroundColor Red
            Write-Host "===========================================" -ForegroundColor Red
            $status = "not-installed"
        }
    }

    if ($choco) {
        if ((Get-Command -Name choco -ErrorAction Ignore) -and ($chocoVersion = (Get-Item "$env:ChocolateyInstall\choco.exe" -ErrorAction Ignore).VersionInfo.ProductVersion)) {
            Write-Host "===========================================" -ForegroundColor Green
            Write-Host "---      Chocolatey is installed        ---" -ForegroundColor Green
            Write-Host "===========================================" -ForegroundColor Green
            Write-Host "Version: v$chocoVersion" -ForegroundColor White
            $status = "installed"
        } else {
            Write-Host "===========================================" -ForegroundColor Red
            Write-Host "---    Chocolatey is not installed      ---" -ForegroundColor Red
            Write-Host "===========================================" -ForegroundColor Red
            $status = "not-installed"
        }
    }

    return $status
}
Function Uninstall-WinUtilEdgeBrowser {
    <#
    .SYNOPSIS
        Uninstall the Edge Browser (Chromium) from the system in an elegant way.
    .DESCRIPTION
        This will switch up the region to one of the EEA countries temporarily and uninstall the Edge Browser (Chromium).
    #>

    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet("install", "uninstall")]
        [string]$action
    )

    function Uninstall-EdgeClient {
        param (
            [Parameter(Mandatory = $true)]
            [string]$Key
        )

        $originalNation = [microsoft.win32.registry]::GetValue('HKEY_USERS\.DEFAULT\Control Panel\International\Geo', 'Nation', [Microsoft.Win32.RegistryValueKind]::String)

        # Set Nation to any of the EEA regions temporarily
        # Refer: https://learn.microsoft.com/en-us/windows/win32/intl/table-of-geographical-locations
        $tmpNation = 68 # Ireland
        [microsoft.win32.registry]::SetValue('HKEY_USERS\.DEFAULT\Control Panel\International\Geo', 'Nation', $tmpNation, [Microsoft.Win32.RegistryValueKind]::String) | Out-Null

        $baseKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate'
        $registryPath = $baseKey + '\ClientState\' + $Key

        if (!(Test-Path -Path $registryPath)) {
            Write-Host "[$Mode] Registry key not found: $registryPath"
            return
        }

        # Remove the status flag
        Remove-ItemProperty -Path $baseKey -Name "IsEdgeStableUninstalled" -ErrorAction SilentlyContinue | Out-Null

        Remove-ItemProperty -Path $registryPath -Name "experiment_control_labels" -ErrorAction SilentlyContinue | Out-Null

        $uninstallString = (Get-ItemProperty -Path $registryPath).UninstallString
        $uninstallArguments = (Get-ItemProperty -Path $registryPath).UninstallArguments

        if ([string]::IsNullOrEmpty($uninstallString) -or [string]::IsNullOrEmpty($uninstallArguments)) {
            Write-Host "[$Mode] Cannot find uninstall methods for $Mode"
            return
        }

        # Extra arguments to nuke it
        $uninstallArguments += " --force-uninstall --delete-profile"

        # $uninstallCommand = "`"$uninstallString`"" + $uninstallArguments
        if (!(Test-Path -Path $uninstallString)) {
            Write-Host "[$Mode] setup.exe not found at: $uninstallString"
            return
        }
        Start-Process -FilePath $uninstallString -ArgumentList $uninstallArguments -Wait -NoNewWindow -Verbose

        # Restore Nation back to the original
        [microsoft.win32.registry]::SetValue('HKEY_USERS\.DEFAULT\Control Panel\International\Geo', 'Nation', $originalNation, [Microsoft.Win32.RegistryValueKind]::String) | Out-Null

        # might not exist in some cases
        if ((Get-ItemProperty -Path $baseKey).IsEdgeStableUninstalled -eq 1) {
            Write-Host "[$Mode] Edge Stable has been successfully uninstalled"
        }
    }

    function Uninstall-Edge {
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" -Name "NoRemove" -ErrorAction SilentlyContinue | Out-Null

        [microsoft.win32.registry]::SetValue("HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdateDev", "AllowUninstall", 1, [Microsoft.Win32.RegistryValueKind]::DWord) | Out-Null

        Uninstall-EdgeClient -Key '{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'

        Remove-Item -Path "Computer\\HKEY_CLASSES_ROOT\\MSEdgePDF" -ErrorAction SilentlyContinue | Out-Null
        Remove-Item -Path "Computer\\HKEY_CLASSES_ROOT\\MSEdgeHTM" -ErrorAction SilentlyContinue | Out-Null
        Remove-Item -Path "Computer\\HKEY_CLASSES_ROOT\\MSEdgeMHT" -ErrorAction SilentlyContinue | Out-Null

        # Remove Edge Polocy reg keys
        Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Recurse -ErrorAction SilentlyContinue | Out-Null

        # Remove Edge reg keys
        Remove-Item -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Edge" -Recurse -ErrorAction SilentlyContinue | Out-Null
    }

    function Uninstall-WebView {
        # FIXME: might not work on some systems

        Remove-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft EdgeWebView" -Name "NoRemove" -ErrorAction SilentlyContinue | Out-Null

        Uninstall-EdgeClient -Key '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    }

    function Uninstall-EdgeUpdate {
        # FIXME: might not work on some systems

        Remove-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update" -Name "NoRemove" -ErrorAction SilentlyContinue | Out-Null

        $registryPath = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate'
        if (!(Test-Path -Path $registryPath)) {
            Write-Host "Registry key not found: $registryPath"
            return
        }
        $uninstallCmdLine = (Get-ItemProperty -Path $registryPath).UninstallCmdLine

        if ([string]::IsNullOrEmpty($uninstallCmdLine)) {
            Write-Host "Cannot find uninstall methods for $Mode"
            return
        }

        Start-Process cmd.exe "/c $uninstallCmdLine" -WindowStyle Hidden -Wait

        # Remove EdgeUpdate reg keys
        Remove-Item -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate" -Recurse -ErrorAction SilentlyContinue | Out-Null
    }

    function Install-Edge {
        $tempEdgePath = "$env:TEMP\MicrosoftEdgeSetup.exe"

        try {
            write-host "Installing Edge ..."
            Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/?linkid=2109047&Channel=Stable&language=en&consent=1" -OutFile $tempEdgePath
            Start-Process -FilePath $tempEdgePath -ArgumentList "/silent /install" -Wait
            Remove-item $tempEdgePath
            write-host "Edge Installed Successfully"
        } catch {
            write-host "Failed to install Edge"
        }
    }

    if ($action -eq "Install") {
        Install-Edge
    } elseif ($action -eq "Uninstall") {
        Uninstall-Edge
        Uninstall-EdgeUpdate
        # Uninstall-WebView - WebView is needed for Visual Studio and some MS Store Games like Forza
    }
}
Function Update-WinUtilProgramWinget {

    <#

    .SYNOPSIS
        This will update all programs using Winget

    #>

    [ScriptBlock]$wingetinstall = {

        $host.ui.RawUI.WindowTitle = """Winget Install"""

        Start-Transcript "$logdir\winget-update_$dateTime.log" -Append
        winget upgrade --all --accept-source-agreements --accept-package-agreements --scope=machine --silent

    }

    $global:WinGetInstall = Start-Process -Verb runas powershell -ArgumentList "-command invoke-command -scriptblock {$wingetinstall} -argumentlist '$($ProgramsToInstall -join ",")'" -PassThru

}

function Invoke-ScratchDialog {

    <#

    .SYNOPSIS
        Enable Editable Text box Alternate Scartch path

    .PARAMETER Button
    #>
    $sync.WPFMicrowinISOScratchDir.IsChecked


    [System.Reflection.Assembly]::LoadWithPartialName("System.windows.forms") | Out-Null
    $Dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $Dialog.SelectedPath =          $sync.MicrowinScratchDirBox.Text
    $Dialog.ShowDialog()
    $filePath = $Dialog.SelectedPath
        Write-Host "No ISO is chosen+  $filePath"

    if ([string]::IsNullOrEmpty($filePath)) {
        Write-Host "No Folder had chosen"
        return
    }

       $sync.MicrowinScratchDirBox.Text =  Join-Path $filePath "\"

}
function Invoke-WPFButton {

    <#

    .SYNOPSIS
        Invokes the function associated with the clicked button

    .PARAMETER Button
        The name of the button that was clicked

    #>

    Param ([string]$Button)

    # Use this to get the name of the button
    #[System.Windows.MessageBox]::Show("$Button","Chris Titus Tech's Windows Utility","OK","Info")
    if (-not $sync.ProcessRunning) {
        Set-WinUtilProgressBar  -label "" -percent 0 -hide $true
    }

    Switch -Wildcard ($Button) {
        "WPFTab?BT" {Invoke-WPFTab $Button}
        "WPFInstall" {Invoke-WPFInstall}
        "WPFUninstall" {Invoke-WPFUnInstall}
        "WPFInstallUpgrade" {Invoke-WPFInstallUpgrade}
        "WPFStandard" {Invoke-WPFPresets "Standard" -checkboxfilterpattern "WPFTweak*"}
        "WPFMinimal" {Invoke-WPFPresets "Minimal" -checkboxfilterpattern "WPFTweak*"}
        "WPFClearTweaksSelection" {Invoke-WPFPresets -imported $true -checkboxfilterpattern "WPFTweak*"}
        "WPFClearInstallSelection" {Invoke-WPFPresets -imported $true -checkboxfilterpattern "WPFInstall*"; Show-OnlyCheckedApps; $sync.wpfselectedfilter.IsChecked = $false}
        "WPFSelectedFilter" {Show-OnlyCheckedApps -appKeys $sync.SelectedApps}
        "WPFtweaksbutton" {Invoke-WPFtweaksbutton}
        "WPFOOSUbutton" {Invoke-WPFOOSU}
        "WPFAddUltPerf" {Invoke-WPFUltimatePerformance -State "Enable"}
        "WPFRemoveUltPerf" {Invoke-WPFUltimatePerformance -State "Disable"}
        "WPFundoall" {Invoke-WPFundoall}
        "WPFFeatureInstall" {Invoke-WPFFeatureInstall}
        "WPFPanelDISM" {Invoke-WPFPanelDISM}
        "WPFPanelAutologin" {Invoke-WPFPanelAutologin}
        "WPFPanelcontrol" {Invoke-WPFControlPanel -Panel $button}
        "WPFPanelnetwork" {Invoke-WPFControlPanel -Panel $button}
        "WPFPanelpower" {Invoke-WPFControlPanel -Panel $button}
        "WPFPanelregion" {Invoke-WPFControlPanel -Panel $button}
        "WPFPanelsound" {Invoke-WPFControlPanel -Panel $button}
        "WPFPanelprinter" {Invoke-WPFControlPanel -Panel $button}
        "WPFPanelsystem" {Invoke-WPFControlPanel -Panel $button}
        "WPFPaneluser" {Invoke-WPFControlPanel -Panel $button}
        "WPFUpdatesdefault" {Invoke-WPFFixesUpdate}
        "WPFFixesUpdate" {Invoke-WPFFixesUpdate}
        "WPFFixesWinget" {Invoke-WPFFixesWinget}
        "WPFRunAdobeCCCleanerTool" {Invoke-WPFRunAdobeCCCleanerTool}
        "WPFFixesNetwork" {Invoke-WPFFixesNetwork}
        "WPFUpdatesdisable" {Invoke-WPFUpdatesdisable}
        "WPFUpdatessecurity" {Invoke-WPFUpdatessecurity}
        "WPFWinUtilShortcut" {Invoke-WPFShortcut -ShortcutToAdd "WinUtil" -RunAsAdmin $true}
        "WPFGetInstalled" {Invoke-WPFGetInstalled -CheckBox "winget"}
        "WPFGetInstalledTweaks" {Invoke-WPFGetInstalled -CheckBox "tweaks"}
        "WPFGetIso" {Invoke-MicrowinGetIso}
        "WPFMicrowin" {Invoke-Microwin}
        "WPFCloseButton" {Invoke-WPFCloseButton}
        "MicrowinScratchDirBT" {Invoke-ScratchDialog}
        "WPFWinUtilInstallPSProfile" {Invoke-WinUtilInstallPSProfile}
        "WPFWinUtilUninstallPSProfile" {Invoke-WinUtilUninstallPSProfile}
        "WPFWinUtilSSHServer" {Invoke-WPFSSHServer}
    }
}
function Invoke-WPFCloseButton {

    <#

    .SYNOPSIS
        Close application

    .PARAMETER Button
    #>
    $sync["Form"].Close()
    Write-Host "Bye bye!"
}
function Invoke-WPFControlPanel {
    <#

    .SYNOPSIS
        Opens the requested legacy panel

    .PARAMETER Panel
        The panel to open

    #>
    param($Panel)

    switch ($Panel) {
        "WPFPanelcontrol" {cmd /c control}
        "WPFPanelnetwork" {cmd /c ncpa.cpl}
        "WPFPanelpower"   {cmd /c powercfg.cpl}
        "WPFPanelregion"  {cmd /c intl.cpl}
        "WPFPanelsound"   {cmd /c mmsys.cpl}
        "WPFPanelprinter" {Start-Process "shell:::{A8A91A66-3A7D-4424-8D24-04E180695C7A}"}
        "WPFPanelsystem"  {cmd /c sysdm.cpl}
        "WPFPaneluser"    {cmd /c "control userpasswords2"}
    }
}
function Invoke-WPFFeatureInstall {
    <#

    .SYNOPSIS
        Installs selected Windows Features

    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFFeatureInstall] Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $Features = (Get-WinUtilCheckBoxes)["WPFFeature"]

    Invoke-WPFRunspace -ArgumentList $Features -DebugPreference $DebugPreference -ScriptBlock {
        param($Features, $DebugPreference)
        $sync.ProcessRunning = $true
        if ($Features.count -eq 1) {
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" })
        } else {
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" })
        }

        Invoke-WinUtilFeatureInstall $Features

        $sync.ProcessRunning = $false
        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" })

        Write-Host "==================================="
        Write-Host "---   Features are Installed    ---"
        Write-Host "---  A Reboot may be required   ---"
        Write-Host "==================================="
    }
}
function Invoke-WPFFixesNetwork {
    <#

    .SYNOPSIS
        Resets various network configurations

    #>

    Write-Host "Resetting Network with netsh"

    # Reset WinSock catalog to a clean state
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winsock", "reset"
    # Resets WinHTTP proxy setting to DIRECT
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winhttp", "reset", "proxy"
    # Removes all user configured IP settings
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "int", "ip", "reset"

    Write-Host "Process complete. Please reboot your computer."

    $ButtonType = [System.Windows.MessageBoxButton]::OK
    $MessageboxTitle = "Network Reset "
    $Messageboxbody = ("Stock settings loaded.`n Please reboot your computer")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)
    Write-Host "=========================================="
    Write-Host "-- Network Configuration has been Reset --"
    Write-Host "=========================================="
}
function Invoke-WPFFixesUpdate {

    <#

    .SYNOPSIS
        Performs various tasks in an attempt to repair Windows Update

    .DESCRIPTION
        1. (Aggressive Only) Scans the system for corruption using chkdsk, SFC, and DISM
            Steps:
                1. Runs chkdsk /scan /perf
                    /scan - Runs an online scan on the volume
                    /perf - Uses more system resources to complete a scan as fast as possible
                2. Runs SFC /scannow
                    /scannow - Scans integrity of all protected system files and repairs files with problems when possible
                3. Runs DISM /Online /Cleanup-Image /RestoreHealth
                    /Online - Targets the running operating system
                    /Cleanup-Image - Performs cleanup and recovery operations on the image
                    /RestoreHealth - Scans the image for component store corruption and attempts to repair the corruption using Windows Update
                4. Runs SFC /scannow
                    Ran twice in case DISM repaired SFC
        2. Stops Windows Update Services
        3. Remove the QMGR Data file, which stores BITS jobs
        4. (Aggressive Only) Renames the DataStore and CatRoot2 folders
            DataStore - Contains the Windows Update History and Log Files
            CatRoot2 - Contains the Signatures for Windows Update Packages
        5. Renames the Windows Update Download Folder
        6. Deletes the Windows Update Log
        7. (Aggressive Only) Resets the Security Descriptors on the Windows Update Services
        8. Reregisters the BITS and Windows Update DLLs
        9. Removes the WSUS client settings
        10. Resets WinSock
        11. Gets and deletes all BITS jobs
        12. Sets the startup type of the Windows Update Services then starts them
        13. Forces Windows Update to check for updates

    .PARAMETER Aggressive
        If specified, the script will take additional steps to repair Windows Update that are more dangerous, take a significant amount of time, or are generally unnecessary

    #>

    param($Aggressive = $false)

    Write-Progress -Id 0 -Activity "Repairing Windows Update" -PercentComplete 0
    # Wait for the first progress bar to show, otherwise the second one won't show
    Start-Sleep -Milliseconds 200

    if ($Aggressive) {
        # Scan system for corruption
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Scanning for corruption..." -PercentComplete 0
        Write-Progress -Id 1 -ParentId 0 -Activity "Scanning for corruption" -Status "Running chkdsk..." -PercentComplete 0
        # 2>&1 redirects stdout, alowing iteration over the output
        chkdsk.exe /scan /perf 2>&1 | ForEach-Object {
            # Write stdout to the Verbose stream
            Write-Verbose $_

            # Get the index of the total percentage
            $index = $_.IndexOf("Total:")
            if (
                # If the percent is found
                ($percent = try {(
                    $_.Substring(
                        $index + 6,
                        $_.IndexOf("%", $index) - $index - 6
                    )
                ).Trim()} catch {0}) `
                <# And the current percentage is greater than the previous one #>`
                -and $percent -gt $oldpercent
            ) {
                # Update the progress bar
                $oldpercent = $percent
                Write-Progress -Id 1 -ParentId 0 -Activity "Scanning for corruption" -Status "Running chkdsk... ($percent%)" -PercentComplete $percent
            }
        }

        Write-Progress -Id 1 -ParentId 0 -Activity "Scanning for corruption" -Status "Running SFC..." -PercentComplete 0
        $oldpercent = 0
        # SFC has a bug when redirected which causes it to output only when the stdout buffer is full, causing the progress bar to move in chunks
        sfc /scannow 2>&1 | ForEach-Object {
            # Write stdout to the Verbose stream
            Write-Verbose $_

            # Filter for lines that contain a percentage that is greater than the previous one
            if (
                (
                    # Use a different method to get the percentage that accounts for SFC's Unicode output
                    [int]$percent = try {(
                        (
                            $_.Substring(
                                $_.IndexOf("n") + 2,
                                $_.IndexOf("%") - $_.IndexOf("n") - 2
                            ).ToCharArray() | Where-Object {$_}
                        ) -join ''
                    ).TrimStart()} catch {0}
                ) -and $percent -gt $oldpercent
            ) {
                # Update the progress bar
                $oldpercent = $percent
                Write-Progress -Id 1 -ParentId 0 -Activity "Scanning for corruption" -Status "Running SFC... ($percent%)" -PercentComplete $percent
            }
        }

        Write-Progress -Id 1 -ParentId 0 -Activity "Scanning for corruption" -Status "Running DISM..." -PercentComplete 0
        $oldpercent = 0
        DISM /Online /Cleanup-Image /RestoreHealth | ForEach-Object {
            # Write stdout to the Verbose stream
            Write-Verbose $_

            # Filter for lines that contain a percentage that is greater than the previous one
            if (
                ($percent = try {
                    [int]($_ -replace "\[" -replace "=" -replace " " -replace "%" -replace "\]")
                } catch {0}) `
                -and $percent -gt $oldpercent
            ) {
                # Update the progress bar
                $oldpercent = $percent
                Write-Progress -Id 1 -ParentId 0 -Activity "Scanning for corruption" -Status "Running DISM... ($percent%)" -PercentComplete $percent
            }
        }

        Write-Progress -Id 1 -ParentId 0 -Activity "Scanning for corruption" -Status "Running SFC again..." -PercentComplete 0
        $oldpercent = 0
        sfc /scannow 2>&1 | ForEach-Object {
            # Write stdout to the Verbose stream
            Write-Verbose $_

            # Filter for lines that contain a percentage that is greater than the previous one
            if (
                (
                    [int]$percent = try {(
                        (
                            $_.Substring(
                                $_.IndexOf("n") + 2,
                                $_.IndexOf("%") - $_.IndexOf("n") - 2
                            ).ToCharArray() | Where-Object {$_}
                        ) -join ''
                    ).TrimStart()} catch {0}
                ) -and $percent -gt $oldpercent
            ) {
                # Update the progress bar
                $oldpercent = $percent
                Write-Progress -Id 1 -ParentId 0 -Activity "Scanning for corruption" -Status "Running SFC... ($percent%)" -PercentComplete $percent
            }
        }
        Write-Progress -Id 1 -ParentId 0 -Activity "Scanning for corruption" -Status "Completed" -PercentComplete 100
    }


    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Stopping Windows Update Services..." -PercentComplete 10
    # Stop the Windows Update Services
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping BITS..." -PercentComplete 0
    Stop-Service -Name BITS -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping wuauserv..." -PercentComplete 20
    Stop-Service -Name wuauserv -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping appidsvc..." -PercentComplete 40
    Stop-Service -Name appidsvc -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping cryptsvc..." -PercentComplete 60
    Stop-Service -Name cryptsvc -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Completed" -PercentComplete 100


    # Remove the QMGR Data file
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Renaming/Removing Files..." -PercentComplete 20
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Removing QMGR Data files..." -PercentComplete 0
    Remove-Item "$env:allusersprofile\Application Data\Microsoft\Network\Downloader\qmgr*.dat" -ErrorAction SilentlyContinue


    if ($Aggressive) {
        # Rename the Windows Update Log and Signature Folders
        Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Renaming the Windows Update Log, Download, and Signature Folder..." -PercentComplete 20
        Rename-Item $env:systemroot\SoftwareDistribution\DataStore DataStore.bak -ErrorAction SilentlyContinue
        Rename-Item $env:systemroot\System32\Catroot2 catroot2.bak -ErrorAction SilentlyContinue
    }

    # Rename the Windows Update Download Folder
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Renaming the Windows Update Download Folder..." -PercentComplete 20
    Rename-Item $env:systemroot\SoftwareDistribution\Download Download.bak -ErrorAction SilentlyContinue

    # Delete the legacy Windows Update Log
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Removing the old Windows Update log..." -PercentComplete 80
    Remove-Item $env:systemroot\WindowsUpdate.log -ErrorAction SilentlyContinue
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Completed" -PercentComplete 100


    if ($Aggressive) {
        # Reset the Security Descriptors on the Windows Update Services
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Resetting the WU Service Security Descriptors..." -PercentComplete 25
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Resetting the BITS Security Descriptor..." -PercentComplete 0
        Start-Process -NoNewWindow -FilePath "sc.exe" -ArgumentList "sdset", "bits", "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" -Wait
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Resetting the wuauserv Security Descriptor..." -PercentComplete 50
        Start-Process -NoNewWindow -FilePath "sc.exe" -ArgumentList "sdset", "wuauserv", "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" -Wait
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Completed" -PercentComplete 100
    }


    # Reregister the BITS and Windows Update DLLs
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Reregistering DLLs..." -PercentComplete 40
    $oldLocation = Get-Location
    Set-Location $env:systemroot\system32
    $i = 0
    $DLLs = @(
        "atl.dll", "urlmon.dll", "mshtml.dll", "shdocvw.dll", "browseui.dll",
        "jscript.dll", "vbscript.dll", "scrrun.dll", "msxml.dll", "msxml3.dll",
        "msxml6.dll", "actxprxy.dll", "softpub.dll", "wintrust.dll", "dssenh.dll",
        "rsaenh.dll", "gpkcsp.dll", "sccbase.dll", "slbcsp.dll", "cryptdlg.dll",
        "oleaut32.dll", "ole32.dll", "shell32.dll", "initpki.dll", "wuapi.dll",
        "wuaueng.dll", "wuaueng1.dll", "wucltui.dll", "wups.dll", "wups2.dll",
        "wuweb.dll", "qmgr.dll", "qmgrprxy.dll", "wucltux.dll", "muweb.dll", "wuwebv.dll"
    )
    foreach ($dll in $DLLs) {
        Write-Progress -Id 5 -ParentId 0 -Activity "Reregistering DLLs" -Status "Registering $dll..." -PercentComplete ($i / $DLLs.Count * 100)
        $i++
        Start-Process -NoNewWindow -FilePath "regsvr32.exe" -ArgumentList "/s", $dll
    }
    Set-Location $oldLocation
    Write-Progress -Id 5 -ParentId 0 -Activity "Reregistering DLLs" -Status "Completed" -PercentComplete 100


    # Remove the WSUS client settings
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate") {
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Removing WSUS client settings..." -PercentComplete 60
        Write-Progress -Id 6 -ParentId 0 -Activity "Removing WSUS client settings" -PercentComplete 0
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "AccountDomainSid", "/f" -RedirectStandardError "NUL"
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "PingID", "/f" -RedirectStandardError "NUL"
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "SusClientId", "/f" -RedirectStandardError "NUL"
        Write-Progress -Id 6 -ParentId 0 -Activity "Removing WSUS client settings" -Status "Completed" -PercentComplete 100
    }

    # Remove Group Policy Windows Update settings
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Removing Group Policy Windows Update settings..." -PercentComplete 60
    Write-Progress -Id 7 -ParentId 0 -Activity "Removing Group Policy Windows Update settings" -PercentComplete 0
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "Defaulting driver offering through Windows Update..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "Defaulting Windows Update automatic restart..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUPowerManagement" -ErrorAction SilentlyContinue
    Write-Host "Clearing ANY Windows Update Policy settings..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "BranchReadinessLevel" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferFeatureUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferQualityUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Process -NoNewWindow -FilePath "secedit" -ArgumentList "/configure", "/cfg", "$env:windir\inf\defltbase.inf", "/db", "defltbase.sdb", "/verbose" -Wait
    Start-Process -NoNewWindow -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicyUsers" -Wait
    Start-Process -NoNewWindow -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicy" -Wait
    Start-Process -NoNewWindow -FilePath "gpupdate" -ArgumentList "/force" -Wait
    Write-Progress -Id 7 -ParentId 0 -Activity "Removing Group Policy Windows Update settings" -Status "Completed" -PercentComplete 100


    # Reset WinSock
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Resetting WinSock..." -PercentComplete 65
    Write-Progress -Id 7 -ParentId 0 -Activity "Resetting WinSock" -Status "Resetting WinSock..." -PercentComplete 0
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winsock", "reset"
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winhttp", "reset", "proxy"
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "int", "ip", "reset"
    Write-Progress -Id 7 -ParentId 0 -Activity "Resetting WinSock" -Status "Completed" -PercentComplete 100


    # Get and delete all BITS jobs
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Deleting BITS jobs..." -PercentComplete 75
    Write-Progress -Id 8 -ParentId 0 -Activity "Deleting BITS jobs" -Status "Deleting BITS jobs..." -PercentComplete 0
    Get-BitsTransfer | Remove-BitsTransfer
    Write-Progress -Id 8 -ParentId 0 -Activity "Deleting BITS jobs" -Status "Completed" -PercentComplete 100


    # Change the startup type of the Windows Update Services and start them
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Starting Windows Update Services..." -PercentComplete 90
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting BITS..." -PercentComplete 0
    Get-Service BITS | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting wuauserv..." -PercentComplete 25
    Get-Service wuauserv | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting AppIDSvc..." -PercentComplete 50
    # The AppIDSvc service is protected, so the startup type has to be changed in the registry
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\AppIDSvc" -Name "Start" -Value "3" # Manual
    Start-Service AppIDSvc
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting CryptSvc..." -PercentComplete 75
    Get-Service CryptSvc | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Completed" -PercentComplete 100


    # Force Windows Update to check for updates
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Forcing discovery..." -PercentComplete 95
    Write-Progress -Id 10 -ParentId 0 -Activity "Forcing discovery" -Status "Forcing discovery..." -PercentComplete 0
    try {
        (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()
    } catch {
        Write-Warning "Failed to create Windows Update COM object: $_"
    }
    Start-Process -NoNewWindow -FilePath "wuauclt" -ArgumentList "/resetauthorization", "/detectnow"
    Write-Progress -Id 10 -ParentId 0 -Activity "Forcing discovery" -Status "Completed" -PercentComplete 100
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Completed" -PercentComplete 100

    $ButtonType = [System.Windows.MessageBoxButton]::OK
    $MessageboxTitle = "Reset Windows Update "
    $Messageboxbody = ("Stock settings loaded.`n Please reboot your computer")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)
    Write-Host "==============================================="
    Write-Host "-- Reset All Windows Update Settings to Stock -"
    Write-Host "==============================================="

    # Remove the progress bars
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Completed
    Write-Progress -Id 1 -Activity "Scanning for corruption" -Completed
    Write-Progress -Id 2 -Activity "Stopping Services" -Completed
    Write-Progress -Id 3 -Activity "Renaming/Removing Files" -Completed
    Write-Progress -Id 4 -Activity "Resetting the WU Service Security Descriptors" -Completed
    Write-Progress -Id 5 -Activity "Reregistering DLLs" -Completed
    Write-Progress -Id 6 -Activity "Removing Group Policy Windows Update settings" -Completed
    Write-Progress -Id 7 -Activity "Resetting WinSock" -Completed
    Write-Progress -Id 8 -Activity "Deleting BITS jobs" -Completed
    Write-Progress -Id 9 -Activity "Starting Windows Update Services" -Completed
    Write-Progress -Id 10 -Activity "Forcing discovery" -Completed
}
function Invoke-WPFFixesWinget {

    <#

    .SYNOPSIS
        Fixes Winget by running choco install winget
    .DESCRIPTION
        BravoNorris for the fantastic idea of a button to reinstall winget
    #>
    # Install Choco if not already present
    Install-WinUtilChoco
    Start-Process -FilePath "choco" -ArgumentList "install winget -y --force" -NoNewWindow -Wait

}
Function Invoke-WPFFormVariables {
    <#

    .SYNOPSIS
        Prints the logo

    #>
    #If ($global:ReadmeDisplay -ne $true) { Write-Host "If you need to reference this display again, run Get-FormVariables" -ForegroundColor Yellow; $global:ReadmeDisplay = $true }


    Write-Host "========EvolveOS========="
    Write-Host "=====Windows Toolbox====="

    #====DEBUG GUI Elements====

    #Write-Host "Found the following interactable elements from our form" -ForegroundColor Cyan
    #get-variable WPF*
}
function Invoke-WPFGetInstalled {
    <#
    TODO: Add the Option to use Chocolatey as Engine
    .SYNOPSIS
        Invokes the function that gets the checkboxes to check in a new runspace

    .PARAMETER checkbox
        Indicates whether to check for installed 'winget' programs or applied 'tweaks'

    #>
    param($checkbox)
    if ($sync.ProcessRunning) {
        $msg = "[Invoke-WPFGetInstalled] Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if (($sync.ChocoRadioButton.IsChecked -eq $false) -and ((Test-WinUtilPackageManager -winget) -eq "not-installed") -and $checkbox -eq "winget") {
        return
    }
    $preferChoco = $sync.ChocoRadioButton.IsChecked
    $sync.ItemsControl.Dispatcher.Invoke([action] {
            $sync.ItemsControl.Items | ForEach-Object { $_.Visibility = [Windows.Visibility]::Collapsed }
            $null = $sync.itemsControl.Items.Add($sync.LoadingLabel)
        })
    Invoke-WPFRunspace -ParameterList @(("preferChoco", $preferChoco),("checkbox", $checkbox),("ShowOnlyCheckedApps", ${function:Show-OnlyCheckedApps})) -DebugPreference $DebugPreference -ScriptBlock {
        param (
            [string]$checkbox,
            [boolean]$preferChoco,
            [scriptblock]$ShowOnlyCheckedApps
        )
        $sync.ProcessRunning = $true
        $sync.form.Dispatcher.Invoke([action] { Set-WinUtilTaskbaritem -state "Indeterminate" })

        if ($checkbox -eq "winget") {
            Write-Host "Getting Installed Programs..."
            if ($preferChoco) { $Checkboxes = Invoke-WinUtilCurrentSystem -CheckBox "choco" }
            else { $Checkboxes = Invoke-WinUtilCurrentSystem -CheckBox $checkbox }
        }
        elseif ($checkbox -eq "tweaks") {
            Write-Host "Getting Installed Tweaks..."
            $Checkboxes = Invoke-WinUtilCurrentSystem -CheckBox $checkbox
        }

        $sync.form.Dispatcher.invoke({
            foreach ($checkbox in $Checkboxes) {
                $sync.$checkbox.ischecked = $True
            }
        })
        $sync.ItemsControl.Dispatcher.Invoke([action] {
            $ShowOnlyCheckedApps.Invoke($sync.SelectedApps)
            $sync["WPFSelectedFilter"].IsChecked = $true
            $sync.ItemsControl.Items.Remove($sync.LoadingLabel)
        })
        Write-Host "Done..."
        $sync.ProcessRunning = $false
        $sync.form.Dispatcher.Invoke([action] { Set-WinUtilTaskbaritem -state "None" })
    }
}
function Invoke-WPFImpex {
    <#

    .SYNOPSIS
        Handles importing and exporting of the checkboxes checked for the tweaks section

    .PARAMETER type
        Indicates whether to 'import' or 'export'

    .PARAMETER checkbox
        The checkbox to export to a file or apply the imported file to

    .EXAMPLE
        Invoke-WPFImpex -type "export"

    #>
    param(
        $type,
        $Config = $null
    )

    function ConfigDialog {
        if (!$Config) {
            switch ($type) {
                "export" { $FileBrowser = New-Object System.Windows.Forms.SaveFileDialog }
                "import" { $FileBrowser = New-Object System.Windows.Forms.OpenFileDialog }
            }
            $FileBrowser.InitialDirectory = [Environment]::GetFolderPath('Desktop')
            $FileBrowser.Filter = "JSON Files (*.json)|*.json"
            $FileBrowser.ShowDialog() | Out-Null

            if ($FileBrowser.FileName -eq "") {
                return $null
            } else {
                return $FileBrowser.FileName
            }
        } else {
            return $Config
        }
    }

    switch ($type) {
        "export" {
            try {
                $Config = ConfigDialog
                if ($Config) {
                    $jsonFile = Get-WinUtilCheckBoxes -unCheck $false | ConvertTo-Json
                    $jsonFile | Out-File $Config -Force
                    "iex ""& { `$(irm https://christitus.com/win) } -Config '$Config'""" | Set-Clipboard
                }
            } catch {
                Write-Error "An error occurred while exporting: $_"
            }
        }
        "import" {
            try {
                $Config = ConfigDialog
                if ($Config) {
                    try {
                        if ($Config -match '^https?://') {
                            $jsonFile = (Invoke-WebRequest "$Config").Content | ConvertFrom-Json
                        } else {
                            $jsonFile = Get-Content $Config | ConvertFrom-Json
                        }
                    } catch {
                        Write-Error "Failed to load the JSON file from the specified path or URL: $_"
                        return
                    }
                    $flattenedJson = $jsonFile.PSObject.Properties.Where({ $_.Name -ne "Install" }).ForEach({ $_.Value })
                    Invoke-WPFPresets -preset $flattenedJson -imported $true
                }
            } catch {
                Write-Error "An error occurred while importing: $_"
            }
        }
    }
}
function Invoke-WPFInstall {
    param (
        [Parameter(Mandatory=$false)]
        [PSObject[]]$PackagesToInstall = $($sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ })
    )
    <#

    .SYNOPSIS
        Installs the selected programs using winget, if one or more of the selected programs are already installed on the system, winget will try and perform an upgrade if there's a newer version to install.

    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFInstall] An Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if ($PackagesToInstall.Count -eq 0) {
        $WarningMsg = "Please select the program(s) to install or upgrade"
        [System.Windows.MessageBox]::Show($WarningMsg, $AppTitle, [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }
    $ChocoPreference = $($sync.ChocoRadioButton.IsChecked)
    $installHandle = Invoke-WPFRunspace -ParameterList @(("PackagesToInstall", $PackagesToInstall),("ChocoPreference", $ChocoPreference)) -DebugPreference $DebugPreference -ScriptBlock {
        param($PackagesToInstall, $ChocoPreference, $DebugPreference)
        if ($PackagesToInstall.count -eq 1) {
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" })
        } else {
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" })
        }
        $packagesWinget, $packagesChoco = {
            $packagesWinget = [System.Collections.ArrayList]::new()
            $packagesChoco = [System.Collections.ArrayList]::new()

        foreach ($package in $PackagesToInstall) {
            if ($ChocoPreference) {
                if ($package.choco -eq "na") {
                    $packagesWinget.add($package.winget)
                    Write-Host "Queueing $($package.winget) for Winget install"
                } else {
                    $null = $packagesChoco.add($package.choco)
                    Write-Host "Queueing $($package.choco) for Chocolatey install"
                }
            }
            else {
                if ($package.winget -eq "na") {
                    $packagesChoco.add($package.choco)
                    Write-Host "Queueing $($package.choco) for Chocolatey install"
                } else {
                    $null = $packagesWinget.add($($package.winget))
                    Write-Host "Queueing $($package.winget) for Winget install"
                }
            }
        }
        return $packagesWinget, $packagesChoco
        }.Invoke($PackagesToInstall)

        try {
            $sync.ProcessRunning = $true
            $errorPackages = @()
            if($packagesWinget.Count -gt 0) {
                Install-WinUtilWinget
                Install-WinUtilProgramWinget -Action Install -Programs $packagesWinget

            }
            if($packagesChoco.Count -gt 0) {
                Install-WinUtilChoco
                Install-WinUtilProgramChoco -Action Install -Programs $packagesChoco
            }
            Write-Host "==========================================="
            Write-Host "--      Installs have finished          ---"
            Write-Host "==========================================="
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" })
        } catch {
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Error" -overlay "warning" })
        }
        $sync.ProcessRunning = $False
    }
}
function Invoke-WPFInstallUpgrade {
    <#

    .SYNOPSIS
        Invokes the function that upgrades all installed programs

    #>
    if ($sync.ChocoRadioButton.IsChecked) {
        Install-WinUtilChoco
        $chocoUpgradeStatus = (Start-Process "choco" -ArgumentList "upgrade all -y" -Wait -PassThru -NoNewWindow).ExitCode
        if ($chocoUpgradeStatus -eq 0) {
            Write-Host "Upgrade Successful"
        }
        else{
            Write-Host "Error Occured. Return Code: $chocoUpgradeStatus"
        }
    }
    else{
        if((Test-WinUtilPackageManager -winget) -eq "not-installed") {
            return
        }

        if(Get-WinUtilInstallerProcess -Process $global:WinGetInstall) {
            $msg = "[Invoke-WPFInstallUpgrade] Install process is currently running. Please check for a powershell window labeled 'Winget Install'"
            [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }

        Update-WinUtilProgramWinget

        Write-Host "==========================================="
        Write-Host "--           Updates started            ---"
        Write-Host "-- You can close this window if desired ---"
        Write-Host "==========================================="
    }
}
function Invoke-WPFOOSU {
    <#
    .SYNOPSIS
        Downloads and runs OO Shutup 10
    #>
    try {
        $OOSU_filepath = "$ENV:temp\OOSU10.exe"
        $Initial_ProgressPreference = $ProgressPreference
        $ProgressPreference = "SilentlyContinue" # Disables the Progress Bar to drasticly speed up Invoke-WebRequest
        Invoke-WebRequest -Uri "https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe" -OutFile $OOSU_filepath
        Write-Host "Starting OO Shutup 10 ..."
        Start-Process $OOSU_filepath
    } catch {
        Write-Host "Error Downloading and Running OO Shutup 10" -ForegroundColor Red
    }
    finally {
        $ProgressPreference = $Initial_ProgressPreference
    }
}
function Invoke-WPFPanelAutologin {
    <#

    .SYNOPSIS
        Enables autologin using Sysinternals Autologon.exe

    #>

    # Official Microsoft recommendation: https://learn.microsoft.com/en-us/sysinternals/downloads/autologon
    Invoke-WebRequest -Uri "https://live.sysinternals.com/Autologon.exe" -OutFile "$env:temp\autologin.exe"
    cmd /c "$env:temp\autologin.exe" /accepteula
}
function Invoke-WPFPanelDISM {
    <#

    .SYNOPSIS
        Checks for system corruption using Chkdsk, SFC, and DISM

    .DESCRIPTION
        1. Chkdsk    - Fixes disk and filesystem corruption
        2. SFC Run 1 - Fixes system file corruption, and fixes DISM if it was corrupted
        3. DISM      - Fixes system image corruption, and fixes SFC's system image if it was corrupted
        4. SFC Run 2 - Fixes system file corruption, this time with an almost guaranteed uncorrupted system image

    .NOTES
        Command Arguments:
            1. Chkdsk
                /Scan - Runs an online scan on the system drive, attempts to fix any corruption, and queues other corruption for fixing on reboot
            2. SFC
                /ScanNow - Performs a scan of the system files and fixes any corruption
            3. DISM      - Fixes system image corruption, and fixes SFC's system image if it was corrupted
                /Online - Fixes the currently running system image
                /Cleanup-Image - Performs cleanup operations on the image, could remove some unneeded temporary files
                /Restorehealth - Performs a scan of the image and fixes any corruption

    #>
    Start-Process PowerShell -ArgumentList "Write-Host '(1/4) Chkdsk' -ForegroundColor Green; Chkdsk /scan;
    Write-Host '`n(2/4) SFC - 1st scan' -ForegroundColor Green; sfc /scannow;
    Write-Host '`n(3/4) DISM' -ForegroundColor Green; DISM /Online /Cleanup-Image /Restorehealth;
    Write-Host '`n(4/4) SFC - 2nd scan' -ForegroundColor Green; sfc /scannow;
    Read-Host '`nPress Enter to Continue'" -verb runas
}
function Invoke-WPFPopup {
    param (
        [ValidateSet("Show", "Hide", "Toggle")]
        [string]$Action = "",

        [string[]]$Popups = @(),

        [ValidateScript({
            $invalid = $_.GetEnumerator() | Where-Object { $_.Value -notin @("Show", "Hide", "Toggle") }
            if ($invalid) {
                throw "Found invalid Popup-Action pair(s): " + ($invalid | ForEach-Object { "$($_.Key) = $($_.Value)" } -join "; ")
            }
            $true
        })]
        [hashtable]$PopupActionTable = @{}
    )

    if (-not $PopupActionTable.Count -and (-not $Action -or -not $Popups.Count)) {
        throw "Provide either 'PopupActionTable' or both 'Action' and 'Popups'."
    }

    if ($PopupActionTable.Count -and ($Action -or $Popups.Count)) {
        throw "Use 'PopupActionTable' on its own, or 'Action' with 'Popups'."
    }

    # Collect popups and actions
    $PopupsToProcess = if ($PopupActionTable.Count) {
        $PopupActionTable.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Name = "$($_.Key)Popup"; Action = $_.Value } }
    } else {
        $Popups | ForEach-Object { [PSCustomObject]@{ Name = "$_`Popup"; Action = $Action } }
    }

    $PopupsNotFound = @()

    # Apply actions
    foreach ($popupEntry in $PopupsToProcess) {
        $popupName = $popupEntry.Name

        if (-not $sync.$popupName) {
            $PopupsNotFound += $popupName
            continue
        }

        $sync.$popupName.IsOpen = switch ($popupEntry.Action) {
            "Show" { $true }
            "Hide" { $false }
            "Toggle" { -not $sync.$popupName.IsOpen }
        }
    }

    if ($PopupsNotFound.Count -gt 0) {
        throw "Could not find the following popups: $($PopupsNotFound -join ', ')"
    }
}
function Invoke-WPFPresets {
    <#

    .SYNOPSIS
        Sets the options in the tweaks panel to the given preset

    .PARAMETER preset
        The preset to set the options to

    .PARAMETER imported
        If the preset is imported from a file, defaults to false

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"

    #>

    param (
        [Parameter(position=0)]
        [Array]$preset = "",

        [Parameter(position=1)]
        [bool]$imported = $false,

        [Parameter(position=2)]
        [string]$checkboxfilterpattern = "**"
    )

    if ($imported -eq $true) {
        $CheckBoxesToCheck = $preset
    } else {
        $CheckBoxesToCheck = $sync.configs.preset.$preset
    }

    $CheckBoxes = ($sync.GetEnumerator()).where{ $_.Value -is [System.Windows.Controls.CheckBox] -and $_.Name -notlike "WPFToggle*" -and $_.Name -like "$checkboxfilterpattern"}
    Write-Debug "Getting checkboxes to set, number of checkboxes: $($CheckBoxes.Count)"

    if ($CheckBoxesToCheck -ne "") {
        $debugMsg = "CheckBoxes to Check are: "
        $CheckBoxesToCheck | ForEach-Object { $debugMsg += "$_, " }
        $debugMsg = $debugMsg -replace (',\s*$', '')
        Write-Debug "$debugMsg"
    }

    foreach ($CheckBox in $CheckBoxes) {
        $checkboxName = $CheckBox.Key

        if (-not $CheckBoxesToCheck) {
            $sync.$checkboxName.IsChecked = $false
            continue
        }

        # Check if the checkbox name exists in the flattened JSON hashtable
        if ($CheckBoxesToCheck -contains $checkboxName) {
            # If it exists, set IsChecked to true
            $sync.$checkboxName.IsChecked = $true
            Write-Debug "$checkboxName is checked"
        } else {
            # If it doesn't exist, set IsChecked to false
            $sync.$checkboxName.IsChecked = $false
            Write-Debug "$checkboxName is not checked"
        }
    }
}
function Invoke-WPFRunAdobeCCCleanerTool {
    <#
    .SYNOPSIS
        It removes or fixes problem files and resolves permission issues in registry keys.
    .DESCRIPTION
        The Creative Cloud Cleaner tool is a utility for experienced users to clean up corrupted installations.
    #>

    [string]$url="https://swupmf.adobe.com/webfeed/CleanerTool/win/AdobeCreativeCloudCleanerTool.exe"

    Write-Host "The Adobe Creative Cloud Cleaner tool is hosted at"
    Write-Host "$url"

    try {
        # Don't show the progress because it will slow down the download speed
        $ProgressPreference='SilentlyContinue'

        Invoke-WebRequest -Uri $url -OutFile "$env:TEMP\AdobeCreativeCloudCleanerTool.exe" -UseBasicParsing -ErrorAction SilentlyContinue -Verbose

        # Revert back the ProgressPreference variable to the default value since we got the file desired
        $ProgressPreference='Continue'

        Start-Process -FilePath "$env:TEMP\AdobeCreativeCloudCleanerTool.exe" -Wait -ErrorAction SilentlyContinue -Verbose
    } catch {
        Write-Error $_.Exception.Message
    } finally {
        if (Test-Path -Path "$env:TEMP\AdobeCreativeCloudCleanerTool.exe") {
            Write-Host "Cleaning up..."
            Remove-Item -Path "$env:TEMP\AdobeCreativeCloudCleanerTool.exe" -Verbose
        }
    }
}
function Invoke-WPFRunspace {

    <#

    .SYNOPSIS
        Creates and invokes a runspace using the given scriptblock and argumentlist

    .PARAMETER ScriptBlock
        The scriptblock to invoke in the runspace

    .PARAMETER ArgumentList
        A list of arguments to pass to the runspace

    .PARAMETER ParameterList
        A list of named parameters that should be provided.
    .EXAMPLE
        Invoke-WPFRunspace `
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ArgumentList "Installadvancedip,Installbitwarden" `

        Invoke-WPFRunspace`
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ParameterList @(("PackagesToInstall", @("Installadvancedip,Installbitwarden")),("ChocoPreference", $true))
    #>

    [CmdletBinding()]
    Param (
        $ScriptBlock,
        $ArgumentList,
        $ParameterList,
        $DebugPreference
    )

    # Create a PowerShell instance
    $script:powershell = [powershell]::Create()

    # Add Scriptblock and Arguments to runspace
    $script:powershell.AddScript($ScriptBlock)
    $script:powershell.AddArgument($ArgumentList)

    foreach ($parameter in $ParameterList) {
        $script:powershell.AddParameter($parameter[0], $parameter[1])
    }
    $script:powershell.AddArgument($DebugPreference)  # Pass DebugPreference to the script block
    $script:powershell.RunspacePool = $sync.runspace

    # Execute the RunspacePool
    $script:handle = $script:powershell.BeginInvoke()

    # Clean up the RunspacePool threads when they are complete, and invoke the garbage collector to clean up the memory
    if ($script:handle.IsCompleted) {
        $script:powershell.EndInvoke($script:handle)
        $script:powershell.Dispose()
        $sync.runspace.Dispose()
        $sync.runspace.Close()
        [System.GC]::Collect()
    }
    # Return the handle
    return $handle
}
function Invoke-WPFSelectedAppsUpdate {
    <#
        .SYNOPSIS
            This is a helper function that is called by the Checked and Unchecked events of the Checkboxes on the install tab.
            It Updates the "Selected Apps" selectedAppLabel on the Install Tab to represent the current collection
        .PARAMETER type
            Eigther: Add | Remove
        .PARAMETER checkbox
            should contain the current instance of the checkbox that triggered the Event.
            Most of the time will be the automatic variable $this
        .EXAMPLE
            $checkbox.Add_Unchecked({Invoke-WPFSelectedAppsUpdate -type "Remove" -checkbox $this})
            OR
            Invoke-WPFSelectedAppsUpdate -type "Add" -checkbox $specificCheckbox
    #>
    param (
        $type,
        $checkbox
    )

    $selectedAppsButton = $sync.WPFselectedAppsButton
    # Get the actual Name from the selectedAppLabel inside the Checkbox
    $appKey = $checkbox.Parent.Parent.Tag
    if ($type -eq "Add") {
        $sync.selectedApps.Add($appKey)
        # The List type needs to be specified again, because otherwise Sort-Object will convert the list to a string if there is only a single entry
        [System.Collections.Generic.List[pscustomobject]]$sync.selectedApps = $sync.SelectedApps | Sort-Object

    }
    elseif ($type -eq "Remove") {
        $sync.SelectedApps.Remove($appKey)
    }
    else{
        Write-Error "Type: $type not implemented"
    }

    $count = $sync.SelectedApps.Count
    $selectedAppsButton.Content = "Selected Apps: $count"
    # On every change, remove all entries inside the Popup Menu. This is done, so we can keep the alphabetical order even if elements are selected in a random way
    $sync.selectedAppsstackPanel.Children.Clear()
    $sync.SelectedApps | Foreach-Object { Add-SelectedAppsMenuItem -name $($sync.configs.applicationsHashtable.$_.Content) -key $_ }

}
function Invoke-WPFSSHServer {
    <#

    .SYNOPSIS
        Invokes the OpenSSH Server install in a runspace

  #>

    Invoke-WPFRunspace -DebugPreference $DebugPreference -ScriptBlock {

        Invoke-WinUtilSSHServer

        Write-Host "======================================="
        Write-Host "--     OpenSSH Server installed!    ---"
        Write-Host "======================================="
    }
}
function Invoke-WPFTab {

    <#

    .SYNOPSIS
        Sets the selected tab to the tab that was clicked

    .PARAMETER ClickedTab
        The name of the tab that was clicked

    #>

    Param (
        [Parameter(Mandatory,position=0)]
        [string]$ClickedTab
    )

    $tabNav = Get-WinUtilVariables | Where-Object {$psitem -like "WPFTabNav"}
    $tabNumber = [int]($ClickedTab -replace "WPFTab","" -replace "BT","") - 1

    $filter = Get-WinUtilVariables -Type ToggleButton | Where-Object {$psitem -like "WPFTab?BT"}
    ($sync.GetEnumerator()).where{$psitem.Key -in $filter} | ForEach-Object {
        if ($ClickedTab -ne $PSItem.name) {
            $sync[$PSItem.Name].IsChecked = $false
        } else {
            $sync["$ClickedTab"].IsChecked = $true
            $tabNumber = [int]($ClickedTab-replace "WPFTab","" -replace "BT","") - 1
            $sync.$tabNav.Items[$tabNumber].IsSelected = $true
        }
    }
    $sync.currentTab = $sync.$tabNav.Items[$tabNumber].Header
}
function Invoke-WPFTweakPS7{
        <#
    .SYNOPSIS
        This will edit the config file of the Windows Terminal Replacing the Powershell 5 to Powershell 7 and install Powershell 7 if necessary
    .PARAMETER action
        PS7:           Configures Powershell 7 to be the default Terminal
        PS5:           Configures Powershell 5 to be the default Terminal
    #>
    param (
        [ValidateSet("PS7", "PS5")]
        [string]$action
    )

    switch ($action) {
        "PS7"{
            if (Test-Path -Path "$env:ProgramFiles\PowerShell\7") {
                Write-Host "Powershell 7 is already installed."
            } else {
                Write-Host "Installing Powershell 7..."
                Install-WinUtilProgramWinget -Action Install -Programs @("Microsoft.PowerShell")
            }
            $targetTerminalName = "PowerShell"
        }
        "PS5"{
            $targetTerminalName = "Windows PowerShell"
        }
    }
    # Check if the Windows Terminal is installed and return if not (Prerequisite for the following code)
    if (-not (Get-Command "wt" -ErrorAction SilentlyContinue)) {
        Write-Host "Windows Terminal not installed. Skipping Terminal preference"
        return
    }
    # Check if the Windows Terminal settings.json file exists and return if not (Prereqisite for the following code)
    $settingsPath = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
    if (-not (Test-Path -Path $settingsPath)) {
        Write-Host "Windows Terminal Settings file not found at $settingsPath"
        return
    }

    Write-Host "Settings file found."
    $settingsContent = Get-Content -Path $settingsPath | ConvertFrom-Json
    $ps7Profile = $settingsContent.profiles.list | Where-Object { $_.name -eq $targetTerminalName }
    if ($ps7Profile) {
        $settingsContent.defaultProfile = $ps7Profile.guid
        $updatedSettings = $settingsContent | ConvertTo-Json -Depth 100
        Set-Content -Path $settingsPath -Value $updatedSettings
        Write-Host "Default profile updated to " -NoNewline
        Write-Host "$targetTerminalName " -ForegroundColor White -NoNewline
        Write-Host "using the name attribute."
    } else {
        Write-Host "No PowerShell 7 profile found in Windows Terminal settings using the name attribute."
    }
}
function Invoke-WPFtweaksbutton {
  <#

    .SYNOPSIS
        Invokes the functions associated with each group of checkboxes

  #>

  if($sync.ProcessRunning) {
    $msg = "[Invoke-WPFtweaksbutton] Install process is currently running."
    [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    return
  }

  $Tweaks = (Get-WinUtilCheckBoxes)["WPFTweaks"]

  Set-WinUtilDNS -DNSProvider $sync["WPFchangedns"].text

  if ($tweaks.count -eq 0 -and  $sync["WPFchangedns"].text -eq "Default") {
    $msg = "Please check the tweaks you wish to perform."
    [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    return
  }

  Write-Debug "Number of tweaks to process: $($Tweaks.Count)"

  # The leading "," in the ParameterList is nessecary because we only provide one argument and powershell cannot be convinced that we want a nested loop with only one argument otherwise
  $tweaksHandle = Invoke-WPFRunspace -ParameterList @(,("tweaks",$tweaks)) -DebugPreference $DebugPreference -ScriptBlock {
    param(
      $tweaks,
      $DebugPreference
      )
    Write-Debug "Inside Number of tweaks to process: $($Tweaks.Count)"

    $sync.ProcessRunning = $true

    if ($Tweaks.count -eq 1) {
        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" })
    } else {
        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" })
    }
    # Execute other selected tweaks

    for ($i = 0; $i -lt $Tweaks.Count; $i++) {
      Set-WinUtilProgressBar -Label "Applying $($tweaks[$i])" -Percent ($i / $tweaks.Count * 100)
      Invoke-WinUtilTweaks $tweaks[$i]
      $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -value ($i/$Tweaks.Count) })
    }
    Set-WinUtilProgressBar -Label "Tweaks finished" -Percent 100
    $sync.ProcessRunning = $false
    $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" })
    Write-Host "================================="
    Write-Host "--     Tweaks are Finished    ---"
    Write-Host "================================="

    # $ButtonType = [System.Windows.MessageBoxButton]::OK
    # $MessageboxTitle = "Tweaks are Finished "
    # $Messageboxbody = ("Done")
    # $MessageIcon = [System.Windows.MessageBoxImage]::Information
    # [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)
  }
}
function Invoke-WPFUIApps {
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [PSCustomObject[]]$Apps,
        [Parameter(Mandatory, Position = 1)]
        [string]$TargetGridName
    )

    switch ($TargetGridName) {
        "appspanel" {
            $dockPanel = Initialize-InstallAppsMainElement -TargetGridName $TargetGridName
            $null = Initialize-InstallHeader -TargetElement $dockPanel
            $sync.ItemsControl = Initialize-InstallAppArea -TargetElement $dockPanel
            Initialize-InstallCategoryAppList -TargetElement $sync.ItemsControl -Apps $Apps
        }
        default {
            Write-Output "$TargetGridName not yet implemented"
        }
    }
}

function Invoke-WPFUIElements {
    <#
    .SYNOPSIS
        Adds UI elements to a specified Grid in the WinUtil GUI based on a JSON configuration.
    .PARAMETER configVariable
        The variable/link containing the JSON configuration.
    .PARAMETER targetGridName
        The name of the grid to which the UI elements should be added.
    .PARAMETER columncount
        The number of columns to be used in the Grid. If not provided, a default value is used based on the panel.
    .EXAMPLE
        Invoke-WPFUIElements -configVariable $sync.configs.applications -targetGridName "install" -columncount 5
    .NOTES
        Future me/contributor: If possible, please wrap this into a runspace to make it load all panels at the same time.
    #>

    param(
        [Parameter(Mandatory, Position = 0)]
        [PSCustomObject]$configVariable,

        [Parameter(Mandatory, Position = 1)]
        [string]$targetGridName,

        [Parameter(Mandatory, Position = 2)]
        [int]$columncount
    )

    $window = $sync.form

    $borderstyle = $window.FindResource("BorderStyle")
    $HoverTextBlockStyle = $window.FindResource("HoverTextBlockStyle")
    $ColorfulToggleSwitchStyle = $window.FindResource("ColorfulToggleSwitchStyle")
    $ToggleButtonStyle = $window.FindResource("ToggleButtonStyle")

    if (!$borderstyle -or !$HoverTextBlockStyle -or !$ColorfulToggleSwitchStyle) {
        throw "Failed to retrieve Styles using 'FindResource' from main window element."
    }

    $targetGrid = $window.FindName($targetGridName)

    if (!$targetGrid) {
        throw "Failed to retrieve Target Grid by name, provided name: $targetGrid"
    }

    # Clear existing ColumnDefinitions and Children
    $targetGrid.ColumnDefinitions.Clear() | Out-Null
    $targetGrid.Children.Clear() | Out-Null

    # Add ColumnDefinitions to the target Grid
    for ($i = 0; $i -lt $columncount; $i++) {
        $colDef = New-Object Windows.Controls.ColumnDefinition
        $colDef.Width = New-Object Windows.GridLength(1, [Windows.GridUnitType]::Star)
        $targetGrid.ColumnDefinitions.Add($colDef) | Out-Null
    }

    # Convert PSCustomObject to Hashtable
    $configHashtable = @{}
    $configVariable.PSObject.Properties.Name | ForEach-Object {
        $configHashtable[$_] = $configVariable.$_
    }

    $radioButtonGroups = @{}

    $organizedData = @{}
    # Iterate through JSON data and organize by panel and category
    foreach ($entry in $configHashtable.Keys) {
        $entryInfo = $configHashtable[$entry]

        # Create an object for the application
        $entryObject = [PSCustomObject]@{
            Name        = $entry
            Order       = $entryInfo.order
            Category    = $entryInfo.Category
            Content     = $entryInfo.Content
            Panel       = if ($entryInfo.Panel) { $entryInfo.Panel } else { "0" }
            Link        = $entryInfo.link
            Description = $entryInfo.description
            Type        = $entryInfo.type
            ComboItems  = $entryInfo.ComboItems
            Checked     = $entryInfo.Checked
            ButtonWidth = $entryInfo.ButtonWidth
            GroupName   = $entryInfo.GroupName  # Added for RadioButton groupings
        }

        if (-not $organizedData.ContainsKey($entryObject.Panel)) {
            $organizedData[$entryObject.Panel] = @{}
        }

        if (-not $organizedData[$entryObject.Panel].ContainsKey($entryObject.Category)) {
            $organizedData[$entryObject.Panel][$entryObject.Category] = @()
        }

        # Store application data in an array under the category
        $organizedData[$entryObject.Panel][$entryObject.Category] += $entryObject

        # Only apply the logic for distributing entries across columns if the targetGridName is "appspanel"
        if ($targetGridName -eq "appspanel") {
            $panelcount = 0
            $entrycount = $configHashtable.Keys.Count + $organizedData["0"].Keys.Count
        }

    }

    # Initialize panel count
    $panelcount = 0

    # Iterate through 'organizedData' by panel, category, and application
    $count = 0
    foreach ($panelKey in ($organizedData.Keys | Sort-Object)) {
        # Create a Border for each column
        $border = New-Object Windows.Controls.Border
        $border.VerticalAlignment = "Stretch"
        [System.Windows.Controls.Grid]::SetColumn($border, $panelcount)
        $border.style = $borderstyle
        $targetGrid.Children.Add($border) | Out-Null

        # Use a DockPanel to contain the content
        $dockPanelContainer = New-Object Windows.Controls.DockPanel
        $border.Child = $dockPanelContainer

        # Create an ItemsControl for application content
        $itemsControl = New-Object Windows.Controls.ItemsControl
        $itemsControl.HorizontalAlignment = 'Stretch'
        $itemsControl.VerticalAlignment = 'Stretch'

        # Set the ItemsPanel to a VirtualizingStackPanel
        $itemsPanelTemplate = New-Object Windows.Controls.ItemsPanelTemplate
        $factory = New-Object Windows.FrameworkElementFactory ([Windows.Controls.VirtualizingStackPanel])
        $itemsPanelTemplate.VisualTree = $factory
        $itemsControl.ItemsPanel = $itemsPanelTemplate

        # Set virtualization properties
        $itemsControl.SetValue([Windows.Controls.VirtualizingStackPanel]::IsVirtualizingProperty, $true)
        $itemsControl.SetValue([Windows.Controls.VirtualizingStackPanel]::VirtualizationModeProperty, [Windows.Controls.VirtualizationMode]::Recycling)

        # Add the ItemsControl directly to the DockPanel
        [Windows.Controls.DockPanel]::SetDock($itemsControl, [Windows.Controls.Dock]::Bottom)
        $dockPanelContainer.Children.Add($itemsControl) | Out-Null
        $panelcount++

        # Now proceed with adding category labels and entries to $itemsControl
        foreach ($category in ($organizedData[$panelKey].Keys | Sort-Object)) {
            $count++

            $label = New-Object Windows.Controls.Label
            $label.Content = $category -replace ".*__", ""
            $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSizeHeading")
            $label.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $itemsControl.Items.Add($label) | Out-Null
            $sync[$category] = $label

            # Sort entries by Order and then by Name
            $entries = $organizedData[$panelKey][$category] | Sort-Object Order, Name
            foreach ($entryInfo in $entries) {
                $count++
                # Create the UI elements based on the entry type
                switch ($entryInfo.Type) {
                    "Toggle" {
                        $dockPanel = New-Object Windows.Controls.DockPanel
                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.HorizontalAlignment = "Right"
                        $dockPanel.Children.Add($checkBox) | Out-Null
                        $checkBox.Style = $ColorfulToggleSwitchStyle

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.ToolTip = $entryInfo.Description
                        $label.HorizontalAlignment = "Left"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $label.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
                        $dockPanel.Children.Add($label) | Out-Null
                        $itemsControl.Items.Add($dockPanel) | Out-Null

                        $sync[$entryInfo.Name] = $checkBox

                        $sync[$entryInfo.Name].IsChecked = (Get-WinUtilToggleStatus $entryInfo.Name)

                        $sync[$entryInfo.Name].Add_Checked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WinUtilTweaks $sender.name
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WinUtiltweaks $sender.name -undo $true
                        })
                    }

                    "ToggleButton" {
                        $toggleButton = New-Object Windows.Controls.Primitives.ToggleButton
                        $toggleButton.Name = $entryInfo.Name
                        $toggleButton.Content = $entryInfo.Content[1]
                        $toggleButton.ToolTip = $entryInfo.Description
                        $toggleButton.HorizontalAlignment = "Left"
                        $toggleButton.Style = $ToggleButtonStyle

                        $toggleButton.Tag = @{
                            contentOn = if ($entryInfo.Content.Count -ge 1) { $entryInfo.Content[0] } else { "" }
                            contentOff = if ($entryInfo.Content.Count -ge 2) { $entryInfo.Content[1] } else { $contentOn }
                        }

                        $itemsControl.Items.Add($toggleButton) | Out-Null

                        $sync[$entryInfo.Name] = $toggleButton

                        $sync[$entryInfo.Name].Add_Checked({
                            $this.Content = $this.Tag.contentOn
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            $this.Content = $this.Tag.contentOff
                        })
                    }

                    "Combobox" {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        $horizontalStackPanel.Margin = "0,5,0,0"

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.HorizontalAlignment = "Left"
                        $label.VerticalAlignment = "Center"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $horizontalStackPanel.Children.Add($label) | Out-Null

                        $comboBox = New-Object Windows.Controls.ComboBox
                        $comboBox.Name = $entryInfo.Name
                        $comboBox.SetResourceReference([Windows.Controls.Control]::HeightProperty, "ButtonHeight")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::WidthProperty, "ButtonWidth")
                        $comboBox.HorizontalAlignment = "Left"
                        $comboBox.VerticalAlignment = "Center"
                        $comboBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")

                        foreach ($comboitem in ($entryInfo.ComboItems -split " ")) {
                            $comboBoxItem = New-Object Windows.Controls.ComboBoxItem
                            $comboBoxItem.Content = $comboitem
                            $comboBoxItem.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                            $comboBox.Items.Add($comboBoxItem) | Out-Null
                        }

                        $horizontalStackPanel.Children.Add($comboBox) | Out-Null
                        $itemsControl.Items.Add($horizontalStackPanel) | Out-Null

                        $comboBox.SelectedIndex = 0

                        $sync[$entryInfo.Name] = $comboBox
                    }

                    "Button" {
                        $button = New-Object Windows.Controls.Button
                        $button.Name = $entryInfo.Name
                        $button.Content = $entryInfo.Content
                        $button.HorizontalAlignment = "Left"
                        $button.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $button.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        if ($entryInfo.ButtonWidth) {
                            $button.Width = $entryInfo.ButtonWidth
                        }
                        $itemsControl.Items.Add($button) | Out-Null

                        $sync[$entryInfo.Name] = $button
                    }

                    "RadioButton" {
                        # Check if a container for this GroupName already exists
                        if (-not $radioButtonGroups.ContainsKey($entryInfo.GroupName)) {
                            # Create a StackPanel for this group
                            $groupStackPanel = New-Object Windows.Controls.StackPanel
                            $groupStackPanel.Orientation = "Vertical"

                            # Add the group container to the ItemsControl
                            $itemsControl.Items.Add($groupStackPanel) | Out-Null
                        }
                        else {
                            # Retrieve the existing group container
                            $groupStackPanel = $radioButtonGroups[$entryInfo.GroupName]
                        }

                        # Create the RadioButton
                        $radioButton = New-Object Windows.Controls.RadioButton
                        $radioButton.Name = $entryInfo.Name
                        $radioButton.GroupName = $entryInfo.GroupName
                        $radioButton.Content = $entryInfo.Content
                        $radioButton.HorizontalAlignment = "Left"
                        $radioButton.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $radioButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $radioButton.ToolTip = $entryInfo.Description

                        if ($entryInfo.Checked -eq $true) {
                            $radioButton.IsChecked = $true
                        }

                        # Add the RadioButton to the group container
                        $groupStackPanel.Children.Add($radioButton) | Out-Null
                        $sync[$entryInfo.Name] = $radioButton
                    }

                    default {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"

                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.Content = $entryInfo.Content
                        $checkBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $checkBox.ToolTip = $entryInfo.Description
                        $checkBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        if ($entryInfo.Checked -eq $true) {
                            $checkBox.IsChecked = $entryInfo.Checked
                        }
                        $horizontalStackPanel.Children.Add($checkBox) | Out-Null

                        if ($entryInfo.Link) {
                            $textBlock = New-Object Windows.Controls.TextBlock
                            $textBlock.Name = $checkBox.Name + "Link"
                            $textBlock.Text = "(?)"
                            $textBlock.ToolTip = $entryInfo.Link
                            $textBlock.Style = $HoverTextBlockStyle

                            $horizontalStackPanel.Children.Add($textBlock) | Out-Null

                            $sync[$textBlock.Name] = $textBlock
                        }

                        $itemsControl.Items.Add($horizontalStackPanel) | Out-Null
                        $sync[$entryInfo.Name] = $checkBox
                    }
                }
            }
        }
    }
}
Function Invoke-WPFUltimatePerformance {
    <#

    .SYNOPSIS
        Enables or disables the Ultimate Performance power scheme based on its GUID.

    .PARAMETER State
        Specifies whether to "Enable" or "Disable" the Ultimate Performance power scheme.

    #>
    param($State)

    try {
        # GUID of the Ultimate Performance power plan
        $ultimateGUID = "e9a42b02-d5df-448d-aa00-03f14749eb61"

        if ($State -eq "Enable") {
            # Duplicate the Ultimate Performance power plan using its GUID
            $duplicateOutput = powercfg /duplicatescheme $ultimateGUID

            $guid = $null
            $nameFromFile = "ChrisTitus - Ultimate Power Plan"
            $description = "Ultimate Power Plan, added via WinUtils"

            # Extract the new GUID from the duplicateOutput
            foreach ($line in $duplicateOutput) {
                if ($line -match "\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b") {
                    $guid = $matches[0]  # $matches[0] will contain the first match, which is the GUID
                    Write-Output "GUID: $guid has been extracted and stored in the variable."
                    break
                }
            }

            if (-not $guid) {
                Write-Output "No GUID found in the duplicateOutput. Check the output format."
                exit 1
            }

            # Change the name of the power plan and set its description
            $changeNameOutput = powercfg /changename $guid "$nameFromFile" "$description"
            Write-Output "The power plan name and description have been changed. Output:"
            Write-Output $changeNameOutput

            # Set the duplicated Ultimate Performance plan as active
            $setActiveOutput = powercfg /setactive $guid
            Write-Output "The power plan has been set as active. Output:"
            Write-Output $setActiveOutput

            Write-Host "> Ultimate Performance plan installed and set as active."

        } elseif ($State -eq "Disable") {
            # Check if the Ultimate Performance plan is installed by GUID
            $installedPlan = (powercfg -list | Select-String -Pattern "ChrisTitus - Ultimate Power Plan").Line.Split()[3]

            if ($installedPlan) {
                # Extract the GUID of the installed Ultimate Performance plan
                $ultimatePlanGUID = $installedPlan.Line.Split()[3]

                # Set a different power plan as active before deleting the Ultimate Performance plan
                $balancedPlanGUID = 381b4222-f694-41f0-9685-ff5bb260df2e
                powercfg -setactive $balancedPlanGUID

                # Delete the Ultimate Performance plan by GUID
                powercfg -delete $ultimatePlanGUID

                Write-Host "Ultimate Performance plan has been uninstalled."
                Write-Host "> Balanced plan is now active."
            } else {
                Write-Host "Ultimate Performance plan is not installed."
            }
        }
    } catch {
        Write-Error "Error occurred: $_"
    }
}
function Invoke-WPFundoall {
    <#

    .SYNOPSIS
        Undoes every selected tweak

    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFundoall] Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $tweaks = (Get-WinUtilCheckBoxes)["WPFtweaks"]

    if ($tweaks.count -eq 0) {
        $msg = "Please check the tweaks you wish to undo."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    Invoke-WPFRunspace -ArgumentList $tweaks -DebugPreference $DebugPreference -ScriptBlock {
        param($tweaks, $DebugPreference)

        $sync.ProcessRunning = $true
        if ($tweaks.count -eq 1) {
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" })
        } else {
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" })
        }


        for ($i = 0; $i -lt $tweaks.Count; $i++) {
            Set-WinUtilProgressBar -Label "Undoing $($tweaks[$i])" -Percent ($i / $tweaks.Count * 100)
            Invoke-WinUtiltweaks $tweaks[$i] -undo $true
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -value ($i/$tweaks.Count) })
        }

        Set-WinUtilProgressBar -Label "Undo Tweaks Finished" -Percent 100
        $sync.ProcessRunning = $false
        $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" })
        Write-Host "=================================="
        Write-Host "---  Undo Tweaks are Finished  ---"
        Write-Host "=================================="

    }
}
function Invoke-WPFUnInstall {
    param(
        [Parameter(Mandatory=$false)]
        [PSObject[]]$PackagesToUninstall = $($sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ })
    )
    <#

    .SYNOPSIS
        Uninstalls the selected programs
    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFUnInstall] Install process is currently running"
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if ($PackagesToUninstall.Count -eq 0) {
        $WarningMsg = "Please select the program(s) to uninstall"
        [System.Windows.MessageBox]::Show($WarningMsg, $AppTitle, [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $ButtonType = [System.Windows.MessageBoxButton]::YesNo
    $MessageboxTitle = "Are you sure?"
    $Messageboxbody = ("This will uninstall the following applications: `n $($PackagesToUninstall | Select-Object Name, Description| Out-String)")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    $confirm = [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)

    if($confirm -eq "No") {return}
    $ChocoPreference = $($sync.ChocoRadioButton.IsChecked)

    Invoke-WPFRunspace -ArgumentList @(("PackagesToUninstall", $PackagesToUninstall),("ChocoPreference", $ChocoPreference)) -DebugPreference $DebugPreference -ScriptBlock {
        param($PackagesToUninstall, $ChocoPreference, $DebugPreference)
        if ($PackagesToUninstall.count -eq 1) {
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" })
        } else {
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" })
        }
        $packagesWinget, $packagesChoco = {
            $packagesWinget = [System.Collections.ArrayList]::new()
            $packagesChoco = [System.Collections.ArrayList]::new()

        foreach ($package in $PackagesToUninstall) {
            if ($ChocoPreference) {
                if ($package.choco -eq "na") {
                    $packagesWinget.add($package.winget)
                    Write-Host "Queueing $($package.winget) for Winget uninstall"
                } else {
                    $null = $packagesChoco.add($package.choco)
                    Write-Host "Queueing $($package.choco) for Chocolatey uninstall"
                }
            }
            else {
                if ($package.winget -eq "na") {
                    $packagesChoco.add($package.choco)
                    Write-Host "Queueing $($package.choco) for Chocolatey uninstall"
                } else {
                    $null = $packagesWinget.add($($package.winget))
                    Write-Host "Queueing $($package.winget) for Winget uninstall"
                }
            }
        }
        return $packagesWinget, $packagesChoco
        }.Invoke($PackagesToUninstall)

        try {
            $sync.ProcessRunning = $true

            # Install all selected programs in new window
            if($packagesWinget.Count -gt 0) {
                Install-WinUtilProgramWinget -Action Uninstall -Programs $packagesWinget
            }
            if($packagesChoco.Count -gt 0) {
                Install-WinUtilProgramChoco -Action Uninstall -Programs $packagesChoco
            }

            Write-Host "==========================================="
            Write-Host "--       Uninstalls have finished       ---"
            Write-Host "==========================================="
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" })
        } catch {
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
            $sync.form.Dispatcher.Invoke([action]{ Set-WinUtilTaskbaritem -state "Error" -overlay "warning" })
        }
        $sync.ProcessRunning = $False

    }
}
function Invoke-WPFUpdatesdefault {
    <#

    .SYNOPSIS
        Resets Windows Update settings to default

    #>
    If (!(Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU")) {
        New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force | Out-Null
    }
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Type DWord -Value 0
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Type DWord -Value 3
    If (!(Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config")) {
        New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Force | Out-Null
    }
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Name "DODownloadMode" -Type DWord -Value 1

    $services = @(
        "BITS"
        "wuauserv"
    )

    foreach ($service in $services) {
        # -ErrorAction SilentlyContinue is so it doesn't write an error to stdout if a service doesn't exist

        Write-Host "Setting $service StartupType to Automatic"
        Get-Service -Name $service -ErrorAction SilentlyContinue | Set-Service -StartupType Automatic
    }
    Write-Host "Enabling driver offering through Windows Update..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "Enabling Windows Update automatic restart..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUPowerManagement" -ErrorAction SilentlyContinue
    Write-Host "Enabled driver offering through Windows Update"
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "BranchReadinessLevel" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferFeatureUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferQualityUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Write-Host "==================================================="
    Write-Host "---  Windows Update Settings Reset to Default   ---"
    Write-Host "==================================================="

    Start-Process -FilePath "secedit" -ArgumentList "/configure /cfg $env:windir\inf\defltbase.inf /db defltbase.sdb /verbose" -Wait
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicyUsers" -Wait
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicy" -Wait
    Start-Process -FilePath "gpupdate" -ArgumentList "/force" -Wait
    Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "==================================================="
    Write-Host "---  Windows Local Policies Reset to Default   ---"
    Write-Host "==================================================="
}
function Invoke-WPFUpdatesdisable {
    <#

    .SYNOPSIS
        Disables Windows Update

    .NOTES
        Disabling Windows Update is not recommended. This is only for advanced users who know what they are doing.

    #>
    If (!(Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU")) {
        New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force | Out-Null
    }
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Type DWord -Value 1
    If (!(Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config")) {
        New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Force | Out-Null
    }
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Name "DODownloadMode" -Type DWord -Value 0

    $services = @(
        "BITS"
        "wuauserv"
    )

    foreach ($service in $services) {
        # -ErrorAction SilentlyContinue is so it doesn't write an error to stdout if a service doesn't exist

        Write-Host "Setting $service StartupType to Disabled"
        Get-Service -Name $service -ErrorAction SilentlyContinue | Set-Service -StartupType Disabled
    }
    Write-Host "================================="
    Write-Host "---   Updates ARE DISABLED    ---"
    Write-Host "================================="
}
function Invoke-WPFUpdatessecurity {
    <#

    .SYNOPSIS
        Sets Windows Update to recommended settings

    .DESCRIPTION
        1. Disables driver offering through Windows Update
        2. Disables Windows Update automatic restart
        3. Sets Windows Update to Semi-Annual Channel (Targeted)
        4. Defers feature updates for 365 days
        5. Defers quality updates for 4 days

    #>
    Write-Host "Disabling driver offering through Windows Update..."
        If (!(Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata")) {
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Force | Out-Null
        }
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -Type DWord -Value 1
        If (!(Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching")) {
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Force | Out-Null
        }
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -Type DWord -Value 1
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -Type DWord -Value 1
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -Type DWord -Value 0
        If (!(Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate")) {
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" | Out-Null
        }
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -Type DWord -Value 1
        Write-Host "Disabling Windows Update automatic restart..."
        If (!(Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU")) {
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force | Out-Null
        }
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -Type DWord -Value 1
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUPowerManagement" -Type DWord -Value 0
        Write-Host "Disabled driver offering through Windows Update"
        If (!(Test-Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings")) {
            New-Item -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Force | Out-Null
        }
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "BranchReadinessLevel" -Type DWord -Value 20
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferFeatureUpdatesPeriodInDays" -Type DWord -Value 365
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferQualityUpdatesPeriodInDays" -Type DWord -Value 4

        $ButtonType = [System.Windows.MessageBoxButton]::OK
        $MessageboxTitle = "Set Security Updates"
        $Messageboxbody = ("Recommended Update settings loaded")
        $MessageIcon = [System.Windows.MessageBoxImage]::Information

        [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)
        Write-Host "================================="
        Write-Host "-- Updates Set to Recommended ---"
        Write-Host "================================="
}
$sync.configs.applications = @'
{
  "WPFInstall1password": {
    "category": "Utilities",
    "choco": "1password",
    "content": "1Password",
    "description": "1Password is a password manager that allows you to store and manage your passwords securely.",
    "link": "https://1password.com/",
    "winget": "AgileBits.1Password"
  },
  "WPFInstall7zip": {
    "category": "Utilities",
    "choco": "7zip",
    "content": "7-Zip",
    "description": "7-Zip is a free and open-source file archiver utility. It supports several compression formats and provides a high compression ratio, making it a popular choice for file compression.",
    "link": "https://www.7-zip.org/",
    "winget": "7zip.7zip"
  },
  "WPFInstalladobe": {
    "category": "Document",
    "choco": "adobereader",
    "content": "Adobe Acrobat Reader",
    "description": "Adobe Acrobat Reader is a free PDF viewer with essential features for viewing, printing, and annotating PDF documents.",
    "link": "https://www.adobe.com/acrobat/pdf-reader.html",
    "winget": "Adobe.Acrobat.Reader.64-bit"
  },
  "WPFInstalladvancedip": {
    "category": "Pro Tools",
    "choco": "advanced-ip-scanner",
    "content": "Advanced IP Scanner",
    "description": "Advanced IP Scanner is a fast and easy-to-use network scanner. It is designed to analyze LAN networks and provides information about connected devices.",
    "link": "https://www.advanced-ip-scanner.com/",
    "winget": "Famatech.AdvancedIPScanner"
  },
  "WPFInstallaffine": {
    "category": "Document",
    "choco": "na",
    "content": "AFFiNE",
    "description": "AFFiNE is an open source alternative to Notion. Write, draw, plan all at once. Selfhost it to sync across devices.",
    "link": "https://affine.pro/",
    "winget": "ToEverything.AFFiNE"
  },
  "WPFInstallaimp": {
    "category": "Multimedia Tools",
    "choco": "aimp",
    "content": "AIMP (Music Player)",
    "description": "AIMP is a feature-rich music player with support for various audio formats, playlists, and customizable user interface.",
    "link": "https://www.aimp.ru/",
    "winget": "AIMP.AIMP"
  },
  "WPFInstallalacritty": {
    "category": "Utilities",
    "choco": "alacritty",
    "content": "Alacritty Terminal",
    "description": "Alacritty is a fast, cross-platform, and GPU-accelerated terminal emulator. It is designed for performance and aims to be the fastest terminal emulator available.",
    "link": "https://alacritty.org/",
    "winget": "Alacritty.Alacritty"
  },
  "WPFInstallanaconda3": {
    "category": "Development",
    "choco": "anaconda3",
    "content": "Anaconda",
    "description": "Anaconda is a distribution of the Python and R programming languages for scientific computing.",
    "link": "https://www.anaconda.com/products/distribution",
    "winget": "Anaconda.Anaconda3"
  },
  "WPFInstallangryipscanner": {
    "category": "Pro Tools",
    "choco": "angryip",
    "content": "Angry IP Scanner",
    "description": "Angry IP Scanner is an open-source and cross-platform network scanner. It is used to scan IP addresses and ports, providing information about network connectivity.",
    "link": "https://angryip.org/",
    "winget": "angryziber.AngryIPScanner"
  },
  "WPFInstallanki": {
    "category": "Document",
    "choco": "anki",
    "content": "Anki",
    "description": "Anki is a flashcard application that helps you memorize information with intelligent spaced repetition.",
    "link": "https://apps.ankiweb.net/",
    "winget": "Anki.Anki"
  },
  "WPFInstallanydesk": {
    "category": "Utilities",
    "choco": "anydesk",
    "content": "AnyDesk",
    "description": "AnyDesk is a remote desktop software that enables users to access and control computers remotely. It is known for its fast connection and low latency.",
    "link": "https://anydesk.com/",
    "winget": "AnyDeskSoftwareGmbH.AnyDesk"
  },
  "WPFInstallaudacity": {
    "category": "Multimedia Tools",
    "choco": "audacity",
    "content": "Audacity",
    "description": "Audacity is a free and open-source audio editing software known for its powerful recording and editing capabilities.",
    "link": "https://www.audacityteam.org/",
    "winget": "Audacity.Audacity"
  },
  "WPFInstallautoruns": {
    "category": "Microsoft Tools",
    "choco": "autoruns",
    "content": "Autoruns",
    "description": "This utility shows you what programs are configured to run during system bootup or login",
    "link": "https://learn.microsoft.com/en-us/sysinternals/downloads/autoruns",
    "winget": "Microsoft.Sysinternals.Autoruns"
  },
  "WPFInstallrdcman": {
    "category": "Microsoft Tools",
    "choco": "rdcman",
    "content": "RDCMan",
    "description": "RDCMan manages multiple remote desktop connections. It is useful for managing server labs where you need regular access to each machine such as automated checkin systems and data centers.",
    "link": "https://learn.microsoft.com/en-us/sysinternals/downloads/rdcman",
    "winget": "Microsoft.Sysinternals.RDCMan"
  },
  "WPFInstallautohotkey": {
    "category": "Utilities",
    "choco": "autohotkey",
    "content": "AutoHotkey",
    "description": "AutoHotkey is a scripting language for Windows that allows users to create custom automation scripts and macros. It is often used for automating repetitive tasks and customizing keyboard shortcuts.",
    "link": "https://www.autohotkey.com/",
    "winget": "AutoHotkey.AutoHotkey"
  },
  "WPFInstallazuredatastudio": {
    "category": "Microsoft Tools",
    "choco": "azure-data-studio",
    "content": "Microsoft Azure Data Studio",
    "description": "Azure Data Studio is a data management tool that enables you to work with SQL Server, Azure SQL DB and SQL DW from Windows, macOS and Linux.",
    "link": "https://docs.microsoft.com/sql/azure-data-studio/what-is-azure-data-studio",
    "winget": "Microsoft.AzureDataStudio"
  },
  "WPFInstallbarrier": {
    "category": "Utilities",
    "choco": "barrier",
    "content": "Barrier",
    "description": "Barrier is an open-source software KVM (keyboard, video, and mouseswitch). It allows users to control multiple computers with a single keyboard and mouse, even if they have different operating systems.",
    "link": "https://github.com/debauchee/barrier",
    "winget": "DebaucheeOpenSourceGroup.Barrier"
  },
  "WPFInstallbat": {
    "category": "Utilities",
    "choco": "bat",
    "content": "Bat (Cat)",
    "description": "Bat is a cat command clone with syntax highlighting. It provides a user-friendly and feature-rich alternative to the traditional cat command for viewing and concatenating files.",
    "link": "https://github.com/sharkdp/bat",
    "winget": "sharkdp.bat"
  },
  "WPFInstallbitwarden": {
    "category": "Utilities",
    "choco": "bitwarden",
    "content": "Bitwarden",
    "description": "Bitwarden is an open-source password management solution. It allows users to store and manage their passwords in a secure and encrypted vault, accessible across multiple devices.",
    "link": "https://bitwarden.com/",
    "winget": "Bitwarden.Bitwarden"
  },
  "WPFInstallbleachbit": {
    "category": "Utilities",
    "choco": "bleachbit",
    "content": "BleachBit",
    "description": "Clean Your System and Free Disk Space",
    "link": "https://www.bleachbit.org/",
    "winget": "BleachBit.BleachBit"
  },
  "WPFInstallblender": {
    "category": "Multimedia Tools",
    "choco": "blender",
    "content": "Blender (3D Graphics)",
    "description": "Blender is a powerful open-source 3D creation suite, offering modeling, sculpting, animation, and rendering tools.",
    "link": "https://www.blender.org/",
    "winget": "BlenderFoundation.Blender"
  },
  "WPFInstallbrave": {
    "category": "Browsers",
    "choco": "brave",
    "content": "Brave",
    "description": "Brave is a privacy-focused web browser that blocks ads and trackers, offering a faster and safer browsing experience.",
    "link": "https://www.brave.com",
    "winget": "Brave.Brave"
  },
  "WPFInstallbulkcrapuninstaller": {
    "category": "Utilities",
    "choco": "bulk-crap-uninstaller",
    "content": "Bulk Crap Uninstaller",
    "description": "Bulk Crap Uninstaller is a free and open-source uninstaller utility for Windows. It helps users remove unwanted programs and clean up their system by uninstalling multiple applications at once.",
    "link": "https://www.bcuninstaller.com/",
    "winget": "Klocman.BulkCrapUninstaller"
  },
  "WPFInstallbulkrenameutility": {
    "category": "Utilities",
    "choco": "bulkrenameutility",
    "content": "Bulk Rename Utility",
    "description": "Bulk Rename Utility allows you to easily rename files and folders recursively based upon find-replace, character place, fields, sequences, regular expressions, EXIF data, and more.",
    "link": "https://www.bulkrenameutility.co.uk",
    "winget": "TGRMNSoftware.BulkRenameUtility"
  },
  "WPFInstallAdvancedRenamer": {
    "category": "Utilities",
    "choco": "advanced-renamer",
    "content": "Advanced Renamer",
    "description": "Advanced Renamer is a program for renaming multiple files and folders at once. By configuring renaming methods the names can be manipulated in various ways.",
    "link": "https://www.advancedrenamer.com/",
    "winget": "HulubuluSoftware.AdvancedRenamer"
  },
  "WPFInstallcalibre": {
    "category": "Document",
    "choco": "calibre",
    "content": "Calibre",
    "description": "Calibre is a powerful and easy-to-use e-book manager, viewer, and converter.",
    "link": "https://calibre-ebook.com/",
    "winget": "calibre.calibre"
  },
  "WPFInstallcarnac": {
    "category": "Utilities",
    "choco": "carnac",
    "content": "Carnac",
    "description": "Carnac is a keystroke visualizer for Windows. It displays keystrokes in an overlay, making it useful for presentations, tutorials, and live demonstrations.",
    "link": "https://carnackeys.com/",
    "winget": "code52.Carnac"
  },
  "WPFInstallcemu": {
    "category": "Games",
    "choco": "cemu",
    "content": "Cemu",
    "description": "Cemu is a highly experimental software to emulate Wii U applications on PC.",
    "link": "https://cemu.info/",
    "winget": "Cemu.Cemu"
  },
  "WPFInstallchatterino": {
    "category": "Communications",
    "choco": "chatterino",
    "content": "Chatterino",
    "description": "Chatterino is a chat client for Twitch chat that offers a clean and customizable interface for a better streaming experience.",
    "link": "https://www.chatterino.com/",
    "winget": "ChatterinoTeam.Chatterino"
  },
  "WPFInstallchrome": {
    "category": "Browsers",
    "choco": "googlechrome",
    "content": "Chrome",
    "description": "Google Chrome is a widely used web browser known for its speed, simplicity, and seamless integration with Google services.",
    "link": "https://www.google.com/chrome/",
    "winget": "Google.Chrome"
  },
  "WPFInstallchromium": {
    "category": "Browsers",
    "choco": "chromium",
    "content": "Chromium",
    "description": "Chromium is the open-source project that serves as the foundation for various web browsers, including Chrome.",
    "link": "https://github.com/Hibbiki/chromium-win64",
    "winget": "Hibbiki.Chromium"
  },
  "WPFInstallarc": {
    "category": "Browsers",
    "choco": "na",
    "content": "Arc",
    "description": "Arc is a Chromium based browser, known for it's clean and modern design.",
    "link": "https://arc.net/",
    "winget": "TheBrowserCompany.Arc"
  },
  "WPFInstallclementine": {
    "category": "Multimedia Tools",
    "choco": "clementine",
    "content": "Clementine",
    "description": "Clementine is a modern music player and library organizer, supporting various audio formats and online radio services.",
    "link": "https://www.clementine-player.org/",
    "winget": "Clementine.Clementine"
  },
  "WPFInstallclink": {
    "category": "Development",
    "choco": "clink",
    "content": "Clink",
    "description": "Clink is a powerful Bash-compatible command-line interface (CLIenhancement for Windows, adding features like syntax highlighting and improved history).",
    "link": "https://mridgers.github.io/clink/",
    "winget": "chrisant996.Clink"
  },
  "WPFInstallclonehero": {
    "category": "Games",
    "choco": "na",
    "content": "Clone Hero",
    "description": "Clone Hero is a free rhythm game, which can be played with any 5 or 6 button guitar controller.",
    "link": "https://clonehero.net/",
    "winget": "CloneHeroTeam.CloneHero"
  },
  "WPFInstallcmake": {
    "category": "Development",
    "choco": "cmake",
    "content": "CMake",
    "description": "CMake is an open-source, cross-platform family of tools designed to build, test and package software.",
    "link": "https://cmake.org/",
    "winget": "Kitware.CMake"
  },
  "WPFInstallcopyq": {
    "category": "Utilities",
    "choco": "copyq",
    "content": "CopyQ (Clipboard Manager)",
    "description": "CopyQ is a clipboard manager with advanced features, allowing you to store, edit, and retrieve clipboard history.",
    "link": "https://copyq.readthedocs.io/",
    "winget": "hluk.CopyQ"
  },
  "WPFInstallcpuz": {
    "category": "Utilities",
    "choco": "cpu-z",
    "content": "CPU-Z",
    "description": "CPU-Z is a system monitoring and diagnostic tool for Windows. It provides detailed information about the computer's hardware components, including the CPU, memory, and motherboard.",
    "link": "https://www.cpuid.com/softwares/cpu-z.html",
    "winget": "CPUID.CPU-Z"
  },
  "WPFInstallcrystaldiskinfo": {
    "category": "Utilities",
    "choco": "crystaldiskinfo",
    "content": "Crystal Disk Info",
    "description": "Crystal Disk Info is a disk health monitoring tool that provides information about the status and performance of hard drives. It helps users anticipate potential issues and monitor drive health.",
    "link": "https://crystalmark.info/en/software/crystaldiskinfo/",
    "winget": "CrystalDewWorld.CrystalDiskInfo"
  },
  "WPFInstallcapframex": {
    "category": "Utilities",
    "choco": "na",
    "content": "CapFrameX",
    "description": "Frametimes capture and analysis tool based on Intel's PresentMon. Overlay provided by Rivatuner Statistics Server.",
    "link": "https://www.capframex.com/",
    "winget": "CXWorld.CapFrameX"
  },
  "WPFInstallcrystaldiskmark": {
    "category": "Utilities",
    "choco": "crystaldiskmark",
    "content": "Crystal Disk Mark",
    "description": "Crystal Disk Mark is a disk benchmarking tool that measures the read and write speeds of storage devices. It helps users assess the performance of their hard drives and SSDs.",
    "link": "https://crystalmark.info/en/software/crystaldiskmark/",
    "winget": "CrystalDewWorld.CrystalDiskMark"
  },
  "WPFInstalldarktable": {
    "category": "Multimedia Tools",
    "choco": "darktable",
    "content": "darktable",
    "description": "Open-source photo editing tool, offering an intuitive interface, advanced editing capabilities, and a non-destructive workflow for seamless image enhancement.",
    "link": "https://www.darktable.org/install/",
    "winget": "darktable.darktable"
  },
  "WPFInstallDaxStudio": {
    "category": "Development",
    "choco": "daxstudio",
    "content": "DaxStudio",
    "description": "DAX (Data Analysis eXpressions) Studio is the ultimate tool for executing and analyzing DAX queries against Microsoft Tabular models.",
    "link": "https://daxstudio.org/",
    "winget": "DaxStudio.DaxStudio"
  },
  "WPFInstallddu": {
    "category": "Utilities",
    "choco": "ddu",
    "content": "Display Driver Uninstaller",
    "description": "Display Driver Uninstaller (DDU) is a tool for completely uninstalling graphics drivers from NVIDIA, AMD, and Intel. It is useful for troubleshooting graphics driver-related issues.",
    "link": "https://www.wagnardsoft.com/display-driver-uninstaller-DDU-",
    "winget": "ddu"
  },
  "WPFInstalldeluge": {
    "category": "Utilities",
    "choco": "deluge",
    "content": "Deluge",
    "description": "Deluge is a free and open-source BitTorrent client. It features a user-friendly interface, support for plugins, and the ability to manage torrents remotely.",
    "link": "https://deluge-torrent.org/",
    "winget": "DelugeTeam.Deluge"
  },
  "WPFInstalldevtoys": {
    "category": "Utilities",
    "choco": "devtoys",
    "content": "DevToys",
    "description": "DevToys is a collection of development-related utilities and tools for Windows. It includes tools for file management, code formatting, and productivity enhancements for developers.",
    "link": "https://devtoys.app/",
    "winget": "DevToys-app.DevToys"
  },
  "WPFInstalldigikam": {
    "category": "Multimedia Tools",
    "choco": "digikam",
    "content": "digiKam",
    "description": "digiKam is an advanced open-source photo management software with features for organizing, editing, and sharing photos.",
    "link": "https://www.digikam.org/",
    "winget": "KDE.digikam"
  },
  "WPFInstalldiscord": {
    "category": "Communications",
    "choco": "discord",
    "content": "Discord",
    "description": "Discord is a popular communication platform with voice, video, and text chat, designed for gamers but used by a wide range of communities.",
    "link": "https://discord.com/",
    "winget": "Discord.Discord"
  },
  "WPFInstallditto": {
    "category": "Utilities",
    "choco": "ditto",
    "content": "Ditto",
    "description": "Ditto is an extension to the standard windows clipboard.",
    "link": "https://github.com/sabrogden/Ditto",
    "winget": "Ditto.Ditto"
  },
  "WPFInstalldockerdesktop": {
    "category": "Development",
    "choco": "docker-desktop",
    "content": "Docker Desktop",
    "description": "Docker Desktop is a powerful tool for containerized application development and deployment.",
    "link": "https://www.docker.com/products/docker-desktop",
    "winget": "Docker.DockerDesktop"
  },
  "WPFInstalldotnet3": {
    "category": "Microsoft Tools",
    "choco": "dotnetcore3-desktop-runtime",
    "content": ".NET Desktop Runtime 3.1",
    "description": ".NET Desktop Runtime 3.1 is a runtime environment required for running applications developed with .NET Core 3.1.",
    "link": "https://dotnet.microsoft.com/download/dotnet/3.1",
    "winget": "Microsoft.DotNet.DesktopRuntime.3_1"
  },
  "WPFInstalldotnet5": {
    "category": "Microsoft Tools",
    "choco": "dotnet-5.0-runtime",
    "content": ".NET Desktop Runtime 5",
    "description": ".NET Desktop Runtime 5 is a runtime environment required for running applications developed with .NET 5.",
    "link": "https://dotnet.microsoft.com/download/dotnet/5.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.5"
  },
  "WPFInstalldotnet6": {
    "category": "Microsoft Tools",
    "choco": "dotnet-6.0-runtime",
    "content": ".NET Desktop Runtime 6",
    "description": ".NET Desktop Runtime 6 is a runtime environment required for running applications developed with .NET 6.",
    "link": "https://dotnet.microsoft.com/download/dotnet/6.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.6"
  },
  "WPFInstalldotnet7": {
    "category": "Microsoft Tools",
    "choco": "dotnet-7.0-runtime",
    "content": ".NET Desktop Runtime 7",
    "description": ".NET Desktop Runtime 7 is a runtime environment required for running applications developed with .NET 7.",
    "link": "https://dotnet.microsoft.com/download/dotnet/7.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.7"
  },
  "WPFInstalldotnet8": {
    "category": "Microsoft Tools",
    "choco": "dotnet-8.0-runtime",
    "content": ".NET Desktop Runtime 8",
    "description": ".NET Desktop Runtime 8 is a runtime environment required for running applications developed with .NET 8.",
    "link": "https://dotnet.microsoft.com/download/dotnet/8.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.8"
  },
  "WPFInstalldotnet9": {
    "category": "Microsoft Tools",
    "choco": "dotnet-9.0-runtime",
    "content": ".NET Desktop Runtime 9",
    "description": ".NET Desktop Runtime 9 is a runtime environment required for running applications developed with .NET 9.",
    "link": "https://dotnet.microsoft.com/download/dotnet/9.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.9"
  },
  "WPFInstalldmt": {
    "winget": "GNE.DualMonitorTools",
    "choco": "dual-monitor-tools",
    "category": "Utilities",
    "content": "Dual Monitor Tools",
    "link": "https://dualmonitortool.sourceforge.net/",
    "description": "Dual Monitor Tools (DMT) is a FOSS app that allows you to customize the handling of multiple monitors. Useful for fullscreen games and apps that handle a second monitor poorly and can improve your workflow."
  },
  "WPFInstallduplicati": {
    "category": "Utilities",
    "choco": "duplicati",
    "content": "Duplicati",
    "description": "Duplicati is an open-source backup solution that supports encrypted, compressed, and incremental backups. It is designed to securely store data on cloud storage services.",
    "link": "https://www.duplicati.com/",
    "winget": "Duplicati.Duplicati"
  },
  "WPFInstalleaapp": {
    "category": "Games",
    "choco": "ea-app",
    "content": "EA App",
    "description": "EA App is a platform for accessing and playing Electronic Arts games.",
    "link": "https://www.ea.com/ea-app",
    "winget": "ElectronicArts.EADesktop"
  },
  "WPFInstalleartrumpet": {
    "category": "Multimedia Tools",
    "choco": "eartrumpet",
    "content": "EarTrumpet (Audio)",
    "description": "EarTrumpet is an audio control app for Windows, providing a simple and intuitive interface for managing sound settings.",
    "link": "https://eartrumpet.app/",
    "winget": "File-New-Project.EarTrumpet"
  },
  "WPFInstalledge": {
    "category": "Browsers",
    "choco": "microsoft-edge",
    "content": "Edge",
    "description": "Microsoft Edge is a modern web browser built on Chromium, offering performance, security, and integration with Microsoft services.",
    "link": "https://www.microsoft.com/edge",
    "winget": "Microsoft.Edge"
  },
  "WPFInstallefibooteditor": {
    "category": "Pro Tools",
    "choco": "na",
    "content": "EFI Boot Editor",
    "description": "EFI Boot Editor is a tool for managing the EFI/UEFI boot entries on your system. It allows you to customize the boot configuration of your computer.",
    "link": "https://www.easyuefi.com/",
    "winget": "EFIBootEditor.EFIBootEditor"
  },
  "WPFInstallemulationstation": {
    "category": "Games",
    "choco": "emulationstation",
    "content": "Emulation Station",
    "description": "Emulation Station is a graphical and themeable emulator front-end that allows you to access all your favorite games in one place.",
    "link": "https://emulationstation.org/",
    "winget": "Emulationstation.Emulationstation"
  },
  "WPFInstallepicgames": {
    "category": "Games",
    "choco": "epicgameslauncher",
    "content": "Epic Games Launcher",
    "description": "Epic Games Launcher is the client for accessing and playing games from the Epic Games Store.",
    "link": "https://www.epicgames.com/store/en-US/",
    "winget": "EpicGames.EpicGamesLauncher"
  },
  "WPFInstallesearch": {
    "category": "Utilities",
    "choco": "everything",
    "content": "Everything Search",
    "description": "Everything Search is a fast and efficient file search utility for Windows.",
    "link": "https://www.voidtools.com/",
    "winget": "voidtools.Everything"
  },
  "WPFInstallespanso": {
    "category": "Utilities",
    "choco": "espanso",
    "content": "Espanso",
    "description": "Cross-platform and open-source Text Expander written in Rust",
    "link": "https://espanso.org/",
    "winget": "Espanso.Espanso"
  },
  "WPFInstalletcher": {
    "category": "Utilities",
    "choco": "etcher",
    "content": "Etcher USB Creator",
    "description": "Etcher is a powerful tool for creating bootable USB drives with ease.",
    "link": "https://www.balena.io/etcher/",
    "winget": "Balena.Etcher"
  },
  "WPFInstallfalkon": {
    "category": "Browsers",
    "choco": "falkon",
    "content": "Falkon",
    "description": "Falkon is a lightweight and fast web browser with a focus on user privacy and efficiency.",
    "link": "https://www.falkon.org/",
    "winget": "KDE.Falkon"
  },
  "WPFInstallfastfetch": {
    "category": "Utilities",
    "choco": "na",
    "content": "Fastfetch",
    "description": "Fastfetch is a neofetch-like tool for fetching system information and displaying them in a pretty way",
    "link": "https://github.com/fastfetch-cli/fastfetch/",
    "winget": "Fastfetch-cli.Fastfetch"
  },
  "WPFInstallferdium": {
    "category": "Communications",
    "choco": "ferdium",
    "content": "Ferdium",
    "description": "Ferdium is a messaging application that combines multiple messaging services into a single app for easy management.",
    "link": "https://ferdium.org/",
    "winget": "Ferdium.Ferdium"
  },
  "WPFInstallffmpeg": {
    "category": "Multimedia Tools",
    "choco": "ffmpeg-full",
    "content": "FFmpeg (full)",
    "description": "FFmpeg is a powerful multimedia processing tool that enables users to convert, edit, and stream audio and video files with a vast range of codecs and formats.",
    "link": "https://ffmpeg.org/",
    "winget": "Gyan.FFmpeg"
  },
  "WPFInstallfileconverter": {
    "category": "Utilities",
    "choco": "file-converter",
    "content": "File-Converter",
    "description": "File Converter is a very simple tool which allows you to convert and compress one or several file(s) using the context menu in windows explorer.",
    "link": "https://file-converter.io/",
    "winget": "AdrienAllard.FileConverter"
  },
  "WPFInstallfiles": {
    "category": "Utilities",
    "choco": "files",
    "content": "Files",
    "description": "Alternative file explorer.",
    "link": "https://github.com/files-community/Files",
    "winget": "na"
  },
  "WPFInstallfirealpaca": {
    "category": "Multimedia Tools",
    "choco": "firealpaca",
    "content": "Fire Alpaca",
    "description": "Fire Alpaca is a free digital painting software that provides a wide range of drawing tools and a user-friendly interface.",
    "link": "https://firealpaca.com/",
    "winget": "FireAlpaca.FireAlpaca"
  },
  "WPFInstallfirefox": {
    "category": "Browsers",
    "choco": "firefox",
    "content": "Firefox",
    "description": "Mozilla Firefox is an open-source web browser known for its customization options, privacy features, and extensions.",
    "link": "https://www.mozilla.org/en-US/firefox/new/",
    "winget": "Mozilla.Firefox"
  },
  "WPFInstallfirefoxesr": {
    "category": "Browsers",
    "choco": "FirefoxESR",
    "content": "Firefox ESR",
    "description": "Mozilla Firefox is an open-source web browser known for its customization options, privacy features, and extensions. Firefox ESR (Extended Support Release) receives major updates every 42 weeks with minor updates such as crash fixes, security fixes and policy updates as needed, but at least every four weeks.",
    "link": "https://www.mozilla.org/en-US/firefox/enterprise/",
    "winget": "Mozilla.Firefox.ESR"
  },
  "WPFInstallflameshot": {
    "category": "Multimedia Tools",
    "choco": "flameshot",
    "content": "Flameshot (Screenshots)",
    "description": "Flameshot is a powerful yet simple to use screenshot software, offering annotation and editing features.",
    "link": "https://flameshot.org/",
    "winget": "Flameshot.Flameshot"
  },
  "WPFInstalllightshot": {
    "category": "Multimedia Tools",
    "choco": "lightshot",
    "content": "Lightshot (Screenshots)",
    "description": "Ligthshot is an Easy-to-use, light-weight screenshot software tool, where you can optionally edit your screenshots using different tools, share them via Internet and/or save to disk, and customize the available options.",
    "link": "https://app.prntscr.com/",
    "winget": "Skillbrains.Lightshot"
  },
  "WPFInstallfloorp": {
    "category": "Browsers",
    "choco": "na",
    "content": "Floorp",
    "description": "Floorp is an open-source web browser project that aims to provide a simple and fast browsing experience.",
    "link": "https://floorp.app/",
    "winget": "Ablaze.Floorp"
  },
  "WPFInstallflow": {
    "category": "Utilities",
    "choco": "flow-launcher",
    "content": "Flow launcher",
    "description": "Keystroke launcher for Windows to search, manage and launch files, folders bookmarks, websites and more.",
    "link": "https://www.flowlauncher.com/",
    "winget": "Flow-Launcher.Flow-Launcher"
  },
  "WPFInstallflux": {
    "category": "Utilities",
    "choco": "flux",
    "content": "F.lux",
    "description": "f.lux adjusts the color temperature of your screen to reduce eye strain during nighttime use.",
    "link": "https://justgetflux.com/",
    "winget": "flux.flux"
  },
  "WPFInstallfoobar": {
    "category": "Multimedia Tools",
    "choco": "foobar2000",
    "content": "foobar2000 (Music Player)",
    "description": "foobar2000 is a highly customizable and extensible music player for Windows, known for its modular design and advanced features.",
    "link": "https://www.foobar2000.org/",
    "winget": "PeterPawlowski.foobar2000"
  },
  "WPFInstallfoxpdfeditor": {
    "category": "Document",
    "choco": "na",
    "content": "Foxit PDF Editor",
    "description": "Foxit PDF Editor is a feature-rich PDF editor and viewer with a familiar ribbon-style interface.",
    "link": "https://www.foxit.com/pdf-editor/",
    "winget": "Foxit.PhantomPDF"
  },
  "WPFInstallfoxpdfreader": {
    "category": "Document",
    "choco": "foxitreader",
    "content": "Foxit PDF Reader",
    "description": "Foxit PDF Reader is a free PDF viewer with a familiar ribbon-style interface.",
    "link": "https://www.foxit.com/pdf-reader/",
    "winget": "Foxit.FoxitReader"
  },
  "WPFInstallfreecad": {
    "category": "Multimedia Tools",
    "choco": "freecad",
    "content": "FreeCAD",
    "description": "FreeCAD is a parametric 3D CAD modeler, designed for product design and engineering tasks, with a focus on flexibility and extensibility.",
    "link": "https://www.freecadweb.org/",
    "winget": "FreeCAD.FreeCAD"
  },
  "WPFInstallfxsound": {
    "category": "Multimedia Tools",
    "choco": "fxsound",
    "content": "FxSound",
    "description": "FxSound is free open-source software to boost sound quality, volume, and bass. Including an equalizer, effects, and presets for customized audio.",
    "link": "https://www.fxsound.com/",
    "winget": "FxSound.FxSound"
  },
  "WPFInstallfzf": {
    "category": "Utilities",
    "choco": "fzf",
    "content": "Fzf",
    "description": "A command-line fuzzy finder",
    "link": "https://github.com/junegunn/fzf/",
    "winget": "junegunn.fzf"
  },
  "WPFInstallgeforcenow": {
    "category": "Games",
    "choco": "nvidia-geforce-now",
    "content": "GeForce NOW",
    "description": "GeForce NOW is a cloud gaming service that allows you to play high-quality PC games on your device.",
    "link": "https://www.nvidia.com/en-us/geforce-now/",
    "winget": "Nvidia.GeForceNow"
  },
  "WPFInstallgimp": {
    "category": "Multimedia Tools",
    "choco": "gimp",
    "content": "GIMP (Image Editor)",
    "description": "GIMP is a versatile open-source raster graphics editor used for tasks such as photo retouching, image editing, and image composition.",
    "link": "https://www.gimp.org/",
    "winget": "GIMP.GIMP"
  },
  "WPFInstallgit": {
    "category": "Development",
    "choco": "git",
    "content": "Git",
    "description": "Git is a distributed version control system widely used for tracking changes in source code during software development.",
    "link": "https://git-scm.com/",
    "winget": "Git.Git"
  },
  "WPFInstallgitbutler": {
    "category": "Development",
    "choco": "na",
    "content": "Git Butler",
    "description": "A Git client for simultaneous branches on top of your existing workflow.",
    "link": "https://gitbutler.com/",
    "winget": "GitButler.GitButler"
  },
  "WPFInstallgitextensions": {
    "category": "Development",
    "choco": "git;gitextensions",
    "content": "Git Extensions",
    "description": "Git Extensions is a graphical user interface for Git, providing additional features for easier source code management.",
    "link": "https://gitextensions.github.io/",
    "winget": "GitExtensionsTeam.GitExtensions"
  },
  "WPFInstallgithubcli": {
    "category": "Development",
    "choco": "git;gh",
    "content": "GitHub CLI",
    "description": "GitHub CLI is a command-line tool that simplifies working with GitHub directly from the terminal.",
    "link": "https://cli.github.com/",
    "winget": "GitHub.cli"
  },
  "WPFInstallgithubdesktop": {
    "category": "Development",
    "choco": "git;github-desktop",
    "content": "GitHub Desktop",
    "description": "GitHub Desktop is a visual Git client that simplifies collaboration on GitHub repositories with an easy-to-use interface.",
    "link": "https://desktop.github.com/",
    "winget": "GitHub.GitHubDesktop"
  },
  "WPFInstallgitkrakenclient": {
    "category": "Development",
    "choco": "gitkraken",
    "content": "GitKraken Client",
    "description": "GitKraken Client is a powerful visual Git client from Axosoft that works with ALL git repositories on any hosting environment.",
    "link": "https://www.gitkraken.com/git-client",
    "winget": "Axosoft.GitKraken"
  },
  "WPFInstallglaryutilities": {
    "category": "Utilities",
    "choco": "glaryutilities-free",
    "content": "Glary Utilities",
    "description": "Glary Utilities is a comprehensive system optimization and maintenance tool for Windows.",
    "link": "https://www.glarysoft.com/glary-utilities/",
    "winget": "Glarysoft.GlaryUtilities"
  },
  "WPFInstallgodotengine": {
    "category": "Development",
    "choco": "godot",
    "content": "Godot Engine",
    "description": "Godot Engine is a free, open-source 2D and 3D game engine with a focus on usability and flexibility.",
    "link": "https://godotengine.org/",
    "winget": "GodotEngine.GodotEngine"
  },
  "WPFInstallgog": {
    "category": "Games",
    "choco": "goggalaxy",
    "content": "GOG Galaxy",
    "description": "GOG Galaxy is a gaming client that offers DRM-free games, additional content, and more.",
    "link": "https://www.gog.com/galaxy",
    "winget": "GOG.Galaxy"
  },
  "WPFInstallgitify": {
    "category": "Development",
    "choco": "na",
    "content": "Gitify",
    "description": "GitHub notifications on your menu bar.",
    "link": "https://www.gitify.io/",
    "winget": "Gitify.Gitify"
  },
  "WPFInstallgolang": {
    "category": "Development",
    "choco": "golang",
    "content": "Go",
    "description": "Go (or Golang) is a statically typed, compiled programming language designed for simplicity, reliability, and efficiency.",
    "link": "https://go.dev/",
    "winget": "GoLang.Go"
  },
  "WPFInstallgoogledrive": {
    "category": "Utilities",
    "choco": "googledrive",
    "content": "Google Drive",
    "description": "File syncing across devices all tied to your google account",
    "link": "https://www.google.com/drive/",
    "winget": "Google.GoogleDrive"
  },
  "WPFInstallgpuz": {
    "category": "Utilities",
    "choco": "gpu-z",
    "content": "GPU-Z",
    "description": "GPU-Z provides detailed information about your graphics card and GPU.",
    "link": "https://www.techpowerup.com/gpuz/",
    "winget": "TechPowerUp.GPU-Z"
  },
  "WPFInstallgreenshot": {
    "category": "Multimedia Tools",
    "choco": "greenshot",
    "content": "Greenshot (Screenshots)",
    "description": "Greenshot is a light-weight screenshot software tool with built-in image editor and customizable capture options.",
    "link": "https://getgreenshot.org/",
    "winget": "Greenshot.Greenshot"
  },
  "WPFInstallgsudo": {
    "category": "Utilities",
    "choco": "gsudo",
    "content": "Gsudo",
    "description": "Gsudo is a sudo implementation for Windows, allowing elevated privilege execution.",
    "link": "https://gerardog.github.io/gsudo/",
    "winget": "gerardog.gsudo"
  },
  "WPFInstallguilded": {
    "category": "Communications",
    "choco": "na",
    "content": "Guilded",
    "description": "Guilded is a communication and productivity platform that includes chat, scheduling, and collaborative tools for gaming and communities.",
    "link": "https://www.guilded.gg/",
    "winget": "Guilded.Guilded"
  },
  "WPFInstallhandbrake": {
    "category": "Multimedia Tools",
    "choco": "handbrake",
    "content": "HandBrake",
    "description": "HandBrake is an open-source video transcoder, allowing you to convert video from nearly any format to a selection of widely supported codecs.",
    "link": "https://handbrake.fr/",
    "winget": "HandBrake.HandBrake"
  },
  "WPFInstallharmonoid": {
    "category": "Multimedia Tools",
    "choco": "na",
    "content": "Harmonoid",
    "description": "Plays and manages your music library. Looks beautiful and juicy. Playlists, visuals, synced lyrics, pitch shift, volume boost and more.",
    "link": "https://harmonoid.com/",
    "winget": "Harmonoid.Harmonoid"
  },
  "WPFInstallheidisql": {
    "category": "Pro Tools",
    "choco": "heidisql",
    "content": "HeidiSQL",
    "description": "HeidiSQL is a powerful and easy-to-use client for MySQL, MariaDB, Microsoft SQL Server, and PostgreSQL databases. It provides tools for database management and development.",
    "link": "https://www.heidisql.com/",
    "winget": "HeidiSQL.HeidiSQL"
  },
  "WPFInstallhelix": {
    "category": "Development",
    "choco": "helix",
    "content": "Helix",
    "description": "Helix is a neovim alternative built in rust.",
    "link": "https://helix-editor.com/",
    "winget": "Helix.Helix"
  },
  "WPFInstallheroiclauncher": {
    "category": "Games",
    "choco": "na",
    "content": "Heroic Games Launcher",
    "description": "Heroic Games Launcher is an open-source alternative game launcher for Epic Games Store.",
    "link": "https://heroicgameslauncher.com/",
    "winget": "HeroicGamesLauncher.HeroicGamesLauncher"
  },
  "WPFInstallhexchat": {
    "category": "Communications",
    "choco": "hexchat",
    "content": "Hexchat",
    "description": "HexChat is a free, open-source IRC (Internet Relay Chat) client with a graphical interface for easy communication.",
    "link": "https://hexchat.github.io/",
    "winget": "HexChat.HexChat"
  },
  "WPFInstallhwinfo": {
    "category": "Utilities",
    "choco": "hwinfo",
    "content": "HWiNFO",
    "description": "HWiNFO provides comprehensive hardware information and diagnostics for Windows.",
    "link": "https://www.hwinfo.com/",
    "winget": "REALiX.HWiNFO"
  },
  "WPFInstallhwmonitor": {
    "category": "Utilities",
    "choco": "hwmonitor",
    "content": "HWMonitor",
    "description": "HWMonitor is a hardware monitoring program that reads PC systems main health sensors.",
    "link": "https://www.cpuid.com/softwares/hwmonitor.html",
    "winget": "CPUID.HWMonitor"
  },
  "WPFInstallimageglass": {
    "category": "Multimedia Tools",
    "choco": "imageglass",
    "content": "ImageGlass (Image Viewer)",
    "description": "ImageGlass is a versatile image viewer with support for various image formats and a focus on simplicity and speed.",
    "link": "https://imageglass.org/",
    "winget": "DuongDieuPhap.ImageGlass"
  },
  "WPFInstallimgburn": {
    "category": "Multimedia Tools",
    "choco": "imgburn",
    "content": "ImgBurn",
    "description": "ImgBurn is a lightweight CD, DVD, HD-DVD, and Blu-ray burning application with advanced features for creating and burning disc images.",
    "link": "https://www.imgburn.com/",
    "winget": "LIGHTNINGUK.ImgBurn"
  },
  "WPFInstallinkscape": {
    "category": "Multimedia Tools",
    "choco": "inkscape",
    "content": "Inkscape",
    "description": "Inkscape is a powerful open-source vector graphics editor, suitable for tasks such as illustrations, icons, logos, and more.",
    "link": "https://inkscape.org/",
    "winget": "Inkscape.Inkscape"
  },
  "WPFInstallitch": {
    "category": "Games",
    "choco": "itch",
    "content": "Itch.io",
    "description": "Itch.io is a digital distribution platform for indie games and creative projects.",
    "link": "https://itch.io/",
    "winget": "ItchIo.Itch"
  },
  "WPFInstallitunes": {
    "category": "Multimedia Tools",
    "choco": "itunes",
    "content": "iTunes",
    "description": "iTunes is a media player, media library, and online radio broadcaster application developed by Apple Inc.",
    "link": "https://www.apple.com/itunes/",
    "winget": "Apple.iTunes"
  },
  "WPFInstalljami": {
    "category": "Communications",
    "choco": "jami",
    "content": "Jami",
    "description": "Jami is a secure and privacy-focused communication platform that offers audio and video calls, messaging, and file sharing.",
    "link": "https://jami.net/",
    "winget": "SFLinux.Jami"
  },
  "WPFInstalljava8": {
    "category": "Development",
    "choco": "corretto8jdk",
    "content": "Amazon Corretto 8 (LTS)",
    "description": "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.8.JDK"
  },
  "WPFInstalljava11": {
    "category": "Development",
    "choco": "corretto11jdk",
    "content": "Amazon Corretto 11 (LTS)",
    "description": "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.11.JDK"
  },
  "WPFInstalljava17": {
    "category": "Development",
    "choco": "corretto17jdk",
    "content": "Amazon Corretto 17 (LTS)",
    "description": "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.17.JDK"
  },
  "WPFInstalljava21": {
    "category": "Development",
    "choco": "corretto21jdk",
    "content": "Amazon Corretto 21 (LTS)",
    "description": "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.21.JDK"
  },
  "WPFInstalljdownloader": {
    "category": "Utilities",
    "choco": "jdownloader",
    "content": "JDownloader",
    "description": "JDownloader is a feature-rich download manager with support for various file hosting services.",
    "link": "https://jdownloader.org/",
    "winget": "AppWork.JDownloader"
  },
  "WPFInstalljellyfinmediaplayer": {
    "category": "Multimedia Tools",
    "choco": "jellyfin-media-player",
    "content": "Jellyfin Media Player",
    "description": "Jellyfin Media Player is a client application for the Jellyfin media server, providing access to your media library.",
    "link": "https://github.com/jellyfin/jellyfin-media-player",
    "winget": "Jellyfin.JellyfinMediaPlayer"
  },
  "WPFInstalljellyfinserver": {
    "category": "Multimedia Tools",
    "choco": "jellyfin",
    "content": "Jellyfin Server",
    "description": "Jellyfin Server is an open-source media server software, allowing you to organize and stream your media library.",
    "link": "https://jellyfin.org/",
    "winget": "Jellyfin.Server"
  },
  "WPFInstalljetbrains": {
    "category": "Development",
    "choco": "jetbrainstoolbox",
    "content": "Jetbrains Toolbox",
    "description": "Jetbrains Toolbox is a platform for easy installation and management of JetBrains developer tools.",
    "link": "https://www.jetbrains.com/toolbox/",
    "winget": "JetBrains.Toolbox"
  },
  "WPFInstalljoplin": {
    "category": "Document",
    "choco": "joplin",
    "content": "Joplin (FOSS Notes)",
    "description": "Joplin is an open-source note-taking and to-do application with synchronization capabilities.",
    "link": "https://joplinapp.org/",
    "winget": "Joplin.Joplin"
  },
  "WPFInstalljpegview": {
    "category": "Utilities",
    "choco": "jpegview",
    "content": "JPEG View",
    "description": "JPEGView is a lean, fast and highly configurable viewer/editor for JPEG, BMP, PNG, WEBP, TGA, GIF, JXL, HEIC, HEIF, AVIF and TIFF images with a minimal GUI",
    "link": "https://github.com/sylikc/jpegview",
    "winget": "sylikc.JPEGView"
  },
  "WPFInstallkdeconnect": {
    "category": "Utilities",
    "choco": "kdeconnect-kde",
    "content": "KDE Connect",
    "description": "KDE Connect allows seamless integration between your KDE desktop and mobile devices.",
    "link": "https://community.kde.org/KDEConnect",
    "winget": "KDE.KDEConnect"
  },
  "WPFInstallkdenlive": {
    "category": "Multimedia Tools",
    "choco": "kdenlive",
    "content": "Kdenlive (Video Editor)",
    "description": "Kdenlive is an open-source video editing software with powerful features for creating and editing professional-quality videos.",
    "link": "https://kdenlive.org/",
    "winget": "KDE.Kdenlive"
  },
  "WPFInstallkeepass": {
    "category": "Utilities",
    "choco": "keepassxc",
    "content": "KeePassXC",
    "description": "KeePassXC is a cross-platform, open-source password manager with strong encryption features.",
    "link": "https://keepassxc.org/",
    "winget": "KeePassXCTeam.KeePassXC"
  },
  "WPFInstallklite": {
    "category": "Multimedia Tools",
    "choco": "k-litecodecpack-standard",
    "content": "K-Lite Codec Standard",
    "description": "K-Lite Codec Pack Standard is a collection of audio and video codecs and related tools, providing essential components for media playback.",
    "link": "https://www.codecguide.com/",
    "winget": "CodecGuide.K-LiteCodecPack.Standard"
  },
  "WPFInstallkodi": {
    "category": "Multimedia Tools",
    "choco": "kodi",
    "content": "Kodi Media Center",
    "description": "Kodi is an open-source media center application that allows you to play and view most videos, music, podcasts, and other digital media files.",
    "link": "https://kodi.tv/",
    "winget": "XBMCFoundation.Kodi"
  },
  "WPFInstallkrita": {
    "category": "Multimedia Tools",
    "choco": "krita",
    "content": "Krita (Image Editor)",
    "description": "Krita is a powerful open-source painting application. It is designed for concept artists, illustrators, matte and texture artists, and the VFX industry.",
    "link": "https://krita.org/en/features/",
    "winget": "KDE.Krita"
  },
  "WPFInstalllazygit": {
    "category": "Development",
    "choco": "lazygit",
    "content": "Lazygit",
    "description": "Simple terminal UI for git commands",
    "link": "https://github.com/jesseduffield/lazygit/",
    "winget": "JesseDuffield.lazygit"
  },
  "WPFInstalllibreoffice": {
    "category": "Document",
    "choco": "libreoffice-fresh",
    "content": "LibreOffice",
    "description": "LibreOffice is a powerful and free office suite, compatible with other major office suites.",
    "link": "https://www.libreoffice.org/",
    "winget": "TheDocumentFoundation.LibreOffice"
  },
  "WPFInstalllibrewolf": {
    "category": "Browsers",
    "choco": "librewolf",
    "content": "LibreWolf",
    "description": "LibreWolf is a privacy-focused web browser based on Firefox, with additional privacy and security enhancements.",
    "link": "https://librewolf-community.gitlab.io/",
    "winget": "LibreWolf.LibreWolf"
  },
  "WPFInstalllinkshellextension": {
    "category": "Utilities",
    "choco": "linkshellextension",
    "content": "Link Shell extension",
    "description": "Link Shell Extension (LSE) provides for the creation of Hardlinks, Junctions, Volume Mountpoints, Symbolic Links, a folder cloning process that utilises Hardlinks or Symbolic Links and a copy process taking care of Junctions, Symbolic Links, and Hardlinks. LSE, as its name implies is implemented as a Shell extension and is accessed from Windows Explorer, or similar file/folder managers.",
    "link": "https://schinagl.priv.at/nt/hardlinkshellext/hardlinkshellext.html",
    "winget": "HermannSchinagl.LinkShellExtension"
  },
  "WPFInstalllinphone": {
    "category": "Communications",
    "choco": "linphone",
    "content": "Linphone",
    "description": "Linphone is an open-source voice over IP (VoIPservice that allows for audio and video calls, messaging, and more.",
    "link": "https://www.linphone.org/",
    "winget": "BelledonneCommunications.Linphone"
  },
  "WPFInstalllivelywallpaper": {
    "category": "Utilities",
    "choco": "lively",
    "content": "Lively Wallpaper",
    "description": "Free and open-source software that allows users to set animated desktop wallpapers and screensavers.",
    "link": "https://www.rocksdanister.com/lively/",
    "winget": "rocksdanister.LivelyWallpaper"
  },
  "WPFInstalllocalsend": {
    "category": "Utilities",
    "choco": "localsend.install",
    "content": "LocalSend",
    "description": "An open source cross-platform alternative to AirDrop.",
    "link": "https://localsend.org/",
    "winget": "LocalSend.LocalSend"
  },
  "WPFInstalllockhunter": {
    "category": "Utilities",
    "choco": "lockhunter",
    "content": "LockHunter",
    "description": "LockHunter is a free tool to delete files blocked by something you do not know.",
    "link": "https://lockhunter.com/",
    "winget": "CrystalRich.LockHunter"
  },
  "WPFInstalllogseq": {
    "category": "Document",
    "choco": "logseq",
    "content": "Logseq",
    "description": "Logseq is a versatile knowledge management and note-taking application designed for the digital thinker. With a focus on the interconnectedness of ideas, Logseq allows users to seamlessly organize their thoughts through a combination of hierarchical outlines and bi-directional linking. It supports both structured and unstructured content, enabling users to create a personalized knowledge graph that adapts to their evolving ideas and insights.",
    "link": "https://logseq.com/",
    "winget": "Logseq.Logseq"
  },
  "WPFInstallmalwarebytes": {
    "category": "Utilities",
    "choco": "malwarebytes",
    "content": "Malwarebytes",
    "description": "Malwarebytes is an anti-malware software that provides real-time protection against threats.",
    "link": "https://www.malwarebytes.com/",
    "winget": "Malwarebytes.Malwarebytes"
  },
  "WPFInstallmasscode": {
    "category": "Document",
    "choco": "na",
    "content": "massCode (Snippet Manager)",
    "description": "massCode is a fast and efficient open-source code snippet manager for developers.",
    "link": "https://masscode.io/",
    "winget": "antonreshetov.massCode"
  },
  "WPFInstallmatrix": {
    "category": "Communications",
    "choco": "element-desktop",
    "content": "Element",
    "description": "Element is a client for Matrix?an open network for secure, decentralized communication.",
    "link": "https://element.io/",
    "winget": "Element.Element"
  },
  "WPFInstallmeld": {
    "category": "Utilities",
    "choco": "meld",
    "content": "Meld",
    "description": "Meld is a visual diff and merge tool for files and directories.",
    "link": "https://meldmerge.org/",
    "winget": "Meld.Meld"
  },
  "WPFInstallModernFlyouts": {
    "category": "Multimedia Tools",
    "choco": "na",
    "content": "Modern Flyouts",
    "description": "An open source, modern, Fluent Design-based set of flyouts for Windows.",
    "link": "https://github.com/ModernFlyouts-Community/ModernFlyouts/",
    "winget": "ModernFlyouts.ModernFlyouts"
  },
  "WPFInstallmonitorian": {
    "category": "Utilities",
    "choco": "monitorian",
    "content": "Monitorian",
    "description": "Monitorian is a utility for adjusting monitor brightness and contrast on Windows.",
    "link": "https://github.com/emoacht/Monitorian",
    "winget": "emoacht.Monitorian"
  },
  "WPFInstallmoonlight": {
    "category": "Games",
    "choco": "moonlight-qt",
    "content": "Moonlight/GameStream Client",
    "description": "Moonlight/GameStream Client allows you to stream PC games to other devices over your local network.",
    "link": "https://moonlight-stream.org/",
    "winget": "MoonlightGameStreamingProject.Moonlight"
  },
  "WPFInstallMotrix": {
    "category": "Utilities",
    "choco": "motrix",
    "content": "Motrix Download Manager",
    "description": "A full-featured download manager.",
    "link": "https://motrix.app/",
    "winget": "agalwood.Motrix"
  },
  "WPFInstallmpchc": {
    "category": "Multimedia Tools",
    "choco": "mpc-hc-clsid2",
    "content": "Media Player Classic - Home Cinema",
    "description": "Media Player Classic - Home Cinema (MPC-HC) is a free and open-source video and audio player for Windows. MPC-HC is based on the original Guliverkli project and contains many additional features and bug fixes.",
    "link": "https://github.com/clsid2/mpc-hc/",
    "winget": "clsid2.mpc-hc"
  },
  "WPFInstallmremoteng": {
    "category": "Pro Tools",
    "choco": "mremoteng",
    "content": "mRemoteNG",
    "description": "mRemoteNG is a free and open-source remote connections manager. It allows you to view and manage multiple remote sessions in a single interface.",
    "link": "https://mremoteng.org/",
    "winget": "mRemoteNG.mRemoteNG"
  },
  "WPFInstallmsedgeredirect": {
    "category": "Utilities",
    "choco": "msedgeredirect",
    "content": "MSEdgeRedirect",
    "description": "A Tool to Redirect News, Search, Widgets, Weather, and More to Your Default Browser.",
    "link": "https://github.com/rcmaehl/MSEdgeRedirect",
    "winget": "rcmaehl.MSEdgeRedirect"
  },
  "WPFInstallmsiafterburner": {
    "category": "Utilities",
    "choco": "msiafterburner",
    "content": "MSI Afterburner",
    "description": "MSI Afterburner is a graphics card overclocking utility with advanced features.",
    "link": "https://www.msi.com/Landing/afterburner",
    "winget": "Guru3D.Afterburner"
  },
  "WPFInstallmullvadvpn": {
    "category": "Pro Tools",
    "choco": "mullvad-app",
    "content": "Mullvad VPN",
    "description": "This is the VPN client software for the Mullvad VPN service.",
    "link": "https://github.com/mullvad/mullvadvpn-app",
    "winget": "MullvadVPN.MullvadVPN"
  },
  "WPFInstallBorderlessGaming": {
    "category": "Utilities",
    "choco": "borderlessgaming",
    "content": "Borderless Gaming",
    "description": "Play your favorite games in a borderless window; no more time consuming alt-tabs.",
    "link": "https://github.com/Codeusa/Borderless-Gaming",
    "winget": "Codeusa.BorderlessGaming"
  },
  "WPFInstallEqualizerAPO": {
    "category": "Multimedia Tools",
    "choco": "equalizerapo",
    "content": "Equalizer APO",
    "description": "Equalizer APO is a parametric / graphic equalizer for Windows.",
    "link": "https://sourceforge.net/projects/equalizerapo",
    "winget": "na"
  },
  "WPFInstallCompactGUI": {
    "category": "Utilities",
    "choco": "compactgui",
    "content": "Compact GUI",
    "description": "Transparently compress active games and programs using Windows 10/11 APIs",
    "link": "https://github.com/IridiumIO/CompactGUI",
    "winget": "IridiumIO.CompactGUI"
  },
  "WPFInstallExifCleaner": {
    "category": "Utilities",
    "choco": "na",
    "content": "ExifCleaner",
    "description": "Desktop app to clean metadata from images, videos, PDFs, and other files.",
    "link": "https://github.com/szTheory/exifcleaner",
    "winget": "szTheory.exifcleaner"
  },
  "WPFInstallmullvadbrowser": {
    "category": "Browsers",
    "choco": "na",
    "content": "Mullvad Browser",
    "description": "Mullvad Browser is a privacy-focused web browser, developed in partnership with the Tor Project.",
    "link": "https://mullvad.net/browser",
    "winget": "MullvadVPN.MullvadBrowser"
  },
  "WPFInstallmusescore": {
    "category": "Multimedia Tools",
    "choco": "musescore",
    "content": "MuseScore",
    "description": "Create, play back and print beautiful sheet music with free and easy to use music notation software MuseScore.",
    "link": "https://musescore.org/en",
    "winget": "Musescore.Musescore"
  },
  "WPFInstallmusicbee": {
    "category": "Multimedia Tools",
    "choco": "musicbee",
    "content": "MusicBee (Music Player)",
    "description": "MusicBee is a customizable music player with support for various audio formats. It includes features like an integrated search function, tag editing, and more.",
    "link": "https://getmusicbee.com/",
    "winget": "MusicBee.MusicBee"
  },
  "WPFInstallmp3tag": {
    "category": "Multimedia Tools",
    "choco": "mp3tag",
    "content": "Mp3tag (Metadata Audio Editor)",
    "description": "Mp3tag is a powerful and yet easy-to-use tool to edit metadata of common audio formats.",
    "link": "https://www.mp3tag.de/en/",
    "winget": "Mp3tag.Mp3tag"
  },
  "WPFInstalltagscanner": {
    "category": "Multimedia Tools",
    "choco": "tagscanner",
    "content": "TagScanner (Tag Scanner)",
    "description": "TagScanner is a powerful tool for organizing and managing your music collection",
    "link": "https://www.xdlab.ru/en/",
    "winget": "SergeySerkov.TagScanner"
  },
  "WPFInstallnanazip": {
    "category": "Utilities",
    "choco": "nanazip",
    "content": "NanaZip",
    "description": "NanaZip is a fast and efficient file compression and decompression tool.",
    "link": "https://github.com/M2Team/NanaZip",
    "winget": "M2Team.NanaZip"
  },
  "WPFInstallnetbird": {
    "category": "Pro Tools",
    "choco": "netbird",
    "content": "NetBird",
    "description": "NetBird is a Open Source alternative comparable to TailScale that can be connected to a selfhosted Server.",
    "link": "https://netbird.io/",
    "winget": "netbird"
  },
  "WPFInstallnaps2": {
    "category": "Document",
    "choco": "naps2",
    "content": "NAPS2 (Document Scanner)",
    "description": "NAPS2 is a document scanning application that simplifies the process of creating electronic documents.",
    "link": "https://www.naps2.com/",
    "winget": "Cyanfish.NAPS2"
  },
  "WPFInstallneofetchwin": {
    "category": "Utilities",
    "choco": "na",
    "content": "Neofetch",
    "description": "Neofetch is a command-line utility for displaying system information in a visually appealing way.",
    "link": "https://github.com/nepnep39/neofetch-win",
    "winget": "nepnep.neofetch-win"
  },
  "WPFInstallneovim": {
    "category": "Development",
    "choco": "neovim",
    "content": "Neovim",
    "description": "Neovim is a highly extensible text editor and an improvement over the original Vim editor.",
    "link": "https://neovim.io/",
    "winget": "Neovim.Neovim"
  },
  "WPFInstallnextclouddesktop": {
    "category": "Utilities",
    "choco": "nextcloud-client",
    "content": "Nextcloud Desktop",
    "description": "Nextcloud Desktop is the official desktop client for the Nextcloud file synchronization and sharing platform.",
    "link": "https://nextcloud.com/install/#install-clients",
    "winget": "Nextcloud.NextcloudDesktop"
  },
  "WPFInstallnglide": {
    "category": "Multimedia Tools",
    "choco": "na",
    "content": "nGlide (3dfx compatibility)",
    "description": "nGlide is a 3Dfx Voodoo Glide wrapper. It allows you to play games that use Glide API on modern graphics cards without the need for a 3Dfx Voodoo graphics card.",
    "link": "https://www.zeus-software.com/downloads/nglide",
    "winget": "ZeusSoftware.nGlide"
  },
  "WPFInstallnmap": {
    "category": "Pro Tools",
    "choco": "nmap",
    "content": "Nmap",
    "description": "Nmap (Network Mapper) is an open-source tool for network exploration and security auditing. It discovers devices on a network and provides information about their ports and services.",
    "link": "https://nmap.org/",
    "winget": "Insecure.Nmap"
  },
  "WPFInstallnodejs": {
    "category": "Development",
    "choco": "nodejs",
    "content": "NodeJS",
    "description": "NodeJS is a JavaScript runtime built on Chrome's V8 JavaScript engine for building server-side and networking applications.",
    "link": "https://nodejs.org/",
    "winget": "OpenJS.NodeJS"
  },
  "WPFInstallnodejslts": {
    "category": "Development",
    "choco": "nodejs-lts",
    "content": "NodeJS LTS",
    "description": "NodeJS LTS provides Long-Term Support releases for stable and reliable server-side JavaScript development.",
    "link": "https://nodejs.org/",
    "winget": "OpenJS.NodeJS.LTS"
  },
  "WPFInstallnomacs": {
    "category": "Multimedia Tools",
    "choco": "nomacs",
    "content": "Nomacs (Image viewer)",
    "description": "Nomacs is a free, open-source image viewer that supports multiple platforms. It features basic image editing capabilities and supports a variety of image formats.",
    "link": "https://nomacs.org/",
    "winget": "nomacs.nomacs"
  },
  "WPFInstallnotepadplus": {
    "category": "Document",
    "choco": "notepadplusplus",
    "content": "Notepad++",
    "description": "Notepad++ is a free, open-source code editor and Notepad replacement with support for multiple languages.",
    "link": "https://notepad-plus-plus.org/",
    "winget": "Notepad++.Notepad++"
  },
  "WPFInstallnuget": {
    "category": "Microsoft Tools",
    "choco": "nuget.commandline",
    "content": "NuGet",
    "description": "NuGet is a package manager for the .NET framework, enabling developers to manage and share libraries in their .NET applications.",
    "link": "https://www.nuget.org/",
    "winget": "Microsoft.NuGet"
  },
  "WPFInstallnushell": {
    "category": "Utilities",
    "choco": "nushell",
    "content": "Nushell",
    "description": "Nushell is a new shell that takes advantage of modern hardware and systems to provide a powerful, expressive, and fast experience.",
    "link": "https://www.nushell.sh/",
    "winget": "Nushell.Nushell"
  },
  "WPFInstallnvclean": {
    "category": "Utilities",
    "choco": "na",
    "content": "NVCleanstall",
    "description": "NVCleanstall is a tool designed to customize NVIDIA driver installations, allowing advanced users to control more aspects of the installation process.",
    "link": "https://www.techpowerup.com/nvcleanstall/",
    "winget": "TechPowerUp.NVCleanstall"
  },
  "WPFInstallnvm": {
    "category": "Development",
    "choco": "nvm",
    "content": "Node Version Manager",
    "description": "Node Version Manager (NVM) for Windows allows you to easily switch between multiple Node.js versions.",
    "link": "https://github.com/coreybutler/nvm-windows",
    "winget": "CoreyButler.NVMforWindows"
  },
  "WPFInstallobs": {
    "category": "Multimedia Tools",
    "choco": "obs-studio",
    "content": "OBS Studio",
    "description": "OBS Studio is a free and open-source software for video recording and live streaming. It supports real-time video/audio capturing and mixing, making it popular among content creators.",
    "link": "https://obsproject.com/",
    "winget": "OBSProject.OBSStudio"
  },
  "WPFInstallobsidian": {
    "category": "Document",
    "choco": "obsidian",
    "content": "Obsidian",
    "description": "Obsidian is a powerful note-taking and knowledge management application.",
    "link": "https://obsidian.md/",
    "winget": "Obsidian.Obsidian"
  },
  "WPFInstallokular": {
    "category": "Document",
    "choco": "okular",
    "content": "Okular",
    "description": "Okular is a versatile document viewer with advanced features.",
    "link": "https://okular.kde.org/",
    "winget": "KDE.Okular"
  },
  "WPFInstallonedrive": {
    "category": "Microsoft Tools",
    "choco": "onedrive",
    "content": "OneDrive",
    "description": "OneDrive is a cloud storage service provided by Microsoft, allowing users to store and share files securely across devices.",
    "link": "https://onedrive.live.com/",
    "winget": "Microsoft.OneDrive"
  },
  "WPFInstallonlyoffice": {
    "category": "Document",
    "choco": "onlyoffice",
    "content": "ONLYOffice Desktop",
    "description": "ONLYOffice Desktop is a comprehensive office suite for document editing and collaboration.",
    "link": "https://www.onlyoffice.com/desktop.aspx",
    "winget": "ONLYOFFICE.DesktopEditors"
  },
  "WPFInstallOPAutoClicker": {
    "category": "Utilities",
    "choco": "autoclicker",
    "content": "OPAutoClicker",
    "description": "A full-fledged autoclicker with two modes of autoclicking, at your dynamic cursor location or at a prespecified location.",
    "link": "https://www.opautoclicker.com",
    "winget": "OPAutoClicker.OPAutoClicker"
  },
  "WPFInstallopenhashtab": {
    "category": "Utilities",
    "choco": "openhashtab",
    "content": "OpenHashTab",
    "description": "OpenHashTab is a shell extension for conveniently calculating and checking file hashes from file properties.",
    "link": "https://github.com/namazso/OpenHashTab/",
    "winget": "namazso.OpenHashTab"
  },
  "WPFInstallopenoffice": {
    "category": "Document",
    "choco": "openoffice",
    "content": "Apache OpenOffice",
    "description": "Apache OpenOffice is an open-source office software suite for word processing, spreadsheets, presentations, and more.",
    "link": "https://www.openoffice.org/",
    "winget": "Apache.OpenOffice"
  },
  "WPFInstallopenrgb": {
    "category": "Utilities",
    "choco": "openrgb",
    "content": "OpenRGB",
    "description": "OpenRGB is an open-source RGB lighting control software designed to manage and control RGB lighting for various components and peripherals.",
    "link": "https://openrgb.org/",
    "winget": "CalcProgrammer1.OpenRGB"
  },
  "WPFInstallopenscad": {
    "category": "Multimedia Tools",
    "choco": "openscad",
    "content": "OpenSCAD",
    "description": "OpenSCAD is a free and open-source script-based 3D CAD modeler. It is especially useful for creating parametric designs for 3D printing.",
    "link": "https://www.openscad.org/",
    "winget": "OpenSCAD.OpenSCAD"
  },
  "WPFInstallopenshell": {
    "category": "Utilities",
    "choco": "open-shell",
    "content": "Open Shell (Start Menu)",
    "description": "Open Shell is a Windows Start Menu replacement with enhanced functionality and customization options.",
    "link": "https://github.com/Open-Shell/Open-Shell-Menu",
    "winget": "Open-Shell.Open-Shell-Menu"
  },
  "WPFInstallOpenVPN": {
    "category": "Pro Tools",
    "choco": "openvpn-connect",
    "content": "OpenVPN Connect",
    "description": "OpenVPN Connect is an open-source VPN client that allows you to connect securely to a VPN server. It provides a secure and encrypted connection for protecting your online privacy.",
    "link": "https://openvpn.net/",
    "winget": "OpenVPNTechnologies.OpenVPNConnect"
  },
  "WPFInstallOVirtualBox": {
    "category": "Utilities",
    "choco": "virtualbox",
    "content": "Oracle VirtualBox",
    "description": "Oracle VirtualBox is a powerful and free open-source virtualization tool for x86 and AMD64/Intel64 architectures.",
    "link": "https://www.virtualbox.org/",
    "winget": "Oracle.VirtualBox"
  },
  "WPFInstallownclouddesktop": {
    "category": "Utilities",
    "choco": "owncloud-client",
    "content": "ownCloud Desktop",
    "description": "ownCloud Desktop is the official desktop client for the ownCloud file synchronization and sharing platform.",
    "link": "https://owncloud.com/desktop-app/",
    "winget": "ownCloud.ownCloudDesktop"
  },
  "WPFInstallPaintdotnet": {
    "category": "Multimedia Tools",
    "choco": "paint.net",
    "content": "Paint.NET",
    "description": "Paint.NET is a free image and photo editing software for Windows. It features an intuitive user interface and supports a wide range of powerful editing tools.",
    "link": "https://www.getpaint.net/",
    "winget": "dotPDN.PaintDotNet"
  },
  "WPFInstallparsec": {
    "category": "Utilities",
    "choco": "parsec",
    "content": "Parsec",
    "description": "Parsec is a low-latency, high-quality remote desktop sharing application for collaborating and gaming across devices.",
    "link": "https://parsec.app/",
    "winget": "Parsec.Parsec"
  },
  "WPFInstallpdf24creator": {
    "category": "Document",
    "choco": "pdf24",
    "content": "PDF24 creator",
    "description": "Free and easy-to-use online/desktop PDF tools that make you more productive",
    "link": "https://tools.pdf24.org/en/",
    "winget": "geeksoftwareGmbH.PDF24Creator"
  },
  "WPFInstallpdfsam": {
    "category": "Document",
    "choco": "pdfsam",
    "content": "PDFsam Basic",
    "description": "PDFsam Basic is a free and open-source tool for splitting, merging, and rotating PDF files.",
    "link": "https://pdfsam.org/",
    "winget": "PDFsam.PDFsam"
  },
  "WPFInstallpeazip": {
    "category": "Utilities",
    "choco": "peazip",
    "content": "PeaZip",
    "description": "PeaZip is a free, open-source file archiver utility that supports multiple archive formats and provides encryption features.",
    "link": "https://peazip.github.io/",
    "winget": "Giorgiotani.Peazip"
  },
  "WPFInstallpiimager": {
    "category": "Utilities",
    "choco": "rpi-imager",
    "content": "Raspberry Pi Imager",
    "description": "Raspberry Pi Imager is a utility for writing operating system images to SD cards for Raspberry Pi devices.",
    "link": "https://www.raspberrypi.com/software/",
    "winget": "RaspberryPiFoundation.RaspberryPiImager"
  },
  "WPFInstallplaynite": {
    "category": "Games",
    "choco": "playnite",
    "content": "Playnite",
    "description": "Playnite is an open-source video game library manager with one simple goal: To provide a unified interface for all of your games.",
    "link": "https://playnite.link/",
    "winget": "Playnite.Playnite"
  },
  "WPFInstallplex": {
    "category": "Multimedia Tools",
    "choco": "plexmediaserver",
    "content": "Plex Media Server",
    "description": "Plex Media Server is a media server software that allows you to organize and stream your media library. It supports various media formats and offers a wide range of features.",
    "link": "https://www.plex.tv/your-media/",
    "winget": "Plex.PlexMediaServer"
  },
  "WPFInstallplexdesktop": {
    "category": "Multimedia Tools",
    "choco": "plex",
    "content": "Plex Desktop",
    "description": "Plex Desktop for Windows is the front end for Plex Media Server.",
    "link": "https://www.plex.tv",
    "winget": "Plex.Plex"
  },
  "WPFInstallPortmaster": {
    "category": "Pro Tools",
    "choco": "portmaster",
    "content": "Portmaster",
    "description": "Portmaster is a free and open-source application that puts you back in charge over all your computers network connections.",
    "link": "https://safing.io/",
    "winget": "Safing.Portmaster"
  },
  "WPFInstallposh": {
    "category": "Development",
    "choco": "oh-my-posh",
    "content": "Oh My Posh (Prompt)",
    "description": "Oh My Posh is a cross-platform prompt theme engine for any shell.",
    "link": "https://ohmyposh.dev/",
    "winget": "JanDeDobbeleer.OhMyPosh"
  },
  "WPFInstallpostman": {
    "category": "Development",
    "choco": "postman",
    "content": "Postman",
    "description": "Postman is a collaboration platform for API development that simplifies the process of developing APIs.",
    "link": "https://www.postman.com/",
    "winget": "Postman.Postman"
  },
  "WPFInstallpowerautomate": {
    "category": "Microsoft Tools",
    "choco": "powerautomatedesktop",
    "content": "Power Automate",
    "description": "Using Power Automate Desktop you can automate tasks on the desktop as well as the Web.",
    "link": "https://www.microsoft.com/en-us/power-platform/products/power-automate",
    "winget": "Microsoft.PowerAutomateDesktop"
  },
  "WPFInstallpowerbi": {
    "category": "Microsoft Tools",
    "choco": "powerbi",
    "content": "Power BI",
    "description": "Create stunning reports and visualizations with Power BI Desktop. It puts visual analytics at your fingertips with intuitive report authoring. Drag-and-drop to place content exactly where you want it on the flexible and fluid canvas. Quickly discover patterns as you explore a single unified view of linked, interactive visualizations.",
    "link": "https://www.microsoft.com/en-us/power-platform/products/power-bi/",
    "winget": "Microsoft.PowerBI"
  },
  "WPFInstallpowershell": {
    "category": "Microsoft Tools",
    "choco": "powershell-core",
    "content": "PowerShell",
    "description": "PowerShell is a task automation framework and scripting language designed for system administrators, offering powerful command-line capabilities.",
    "link": "https://github.com/PowerShell/PowerShell",
    "winget": "Microsoft.PowerShell"
  },
  "WPFInstallpowertoys": {
    "category": "Microsoft Tools",
    "choco": "powertoys",
    "content": "PowerToys",
    "description": "PowerToys is a set of utilities for power users to enhance productivity, featuring tools like FancyZones, PowerRename, and more.",
    "link": "https://github.com/microsoft/PowerToys",
    "winget": "Microsoft.PowerToys"
  },
  "WPFInstallprismlauncher": {
    "category": "Games",
    "choco": "prismlauncher",
    "content": "Prism Launcher",
    "description": "Prism Launcher is a game launcher and manager designed to provide a clean and intuitive interface for organizing and launching your games.",
    "link": "https://prismlauncher.org/",
    "winget": "PrismLauncher.PrismLauncher"
  },
  "WPFInstallprocesslasso": {
    "category": "Utilities",
    "choco": "plasso",
    "content": "Process Lasso",
    "description": "Process Lasso is a system optimization and automation tool that improves system responsiveness and stability by adjusting process priorities and CPU affinities.",
    "link": "https://bitsum.com/",
    "winget": "BitSum.ProcessLasso"
  },
  "WPFInstallspotify": {
    "category": "Multimedia Tools",
    "choco": "spotify",
    "content": "Spotify",
    "description": "Spotify is a digital music service that gives you access to millions of songs, podcasts, and videos from artists all over the world.",
    "link": "https://www.spotify.com/",
    "winget": "Spotify.Spotify"
  },
  "WPFInstallprocessmonitor": {
    "category": "Microsoft Tools",
    "choco": "procexp",
    "content": "SysInternals Process Monitor",
    "description": "SysInternals Process Monitor is an advanced monitoring tool that shows real-time file system, registry, and process/thread activity.",
    "link": "https://docs.microsoft.com/en-us/sysinternals/downloads/procmon",
    "winget": "Microsoft.Sysinternals.ProcessMonitor"
  },
  "WPFInstallorcaslicer": {
    "category": "Utilities",
    "choco": "orcaslicer",
    "content": "OrcaSlicer",
    "description": "G-code generator for 3D printers (Bambu, Prusa, Voron, VzBot, RatRig, Creality, etc.)",
    "link": "https://github.com/SoftFever/OrcaSlicer",
    "winget": "SoftFever.OrcaSlicer"
  },
  "WPFInstallprucaslicer": {
    "category": "Utilities",
    "choco": "prusaslicer",
    "content": "PrusaSlicer",
    "description": "PrusaSlicer is a powerful and easy-to-use slicing software for 3D printing with Prusa 3D printers.",
    "link": "https://www.prusa3d.com/prusaslicer/",
    "winget": "Prusa3d.PrusaSlicer"
  },
  "WPFInstallpsremoteplay": {
    "category": "Games",
    "choco": "ps-remote-play",
    "content": "PS Remote Play",
    "description": "PS Remote Play is a free application that allows you to stream games from your PlayStation console to a PC or mobile device.",
    "link": "https://remoteplay.dl.playstation.net/remoteplay/lang/gb/",
    "winget": "PlayStation.PSRemotePlay"
  },
  "WPFInstallputty": {
    "category": "Pro Tools",
    "choco": "putty",
    "content": "PuTTY",
    "description": "PuTTY is a free and open-source terminal emulator, serial console, and network file transfer application. It supports various network protocols such as SSH, Telnet, and SCP.",
    "link": "https://www.chiark.greenend.org.uk/~sgtatham/putty/",
    "winget": "PuTTY.PuTTY"
  },
  "WPFInstallpython3": {
    "category": "Development",
    "choco": "python",
    "content": "Python3",
    "description": "Python is a versatile programming language used for web development, data analysis, artificial intelligence, and more.",
    "link": "https://www.python.org/",
    "winget": "Python.Python.3.12"
  },
  "WPFInstallqbittorrent": {
    "category": "Utilities",
    "choco": "qbittorrent",
    "content": "qBittorrent",
    "description": "qBittorrent is a free and open-source BitTorrent client that aims to provide a feature-rich and lightweight alternative to other torrent clients.",
    "link": "https://www.qbittorrent.org/",
    "winget": "qBittorrent.qBittorrent"
  },
  "WPFInstalltransmission": {
    "category": "Utilities",
    "choco": "transmission",
    "content": "Transmission",
    "description": "Transmission is a cross-platform BitTorrent client that is open source, easy, powerful, and lean.",
    "link": "https://transmissionbt.com/",
    "winget": "Transmission.Transmission"
  },
  "WPFInstalltixati": {
    "category": "Utilities",
    "choco": "tixati.portable",
    "content": "Tixati",
    "description": "Tixati is a cross-platform BitTorrent client written in C++ that has been designed to be light on system resources.",
    "link": "https://www.tixati.com/",
    "winget": "Tixati.Tixati.Portable"
  },
  "WPFInstallqtox": {
    "category": "Communications",
    "choco": "qtox",
    "content": "QTox",
    "description": "QTox is a free and open-source messaging app that prioritizes user privacy and security in its design.",
    "link": "https://qtox.github.io/",
    "winget": "Tox.qTox"
  },
  "WPFInstallquicklook": {
    "category": "Utilities",
    "choco": "quicklook",
    "content": "Quicklook",
    "description": "Bring macOS ?Quick Look? feature to Windows",
    "link": "https://github.com/QL-Win/QuickLook",
    "winget": "QL-Win.QuickLook"
  },
  "WPFInstallrainmeter": {
    "category": "Utilities",
    "choco": "na",
    "content": "Rainmeter",
    "description": "Rainmeter is a desktop customization tool that allows you to create and share customizable skins for your desktop.",
    "link": "https://www.rainmeter.net/",
    "winget": "Rainmeter.Rainmeter"
  },
  "WPFInstallrevo": {
    "category": "Utilities",
    "choco": "revo-uninstaller",
    "content": "Revo Uninstaller",
    "description": "Revo Uninstaller is an advanced uninstaller tool that helps you remove unwanted software and clean up your system.",
    "link": "https://www.revouninstaller.com/",
    "winget": "RevoUninstaller.RevoUninstaller"
  },
  "WPFInstallWiseProgramUninstaller": {
    "category": "Utilities",
    "choco": "na",
    "content": "Wise Program Uninstaller (WiseCleaner)",
    "description": "Wise Program Uninstaller is the perfect solution for uninstalling Windows programs, allowing you to uninstall applications quickly and completely using its simple and user-friendly interface.",
    "link": "https://www.wisecleaner.com/wise-program-uninstaller.html",
    "winget": "WiseCleaner.WiseProgramUninstaller"
  },
  "WPFInstallrevolt": {
    "category": "Communications",
    "choco": "na",
    "content": "Revolt",
    "description": "Find your community, connect with the world. Revolt is one of the best ways to stay connected with your friends and community without sacrificing any usability.",
    "link": "https://revolt.chat/",
    "winget": "Revolt.RevoltDesktop"
  },
  "WPFInstallripgrep": {
    "category": "Utilities",
    "choco": "ripgrep",
    "content": "Ripgrep",
    "description": "Fast and powerful commandline search tool",
    "link": "https://github.com/BurntSushi/ripgrep/",
    "winget": "BurntSushi.ripgrep.MSVC"
  },
  "WPFInstallrufus": {
    "category": "Utilities",
    "choco": "rufus",
    "content": "Rufus Imager",
    "description": "Rufus is a utility that helps format and create bootable USB drives, such as USB keys or pen drives.",
    "link": "https://rufus.ie/",
    "winget": "Rufus.Rufus"
  },
  "WPFInstallrustdesk": {
    "category": "Pro Tools",
    "choco": "rustdesk.portable",
    "content": "RustDesk",
    "description": "RustDesk is a free and open-source remote desktop application. It provides a secure way to connect to remote machines and access desktop environments.",
    "link": "https://rustdesk.com/",
    "winget": "RustDesk.RustDesk"
  },
  "WPFInstallrustlang": {
    "category": "Development",
    "choco": "rust",
    "content": "Rust",
    "description": "Rust is a programming language designed for safety and performance, particularly focused on systems programming.",
    "link": "https://www.rust-lang.org/",
    "winget": "Rustlang.Rust.MSVC"
  },
  "WPFInstallsagethumbs": {
    "category": "Utilities",
    "choco": "sagethumbs",
    "content": "SageThumbs",
    "description": "Provides support for thumbnails in Explorer with more formats.",
    "link": "https://sagethumbs.en.lo4d.com/windows",
    "winget": "CherubicSoftware.SageThumbs"
  },
  "WPFInstallsamsungmagician": {
    "category": "Utilities",
    "choco": "samsung-magician",
    "content": "Samsung Magician",
    "description": "Samsung Magician is a utility for managing and optimizing Samsung SSDs.",
    "link": "https://semiconductor.samsung.com/consumer-storage/magician/",
    "winget": "Samsung.SamsungMagician"
  },
  "WPFInstallsandboxie": {
    "category": "Utilities",
    "choco": "sandboxie",
    "content": "Sandboxie Plus",
    "description": "Sandboxie Plus is a sandbox-based isolation program that provides enhanced security by running applications in an isolated environment.",
    "link": "https://github.com/sandboxie-plus/Sandboxie",
    "winget": "Sandboxie.Plus"
  },
  "WPFInstallsdio": {
    "category": "Utilities",
    "choco": "sdio",
    "content": "Snappy Driver Installer Origin",
    "description": "Snappy Driver Installer Origin is a free and open-source driver updater with a vast driver database for Windows.",
    "link": "https://www.glenn.delahoy.com/snappy-driver-installer-origin/",
    "winget": "GlennDelahoy.SnappyDriverInstallerOrigin"
  },
  "WPFInstallsession": {
    "category": "Communications",
    "choco": "session",
    "content": "Session",
    "description": "Session is a private and secure messaging app built on a decentralized network for user privacy and data protection.",
    "link": "https://getsession.org/",
    "winget": "Oxen.Session"
  },
  "WPFInstallsharex": {
    "category": "Multimedia Tools",
    "choco": "sharex",
    "content": "ShareX (Screenshots)",
    "description": "ShareX is a free and open-source screen capture and file sharing tool. It supports various capture methods and offers advanced features for editing and sharing screenshots.",
    "link": "https://getsharex.com/",
    "winget": "ShareX.ShareX"
  },
  "WPFInstallnilesoftShell": {
    "category": "Utilities",
    "choco": "nilesoft-shell",
    "content": "Nilesoft Shell",
    "description": "Shell is an expanded context menu tool that adds extra functionality and customization options to the Windows context menu.",
    "link": "https://nilesoft.org/",
    "winget": "Nilesoft.Shell"
  },
  "WPFInstallsidequest": {
    "category": "Games",
    "choco": "sidequest",
    "content": "SideQuestVR",
    "description": "SideQuestVR is a community-driven platform that enables users to discover, install, and manage virtual reality content on Oculus Quest devices.",
    "link": "https://sidequestvr.com/",
    "winget": "SideQuestVR.SideQuest"
  },
  "WPFInstallsignal": {
    "category": "Communications",
    "choco": "signal",
    "content": "Signal",
    "description": "Signal is a privacy-focused messaging app that offers end-to-end encryption for secure and private communication.",
    "link": "https://signal.org/",
    "winget": "OpenWhisperSystems.Signal"
  },
  "WPFInstallsignalrgb": {
    "category": "Utilities",
    "choco": "na",
    "content": "SignalRGB",
    "description": "SignalRGB lets you control and sync your favorite RGB devices with one free application.",
    "link": "https://www.signalrgb.com/",
    "winget": "WhirlwindFX.SignalRgb"
  },
  "WPFInstallsimplenote": {
    "category": "Document",
    "choco": "simplenote",
    "content": "simplenote",
    "description": "Simplenote is an easy way to keep notes, lists, ideas and more.",
    "link": "https://simplenote.com/",
    "winget": "Automattic.Simplenote"
  },
  "WPFInstallsimplewall": {
    "category": "Pro Tools",
    "choco": "simplewall",
    "content": "Simplewall",
    "description": "Simplewall is a free and open-source firewall application for Windows. It allows users to control and manage the inbound and outbound network traffic of applications.",
    "link": "https://github.com/henrypp/simplewall",
    "winget": "Henry++.simplewall"
  },
  "WPFInstallskype": {
    "category": "Communications",
    "choco": "skype",
    "content": "Skype",
    "description": "Skype is a widely used communication platform offering video calls, voice calls, and instant messaging services.",
    "link": "https://www.skype.com/",
    "winget": "Microsoft.Skype"
  },
  "WPFInstallslack": {
    "category": "Communications",
    "choco": "slack",
    "content": "Slack",
    "description": "Slack is a collaboration hub that connects teams and facilitates communication through channels, messaging, and file sharing.",
    "link": "https://slack.com/",
    "winget": "SlackTechnologies.Slack"
  },
  "WPFInstallspacedrive": {
    "category": "Utilities",
    "choco": "na",
    "content": "Spacedrive File Manager",
    "description": "Spacedrive is a file manager that offers cloud storage integration and file synchronization across devices.",
    "link": "https://www.spacedrive.com/",
    "winget": "spacedrive.Spacedrive"
  },
  "WPFInstallspacesniffer": {
    "category": "Utilities",
    "choco": "spacesniffer",
    "content": "SpaceSniffer",
    "description": "A tool application that lets you understand how folders and files are structured on your disks",
    "link": "http://www.uderzo.it/main_products/space_sniffer/",
    "winget": "UderzoSoftware.SpaceSniffer"
  },
  "WPFInstallspotube": {
    "category": "Multimedia Tools",
    "choco": "spotube",
    "content": "Spotube",
    "description": "Open source Spotify client that doesn't require Premium nor uses Electron! Available for both desktop & mobile! ",
    "link": "https://github.com/KRTirtho/spotube",
    "winget": "KRTirtho.Spotube"
  },
  "WPFInstallstarship": {
    "category": "Development",
    "choco": "starship",
    "content": "Starship (Shell Prompt)",
    "description": "Starship is a minimal, fast, and customizable prompt for any shell.",
    "link": "https://starship.rs/",
    "winget": "starship"
  },
  "WPFInstallsteam": {
    "category": "Games",
    "choco": "steam-client",
    "content": "Steam",
    "description": "Steam is a digital distribution platform for purchasing and playing video games, offering multiplayer gaming, video streaming, and more.",
    "link": "https://store.steampowered.com/about/",
    "winget": "Valve.Steam"
  },
  "WPFInstallstrawberry": {
    "category": "Multimedia Tools",
    "choco": "strawberrymusicplayer",
    "content": "Strawberry (Music Player)",
    "description": "Strawberry is an open-source music player that focuses on music collection management and audio quality. It supports various audio formats and features a clean user interface.",
    "link": "https://www.strawberrymusicplayer.org/",
    "winget": "StrawberryMusicPlayer.Strawberry"
  },
  "WPFInstallstremio": {
    "winget": "Stremio.Stremio",
    "choco": "stremio",
    "category": "Multimedia Tools",
    "content": "Stremio",
    "link": "https://www.stremio.com/",
    "description": "Stremio is a media center application that allows users to organize and stream their favorite movies, TV shows, and video content."
  },
  "WPFInstallsublimemerge": {
    "category": "Development",
    "choco": "sublimemerge",
    "content": "Sublime Merge",
    "description": "Sublime Merge is a Git client with advanced features and a beautiful interface.",
    "link": "https://www.sublimemerge.com/",
    "winget": "SublimeHQ.SublimeMerge"
  },
  "WPFInstallsublimetext": {
    "category": "Development",
    "choco": "sublimetext4",
    "content": "Sublime Text",
    "description": "Sublime Text is a sophisticated text editor for code, markup, and prose.",
    "link": "https://www.sublimetext.com/",
    "winget": "SublimeHQ.SublimeText.4"
  },
  "WPFInstallsumatra": {
    "category": "Document",
    "choco": "sumatrapdf",
    "content": "Sumatra PDF",
    "description": "Sumatra PDF is a lightweight and fast PDF viewer with minimalistic design.",
    "link": "https://www.sumatrapdfreader.org/free-pdf-reader.html",
    "winget": "SumatraPDF.SumatraPDF"
  },
  "WPFInstallpdfgear": {
    "category": "Document",
    "choco": "na",
    "content": "PDFgear",
    "description": "PDFgear is a piece of full-featured PDF management software for Windows, Mac, and mobile, and it's completely free to use.",
    "link": "https://www.pdfgear.com/",
    "winget": "PDFgear.PDFgear"
  },
  "WPFInstallsunshine": {
    "category": "Games",
    "choco": "sunshine",
    "content": "Sunshine/GameStream Server",
    "description": "Sunshine is a GameStream server that allows you to remotely play PC games on Android devices, offering low-latency streaming.",
    "link": "https://github.com/LizardByte/Sunshine",
    "winget": "LizardByte.Sunshine"
  },
  "WPFInstallsuperf4": {
    "category": "Utilities",
    "choco": "superf4",
    "content": "SuperF4",
    "description": "SuperF4 is a utility that allows you to terminate programs instantly by pressing a customizable hotkey.",
    "link": "https://stefansundin.github.io/superf4/",
    "winget": "StefanSundin.Superf4"
  },
  "WPFInstallswift": {
    "category": "Development",
    "choco": "na",
    "content": "Swift toolchain",
    "description": "Swift is a general-purpose programming language that's approachable for newcomers and powerful for experts.",
    "link": "https://www.swift.org/",
    "winget": "Swift.Toolchain"
  },
  "WPFInstallsynctrayzor": {
    "category": "Utilities",
    "choco": "synctrayzor",
    "content": "SyncTrayzor",
    "description": "Windows tray utility / filesystem watcher / launcher for Syncthing",
    "link": "https://github.com/canton7/SyncTrayzor/",
    "winget": "SyncTrayzor.SyncTrayzor"
  },
  "WPFInstallsqlmanagementstudio": {
    "category": "Microsoft Tools",
    "choco": "sql-server-management-studio",
    "content": "Microsoft SQL Server Management Studio",
    "description": "SQL Server Management Studio (SSMS) is an integrated environment for managing any SQL infrastructure, from SQL Server to Azure SQL Database. SSMS provides tools to configure, monitor, and administer instances of SQL Server and databases.",
    "link": "https://learn.microsoft.com/en-us/sql/ssms/download-sql-server-management-studio-ssms?view=sql-server-ver16",
    "winget": "Microsoft.SQLServerManagementStudio"
  },
  "WPFInstalltabby": {
    "category": "Utilities",
    "choco": "tabby",
    "content": "Tabby.sh",
    "description": "Tabby is a highly configurable terminal emulator, SSH and serial client for Windows, macOS and Linux",
    "link": "https://tabby.sh/",
    "winget": "Eugeny.Tabby"
  },
  "WPFInstalltailscale": {
    "category": "Utilities",
    "choco": "tailscale",
    "content": "Tailscale",
    "description": "Tailscale is a secure and easy-to-use VPN solution for connecting your devices and networks.",
    "link": "https://tailscale.com/",
    "winget": "tailscale.tailscale"
  },
  "WPFInstallTcNoAccSwitcher": {
    "category": "Games",
    "choco": "tcno-acc-switcher",
    "content": "TCNO Account Switcher",
    "description": "A Super-fast account switcher for Steam, Battle.net, Epic Games, Origin, Riot, Ubisoft and many others!",
    "link": "https://github.com/TCNOco/TcNo-Acc-Switcher",
    "winget": "TechNobo.TcNoAccountSwitcher"
  },
  "WPFInstalltcpview": {
    "category": "Microsoft Tools",
    "choco": "tcpview",
    "content": "SysInternals TCPView",
    "description": "SysInternals TCPView is a network monitoring tool that displays a detailed list of all TCP and UDP endpoints on your system.",
    "link": "https://docs.microsoft.com/en-us/sysinternals/downloads/tcpview",
    "winget": "Microsoft.Sysinternals.TCPView"
  },
  "WPFInstallteams": {
    "category": "Communications",
    "choco": "microsoft-teams",
    "content": "Teams",
    "description": "Microsoft Teams is a collaboration platform that integrates with Office 365 and offers chat, video conferencing, file sharing, and more.",
    "link": "https://www.microsoft.com/en-us/microsoft-teams/group-chat-software",
    "winget": "Microsoft.Teams"
  },
  "WPFInstallteamviewer": {
    "category": "Utilities",
    "choco": "teamviewer9",
    "content": "TeamViewer",
    "description": "TeamViewer is a popular remote access and support software that allows you to connect to and control remote devices.",
    "link": "https://www.teamviewer.com/",
    "winget": "TeamViewer.TeamViewer"
  },
  "WPFInstalltelegram": {
    "category": "Communications",
    "choco": "telegram",
    "content": "Telegram",
    "description": "Telegram is a cloud-based instant messaging app known for its security features, speed, and simplicity.",
    "link": "https://telegram.org/",
    "winget": "Telegram.TelegramDesktop"
  },
  "WPFInstallunigram": {
    "category": "Communications",
    "choco": "na",
    "content": "Unigram",
    "description": "Unigram - Telegram for Windows",
    "link": "https://unigramdev.github.io/",
    "winget": "Telegram.Unigram"
  },
  "WPFInstallterminal": {
    "category": "Microsoft Tools",
    "choco": "microsoft-windows-terminal",
    "content": "Windows Terminal",
    "description": "Windows Terminal is a modern, fast, and efficient terminal application for command-line users, supporting multiple tabs, panes, and more.",
    "link": "https://aka.ms/terminal",
    "winget": "Microsoft.WindowsTerminal"
  },
  "WPFInstallThonny": {
    "category": "Development",
    "choco": "thonny",
    "content": "Thonny Python IDE",
    "description": "Python IDE for beginners.",
    "link": "https://github.com/thonny/thonny",
    "winget": "AivarAnnamaa.Thonny"
  },
  "WPFInstallMuEditor": {
    "category": "Development",
    "choco": "na",
    "content": "Code With Mu (Mu Editor)",
    "description": "Mu is a Python code editor for beginner programmers",
    "link": "https://codewith.mu/",
    "winget": "Mu.Mu"
  },
  "WPFInstallthorium": {
    "category": "Browsers",
    "choco": "na",
    "content": "Thorium Browser AVX2",
    "description": "Browser built for speed over vanilla chromium. It is built with AVX2 optimizations and is the fastest browser on the market.",
    "link": "https://thorium.rocks/",
    "winget": "Alex313031.Thorium.AVX2"
  },
  "WPFInstallthunderbird": {
    "category": "Communications",
    "choco": "thunderbird",
    "content": "Thunderbird",
    "description": "Mozilla Thunderbird is a free and open-source email client, news client, and chat client with advanced features.",
    "link": "https://www.thunderbird.net/",
    "winget": "Mozilla.Thunderbird"
  },
  "WPFInstallbetterbird": {
    "category": "Communications",
    "choco": "betterbird",
    "content": "Betterbird",
    "description": "Betterbird is a fork of Mozilla Thunderbird with additional features and bugfixes.",
    "link": "https://www.betterbird.eu/",
    "winget": "Betterbird.Betterbird"
  },
  "WPFInstalltidal": {
    "category": "Multimedia Tools",
    "choco": "na",
    "content": "Tidal",
    "description": "Tidal is a music streaming service known for its high-fidelity audio quality and exclusive content. It offers a vast library of songs and curated playlists.",
    "link": "https://tidal.com/",
    "winget": "9NNCB5BS59PH"
  },
  "WPFInstalltor": {
    "category": "Browsers",
    "choco": "tor-browser",
    "content": "Tor Browser",
    "description": "Tor Browser is designed for anonymous web browsing, utilizing the Tor network to protect user privacy and security.",
    "link": "https://www.torproject.org/",
    "winget": "TorProject.TorBrowser"
  },
  "WPFInstalltotalcommander": {
    "category": "Utilities",
    "choco": "TotalCommander",
    "content": "Total Commander",
    "description": "Total Commander is a file manager for Windows that provides a powerful and intuitive interface for file management.",
    "link": "https://www.ghisler.com/",
    "winget": "Ghisler.TotalCommander"
  },
  "WPFInstalltreesize": {
    "category": "Utilities",
    "choco": "treesizefree",
    "content": "TreeSize Free",
    "description": "TreeSize Free is a disk space manager that helps you analyze and visualize the space usage on your drives.",
    "link": "https://www.jam-software.com/treesize_free/",
    "winget": "JAMSoftware.TreeSize.Free"
  },
  "WPFInstallttaskbar": {
    "category": "Utilities",
    "choco": "translucenttb",
    "content": "Translucent Taskbar",
    "description": "Translucent Taskbar is a tool that allows you to customize the transparency of the Windows taskbar.",
    "link": "https://github.com/TranslucentTB/TranslucentTB",
    "winget": "9PF4KZ2VN4W9"
  },
  "WPFInstalltwinkletray": {
    "category": "Utilities",
    "choco": "twinkle-tray",
    "content": "Twinkle Tray",
    "description": "Twinkle Tray lets you easily manage the brightness levels of multiple monitors.",
    "link": "https://twinkletray.com/",
    "winget": "xanderfrangos.twinkletray"
  },
  "WPFInstallubisoft": {
    "category": "Games",
    "choco": "ubisoft-connect",
    "content": "Ubisoft Connect",
    "description": "Ubisoft Connect is Ubisoft's digital distribution and online gaming service, providing access to Ubisoft's games and services.",
    "link": "https://ubisoftconnect.com/",
    "winget": "Ubisoft.Connect"
  },
  "WPFInstallungoogled": {
    "category": "Browsers",
    "choco": "ungoogled-chromium",
    "content": "Ungoogled",
    "description": "Ungoogled Chromium is a version of Chromium without Google's integration for enhanced privacy and control.",
    "link": "https://github.com/Eloston/ungoogled-chromium",
    "winget": "eloston.ungoogled-chromium"
  },
  "WPFInstallunity": {
    "category": "Development",
    "choco": "unityhub",
    "content": "Unity Game Engine",
    "description": "Unity is a powerful game development platform for creating 2D, 3D, augmented reality, and virtual reality games.",
    "link": "https://unity.com/",
    "winget": "Unity.UnityHub"
  },
  "WPFInstallvagrant": {
    "category": "Development",
    "choco": "vagrant",
    "content": "Vagrant",
    "description": "Vagrant is an open-source tool for building and managing virtualized development environments.",
    "link": "https://www.vagrantup.com/",
    "winget": "Hashicorp.Vagrant"
  },
  "WPFInstallvc2015_32": {
    "category": "Microsoft Tools",
    "choco": "na",
    "content": "Visual C++ 2015-2022 32-bit",
    "description": "Visual C++ 2015-2022 32-bit redistributable package installs runtime components of Visual C++ libraries required to run 32-bit applications.",
    "link": "https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads",
    "winget": "Microsoft.VCRedist.2015+.x86"
  },
  "WPFInstallvc2015_64": {
    "category": "Microsoft Tools",
    "choco": "na",
    "content": "Visual C++ 2015-2022 64-bit",
    "description": "Visual C++ 2015-2022 64-bit redistributable package installs runtime components of Visual C++ libraries required to run 64-bit applications.",
    "link": "https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads",
    "winget": "Microsoft.VCRedist.2015+.x64"
  },
  "WPFInstallventoy": {
    "category": "Pro Tools",
    "choco": "ventoy",
    "content": "Ventoy",
    "description": "Ventoy is an open-source tool for creating bootable USB drives. It supports multiple ISO files on a single USB drive, making it a versatile solution for installing operating systems.",
    "link": "https://www.ventoy.net/",
    "winget": "Ventoy.Ventoy"
  },
  "WPFInstallvesktop": {
    "category": "Communications",
    "choco": "na",
    "content": "Vesktop",
    "description": "A cross platform electron-based desktop app aiming to give you a snappier Discord experience with Vencord pre-installed.",
    "link": "https://github.com/Vencord/Vesktop",
    "winget": "Vencord.Vesktop"
  },
  "WPFInstallviber": {
    "category": "Communications",
    "choco": "viber",
    "content": "Viber",
    "description": "Viber is a free messaging and calling app with features like group chats, video calls, and more.",
    "link": "https://www.viber.com/",
    "winget": "Viber.Viber"
  },
  "WPFInstallvideomass": {
    "category": "Multimedia Tools",
    "choco": "na",
    "content": "Videomass",
    "description": "Videomass by GianlucaPernigotto is a cross-platform GUI for FFmpeg, streamlining multimedia file processing with batch conversions and user-friendly features.",
    "link": "https://jeanslack.github.io/Videomass/",
    "winget": "GianlucaPernigotto.Videomass"
  },
  "WPFInstallvisualstudio": {
    "category": "Development",
    "choco": "visualstudio2022community",
    "content": "Visual Studio 2022",
    "description": "Visual Studio 2022 is an integrated development environment (IDE) for building, debugging, and deploying applications.",
    "link": "https://visualstudio.microsoft.com/",
    "winget": "Microsoft.VisualStudio.2022.Community"
  },
  "WPFInstallvivaldi": {
    "category": "Browsers",
    "choco": "vivaldi",
    "content": "Vivaldi",
    "description": "Vivaldi is a highly customizable web browser with a focus on user personalization and productivity features.",
    "link": "https://vivaldi.com/",
    "winget": "Vivaldi.Vivaldi"
  },
  "WPFInstallvlc": {
    "category": "Multimedia Tools",
    "choco": "vlc",
    "content": "VLC (Video Player)",
    "description": "VLC Media Player is a free and open-source multimedia player that supports a wide range of audio and video formats. It is known for its versatility and cross-platform compatibility.",
    "link": "https://www.videolan.org/vlc/",
    "winget": "VideoLAN.VLC"
  },
  "WPFInstallvoicemeeter": {
    "category": "Multimedia Tools",
    "choco": "voicemeeter",
    "content": "Voicemeeter (Audio)",
    "description": "Voicemeeter is a virtual audio mixer that allows you to manage and enhance audio streams on your computer. It is commonly used for audio recording and streaming purposes.",
    "link": "https://voicemeeter.com/",
    "winget": "VB-Audio.Voicemeeter"
  },
  "WPFInstallVoicemeeterPotato": {
    "category": "Multimedia Tools",
    "choco": "voicemeeter-potato",
    "content": "Voicemeeter Potato",
    "description": "Voicemeeter Potato is the ultimate version of the Voicemeeter Audio Mixer Application endowed with Virtual Audio Device to mix and manage any audio sources from or to any audio devices or applications.",
    "link": "https://voicemeeter.com/",
    "winget": "VB-Audio.Voicemeeter.Potato"
  },
  "WPFInstallvrdesktopstreamer": {
    "category": "Games",
    "choco": "na",
    "content": "Virtual Desktop Streamer",
    "description": "Virtual Desktop Streamer is a tool that allows you to stream your desktop screen to VR devices.",
    "link": "https://www.vrdesktop.net/",
    "winget": "VirtualDesktop.Streamer"
  },
  "WPFInstallvscode": {
    "category": "Development",
    "choco": "vscode",
    "content": "VS Code",
    "description": "Visual Studio Code is a free, open-source code editor with support for multiple programming languages.",
    "link": "https://code.visualstudio.com/",
    "winget": "Microsoft.VisualStudioCode"
  },
  "WPFInstallvscodium": {
    "category": "Development",
    "choco": "vscodium",
    "content": "VS Codium",
    "description": "VSCodium is a community-driven, freely-licensed binary distribution of Microsoft's VS Code.",
    "link": "https://vscodium.com/",
    "winget": "VSCodium.VSCodium"
  },
  "WPFInstallwaterfox": {
    "category": "Browsers",
    "choco": "waterfox",
    "content": "Waterfox",
    "description": "Waterfox is a fast, privacy-focused web browser based on Firefox, designed to preserve user choice and privacy.",
    "link": "https://www.waterfox.net/",
    "winget": "Waterfox.Waterfox"
  },
  "WPFInstallwazuh": {
    "category": "Utilities",
    "choco": "wazuh-agent",
    "content": "Wazuh.",
    "description": "Wazuh is an open-source security monitoring platform that offers intrusion detection, compliance checks, and log analysis.",
    "link": "https://wazuh.com/",
    "winget": "Wazuh.WazuhAgent"
  },
  "WPFInstallwezterm": {
    "category": "Development",
    "choco": "wezterm",
    "content": "Wezterm",
    "description": "WezTerm is a powerful cross-platform terminal emulator and multiplexer",
    "link": "https://wezfurlong.org/wezterm/index.html",
    "winget": "wez.wezterm"
  },
  "WPFInstallwindowspchealth": {
    "category": "Utilities",
    "choco": "na",
    "content": "Windows PC Health Check",
    "description": "Windows PC Health Check is a tool that helps you check if your PC meets the system requirements for Windows 11.",
    "link": "https://support.microsoft.com/en-us/windows/how-to-use-the-pc-health-check-app-9c8abd9b-03ba-4e67-81ef-36f37caa7844",
    "winget": "Microsoft.WindowsPCHealthCheck"
  },
  "WPFInstallWindowGrid": {
    "category": "Utilities",
    "choco": "windowgrid",
    "content": "WindowGrid",
    "description": "WindowGrid is a modern window management program for Windows that allows the user to quickly and easily layout their windows on a dynamic grid using just the mouse.",
    "link": "http://windowgrid.net/",
    "winget": "na"
  },
  "WPFInstallwingetui": {
    "category": "Utilities",
    "choco": "wingetui",
    "content": "UniGetUI",
    "description": "UniGetUI is a GUI for Winget, Chocolatey, and other Windows CLI package managers.",
    "link": "https://www.marticliment.com/wingetui/",
    "winget": "MartiCliment.UniGetUI"
  },
  "WPFInstallwinmerge": {
    "category": "Document",
    "choco": "winmerge",
    "content": "WinMerge",
    "description": "WinMerge is a visual text file and directory comparison tool for Windows.",
    "link": "https://winmerge.org/",
    "winget": "WinMerge.WinMerge"
  },
  "WPFInstallwinpaletter": {
    "category": "Utilities",
    "choco": "WinPaletter",
    "content": "WinPaletter",
    "description": "WinPaletter is a tool for adjusting the color palette of Windows 10, providing customization options for window colors.",
    "link": "https://github.com/Abdelrhman-AK/WinPaletter",
    "winget": "Abdelrhman-AK.WinPaletter"
  },
  "WPFInstallwinrar": {
    "category": "Utilities",
    "choco": "winrar",
    "content": "WinRAR",
    "description": "WinRAR is a powerful archive manager that allows you to create, manage, and extract compressed files.",
    "link": "https://www.win-rar.com/",
    "winget": "RARLab.WinRAR"
  },
  "WPFInstallwinscp": {
    "category": "Pro Tools",
    "choco": "winscp",
    "content": "WinSCP",
    "description": "WinSCP is a popular open-source SFTP, FTP, and SCP client for Windows. It allows secure file transfers between a local and a remote computer.",
    "link": "https://winscp.net/",
    "winget": "WinSCP.WinSCP"
  },
  "WPFInstallwireguard": {
    "category": "Pro Tools",
    "choco": "wireguard",
    "content": "WireGuard",
    "description": "WireGuard is a fast and modern VPN (Virtual Private Network) protocol. It aims to be simpler and more efficient than other VPN protocols, providing secure and reliable connections.",
    "link": "https://www.wireguard.com/",
    "winget": "WireGuard.WireGuard"
  },
  "WPFInstallwireshark": {
    "category": "Pro Tools",
    "choco": "wireshark",
    "content": "Wireshark",
    "description": "Wireshark is a widely-used open-source network protocol analyzer. It allows users to capture and analyze network traffic in real-time, providing detailed insights into network activities.",
    "link": "https://www.wireshark.org/",
    "winget": "WiresharkFoundation.Wireshark"
  },
  "WPFInstallwisetoys": {
    "category": "Utilities",
    "choco": "na",
    "content": "WiseToys",
    "description": "WiseToys is a set of utilities and tools designed to enhance and optimize your Windows experience.",
    "link": "https://toys.wisecleaner.com/",
    "winget": "WiseCleaner.WiseToys"
  },
  "WPFInstallTeraCopy": {
    "category": "Utilities",
    "choco": "TeraCopy",
    "content": "TeraCopy",
    "description": "Copy your files faster and more securely",
    "link": "https://codesector.com/teracopy",
    "winget": "CodeSector.TeraCopy"
  },
  "WPFInstallwizfile": {
    "category": "Utilities",
    "choco": "na",
    "content": "WizFile",
    "description": "Find files by name on your hard drives almost instantly.",
    "link": "https://antibody-software.com/wizfile/",
    "winget": "AntibodySoftware.WizFile"
  },
  "WPFInstallwiztree": {
    "category": "Utilities",
    "choco": "wiztree",
    "content": "WizTree",
    "description": "WizTree is a fast disk space analyzer that helps you quickly find the files and folders consuming the most space on your hard drive.",
    "link": "https://wiztreefree.com/",
    "winget": "AntibodySoftware.WizTree"
  },
  "WPFInstallxdm": {
    "category": "Utilities",
    "choco": "xdm",
    "content": "Xtreme Download Manager",
    "description": "Xtreme Download Manager is an advanced download manager with support for various protocols and browsers.*Browser integration deprecated by google store. No official release.*",
    "link": "https://xtremedownloadmanager.com/",
    "winget": "subhra74.XtremeDownloadManager"
  },
  "WPFInstallxeheditor": {
    "category": "Utilities",
    "choco": "HxD",
    "content": "HxD Hex Editor",
    "description": "HxD is a free hex editor that allows you to edit, view, search, and analyze binary files.",
    "link": "https://mh-nexus.de/en/hxd/",
    "winget": "MHNexus.HxD"
  },
  "WPFInstallxemu": {
    "category": "Games",
    "choco": "na",
    "content": "XEMU",
    "description": "XEMU is an open-source Xbox emulator that allows you to play Xbox games on your PC, aiming for accuracy and compatibility.",
    "link": "https://xemu.app/",
    "winget": "xemu-project.xemu"
  },
  "WPFInstallxnview": {
    "category": "Utilities",
    "choco": "xnview",
    "content": "XnView classic",
    "description": "XnView is an efficient image viewer, browser and converter for Windows.",
    "link": "https://www.xnview.com/en/xnview/",
    "winget": "XnSoft.XnView.Classic"
  },
  "WPFInstallxournal": {
    "category": "Document",
    "choco": "xournalplusplus",
    "content": "Xournal++",
    "description": "Xournal++ is an open-source handwriting notetaking software with PDF annotation capabilities.",
    "link": "https://xournalpp.github.io/",
    "winget": "Xournal++.Xournal++"
  },
  "WPFInstallxpipe": {
    "category": "Pro Tools",
    "choco": "xpipe",
    "content": "XPipe",
    "description": "XPipe is an open-source tool for orchestrating containerized applications. It simplifies the deployment and management of containerized services in a distributed environment.",
    "link": "https://xpipe.io/",
    "winget": "xpipe-io.xpipe"
  },
  "WPFInstallyarn": {
    "category": "Development",
    "choco": "yarn",
    "content": "Yarn",
    "description": "Yarn is a fast, reliable, and secure dependency management tool for JavaScript projects.",
    "link": "https://yarnpkg.com/",
    "winget": "Yarn.Yarn"
  },
  "WPFInstallytdlp": {
    "category": "Multimedia Tools",
    "choco": "yt-dlp",
    "content": "Yt-dlp",
    "description": "Command-line tool that allows you to download videos from YouTube and other supported sites. It is an improved version of the popular youtube-dl.",
    "link": "https://github.com/yt-dlp/yt-dlp",
    "winget": "yt-dlp.yt-dlp"
  },
  "WPFInstallzerotierone": {
    "category": "Utilities",
    "choco": "zerotier-one",
    "content": "ZeroTier One",
    "description": "ZeroTier One is a software-defined networking tool that allows you to create secure and scalable networks.",
    "link": "https://zerotier.com/",
    "winget": "ZeroTier.ZeroTierOne"
  },
  "WPFInstallzim": {
    "category": "Document",
    "choco": "zim",
    "content": "Zim Desktop Wiki",
    "description": "Zim Desktop Wiki is a graphical text editor used to maintain a collection of wiki pages.",
    "link": "https://zim-wiki.org/",
    "winget": "Zimwiki.Zim"
  },
  "WPFInstallznote": {
    "category": "Document",
    "choco": "na",
    "content": "Znote",
    "description": "Znote is a note-taking application.",
    "link": "https://znote.io/",
    "winget": "alagrede.znote"
  },
  "WPFInstallzoom": {
    "category": "Communications",
    "choco": "zoom",
    "content": "Zoom",
    "description": "Zoom is a popular video conferencing and web conferencing service for online meetings, webinars, and collaborative projects.",
    "link": "https://zoom.us/",
    "winget": "Zoom.Zoom"
  },
  "WPFInstallzoomit": {
    "category": "Utilities",
    "choco": "na",
    "content": "ZoomIt",
    "description": "A screen zoom, annotation, and recording tool for technical presentations and demos",
    "link": "https://learn.microsoft.com/en-us/sysinternals/downloads/zoomit",
    "winget": "Microsoft.Sysinternals.ZoomIt"
  },
  "WPFInstallzotero": {
    "category": "Document",
    "choco": "zotero",
    "content": "Zotero",
    "description": "Zotero is a free, easy-to-use tool to help you collect, organize, cite, and share your research materials.",
    "link": "https://www.zotero.org/",
    "winget": "DigitalScholar.Zotero"
  },
  "WPFInstallzoxide": {
    "category": "Utilities",
    "choco": "zoxide",
    "content": "Zoxide",
    "description": "Zoxide is a fast and efficient directory changer (cd) that helps you navigate your file system with ease.",
    "link": "https://github.com/ajeetdsouza/zoxide",
    "winget": "ajeetdsouza.zoxide"
  },
  "WPFInstallzulip": {
    "category": "Communications",
    "choco": "zulip",
    "content": "Zulip",
    "description": "Zulip is an open-source team collaboration tool with chat streams for productive and organized communication.",
    "link": "https://zulipchat.com/",
    "winget": "Zulip.Zulip"
  },
  "WPFInstallsyncthingtray": {
    "category": "Utilities",
    "choco": "syncthingtray",
    "content": "Syncthingtray",
    "description": "Might be the alternative for Synctrayzor. Windows tray utility / filesystem watcher / launcher for Syncthing",
    "link": "https://github.com/Martchus/syncthingtray",
    "winget": "Martchus.syncthingtray"
  },
  "WPFInstallminiconda": {
    "category": "Development",
    "choco": "miniconda3",
    "content": "Miniconda",
    "description": "Miniconda is a free minimal installer for conda. It is a small bootstrap version of Anaconda that includes only conda, Python, the packages they both depend on, and a small number of other useful packages (like pip, zlib, and a few others).",
    "link": "https://docs.conda.io/projects/miniconda",
    "winget": "Anaconda.Miniconda3"
  },
  "WPFInstallpixi": {
    "category": "Development",
    "choco": "pixi",
    "content": "Pixi",
    "description": "Pixi is a fast software package manager built on top of the existing conda ecosystem. Spins up development environments quickly on Windows, macOS and Linux. Pixi supports Python, R, C/C++, Rust, Ruby, and many other languages.",
    "link": "https://pixi.sh",
    "winget": "prefix-dev.pixi"
  },
  "WPFInstalltemurin": {
    "category": "Development",
    "choco": "temurin",
    "content": "Eclipse Temurin",
    "description": "Eclipse Temurin is the open source Java SE build based upon OpenJDK.",
    "link": "https://adoptium.net/temurin/",
    "winget": "EclipseAdoptium.Temurin.21.JDK"
  },
  "WPFInstallintelpresentmon": {
    "category": "Utilities",
    "choco": "na",
    "content": "Intel-PresentMon",
    "description": "A new gaming performance overlay and telemetry application to monitor and measure your gaming experience.",
    "link": "https://game.intel.com/us/stories/intel-presentmon/",
    "winget": "Intel.PresentMon.Beta"
  },
  "WPFInstallpyenvwin": {
    "category": "Development",
    "choco": "pyenv-win",
    "content": "Python Version Manager (pyenv-win)",
    "description": "pyenv for Windows is a simple python version management tool. It lets you easily switch between multiple versions of Python.",
    "link": "https://pyenv-win.github.io/pyenv-win/",
    "winget": "na"
  },
  "WPFInstalltightvnc": {
    "category": "Utilities",
    "choco": "TightVNC",
    "content": "TightVNC",
    "description": "TightVNC is a free and Open Source remote desktop software that lets you access and control a computer over the network. With its intuitive interface, you can interact with the remote screen as if you were sitting in front of it. You can open files, launch applications, and perform other actions on the remote desktop almost as if you were physically there",
    "link": "https://www.tightvnc.com/",
    "winget": "GlavSoft.TightVNC"
  },
  "WPFInstallultravnc": {
    "category": "Utilities",
    "choco": "ultravnc",
    "content": "UltraVNC",
    "description": "UltraVNC is a powerful, easy to use and free - remote pc access softwares - that can display the screen of another computer (via internet or network) on your own screen. The program allows you to use your mouse and keyboard to control the other PC remotely. It means that you can work on a remote computer, as if you were sitting in front of it, right from your current location.",
    "link": "https://uvnc.com/",
    "winget": "uvncbvba.UltraVnc"
  },
  "WPFInstallwindowsfirewallcontrol": {
    "category": "Utilities",
    "choco": "windowsfirewallcontrol",
    "content": "Windows Firewall Control",
    "description": "Windows Firewall Control is a powerful tool which extends the functionality of Windows Firewall and provides new extra features which makes Windows Firewall better.",
    "link": "https://www.binisoft.org/wfc",
    "winget": "BiniSoft.WindowsFirewallControl"
  },
  "WPFInstallvistaswitcher": {
    "category": "Utilities",
    "choco": "na",
    "content": "VistaSwitcher",
    "description": "VistaSwitcher makes it easier for you to locate windows and switch focus, even on multi-monitor systems. The switcher window consists of an easy-to-read list of all tasks running with clearly shown titles and a full-sized preview of the selected task.",
    "link": "https://www.ntwind.com/freeware/vistaswitcher.html",
    "winget": "ntwind.VistaSwitcher"
  },
  "WPFInstallautodarkmode": {
    "category": "Utilities",
    "choco": "auto-dark-mode",
    "content": "Windows Auto Dark Mode",
    "description": "Automatically switches between the dark and light theme of Windows 10 and Windows 11",
    "link": "https://github.com/AutoDarkMode/Windows-Auto-Night-Mode",
    "winget": "Armin2208.WindowsAutoNightMode"
  },
  "WPFInstallAmbieWhiteNoise": {
    "category": "Utilities",
    "choco": "na",
    "content": "Ambie White Noise",
    "description": "Ambie is the ultimate app to help you focus, study, or relax. We use white noise and nature sounds combined with an innovative focus timer to keep you concentrated on doing your best work.",
    "link": "https://ambieapp.com/",
    "winget": "9P07XNM5CHP0"
  },
  "WPFInstallmagicwormhole": {
    "category": "Utilities",
    "choco": "magic-wormhole",
    "content": "Magic Wormhole",
    "description": "get things from one computer to another, safely",
    "link": "https://github.com/magic-wormhole/magic-wormhole",
    "winget": "magic-wormhole.magic-wormhole"
  },
  "WPFInstallcroc": {
    "category": "Utilities",
    "choco": "croc",
    "content": "croc",
    "description": "Easily and securely send things from one computer to another.",
    "link": "https://github.com/schollz/croc",
    "winget": "schollz.croc"
  },
  "WPFInstallqgis": {
    "category": "Multimedia Tools",
    "choco": "qgis",
    "content": "QGIS",
    "description": "QGIS (Quantum GIS) is an open-source Geographic Information System (GIS) software that enables users to create, edit, visualize, analyze, and publish geospatial information on Windows, Mac, and Linux platforms.",
    "link": "https://qgis.org/en/site/",
    "winget": "OSGeo.QGIS"
  },
  "WPFInstallsmplayer": {
    "category": "Multimedia Tools",
    "choco": "smplayer",
    "content": "SMPlayer",
    "description": "SMPlayer is a free media player for Windows and Linux with built-in codecs that can play virtually all video and audio formats.",
    "link": "https://www.smplayer.info",
    "winget": "SMPlayer.SMPlayer"
  },
  "WPFInstallglazewm": {
    "category": "Utilities",
    "choco": "na",
    "content": "GlazeWM",
    "description": "GlazeWM is a tiling window manager for Windows inspired by i3 and Polybar",
    "link": "https://github.com/glzr-io/glazewm",
    "winget": "glzr-io.glazewm"
  },
  "WPFInstallfancontrol": {
    "category": "Utilities",
    "choco": "na",
    "content": "FanControl",
    "description": "Fan Control is a free and open-source software that allows the user to control his CPU, GPU and case fans using temperatures.",
    "link": "https://getfancontrol.com/",
    "winget": "Rem0o.FanControl"
  },
  "WPFInstallfnm": {
    "category": "Development",
    "choco": "fnm",
    "content": "Fast Node Manager",
    "description": "Fast Node Manager (fnm) allows you to switch your Node version by using the Terminal",
    "link": "https://github.com/Schniz/fnm",
    "winget": "Schniz.fnm"
  },
  "WPFInstallWindhawk": {
    "category": "Utilities",
    "choco": "windhawk",
    "content": "Windhawk",
    "description": "The customization marketplace for Windows programs",
    "link": "https://windhawk.net",
    "winget": "RamenSoftware.Windhawk"
  },
  "WPFInstallForceAutoHDR": {
    "category": "Utilities",
    "choco": "na",
    "content": "ForceAutoHDR",
    "description": "ForceAutoHDR simplifies the process of adding games to the AutoHDR list in the Windows Registry",
    "link": "https://github.com/7gxycn08/ForceAutoHDR",
    "winget": "ForceAutoHDR.7gxycn08"
  },
  "WPFInstallJoyToKey": {
    "category": "Utilities",
    "choco": "joytokey",
    "content": "JoyToKey",
    "description": "enables PC game controllers to emulate the keyboard and mouse input",
    "link": "https://joytokey.net/en/",
    "winget": "JTKsoftware.JoyToKey"
  },
  "WPFInstallnditools": {
    "category": "Multimedia Tools",
    "choco": "na",
    "content": "NDI Tools",
    "description": "NDI, or Network Device Interface, is a video connectivity standard that enables multimedia systems to identify and communicate with one another over IP and to encode, transmit, and receive high-quality, low latency, frame-accurate video and audio, and exchange metadata in real-time.",
    "link": "https://ndi.video/",
    "winget": "NDI.NDITools"
  },
  "WPFInstallkicad": {
    "category": "Multimedia Tools",
    "choco": "na",
    "content": "Kicad",
    "description": "Kicad is an open-source EDA tool. It's a good starting point for those who want to do electrical design and is even used by professionals in the industry.",
    "link": "https://www.kicad.org/",
    "winget": "KiCad.KiCad"
  },
  "WPFInstalldropox": {
    "category": "Utilities",
    "choco": "na",
    "content": "Dropbox",
    "description": "The Dropbox desktop app! Save hard drive space, share and edit files and send for signature ? all without the distraction of countless browser tabs.",
    "link": "https://www.dropbox.com/en_GB/desktop",
    "winget": "Dropbox.Dropbox"
  },
  "WPFInstallOFGB": {
    "category": "Utilities",
    "choco": "ofgb",
    "content": "OFGB (Oh Frick Go Back)",
    "description": "GUI Tool to remove ads from various places around Windows 11",
    "link": "https://github.com/xM4ddy/OFGB",
    "winget": "xM4ddy.OFGB"
  },
  "WPFInstallPaleMoon": {
    "category": "Browsers",
    "choco": "paleMoon",
    "content": "PaleMoon",
    "description": "Pale Moon is an Open Source, Goanna-based web browser available for Microsoft Windows and Linux (with other operating systems in development), focusing on efficiency and ease of use.",
    "link": "https://www.palemoon.org/download.shtml",
    "winget": "MoonchildProductions.PaleMoon"
  },
  "WPFInstallShotcut": {
    "category": "Multimedia Tools",
    "choco": "na",
    "content": "Shotcut",
    "description": "Shotcut is a free, open source, cross-platform video editor.",
    "link": "https://shotcut.org/",
    "winget": "Meltytech.Shotcut"
  },
  "WPFInstallLenovoLegionToolkit": {
    "category": "Utilities",
    "choco": "na",
    "content": "Lenovo Legion Toolkit",
    "description": "Lenovo Legion Toolkit (LLT) is a open-source utility created for Lenovo Legion (and similar) series laptops, that allows changing a couple of features that are only available in Lenovo Vantage or Legion Zone. It runs no background services, uses less memory, uses virtually no CPU, and contains no telemetry. Just like Lenovo Vantage, this application is Windows only.",
    "link": "https://github.com/BartoszCichecki/LenovoLegionToolkit",
    "winget": "BartoszCichecki.LenovoLegionToolkit"
  },
  "WPFInstallPulsarEdit": {
    "category": "Development",
    "choco": "pulsar",
    "content": "Pulsar",
    "description": "A Community-led Hyper-Hackable Text Editor",
    "link": "https://pulsar-edit.dev/",
    "winget": "Pulsar-Edit.Pulsar"
  },
  "WPFInstallAegisub": {
    "category": "Development",
    "choco": "aegisub",
    "content": "Aegisub",
    "description": "Aegisub is a free, cross-platform open source tool for creating and modifying subtitles. Aegisub makes it quick and easy to time subtitles to audio, and features many powerful tools for styling them, including a built-in real-time video preview.",
    "link": "https://github.com/Aegisub/Aegisub",
    "winget": "Aegisub.Aegisub"
  },
  "WPFInstallSubtitleEdit": {
    "category": "Multimedia Tools",
    "choco": "na",
    "content": "Subtitle Edit",
    "description": "Subtitle Edit is a free and open source editor for video subtitles.",
    "link": "https://github.com/SubtitleEdit/subtitleedit",
    "winget": "Nikse.SubtitleEdit"
  },
  "WPFInstallFork": {
    "category": "Development",
    "choco": "git-fork",
    "content": "Fork",
    "description": "Fork - a fast and friendly git client.",
    "link": "https://git-fork.com/",
    "winget": "Fork.Fork"
  },
  "WPFInstallZenBrowser": {
    "category": "Browsers",
    "choco": "na",
    "content": "Zen Browser",
    "description": "The modern, privacy-focused, performance-driven browser built on Firefox",
    "link": "https://zen-browser.app/",
    "winget": "Zen-Team.Zen-Browser"
  }
}
'@ | ConvertFrom-Json
$sync.configs.appnavigation = @'
{
  "WPFToggleView": {
    "Content": [
      "Expanded View",
      "Compact View"
    ],
    "Category": "____Actions",
    "Type": "ToggleButton",
    "Order": "1",
    "Description": "Toggle between a list and a compact grid like view"
  },
  "WPFSelectedFilter": {
    "Content": [
      "Show All",
      "Show Selected"
    ],
    "Category": "____Actions",
    "Type": "ToggleButton",
    "Order": "2",
    "Description": "Toggle between showing all or only the selected applications"
  },
  "WPFClearInstallSelection": {
    "Content": "Clear Selection",
    "Category": "____Actions",
    "Type": "Button",
    "Order": "3",
    "Description": "Clear the selection of applications"
  },
  "WPFGetInstalled": {
    "Content": "Get Installed",
    "Category": "____Actions",
    "Type": "Button",
    "Order": "4",
    "Description": "Show installed applications"
  },
  "WingetRadioButton": {
    "Content": "Winget",
    "Category": "__Package Manager",
    "Type": "RadioButton",
    "GroupName": "PackageManagerGroup",
    "Checked": true,
    "Order": "1",
    "Description": "Use Winget for package management"
  },
  "ChocoRadioButton": {
    "Content": "Chocolatey",
    "Category": "__Package Manager",
    "Type": "RadioButton",
    "GroupName": "PackageManagerGroup",
    "Checked": false,
    "Order": "2",
    "Description": "Use Chocolatey for package management"
  }
}
'@ | ConvertFrom-Json
$sync.configs.dns = @'
{
  "Google": {
    "Primary": "8.8.8.8",
    "Secondary": "8.8.4.4",
    "Primary6": "2001:4860:4860::8888",
    "Secondary6": "2001:4860:4860::8844"
  },
  "Cloudflare": {
    "Primary": "1.1.1.1",
    "Secondary": "1.0.0.1",
    "Primary6": "2606:4700:4700::1111",
    "Secondary6": "2606:4700:4700::1001"
  },
  "Cloudflare_Malware": {
    "Primary": "1.1.1.2",
    "Secondary": "1.0.0.2",
    "Primary6": "2606:4700:4700::1112",
    "Secondary6": "2606:4700:4700::1002"
  },
  "Cloudflare_Malware_Adult": {
    "Primary": "1.1.1.3",
    "Secondary": "1.0.0.3",
    "Primary6": "2606:4700:4700::1113",
    "Secondary6": "2606:4700:4700::1003"
  },
  "Open_DNS": {
    "Primary": "208.67.222.222",
    "Secondary": "208.67.220.220",
    "Primary6": "2620:119:35::35",
    "Secondary6": "2620:119:53::53"
  },
  "Quad9": {
    "Primary": "9.9.9.9",
    "Secondary": "149.112.112.112",
    "Primary6": "2620:fe::fe",
    "Secondary6": "2620:fe::9"
  },
  "AdGuard_Ads_Trackers": {
    "Primary": "94.140.14.14",
    "Secondary": "94.140.15.15",
    "Primary6": "2a10:50c0::ad1:ff",
    "Secondary6": "2a10:50c0::ad2:ff"
  },
  "AdGuard_Ads_Trackers_Malware_Adult": {
    "Primary": "94.140.14.15",
    "Secondary": "94.140.15.16",
    "Primary6": "2a10:50c0::bad1:ff",
    "Secondary6": "2a10:50c0::bad2:ff"
  },
  "dns0.eu_Open": {
    "Primary": "193.110.81.254",
    "Secondary": "185.253.5.254",
    "Primary6": "2a0f:fc80::ffff",
    "Secondary6": "2a0f:fc81::ffff"
  },
  "dns0.eu_ZERO": {
    "Primary": "193.110.81.9",
    "Secondary": "185.253.5.9",
    "Primary6": "2a0f:fc80::9",
    "Secondary6": "2a0f:fc81::9"
  },
  "dns0.eu_KIDS": {
    "Primary": "193.110.81.1",
    "Secondary": "185.253.5.1",
    "Primary6": "2a0f:fc80::1",
    "Secondary6": "2a0f:fc81::1"
  }
}
'@ | ConvertFrom-Json
$sync.configs.feature = @'
{
  "WPFFeaturesdotnet": {
    "Content": "All .Net Framework (2,3,4)",
    "Description": ".NET and .NET Framework is a developer platform made up of tools, programming languages, and libraries for building many different types of applications.",
    "category": "Features",
    "panel": "1",
    "Order": "a010_",
    "feature": [
      "NetFx4-AdvSrvs",
      "NetFx3"
    ],
    "InvokeScript": [],
    "link": "https://christitustech.github.io/winutil/dev/features/Features/dotnet"
  },
  "WPFFeatureshyperv": {
    "Content": "HyperV Virtualization",
    "Description": "Hyper-V is a hardware virtualization product developed by Microsoft that allows users to create and manage virtual machines.",
    "category": "Features",
    "panel": "1",
    "Order": "a011_",
    "feature": [
      "HypervisorPlatform",
      "Microsoft-Hyper-V-All",
      "Microsoft-Hyper-V",
      "Microsoft-Hyper-V-Tools-All",
      "Microsoft-Hyper-V-Management-PowerShell",
      "Microsoft-Hyper-V-Hypervisor",
      "Microsoft-Hyper-V-Services",
      "Microsoft-Hyper-V-Management-Clients"
    ],
    "InvokeScript": [
      "Start-Process -FilePath cmd.exe -ArgumentList '/c bcdedit /set hypervisorschedulertype classic' -Wait"
    ],
    "link": "https://christitustech.github.io/winutil/dev/features/Features/hyperv"
  },
  "WPFFeatureslegacymedia": {
    "Content": "Legacy Media (WMP, DirectPlay)",
    "Description": "Enables legacy programs from previous versions of windows",
    "category": "Features",
    "panel": "1",
    "Order": "a012_",
    "feature": [
      "WindowsMediaPlayer",
      "MediaPlayback",
      "DirectPlay",
      "LegacyComponents"
    ],
    "InvokeScript": [],
    "link": "https://christitustech.github.io/winutil/dev/features/Features/legacymedia"
  },
  "WPFFeaturewsl": {
    "Content": "Windows Subsystem for Linux",
    "Description": "Windows Subsystem for Linux is an optional feature of Windows that allows Linux programs to run natively on Windows without the need for a separate virtual machine or dual booting.",
    "category": "Features",
    "panel": "1",
    "Order": "a020_",
    "feature": [
      "VirtualMachinePlatform",
      "Microsoft-Windows-Subsystem-Linux"
    ],
    "InvokeScript": [],
    "link": "https://christitustech.github.io/winutil/dev/features/Features/wsl"
  },
  "WPFFeaturenfs": {
    "Content": "NFS - Network File System",
    "Description": "Network File System (NFS) is a mechanism for storing files on a network.",
    "category": "Features",
    "panel": "1",
    "Order": "a014_",
    "feature": [
      "ServicesForNFS-ClientOnly",
      "ClientForNFS-Infrastructure",
      "NFS-Administration"
    ],
    "InvokeScript": [
      "nfsadmin client stop",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default' -Name 'AnonymousUID' -Type DWord -Value 0",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default' -Name 'AnonymousGID' -Type DWord -Value 0",
      "nfsadmin client start",
      "nfsadmin client localhost config fileaccess=755 SecFlavors=+sys -krb5 -krb5i"
    ],
    "link": "https://christitustech.github.io/winutil/dev/features/Features/nfs"
  },
  "WPFFeatureEnableSearchSuggestions": {
    "Content": "Enable Search Box Web Suggestions in Registry(explorer restart)",
    "Description": "Enables web suggestions when searching using Windows Search.",
    "category": "Features",
    "panel": "1",
    "Order": "a015_",
    "feature": [],
    "InvokeScript": [
      "\r\n      If (!(Test-Path 'HKCU:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer')) {\r\n            New-Item -Path 'HKCU:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer' -Force | Out-Null\r\n      }\r\n      New-ItemProperty -Path 'HKCU:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer' -Name 'DisableSearchBoxSuggestions' -Type DWord -Value 0 -Force\r\n      Stop-Process -name explorer -force\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/features/Features/EnableSearchSuggestions"
  },
  "WPFFeatureDisableSearchSuggestions": {
    "Content": "Disable Search Box Web Suggestions in Registry(explorer restart)",
    "Description": "Disables web suggestions when searching using Windows Search.",
    "category": "Features",
    "panel": "1",
    "Order": "a016_",
    "feature": [],
    "InvokeScript": [
      "\r\n      If (!(Test-Path 'HKCU:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer')) {\r\n            New-Item -Path 'HKCU:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer' -Force | Out-Null\r\n      }\r\n      New-ItemProperty -Path 'HKCU:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer' -Name 'DisableSearchBoxSuggestions' -Type DWord -Value 1 -Force\r\n      Stop-Process -name explorer -force\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/features/Features/DisableSearchSuggestions"
  },
  "WPFFeatureRegBackup": {
    "Content": "Enable Daily Registry Backup Task 12.30am",
    "Description": "Enables daily registry backup, previously disabled by Microsoft in Windows 10 1803.",
    "category": "Features",
    "panel": "1",
    "Order": "a017_",
    "feature": [],
    "InvokeScript": [
      "\r\n      New-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager' -Name 'EnablePeriodicBackup' -Type DWord -Value 1 -Force\r\n      New-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager' -Name 'BackupCount' -Type DWord -Value 2 -Force\r\n      $action = New-ScheduledTaskAction -Execute 'schtasks' -Argument '/run /i /tn \"\\Microsoft\\Windows\\Registry\\RegIdleBackup\"'\r\n      $trigger = New-ScheduledTaskTrigger -Daily -At 00:30\r\n      Register-ScheduledTask -Action $action -Trigger $trigger -TaskName 'AutoRegBackup' -Description 'Create System Registry Backups' -User 'System'\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/features/Features/RegBackup"
  },
  "WPFFeatureEnableLegacyRecovery": {
    "Content": "Enable Legacy F8 Boot Recovery",
    "Description": "Enables Advanced Boot Options screen that lets you start Windows in advanced troubleshooting modes.",
    "category": "Features",
    "panel": "1",
    "Order": "a018_",
    "feature": [],
    "InvokeScript": [
      "\r\n      If (!(Test-Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager\\LastKnownGood')) {\r\n            New-Item -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager\\LastKnownGood' -Force | Out-Null\r\n      }\r\n      New-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager\\LastKnownGood' -Name 'Enabled' -Type DWord -Value 1 -Force\r\n      Start-Process -FilePath cmd.exe -ArgumentList '/c bcdedit /Set {Current} BootMenuPolicy Legacy' -Wait\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/features/Features/EnableLegacyRecovery"
  },
  "WPFFeatureDisableLegacyRecovery": {
    "Content": "Disable Legacy F8 Boot Recovery",
    "Description": "Disables Advanced Boot Options screen that lets you start Windows in advanced troubleshooting modes.",
    "category": "Features",
    "panel": "1",
    "Order": "a019_",
    "feature": [],
    "InvokeScript": [
      "\r\n      If (!(Test-Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager\\LastKnownGood')) {\r\n            New-Item -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager\\LastKnownGood' -Force | Out-Null\r\n      }\r\n      New-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager\\LastKnownGood' -Name 'Enabled' -Type DWord -Value 0 -Force\r\n      Start-Process -FilePath cmd.exe -ArgumentList '/c bcdedit /Set {Current} BootMenuPolicy Standard' -Wait\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/features/Features/DisableLegacyRecovery"
  },
  "WPFFeaturesSandbox": {
    "Content": "Windows Sandbox",
    "category": "Features",
    "panel": "1",
    "Order": "a021_",
    "Description": "Windows Sandbox is a lightweight virtual machine that provides a temporary desktop environment to safely run applications and programs in isolation.",
    "link": "https://christitustech.github.io/winutil/dev/features/Features/Sandbox"
  },
  "WPFFeatureInstall": {
    "Content": "Install Features",
    "category": "Features",
    "panel": "1",
    "Order": "a060_",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://christitustech.github.io/winutil/dev/features/Features/Install"
  },
  "WPFPanelAutologin": {
    "Content": "Set Up Autologin",
    "category": "Fixes",
    "Order": "a040_",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://christitustech.github.io/winutil/dev/features/Fixes/Autologin"
  },
  "WPFFixesUpdate": {
    "Content": "Reset Windows Update",
    "category": "Fixes",
    "panel": "1",
    "Order": "a041_",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://christitustech.github.io/winutil/dev/features/Fixes/Update"
  },
  "WPFFixesNetwork": {
    "Content": "Reset Network",
    "category": "Fixes",
    "Order": "a042_",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://christitustech.github.io/winutil/dev/features/Fixes/Network"
  },
  "WPFPanelDISM": {
    "Content": "System Corruption Scan",
    "category": "Fixes",
    "panel": "1",
    "Order": "a043_",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://christitustech.github.io/winutil/dev/features/Fixes/DISM"
  },
  "WPFFixesWinget": {
    "Content": "WinGet Reinstall",
    "category": "Fixes",
    "panel": "1",
    "Order": "a044_",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://christitustech.github.io/winutil/dev/features/Fixes/Winget"
  },
  "WPFRunAdobeCCCleanerTool": {
    "Content": "Remove Adobe Creative Cloud",
    "category": "Fixes",
    "panel": "1",
    "Order": "a045_",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://christitustech.github.io/winutil/dev/features/Fixes/RunAdobeCCCleanerTool"
  },
  "WPFPanelnetwork": {
    "Content": "Network Connections",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://christitustech.github.io/winutil/dev/features/Legacy-Windows-Panels/network"
  },
  "WPFPanelcontrol": {
    "Content": "Control Panel",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://christitustech.github.io/winutil/dev/features/Legacy-Windows-Panels/control"
  },
  "WPFPanelpower": {
    "Content": "Power Panel",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://christitustech.github.io/winutil/dev/features/Legacy-Windows-Panels/power"
  },
  "WPFPanelregion": {
    "Content": "Region",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://christitustech.github.io/winutil/dev/features/Legacy-Windows-Panels/region"
  },
  "WPFPanelsound": {
    "Content": "Sound Settings",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://christitustech.github.io/winutil/dev/features/Legacy-Windows-Panels/sound"
  },
  "WPFPanelprinter": {
    "Content": "Printer Panel",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://christitustech.github.io/winutil/dev/features/Legacy-Windows-Panels/printer"
  },
  "WPFPanelsystem": {
    "Content": "System Properties",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://christitustech.github.io/winutil/dev/features/Legacy-Windows-Panels/system"
  },
  "WPFPaneluser": {
    "Content": "User Accounts",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://christitustech.github.io/winutil/dev/features/Legacy-Windows-Panels/user"
  },
  "WPFWinUtilInstallPSProfile": {
    "Content": "Install CTT PowerShell Profile",
    "category": "Powershell Profile",
    "panel": "2",
    "Order": "a083_",
    "Type": "Button",
    "ButtonWidth": "300"
  },
  "WPFWinUtilUninstallPSProfile": {
    "Content": "Uninstall CTT PowerShell Profile",
    "category": "Powershell Profile",
    "panel": "2",
    "Order": "a084_",
    "Type": "Button",
    "ButtonWidth": "300"
  },
  "WPFWinUtilSSHServer": {
    "Content": "Enable OpenSSH Server",
    "category": "Remote Access",
    "panel": "2",
    "Order": "a084_",
    "Type": "Button",
    "ButtonWidth": "300"
  }
}
'@ | ConvertFrom-Json
$sync.configs.preset = @'
{
  "Standard": [
    "WPFTweaksAH",
    "WPFTweaksConsumerFeatures",
    "WPFTweaksDVR",
    "WPFTweaksHiber",
    "WPFTweaksHome",
    "WPFTweaksLoc",
    "WPFTweaksServices",
    "WPFTweaksStorage",
    "WPFTweaksTele",
    "WPFTweaksWifi",
    "WPFTweaksDiskCleanup",
    "WPFTweaksDeleteTempFiles",
    "WPFTweaksEndTaskOnTaskbar",
    "WPFTweaksRestorePoint",
    "WPFTweaksPowershell7Tele"
  ],
  "Minimal": [
    "WPFTweaksConsumerFeatures",
    "WPFTweaksHome",
    "WPFTweaksServices",
    "WPFTweaksTele"
  ]
}
'@ | ConvertFrom-Json
$sync.configs.themes = @'
{
  "shared": {
    "CustomDialogFontSize": "12",
    "CustomDialogFontSizeHeader": "14",
    "CustomDialogLogoSize": "25",
    "CustomDialogWidth": "400",
    "CustomDialogHeight": "200",
    "FontSize": "12",
    "FontFamily": "Arial",
    "HeadingFontSize": "16",
    "HeaderFontFamily": "Consolas, Monaco",
    "CheckBoxBulletDecoratorSize": "14",
    "CheckBoxMargin": "15,0,0,2",
    "TabContentMargin": "5",
    "TabButtonFontSize": "14",
    "TabButtonWidth": "110",
    "TabButtonHeight": "26",
    "TabRowHeightInPixels": "50",
    "IconFontSize": "14",
    "IconButtonSize": "35",
    "SettingsIconFontSize": "18",
    "CloseIconFontSize": "18",
    "MicroWinLogoSize": "10",
    "MicrowinCheckBoxMargin": "-10,5,0,0",
    "GroupBorderBackgroundColor": "#232629",
    "ButtonFontSize": "12",
    "ButtonFontFamily": "Arial",
    "ButtonWidth": "200",
    "ButtonHeight": "25",
    "ConfigUpdateButtonFontSize": "14",
    "SearchBarWidth": "200",
    "SearchBarHeight": "26",
    "SearchBarTextBoxFontSize": "12",
    "SearchBarClearButtonFontSize": "14",
    "CheckboxMouseOverColor": "#999999",
    "ButtonBorderThickness": "1",
    "ButtonMargin": "1",
    "ButtonCornerRadius": "2"
  },
  "Light": {
    "AppInstallUnselectedColor": "#F0F0F0",
    "AppInstallHighlightedColor": "#CFCFCF",
    "AppInstallSelectedColor": "#C2C2C2",
    "ComboBoxForegroundColor": "#232629",
    "ComboBoxBackgroundColor": "#F7F7F7",
    "LabelboxForegroundColor": "#232629",
    "MainForegroundColor": "#232629",
    "MainBackgroundColor": "#F7F7F7",
    "LabelBackgroundColor": "#F7F7F7",
    "LinkForegroundColor": "#484848",
    "LinkHoverForegroundColor": "#232629",
    "ScrollBarBackgroundColor": "#4A4D52",
    "ScrollBarHoverColor": "#5A5D62",
    "ScrollBarDraggingColor": "#6A6D72",
    "ProgressBarForegroundColor": "#2e77ff",
    "ProgressBarBackgroundColor": "Transparent",
    "ProgressBarTextColor": "#232629",
    "ButtonInstallBackgroundColor": "#F7F7F7",
    "ButtonTweaksBackgroundColor": "#F7F7F7",
    "ButtonConfigBackgroundColor": "#F7F7F7",
    "ButtonUpdatesBackgroundColor": "#F7F7F7",
    "ButtonInstallForegroundColor": "#232629",
    "ButtonTweaksForegroundColor": "#232629",
    "ButtonConfigForegroundColor": "#232629",
    "ButtonUpdatesForegroundColor": "#232629",
    "ButtonBackgroundColor": "#F5F5F5",
    "ButtonBackgroundPressedColor": "#1A1A1A",
    "ButtonBackgroundMouseoverColor": "#C2C2C2",
    "ButtonBackgroundSelectedColor": "#F0F0F0",
    "ButtonForegroundColor": "#232629",
    "ToggleButtonOnColor": "#2e77ff",
    "ToggleButtonOffColor": "#707070",
    "BorderColor": "#232629",
    "BorderOpacity": "0.2"
  },
  "Dark": {
    "AppInstallUnselectedColor": "#232629",
    "AppInstallHighlightedColor": "#3C3C3C",
    "AppInstallSelectedColor": "#4C4C4C",
    "ComboBoxForegroundColor": "#F7F7F7",
    "ComboBoxBackgroundColor": "#1E3747",
    "LabelboxForegroundColor": "#0567ff",
    "MainForegroundColor": "#F7F7F7",
    "MainBackgroundColor": "#232629",
    "LabelBackgroundColor": "#232629",
    "LinkForegroundColor": "#add8e6",
    "LinkHoverForegroundColor": "#F7F7F7",
    "ScrollBarBackgroundColor": "#2E3135",
    "ScrollBarHoverColor": "#3B4252",
    "ScrollBarDraggingColor": "#5E81AC",
    "ProgressBarForegroundColor": "#222222",
    "ProgressBarBackgroundColor": "Transparent",
    "ProgressBarTextColor": "#cccccc",
    "ButtonInstallBackgroundColor": "#222222",
    "ButtonTweaksBackgroundColor": "#333333",
    "ButtonConfigBackgroundColor": "#444444",
    "ButtonUpdatesBackgroundColor": "#555555",
    "ButtonInstallForegroundColor": "#F7F7F7",
    "ButtonTweaksForegroundColor": "#F7F7F7",
    "ButtonConfigForegroundColor": "#F7F7F7",
    "ButtonUpdatesForegroundColor": "#F7F7F7",
    "ButtonBackgroundColor": "#1E3747",
    "ButtonBackgroundPressedColor": "#F7F7F7",
    "ButtonBackgroundMouseoverColor": "#3B4252",
    "ButtonBackgroundSelectedColor": "#5E81AC",
    "ButtonForegroundColor": "#F7F7F7",
    "ToggleButtonOnColor": "#2e77ff",
    "ToggleButtonOffColor": "#707070",
    "BorderColor": "#2F373D",
    "BorderOpacity": "0.2"
  }
}
'@ | ConvertFrom-Json
$sync.configs.tweaks = @'
{
  "WPFTweaksAH": {
    "Content": "Disable Activity History",
    "Description": "This erases recent docs, clipboard, and run history.",
    "category": "Essential Tweaks",
    "panel": "1",
    "Order": "a005_",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "EnableActivityFeed",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "PublishUserActivities",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "UploadUserActivities",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/AH"
  },
  "WPFTweaksHiber": {
    "Content": "Disable Hibernation",
    "Description": "Hibernation is really meant for laptops as it saves what's in memory before turning the pc off. It really should never be used, but some people are lazy and rely on it. Don't be like Bob. Bob likes hibernation.",
    "category": "Essential Tweaks",
    "panel": "1",
    "Order": "a005_",
    "registry": [
      {
        "Path": "HKLM:\\System\\CurrentControlSet\\Control\\Session Manager\\Power",
        "Name": "HibernateEnabled",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FlyoutMenuSettings",
        "Name": "ShowHibernateOption",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "1"
      }
    ],
    "InvokeScript": [
      "powercfg.exe /hibernate off"
    ],
    "UndoScript": [
      "powercfg.exe /hibernate on"
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/Hiber"
  },
  "WPFTweaksLaptopHibernation": {
    "Content": "Set Hibernation as default (good for laptops)",
    "Description": "Most modern laptops have connected standby enabled which drains the battery, this sets hibernation as default which will not drain the battery. See issue https://github.com/ChrisTitusTech/winutil/issues/1399",
    "category": "Essential Tweaks",
    "panel": "1",
    "Order": "a014_",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power\\PowerSettings\\238C9FA8-0AAD-41ED-83F4-97BE242C8F20\\7bc4a2f9-d8fc-4469-b07b-33eb785aaca0",
        "OriginalValue": "1",
        "Name": "Attributes",
        "Value": "2",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power\\PowerSettings\\abfc2519-3608-4c2a-94ea-171b0ed546ab\\94ac6d29-73ce-41a6-809f-6363ba21b47e",
        "OriginalValue": "0",
        "Name": "Attributes ",
        "Value": "2",
        "Type": "DWord"
      }
    ],
    "InvokeScript": [
      "\r\n      Write-Host \"Turn on Hibernation\"\r\n      Start-Process -FilePath powercfg -ArgumentList \"/hibernate on\" -NoNewWindow -Wait\r\n\r\n      # Set hibernation as the default action\r\n      Start-Process -FilePath powercfg -ArgumentList \"/change standby-timeout-ac 60\" -NoNewWindow -Wait\r\n      Start-Process -FilePath powercfg -ArgumentList \"/change standby-timeout-dc 60\" -NoNewWindow -Wait\r\n      Start-Process -FilePath powercfg -ArgumentList \"/change monitor-timeout-ac 10\" -NoNewWindow -Wait\r\n      Start-Process -FilePath powercfg -ArgumentList \"/change monitor-timeout-dc 1\" -NoNewWindow -Wait\r\n      "
    ],
    "UndoScript": [
      "\r\n      Write-Host \"Turn off Hibernation\"\r\n      Start-Process -FilePath powercfg -ArgumentList \"/hibernate off\" -NoNewWindow -Wait\r\n\r\n      # Set standby to detault values\r\n      Start-Process -FilePath powercfg -ArgumentList \"/change standby-timeout-ac 15\" -NoNewWindow -Wait\r\n      Start-Process -FilePath powercfg -ArgumentList \"/change standby-timeout-dc 15\" -NoNewWindow -Wait\r\n      Start-Process -FilePath powercfg -ArgumentList \"/change monitor-timeout-ac 15\" -NoNewWindow -Wait\r\n      Start-Process -FilePath powercfg -ArgumentList \"/change monitor-timeout-dc 15\" -NoNewWindow -Wait\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/LaptopHibernation"
  },
  "WPFTweaksHome": {
    "Content": "Disable Homegroup",
    "Description": "Disables HomeGroup - HomeGroup is a password-protected home networking service that lets you share your stuff with other PCs that are currently running and connected to your network.",
    "category": "Essential Tweaks",
    "panel": "1",
    "Order": "a005_",
    "service": [
      {
        "Name": "HomeGroupListener",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "HomeGroupProvider",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/Home"
  },
  "WPFTweaksLoc": {
    "Content": "Disable Location Tracking",
    "Description": "Disables Location Tracking...DUH!",
    "category": "Essential Tweaks",
    "panel": "1",
    "Order": "a005_",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\location",
        "Name": "Value",
        "Type": "String",
        "Value": "Deny",
        "OriginalValue": "Allow"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Sensor\\Overrides\\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}",
        "Name": "SensorPermissionState",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\lfsvc\\Service\\Configuration",
        "Name": "Status",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SYSTEM\\Maps",
        "Name": "AutoUpdateEnabled",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "1"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/Loc"
  },
  "WPFTweaksServices": {
    "Content": "Set Services to Manual",
    "Description": "Turns a bunch of system services to manual that don't need to be running all the time. This is pretty harmless as if the service is needed, it will simply start on demand.",
    "category": "Essential Tweaks",
    "panel": "1",
    "Order": "a014_",
    "service": [
      {
        "Name": "AJRouter",
        "StartupType": "Disabled",
        "OriginalType": "Manual"
      },
      {
        "Name": "ALG",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "AppIDSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "AppMgmt",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "AppReadiness",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "AppVClient",
        "StartupType": "Disabled",
        "OriginalType": "Disabled"
      },
      {
        "Name": "AppXSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "Appinfo",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "AssignedAccessManagerSvc",
        "StartupType": "Disabled",
        "OriginalType": "Manual"
      },
      {
        "Name": "AudioEndpointBuilder",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "AudioSrv",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "Audiosrv",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "AxInstSV",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "BDESVC",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "BFE",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "BITS",
        "StartupType": "AutomaticDelayedStart",
        "OriginalType": "Automatic"
      },
      {
        "Name": "BTAGService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "BcastDVRUserService_*",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "BluetoothUserService_*",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "BrokerInfrastructure",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "Browser",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "BthAvctpSvc",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "BthHFSrv",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "CDPSvc",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "CDPUserSvc_*",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "COMSysApp",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "CaptureService_*",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "CertPropSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "ClipSVC",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "ConsentUxUserSvc_*",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "CoreMessagingRegistrar",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "CredentialEnrollmentManagerUserSvc_*",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "CryptSvc",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "CscService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "DPS",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "DcomLaunch",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "DcpSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "DevQueryBroker",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "DeviceAssociationBrokerSvc_*",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "DeviceAssociationService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "DeviceInstall",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "DevicePickerUserSvc_*",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "DevicesFlowUserSvc_*",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "Dhcp",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "DiagTrack",
        "StartupType": "Disabled",
        "OriginalType": "Automatic"
      },
      {
        "Name": "DialogBlockingService",
        "StartupType": "Disabled",
        "OriginalType": "Disabled"
      },
      {
        "Name": "DispBrokerDesktopSvc",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "DisplayEnhancementService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "DmEnrollmentSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "Dnscache",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "EFS",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "EapHost",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "EntAppSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "EventLog",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "EventSystem",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "FDResPub",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "Fax",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "FontCache",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "FrameServer",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "FrameServerMonitor",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "GraphicsPerfSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "HomeGroupListener",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "HomeGroupProvider",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "HvHost",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "IEEtwCollectorService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "IKEEXT",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "InstallService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "InventorySvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "IpxlatCfgSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "KeyIso",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "KtmRm",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "LSM",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "LanmanServer",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "LanmanWorkstation",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "LicenseManager",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "LxpSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "MSDTC",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "MSiSCSI",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "MapsBroker",
        "StartupType": "AutomaticDelayedStart",
        "OriginalType": "Automatic"
      },
      {
        "Name": "McpManagementService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "MessagingService_*",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "MicrosoftEdgeElevationService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "MixedRealityOpenXRSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "MpsSvc",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "MsKeyboardFilter",
        "StartupType": "Manual",
        "OriginalType": "Disabled"
      },
      {
        "Name": "NPSMSvc_*",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "NaturalAuthentication",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "NcaSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "NcbService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "NcdAutoSetup",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "NetSetupSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "NetTcpPortSharing",
        "StartupType": "Disabled",
        "OriginalType": "Disabled"
      },
      {
        "Name": "Netlogon",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "Netman",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "NgcCtnrSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "NgcSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "NlaSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "OneSyncSvc_*",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "P9RdrService_*",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "PNRPAutoReg",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "PNRPsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "PcaSvc",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "PeerDistSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "PenService_*",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "PerfHost",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "PhoneSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "PimIndexMaintenanceSvc_*",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "PlugPlay",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "PolicyAgent",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "Power",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "PrintNotify",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "PrintWorkflowUserSvc_*",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "ProfSvc",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "PushToInstall",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "QWAVE",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "RasAuto",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "RasMan",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "RemoteAccess",
        "StartupType": "Disabled",
        "OriginalType": "Disabled"
      },
      {
        "Name": "RemoteRegistry",
        "StartupType": "Disabled",
        "OriginalType": "Disabled"
      },
      {
        "Name": "RetailDemo",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "RmSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "RpcEptMapper",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "RpcLocator",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "RpcSs",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "SCPolicySvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SCardSvr",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SDRSVC",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SEMgrSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SENS",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "SNMPTRAP",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SNMPTrap",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SSDPSRV",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SamSs",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "ScDeviceEnum",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "Schedule",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "SecurityHealthService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "Sense",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SensorDataService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SensorService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SensrSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SessionEnv",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SharedAccess",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "SharedRealitySvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "ShellHWDetection",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "SmsRouter",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "Spooler",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "SstpSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "StiSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "StorSvc",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "SysMain",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "SystemEventsBroker",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "TabletInputService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "TapiSrv",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "TermService",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "Themes",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "TieringEngineService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "TimeBroker",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "TimeBrokerSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "TokenBroker",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "TrkWks",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "TroubleshootingSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "TrustedInstaller",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "UI0Detect",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "UdkUserSvc_*",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "UevAgentService",
        "StartupType": "Disabled",
        "OriginalType": "Disabled"
      },
      {
        "Name": "UmRdpService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "UnistoreSvc_*",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "UserDataSvc_*",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "UserManager",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "UsoSvc",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "VGAuthService",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "VMTools",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "VSS",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "VacSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "VaultSvc",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "W32Time",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WEPHOSTSVC",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WFDSConMgrSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WMPNetworkSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WManSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WPDBusEnum",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WSService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WSearch",
        "StartupType": "AutomaticDelayedStart",
        "OriginalType": "Automatic"
      },
      {
        "Name": "WaaSMedicSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WalletService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WarpJITSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WbioSrvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "Wcmsvc",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "WcsPlugInService",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WdNisSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WdiServiceHost",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WdiSystemHost",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WebClient",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "Wecsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WerSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WiaRpc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WinDefend",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "WinHttpAutoProxySvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WinRM",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "Winmgmt",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "WlanSvc",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "WpcMonSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "WpnService",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "WpnUserService_*",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "XblAuthManager",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "XblGameSave",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "XboxGipSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "XboxNetApiSvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "autotimesvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "bthserv",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "camsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "cbdhsvc_*",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "cloudidsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "dcsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "defragsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "diagnosticshub.standardcollector.service",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "diagsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "dmwappushservice",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "dot3svc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "edgeupdate",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "edgeupdatem",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "embeddedmode",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "fdPHost",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "fhsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "gpsvc",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "hidserv",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "icssvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "iphlpsvc",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "lfsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "lltdsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "lmhosts",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "mpssvc",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "msiserver",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "netprofm",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "nsi",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "p2pimsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "p2psvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "perceptionsimulation",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "pla",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "seclogon",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "shpamsvc",
        "StartupType": "Disabled",
        "OriginalType": "Disabled"
      },
      {
        "Name": "smphost",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "spectrum",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "sppsvc",
        "StartupType": "AutomaticDelayedStart",
        "OriginalType": "Automatic"
      },
      {
        "Name": "ssh-agent",
        "StartupType": "Disabled",
        "OriginalType": "Disabled"
      },
      {
        "Name": "svsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "swprv",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "tiledatamodelsvc",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "tzautoupdate",
        "StartupType": "Disabled",
        "OriginalType": "Disabled"
      },
      {
        "Name": "uhssvc",
        "StartupType": "Disabled",
        "OriginalType": "Disabled"
      },
      {
        "Name": "upnphost",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "vds",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "vm3dservice",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "vmicguestinterface",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "vmicheartbeat",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "vmickvpexchange",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "vmicrdv",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "vmicshutdown",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "vmictimesync",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "vmicvmsession",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "vmicvss",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "vmvss",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "wbengine",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "wcncsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "webthreatdefsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "webthreatdefusersvc_*",
        "StartupType": "Automatic",
        "OriginalType": "Automatic"
      },
      {
        "Name": "wercplsupport",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "wisvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "wlidsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "wlpasvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "wmiApSrv",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "workfolderssvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "wscsvc",
        "StartupType": "AutomaticDelayedStart",
        "OriginalType": "Automatic"
      },
      {
        "Name": "wuauserv",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      },
      {
        "Name": "wudfsvc",
        "StartupType": "Manual",
        "OriginalType": "Manual"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/Services"
  },
  "WPFTweaksEdgeDebloat": {
    "Content": "Debloat Edge",
    "Description": "Disables various telemetry options, popups, and other annoyances in Edge.",
    "category": "Essential Tweaks",
    "panel": "1",
    "Order": "a016_",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\EdgeUpdate",
        "Name": "CreateDesktopShortcutDefault",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "PersonalizationReportingEnabled",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ShowRecommendationsEnabled",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "HideFirstRunExperience",
        "Type": "DWord",
        "Value": "1",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "UserFeedbackAllowed",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ConfigureDoNotTrack",
        "Type": "DWord",
        "Value": "1",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "AlternateErrorPagesEnabled",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeCollectionsEnabled",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeShoppingAssistantEnabled",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "MicrosoftEdgeInsiderPromotionEnabled",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "PersonalizationReportingEnabled",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ShowMicrosoftRewards",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "WebWidgetAllowed",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "DiagnosticData",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeAssetDeliveryServiceEnabled",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeCollectionsEnabled",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "CryptoWalletEnabled",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "WalletDonationEnabled",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/EdgeDebloat"
  },
  "WPFTweaksConsumerFeatures": {
    "Content": "Disable ConsumerFeatures",
    "Description": "Windows 10 will not automatically install any games, third-party apps, or application links from the Windows Store for the signed-in user. Some default Apps will be inaccessible (eg. Phone Link)",
    "category": "Essential Tweaks",
    "panel": "1",
    "Order": "a003_",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\CloudContent",
        "OriginalValue": "<RemoveEntry>",
        "Name": "DisableWindowsConsumerFeatures",
        "Value": "1",
        "Type": "DWord"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/ConsumerFeatures"
  },
  "WPFTweaksTele": {
    "Content": "Disable Telemetry",
    "Description": "Disables Microsoft Telemetry. Note: This will lock many Edge Browser settings. Microsoft spies heavily on you when using the Edge browser.",
    "category": "Essential Tweaks",
    "panel": "1",
    "Order": "a003_",
    "ScheduledTask": [
      {
        "Name": "Microsoft\\Windows\\Application Experience\\Microsoft Compatibility Appraiser",
        "State": "Disabled",
        "OriginalState": "Enabled"
      },
      {
        "Name": "Microsoft\\Windows\\Application Experience\\ProgramDataUpdater",
        "State": "Disabled",
        "OriginalState": "Enabled"
      },
      {
        "Name": "Microsoft\\Windows\\Autochk\\Proxy",
        "State": "Disabled",
        "OriginalState": "Enabled"
      },
      {
        "Name": "Microsoft\\Windows\\Customer Experience Improvement Program\\Consolidator",
        "State": "Disabled",
        "OriginalState": "Enabled"
      },
      {
        "Name": "Microsoft\\Windows\\Customer Experience Improvement Program\\UsbCeip",
        "State": "Disabled",
        "OriginalState": "Enabled"
      },
      {
        "Name": "Microsoft\\Windows\\DiskDiagnostic\\Microsoft-Windows-DiskDiagnosticDataCollector",
        "State": "Disabled",
        "OriginalState": "Enabled"
      },
      {
        "Name": "Microsoft\\Windows\\Feedback\\Siuf\\DmClient",
        "State": "Disabled",
        "OriginalState": "Enabled"
      },
      {
        "Name": "Microsoft\\Windows\\Feedback\\Siuf\\DmClientOnScenarioDownload",
        "State": "Disabled",
        "OriginalState": "Enabled"
      },
      {
        "Name": "Microsoft\\Windows\\Windows Error Reporting\\QueueReporting",
        "State": "Disabled",
        "OriginalState": "Enabled"
      },
      {
        "Name": "Microsoft\\Windows\\Application Experience\\MareBackup",
        "State": "Disabled",
        "OriginalState": "Enabled"
      },
      {
        "Name": "Microsoft\\Windows\\Application Experience\\StartupAppTask",
        "State": "Disabled",
        "OriginalState": "Enabled"
      },
      {
        "Name": "Microsoft\\Windows\\Application Experience\\PcaPatchDbTask",
        "State": "Disabled",
        "OriginalState": "Enabled"
      },
      {
        "Name": "Microsoft\\Windows\\Maps\\MapsUpdateTask",
        "State": "Disabled",
        "OriginalState": "Enabled"
      }
    ],
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\DataCollection",
        "Type": "DWord",
        "Value": "0",
        "Name": "AllowTelemetry",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\DataCollection",
        "OriginalValue": "<RemoveEntry>",
        "Name": "AllowTelemetry",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager",
        "OriginalValue": "1",
        "Name": "ContentDeliveryAllowed",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager",
        "OriginalValue": "1",
        "Name": "OemPreInstalledAppsEnabled",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager",
        "OriginalValue": "1",
        "Name": "PreInstalledAppsEnabled",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager",
        "OriginalValue": "1",
        "Name": "PreInstalledAppsEverEnabled",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager",
        "OriginalValue": "1",
        "Name": "SilentInstalledAppsEnabled",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager",
        "OriginalValue": "1",
        "Name": "SubscribedContent-338387Enabled",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager",
        "OriginalValue": "1",
        "Name": "SubscribedContent-338388Enabled",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager",
        "OriginalValue": "1",
        "Name": "SubscribedContent-338389Enabled",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager",
        "OriginalValue": "1",
        "Name": "SubscribedContent-353698Enabled",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager",
        "OriginalValue": "1",
        "Name": "SystemPaneSuggestionsEnabled",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Siuf\\Rules",
        "OriginalValue": "0",
        "Name": "NumberOfSIUFInPeriod",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\DataCollection",
        "OriginalValue": "<RemoveEntry>",
        "Name": "DoNotShowFeedbackNotifications",
        "Value": "1",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Policies\\Microsoft\\Windows\\CloudContent",
        "OriginalValue": "<RemoveEntry>",
        "Name": "DisableTailoredExperiencesWithDiagnosticData",
        "Value": "1",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\AdvertisingInfo",
        "OriginalValue": "<RemoveEntry>",
        "Name": "DisabledByGroupPolicy",
        "Value": "1",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\Windows Error Reporting",
        "OriginalValue": "0",
        "Name": "Disabled",
        "Value": "1",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\DeliveryOptimization\\Config",
        "OriginalValue": "1",
        "Name": "DODownloadMode",
        "Value": "1",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Remote Assistance",
        "OriginalValue": "1",
        "Name": "fAllowToGetHelp",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\OperationStatusManager",
        "OriginalValue": "0",
        "Name": "EnthusiastMode",
        "Value": "1",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "OriginalValue": "1",
        "Name": "ShowTaskViewButton",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\\People",
        "OriginalValue": "1",
        "Name": "PeopleBand",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "OriginalValue": "1",
        "Name": "LaunchTo",
        "Value": "1",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FileSystem",
        "OriginalValue": "0",
        "Name": "LongPathsEnabled",
        "Value": "1",
        "Type": "DWord"
      },
      {
        "_Comment": "Driver searching is a function that should be left in",
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\DriverSearching",
        "OriginalValue": "1",
        "Name": "SearchOrderConfig",
        "Value": "1",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Multimedia\\SystemProfile",
        "OriginalValue": "1",
        "Name": "SystemResponsiveness",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Multimedia\\SystemProfile",
        "OriginalValue": "1",
        "Name": "NetworkThrottlingIndex",
        "Value": "4294967295",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "OriginalValue": "1",
        "Name": "MenuShowDelay",
        "Value": "1",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "OriginalValue": "1",
        "Name": "AutoEndTasks",
        "Value": "1",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management",
        "OriginalValue": "0",
        "Name": "ClearPageFileAtShutdown",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SYSTEM\\ControlSet001\\Services\\Ndu",
        "OriginalValue": "1",
        "Name": "Start",
        "Value": "2",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "OriginalValue": "400",
        "Name": "MouseHoverTime",
        "Value": "400",
        "Type": "String"
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\LanmanServer\\Parameters",
        "OriginalValue": "20",
        "Name": "IRPStackSize",
        "Value": "30",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Windows Feeds",
        "OriginalValue": "<RemoveEntry>",
        "Name": "EnableFeeds",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Feeds",
        "OriginalValue": "1",
        "Name": "ShellFeedsTaskbarViewMode",
        "Value": "2",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer",
        "OriginalValue": "<RemoveEntry>",
        "Name": "HideSCAMeetNow",
        "Value": "1",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\UserProfileEngagement",
        "OriginalValue": "1",
        "Name": "ScoobeSystemSettingEnabled",
        "Value": "0",
        "Type": "DWord"
      }
    ],
    "InvokeScript": [
      "\r\n      bcdedit /set `{current`} bootmenupolicy Legacy | Out-Null\r\n        If ((get-ItemProperty -Path \"HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\" -Name CurrentBuild).CurrentBuild -lt 22557) {\r\n            $taskmgr = Start-Process -WindowStyle Hidden -FilePath taskmgr.exe -PassThru\r\n            Do {\r\n                Start-Sleep -Milliseconds 100\r\n                $preferences = Get-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\TaskManager\" -Name \"Preferences\" -ErrorAction SilentlyContinue\r\n            } Until ($preferences)\r\n            Stop-Process $taskmgr\r\n            $preferences.Preferences[28] = 0\r\n            Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\TaskManager\" -Name \"Preferences\" -Type Binary -Value $preferences.Preferences\r\n        }\r\n        Remove-Item -Path \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\MyComputer\\NameSpace\\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}\" -Recurse -ErrorAction SilentlyContinue\r\n\r\n        # Fix Managed by your organization in Edge if regustry path exists then remove it\r\n\r\n        If (Test-Path \"HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge\") {\r\n            Remove-Item -Path \"HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge\" -Recurse -ErrorAction SilentlyContinue\r\n        }\r\n\r\n        # Group svchost.exe processes\r\n        $ram = (Get-CimInstance -ClassName Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1kb\r\n        Set-ItemProperty -Path \"HKLM:\\SYSTEM\\CurrentControlSet\\Control\" -Name \"SvcHostSplitThresholdInKB\" -Type DWord -Value $ram -Force\r\n\r\n        $autoLoggerDir = \"$env:PROGRAMDATA\\Microsoft\\Diagnosis\\ETLLogs\\AutoLogger\"\r\n        If (Test-Path \"$autoLoggerDir\\AutoLogger-Diagtrack-Listener.etl\") {\r\n            Remove-Item \"$autoLoggerDir\\AutoLogger-Diagtrack-Listener.etl\"\r\n        }\r\n        icacls $autoLoggerDir /deny SYSTEM:`(OI`)`(CI`)F | Out-Null\r\n\r\n        # Disable Defender Auto Sample Submission\r\n        Set-MpPreference -SubmitSamplesConsent 2 -ErrorAction SilentlyContinue | Out-Null\r\n        "
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/Tele"
  },
  "WPFTweaksWifi": {
    "Content": "Disable Wifi-Sense",
    "Description": "Wifi Sense is a spying service that phones home all nearby scanned wifi networks and your current geo location.",
    "category": "Essential Tweaks",
    "panel": "1",
    "Order": "a005_",
    "registry": [
      {
        "Path": "HKLM:\\Software\\Microsoft\\PolicyManager\\default\\WiFi\\AllowWiFiHotSpotReporting",
        "Name": "Value",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\Software\\Microsoft\\PolicyManager\\default\\WiFi\\AllowAutoConnectToWiFiSenseHotspots",
        "Name": "Value",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "1"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/Wifi"
  },
  "WPFTweaksUTC": {
    "Content": "Set Time to UTC (Dual Boot)",
    "Description": "Essential for computers that are dual booting. Fixes the time sync with Linux Systems.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a027_",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\TimeZoneInformation",
        "Name": "RealTimeIsUniversal",
        "Type": "DWord",
        "Value": "1",
        "OriginalValue": "0"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/z--Advanced-Tweaks---CAUTION/UTC"
  },
  "WPFTweaksRemoveHomeGallery": {
    "Content": "Remove Home and Gallery from explorer",
    "Description": "Removes the Home and Gallery from explorer and sets This PC as default",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a029_",
    "InvokeScript": [
      "\r\n      REG DELETE \"HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Desktop\\NameSpace\\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}\" /f\r\n      REG DELETE \"HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Desktop\\NameSpace\\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}\" /f\r\n      REG ADD \"HKEY_CURRENT_USER\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\" /f /v \"LaunchTo\" /t REG_DWORD /d \"1\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      REG ADD \"HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Desktop\\NameSpace\\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}\" /f /ve /t REG_SZ /d \"{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}\"\r\n      REG ADD \"HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Desktop\\NameSpace\\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}\" /f /ve /t REG_SZ /d \"CLSID_MSGraphHomeFolder\"\r\n      REG DELETE \"HKEY_CURRENT_USER\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\" /f /v \"LaunchTo\"\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/z--Advanced-Tweaks---CAUTION/RemoveHomeGallery"
  },
  "WPFTweaksDisplay": {
    "Content": "Set Display for Performance",
    "Description": "Sets the system preferences to performance. You can do this manually with sysdm.cpl as well.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a027_",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects\\DragFullWindows",
        "OriginalValue": "1",
        "Name": "DefaultValue",
        "Value": "1",
        "Type": "String"
      },
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "OriginalValue": "1",
        "Name": "MenuShowDelay",
        "Value": "200",
        "Type": "String"
      },
      {
        "Path": "HKCU:\\Control Panel\\Desktop\\WindowMetrics",
        "OriginalValue": "1",
        "Name": "MinAnimate",
        "Value": "0",
        "Type": "String"
      },
      {
        "Path": "HKCU:\\Control Panel\\Keyboard",
        "OriginalValue": "1",
        "Name": "KeyboardDelay",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects\\AnimateMinMax",
        "OriginalValue": "1",
        "Name": "DefaultValue",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects\\TaskbarAnimations",
        "OriginalValue": "1",
        "Name": "DefaultValue",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects\\DWMAeroPeekEnabled",
        "OriginalValue": "1",
        "Name": "DefaultValue",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects",
        "OriginalValue": "1",
        "Name": "VisualFXSetting",
        "Value": "3",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects\\MenuAnimation",
        "OriginalValue": "1",
        "Name": "DefaultValue",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects\\TooltipAnimation",
        "OriginalValue": "1",
        "Name": "DefaultValue",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects\\SelectionFade,
        "OriginalValue": "1",
        "Name": "DefaultValue",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects\\DWMSaveThumbnailEnabled",
        "OriginalValue": "1",
        "Name": "DefaultValue",
        "Value": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects\\CursorShadow",
        "OriginalValue": "1",
        "Name": "DefaultValue",
        "Value": "1",
        "Type": "DWord"
      },
	  {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects\\DropShadow",
        "OriginalValue": "1",
        "Name": "DefaultValue",
        "Value": "1",
        "Type": "DWord"
      },
	  {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects\\ThumbnailsOrIcon",
        "OriginalValue": "1",
        "Name": "DefaultValue",
        "Value": "1",
        "Type": "DWord"
      },
	  {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects\\ListviewAlphaSelect",
        "OriginalValue": "1",
        "Name": "DefaultValue",
        "Value": "1",
        "Type": "DWord"
      },
	  {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects\\DragFullWindows",
        "OriginalValue": "1",
        "Name": "DefaultValue",
        "Value": "1",
        "Type": "DWord"
      },
	  {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects\\ComboBoxAnimation",
        "OriginalValue": "1",
        "Name": "DefaultValue",
        "Value": "1",
        "Type": "DWord"
      },
	  {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects\\FontSmoothing",
        "OriginalValue": "1",
        "Name": "DefaultValue",
        "Value": "1",
        "Type": "DWord"
      },
	  {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects\\ListBoxSmoothScrolling",
        "OriginalValue": "1",
        "Name": "DefaultValue",
        "Value": "1",
        "Type": "DWord"
      },
	  {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects\\ListviewShadow",
        "OriginalValue": "1",
        "Name": "DefaultValue",
        "Value": "1",
        "Type": "DWord"
      }
    ],
    "InvokeScript": [
      "Set-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\" -Type Binary -Value ([byte[]](144,18,3,128,16,0,0,0))"
    ],
    "UndoScript": [
      "Remove-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\""
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/z--Advanced-Tweaks---CAUTION/Display"
  },
  "WPFTweaksDeBloat": {
    "Content": "Remove ALL MS Store Apps - NOT RECOMMENDED",
    "Description": "USE WITH CAUTION!!!!! This will remove ALL Microsoft store apps other than the essentials to make winget work. Games installed by MS Store ARE INCLUDED!",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a028_",
    "appx": [
      "Microsoft.Microsoft3DViewer",
      "Microsoft.AppConnector",
      "Microsoft.BingFinance",
      "Microsoft.BingNews",
      "Microsoft.BingSports",
      "Microsoft.BingTranslator",
      "Microsoft.BingWeather",
      "Microsoft.BingFoodAndDrink",
      "Microsoft.BingHealthAndFitness",
      "Microsoft.BingTravel",
      "Microsoft.MinecraftUWP",
      "Microsoft.GamingServices",
      "Microsoft.GetHelp",
      "Microsoft.Getstarted",
      "Microsoft.Messaging",
      "Microsoft.Microsoft3DViewer",
      "Microsoft.MicrosoftSolitaireCollection",
      "Microsoft.NetworkSpeedTest",
      "Microsoft.News",
      "Microsoft.Office.Lens",
      "Microsoft.Office.Sway",
      "Microsoft.Office.OneNote",
      "Microsoft.OneConnect",
      "Microsoft.People",
      "Microsoft.Print3D",
      "Microsoft.SkypeApp",
      "Microsoft.Wallet",
      "Microsoft.Whiteboard",
      "Microsoft.WindowsAlarms",
      "microsoft.windowscommunicationsapps",
      "Microsoft.WindowsFeedbackHub",
      "Microsoft.WindowsMaps",
      "Microsoft.WindowsSoundRecorder",
      "Microsoft.ConnectivityStore",
      "Microsoft.ScreenSketch",
      "Microsoft.MixedReality.Portal",
      "Microsoft.ZuneMusic",
      "Microsoft.ZuneVideo",
      "Microsoft.Getstarted",
      "Microsoft.MicrosoftOfficeHub",
      "*EclipseManager*",
      "*ActiproSoftwareLLC*",
      "*AdobeSystemsIncorporated.AdobePhotoshopExpress*",
      "*Duolingo-LearnLanguagesforFree*",
      "*PandoraMediaInc*",
      "*CandyCrush*",
      "*BubbleWitch3Saga*",
      "*Wunderlist*",
      "*Flipboard*",
      "*Twitter*",
      "*Facebook*",
      "*Royal Revolt*",
      "*Sway*",
      "*Speed Test*",
      "*Dolby*",
      "*Viber*",
      "*ACGMediaPlayer*",
      "*Netflix*",
      "*OneCalendar*",
      "*LinkedInforWindows*",
      "*HiddenCityMysteryofShadows*",
      "*Hulu*",
      "*HiddenCity*",
      "*AdobePhotoshopExpress*",
      "*HotspotShieldFreeVPN*",
      "*Microsoft.Advertising.Xaml*"
    ],
    "InvokeScript": [
      "\r\n        $TeamsPath = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Microsoft', 'Teams')\r\n        $TeamsUpdateExePath = [System.IO.Path]::Combine($TeamsPath, 'Update.exe')\r\n\r\n        Write-Host \"Stopping Teams process...\"\r\n        Stop-Process -Name \"*teams*\" -Force -ErrorAction SilentlyContinue\r\n\r\n        Write-Host \"Uninstalling Teams from AppData\\Microsoft\\Teams\"\r\n        if ([System.IO.File]::Exists($TeamsUpdateExePath)) {\r\n            # Uninstall app\r\n            $proc = Start-Process $TeamsUpdateExePath \"-uninstall -s\" -PassThru\r\n            $proc.WaitForExit()\r\n        }\r\n\r\n        Write-Host \"Removing Teams AppxPackage...\"\r\n        Get-AppxPackage \"*Teams*\" | Remove-AppxPackage -ErrorAction SilentlyContinue\r\n        Get-AppxPackage \"*Teams*\" -AllUsers | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue\r\n\r\n        Write-Host \"Deleting Teams directory\"\r\n        if ([System.IO.Directory]::Exists($TeamsPath)) {\r\n            Remove-Item $TeamsPath -Force -Recurse -ErrorAction SilentlyContinue\r\n        }\r\n\r\n        Write-Host \"Deleting Teams uninstall registry key\"\r\n        # Uninstall from Uninstall registry key UninstallString\r\n        $us = (Get-ChildItem -Path HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall, HKLM:\\SOFTWARE\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall | Get-ItemProperty | Where-Object { $_.DisplayName -like '*Teams*'}).UninstallString\r\n        if ($us.Length -gt 0) {\r\n            $us = ($us.Replace('/I', '/uninstall ') + ' /quiet').Replace('  ', ' ')\r\n            $FilePath = ($us.Substring(0, $us.IndexOf('.exe') + 4).Trim())\r\n            $ProcessArgs = ($us.Substring($us.IndexOf('.exe') + 5).Trim().replace('  ', ' '))\r\n            $proc = Start-Process -FilePath $FilePath -Args $ProcessArgs -PassThru\r\n            $proc.WaitForExit()\r\n        }\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/z--Advanced-Tweaks---CAUTION/DeBloat"
  },
  "WPFTweaksRestorePoint": {
    "Content": "Create Restore Point",
    "Description": "Creates a restore point at runtime in case a revert is needed from WinUtil modifications",
    "category": "Essential Tweaks",
    "panel": "1",
    "Checked": "False",
    "Order": "a001_",
    "InvokeScript": [
      "\r\n        # Check if System Restore is enabled for the main drive\r\n        try {\r\n            # Try getting restore points to check if System Restore is enabled\r\n            Enable-ComputerRestore -Drive \"$env:SystemDrive\"\r\n        } catch {\r\n            Write-Host \"An error occurred while enabling System Restore: $_\"\r\n        }\r\n\r\n        # Check if the SystemRestorePointCreationFrequency value exists\r\n        $exists = Get-ItemProperty -path \"HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\SystemRestore\" -Name \"SystemRestorePointCreationFrequency\" -ErrorAction SilentlyContinue\r\n        if($null -eq $exists) {\r\n            write-host 'Changing system to allow multiple restore points per day'\r\n            Set-ItemProperty -Path \"HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\SystemRestore\" -Name \"SystemRestorePointCreationFrequency\" -Value \"0\" -Type DWord -Force -ErrorAction Stop | Out-Null\r\n        }\r\n\r\n        # Attempt to load the required module for Get-ComputerRestorePoint\r\n        try {\r\n            Import-Module Microsoft.PowerShell.Management -ErrorAction Stop\r\n        } catch {\r\n            Write-Host \"Failed to load the Microsoft.PowerShell.Management module: $_\"\r\n            return\r\n        }\r\n\r\n        # Get all the restore points for the current day\r\n        try {\r\n            $existingRestorePoints = Get-ComputerRestorePoint | Where-Object { $_.CreationTime.Date -eq (Get-Date).Date }\r\n        } catch {\r\n            Write-Host \"Failed to retrieve restore points: $_\"\r\n            return\r\n        }\r\n\r\n        # Check if there is already a restore point created today\r\n        if ($existingRestorePoints.Count -eq 0) {\r\n            $description = \"System Restore Point created by WinUtil\"\r\n\r\n            Checkpoint-Computer -Description $description -RestorePointType \"MODIFY_SETTINGS\"\r\n            Write-Host -ForegroundColor Green \"System Restore Point Created Successfully\"\r\n        }\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/RestorePoint"
  },
  "WPFTweaksEndTaskOnTaskbar": {
    "Content": "Enable End Task With Right Click",
    "Description": "Enables option to end task when right clicking a program in the taskbar",
    "category": "Essential Tweaks",
    "panel": "1",
    "Order": "a006_",
    "InvokeScript": [
      "$path = \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\\TaskbarDeveloperSettings\"\r\n      $name = \"TaskbarEndTask\"\r\n      $value = 1\r\n\r\n      # Ensure the registry key exists\r\n      if (-not (Test-Path $path)) {\r\n        New-Item -Path $path -Force | Out-Null\r\n      }\r\n\r\n      # Set the property, creating it if it doesn't exist\r\n      New-ItemProperty -Path $path -Name $name -PropertyType DWord -Value $value -Force | Out-Null"
    ],
    "UndoScript": [
      "$path = \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\\TaskbarDeveloperSettings\"\r\n      $name = \"TaskbarEndTask\"\r\n      $value = 0\r\n\r\n      # Ensure the registry key exists\r\n      if (-not (Test-Path $path)) {\r\n        New-Item -Path $path -Force | Out-Null\r\n      }\r\n\r\n      # Set the property, creating it if it doesn't exist\r\n      New-ItemProperty -Path $path -Name $name -PropertyType DWord -Value $value -Force | Out-Null"
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/EndTaskOnTaskbar"
  },
  "WPFTweaksPowershell7": {
    "Content": "Change Windows Terminal default: PowerShell 5 -> PowerShell 7",
    "Description": "This will edit the config file of the Windows Terminal replacing PowerShell 5 with PowerShell 7 and installing PS7 if necessary",
    "category": "Essential Tweaks",
    "panel": "1",
    "Order": "a009_",
    "InvokeScript": [
      "Invoke-WPFTweakPS7 -action \"PS7\""
    ],
    "UndoScript": [
      "Invoke-WPFTweakPS7 -action \"PS5\""
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/Powershell7"
  },
  "WPFTweaksPowershell7Tele": {
    "Content": "Disable Powershell 7 Telemetry",
    "Description": "This will create an Environment Variable called 'POWERSHELL_TELEMETRY_OPTOUT' with a value of '1' which will tell Powershell 7 to not send Telemetry Data.",
    "category": "Essential Tweaks",
    "panel": "1",
    "Order": "a009_",
    "InvokeScript": [
      "[Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', 'Machine')"
    ],
    "UndoScript": [
      "[Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '', 'Machine')"
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/Powershell7Tele"
  },
  "WPFTweaksStorage": {
    "Content": "Disable Storage Sense",
    "Description": "Storage Sense deletes temp files automatically.",
    "category": "Essential Tweaks",
    "panel": "1",
    "Order": "a005_",
    "InvokeScript": [
      "Set-ItemProperty -Path \"HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\StorageSense\\Parameters\\StoragePolicy\" -Name \"01\" -Value 0 -Type Dword -Force"
    ],
    "UndoScript": [
      "Set-ItemProperty -Path \"HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\StorageSense\\Parameters\\StoragePolicy\" -Name \"01\" -Value 1 -Type Dword -Force"
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/Storage"
  },
  "WPFTweaksRemoveEdge": {
    "Content": "Remove Microsoft Edge",
    "Description": "Removes MS Edge when it gets reinstalled by updates. Credit: Psyirius",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a029_",
    "InvokeScript": [
      "Uninstall-WinUtilEdgeBrowser -action \"Uninstall\""
    ],
    "UndoScript": [
      "Uninstall-WinUtilEdgeBrowser -action \"Install\""
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/z--Advanced-Tweaks---CAUTION/RemoveEdge"
  },
  "WPFTweaksRemoveCopilot": {
    "Content": "Disable Microsoft Copilot",
    "Description": "Disables MS Copilot AI built into Windows since 23H2.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a025_",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsCopilot",
        "Name": "TurnOffWindowsCopilot",
        "Type": "DWord",
        "Value": "1",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Windows\\WindowsCopilot",
        "Name": "TurnOffWindowsCopilot",
        "Type": "DWord",
        "Value": "1",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ShowCopilotButton",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "1"
      }
    ],
    "InvokeScript": [
      "\r\n      Write-Host \"Remove Copilot\"\r\n      dism /online /remove-package /package-name:Microsoft.Windows.Copilot\r\n      "
    ],
    "UndoScript": [
      "\r\n      Write-Host \"Install Copilot\"\r\n      dism /online /add-package /package-name:Microsoft.Windows.Copilot\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/z--Advanced-Tweaks---CAUTION/RemoveCopilot"
  },
  "WPFTweaksRecallOff": {
    "Content": "Disable Recall",
    "Description": "Turn Recall off",
    "category": "Essential Tweaks",
    "panel": "1",
    "Order": "a011_",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsAI",
        "Name": "DisableAIDataAnalysis",
        "Type": "DWord",
        "Value": "1",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "InvokeScript": [
      "\r\n      Write-Host \"Disable Recall\"\r\n      DISM /Online /Disable-Feature /FeatureName:Recall /Quiet /NoRestart\r\n      Write-Host \"Please restart your computer in order for the changes to be fully applied.\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Write-Host \"Enable Recall\"\r\n      DISM /Online /Enable-Feature /FeatureName:Recall /Quiet /NoRestart\r\n      Write-Host \"Please restart your computer in order for the changes to be fully applied.\"\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/DisableRecall"
  },
  "WPFTweaksDisableLMS1": {
    "Content": "Disable Intel MM (vPro LMS)",
    "Description": "Intel LMS service is always listening on all ports and could be a huge security risk. There is no need to run LMS on home machines and even in the Enterprise there are better solutions.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a026_",
    "InvokeScript": [
      "\r\n        Write-Host \"Kill LMS\"\r\n        $serviceName = \"LMS\"\r\n        Write-Host \"Stopping and disabling service: $serviceName\"\r\n        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue;\r\n        Set-Service -Name $serviceName -StartupType Disabled -ErrorAction SilentlyContinue;\r\n\r\n        Write-Host \"Removing service: $serviceName\";\r\n        sc.exe delete $serviceName;\r\n\r\n        Write-Host \"Removing LMS driver packages\";\r\n        $lmsDriverPackages = Get-ChildItem -Path \"C:\\Windows\\System32\\DriverStore\\FileRepository\" -Recurse -Filter \"lms.inf*\";\r\n        foreach ($package in $lmsDriverPackages) {\r\n            Write-Host \"Removing driver package: $($package.Name)\";\r\n            pnputil /delete-driver $($package.Name) /uninstall /force;\r\n        }\r\n        if ($lmsDriverPackages.Count -eq 0) {\r\n            Write-Host \"No LMS driver packages found in the driver store.\";\r\n        } else {\r\n            Write-Host \"All found LMS driver packages have been removed.\";\r\n        }\r\n\r\n        Write-Host \"Searching and deleting LMS executable files\";\r\n        $programFilesDirs = @(\"C:\\Program Files\", \"C:\\Program Files (x86)\");\r\n        $lmsFiles = @();\r\n        foreach ($dir in $programFilesDirs) {\r\n            $lmsFiles += Get-ChildItem -Path $dir -Recurse -Filter \"LMS.exe\" -ErrorAction SilentlyContinue;\r\n        }\r\n        foreach ($file in $lmsFiles) {\r\n            Write-Host \"Taking ownership of file: $($file.FullName)\";\r\n            & icacls $($file.FullName) /grant Administrators:F /T /C /Q;\r\n            & takeown /F $($file.FullName) /A /R /D Y;\r\n            Write-Host \"Deleting file: $($file.FullName)\";\r\n            Remove-Item $($file.FullName) -Force -ErrorAction SilentlyContinue;\r\n        }\r\n        if ($lmsFiles.Count -eq 0) {\r\n            Write-Host \"No LMS.exe files found in Program Files directories.\";\r\n        } else {\r\n            Write-Host \"All found LMS.exe files have been deleted.\";\r\n        }\r\n        Write-Host 'Intel LMS vPro service has been disabled, removed, and blocked.';\r\n       "
    ],
    "UndoScript": [
      "\r\n      Write-Host \"LMS vPro needs to be redownloaded from intel.com\"\r\n\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/z--Advanced-Tweaks---CAUTION/DisableLMS1"
  },
  "WPFTweaksDisableWpbtExecution": {
    "Content": "Disable Windows Platform Binary Table (WPBT)",
    "Description": "If enabled then allows your computer vendor to execute a program each time it boots. It enables computer vendors to force install anti-theft software, software drivers, or a software program conveniently. This could also be a security risk.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a027_",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager",
        "Name": "DisableWpbtExecution",
        "Value": "1",
        "OriginalValue": "<RemoveEntry>",
        "Type": "DWord"
      }
    ]
  },
  "WPFTweaksRemoveOnedrive": {
    "Content": "Remove OneDrive",
    "Description": "Moves OneDrive files to Default Home Folders and Uninstalls it.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a030_",
    "InvokeScript": [
      "\r\n      $OneDrivePath = $($env:OneDrive)\r\n      Write-Host \"Removing OneDrive\"\r\n\r\n      # Check both traditional and Microsoft Store installations\r\n      $regPath = \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\OneDriveSetup.exe\"\r\n      $msStorePath = \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\Applications\\*OneDrive*\"\r\n\r\n      if (Test-Path $regPath) {\r\n          $OneDriveUninstallString = Get-ItemPropertyValue \"$regPath\" -Name \"UninstallString\"\r\n          $OneDriveExe, $OneDriveArgs = $OneDriveUninstallString.Split(\" \")\r\n          Start-Process -FilePath $OneDriveExe -ArgumentList \"$OneDriveArgs /silent\" -NoNewWindow -Wait\r\n      } elseif (Test-Path $msStorePath) {\r\n          Write-Host \"OneDrive appears to be installed via Microsoft Store\" -ForegroundColor Yellow\r\n          # Attempt to uninstall via winget\r\n          Start-Process -FilePath winget -ArgumentList \"uninstall -e --purge --accept-source-agreements Microsoft.OneDrive\" -NoNewWindow -Wait\r\n      } else {\r\n          Write-Host \"OneDrive doesn't seem to be installed\" -ForegroundColor Red\r\n          Write-Host \"Running cleanup if OneDrive path exists\" -ForegroundColor Red\r\n      }\r\n\r\n      # Check if OneDrive got Uninstalled (both paths)\r\n      if (Test-Path $OneDrivePath) {\r\n        Write-Host \"Copy downloaded Files from the OneDrive Folder to Root UserProfile\"\r\n        Start-Process -FilePath powershell -ArgumentList \"robocopy '$($OneDrivePath)' '$($env:USERPROFILE.TrimEnd())\\' /mov /e /xj\" -NoNewWindow -Wait\r\n\r\n        Write-Host \"Removing OneDrive leftovers\"\r\n        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue \"$env:localappdata\\Microsoft\\OneDrive\"\r\n        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue \"$env:localappdata\\OneDrive\"\r\n        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue \"$env:programdata\\Microsoft OneDrive\"\r\n        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue \"$env:systemdrive\\OneDriveTemp\"\r\n        reg delete \"HKEY_CURRENT_USER\\Software\\Microsoft\\OneDrive\" -f\r\n        # check if directory is empty before removing:\r\n        If ((Get-ChildItem \"$OneDrivePath\" -Recurse | Measure-Object).Count -eq 0) {\r\n            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue \"$OneDrivePath\"\r\n        }\r\n\r\n        Write-Host \"Remove Onedrive from explorer sidebar\"\r\n        Set-ItemProperty -Path \"HKCR:\\CLSID\\{018D5C66-4533-4307-9B53-224DE2ED1FE6}\" -Name \"System.IsPinnedToNameSpaceTree\" -Value 0\r\n        Set-ItemProperty -Path \"HKCR:\\Wow6432Node\\CLSID\\{018D5C66-4533-4307-9B53-224DE2ED1FE6}\" -Name \"System.IsPinnedToNameSpaceTree\" -Value 0\r\n\r\n        Write-Host \"Removing run hook for new users\"\r\n        reg load \"hku\\Default\" \"C:\\Users\\Default\\NTUSER.DAT\"\r\n        reg delete \"HKEY_USERS\\Default\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run\" /v \"OneDriveSetup\" /f\r\n        reg unload \"hku\\Default\"\r\n\r\n        Write-Host \"Removing autostart key\"\r\n        reg delete \"HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\" /v \"OneDrive\" /f\r\n\r\n        Write-Host \"Removing startmenu entry\"\r\n        Remove-Item -Force -ErrorAction SilentlyContinue \"$env:userprofile\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\OneDrive.lnk\"\r\n\r\n        Write-Host \"Removing scheduled task\"\r\n        Get-ScheduledTask -TaskPath '\\' -TaskName 'OneDrive*' -ea SilentlyContinue | Unregister-ScheduledTask -Confirm:$false\r\n\r\n        # Add Shell folders restoring default locations\r\n        Write-Host \"Shell Fixing\"\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"AppData\" -Value \"$env:userprofile\\AppData\\Roaming\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"Cache\" -Value \"$env:userprofile\\AppData\\Local\\Microsoft\\Windows\\INetCache\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"Cookies\" -Value \"$env:userprofile\\AppData\\Local\\Microsoft\\Windows\\INetCookies\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"Favorites\" -Value \"$env:userprofile\\Favorites\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"History\" -Value \"$env:userprofile\\AppData\\Local\\Microsoft\\Windows\\History\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"Local AppData\" -Value \"$env:userprofile\\AppData\\Local\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"My Music\" -Value \"$env:userprofile\\Music\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"My Video\" -Value \"$env:userprofile\\Videos\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"NetHood\" -Value \"$env:userprofile\\AppData\\Roaming\\Microsoft\\Windows\\Network Shortcuts\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"PrintHood\" -Value \"$env:userprofile\\AppData\\Roaming\\Microsoft\\Windows\\Printer Shortcuts\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"Programs\" -Value \"$env:userprofile\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"Recent\" -Value \"$env:userprofile\\AppData\\Roaming\\Microsoft\\Windows\\Recent\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"SendTo\" -Value \"$env:userprofile\\AppData\\Roaming\\Microsoft\\Windows\\SendTo\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"Start Menu\" -Value \"$env:userprofile\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"Startup\" -Value \"$env:userprofile\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"Templates\" -Value \"$env:userprofile\\AppData\\Roaming\\Microsoft\\Windows\\Templates\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"{374DE290-123F-4565-9164-39C4925E467B}\" -Value \"$env:userprofile\\Downloads\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"Desktop\" -Value \"$env:userprofile\\Desktop\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"My Pictures\" -Value \"$env:userprofile\\Pictures\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"Personal\" -Value \"$env:userprofile\\Documents\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"{F42EE2D3-909F-4907-8871-4C22FC0BF756}\" -Value \"$env:userprofile\\Documents\" -Type ExpandString\r\n        Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders\" -Name \"{0DDD015D-B06C-45D5-8C4C-F59713854639}\" -Value \"$env:userprofile\\Pictures\" -Type ExpandString\r\n        Write-Host \"Restarting explorer\"\r\n        taskkill.exe /F /IM \"explorer.exe\"\r\n        Start-Process \"explorer.exe\"\r\n\r\n        Write-Host \"Waiting for explorer to complete loading\"\r\n        Write-Host \"Please Note - The OneDrive folder at $OneDrivePath may still have items in it. You must manually delete it, but all the files should already be copied to the base user folder.\"\r\n        Write-Host \"If there are Files missing afterwards, please Login to Onedrive.com and Download them manually\" -ForegroundColor Yellow\r\n        Start-Sleep 5\r\n      } else {\r\n        Write-Host \"Nothing to Cleanup with OneDrive\" -ForegroundColor Red\r\n      }\r\n      "
    ],
    "UndoScript": [
      "\r\n      Write-Host \"Install OneDrive\"\r\n      Start-Process -FilePath winget -ArgumentList \"install -e --accept-source-agreements --accept-package-agreements --silent Microsoft.OneDrive \" -NoNewWindow -Wait\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/z--Advanced-Tweaks---CAUTION/RemoveOnedrive"
  },
  "WPFTweaksRazerBlock": {
    "Content": "Block Razer Software Installs",
    "Description": "Blocks ALL Razer Software installations. The hardware works fine without any software.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a031_",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\DriverSearching",
        "Name": "SearchOrderConfig",
        "Value": "0",
        "OriginalValue": "1",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Device Installer",
        "Name": "DisableCoInstallers",
        "Value": "1",
        "OriginalValue": "0",
        "Type": "DWord"
      }
    ],
    "InvokeScript": [
      "\r\n          $RazerPath = \"C:\\Windows\\Installer\\Razer\"\r\n          Remove-Item $RazerPath -Recurse -Force\r\n          New-Item -Path \"C:\\Windows\\Installer\\\" -Name \"Razer\" -ItemType \"directory\"\r\n          $Acl = Get-Acl $RazerPath\r\n          $Ar = New-Object System.Security.AccessControl.FileSystemAccessRule(\"NT AUTHORITY\\SYSTEM\",\"Write\",\"ContainerInherit,ObjectInherit\",\"None\",\"Deny\")\r\n          $Acl.SetAccessRule($Ar)\r\n          Set-Acl $RazerPath $Acl\r\n      "
    ],
    "UndoScript": [
      "\r\n          $RazerPath = \"C:\\Windows\\Installer\\Razer\"\r\n          Remove-Item $RazerPath -Recurse -Force\r\n          New-Item -Path \"C:\\Windows\\Installer\\\" -Name \"Razer\" -ItemType \"directory\"\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/RazerBlock"
  },
  "WPFTweaksDisableNotifications": {
    "Content": "Disable Notification Tray/Calendar",
    "Description": "Disables all Notifications INCLUDING Calendar",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a026_",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Windows\\Explorer",
        "Name": "DisableNotificationCenter",
        "Type": "DWord",
        "Value": "1",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications",
        "Name": "ToastEnabled",
        "Type": "DWord",
        "Value": "0",
        "OriginalValue": "1"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/z--Advanced-Tweaks---CAUTION/DisableNotifications"
  },
  "WPFTweaksDebloatAdobe": {
    "Content": "Adobe Debloat",
    "Description": "Manages Adobe Services, Adobe Desktop Service, and Acrobat Updates",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a021_",
    "InvokeScript": [
      "\r\n      function CCStopper {\r\n        $path = \"C:\\Program Files (x86)\\Common Files\\Adobe\\Adobe Desktop Common\\ADS\\Adobe Desktop Service.exe\"\r\n\r\n        # Test if the path exists before proceeding\r\n        if (Test-Path $path) {\r\n            Takeown /f $path\r\n            $acl = Get-Acl $path\r\n            $acl.SetOwner([System.Security.Principal.NTAccount]\"Administrators\")\r\n            $acl | Set-Acl $path\r\n\r\n            Rename-Item -Path $path -NewName \"Adobe Desktop Service.exe.old\" -Force\r\n        } else {\r\n            Write-Host \"Adobe Desktop Service is not in the default location.\"\r\n        }\r\n      }\r\n\r\n\r\n      function AcrobatUpdates {\r\n        # Editing Acrobat Updates. The last folder before the key is dynamic, therefore using a script.\r\n        # Possible Values for the edited key:\r\n        # 0 = Do not download or install updates automatically\r\n        # 2 = Automatically download updates but let the user choose when to install them\r\n        # 3 = Automatically download and install updates (default value)\r\n        # 4 = Notify the user when an update is available but don't download or install it automatically\r\n        #   = It notifies the user using Windows Notifications. It runs on startup without having to have a Service/Acrobat/Reader running, therefore 0 is the next best thing.\r\n\r\n        $rootPath = \"HKLM:\\SOFTWARE\\WOW6432Node\\Adobe\\Adobe ARM\\Legacy\\Acrobat\"\r\n\r\n        # Get all subkeys under the specified root path\r\n        $subKeys = Get-ChildItem -Path $rootPath | Where-Object { $_.PSChildName -like \"{*}\" }\r\n\r\n        # Loop through each subkey\r\n        foreach ($subKey in $subKeys) {\r\n            # Get the full registry path\r\n            $fullPath = Join-Path -Path $rootPath -ChildPath $subKey.PSChildName\r\n            try {\r\n                Set-ItemProperty -Path $fullPath -Name Mode -Value 0\r\n                Write-Host \"Acrobat Updates have been disabled.\"\r\n            } catch {\r\n                Write-Host \"Registry Key for changing Acrobat Updates does not exist in $fullPath\"\r\n            }\r\n        }\r\n      }\r\n\r\n      CCStopper\r\n      AcrobatUpdates\r\n      "
    ],
    "UndoScript": [
      "\r\n      function RestoreCCService {\r\n        $originalPath = \"C:\\Program Files (x86)\\Common Files\\Adobe\\Adobe Desktop Common\\ADS\\Adobe Desktop Service.exe.old\"\r\n        $newPath = \"C:\\Program Files (x86)\\Common Files\\Adobe\\Adobe Desktop Common\\ADS\\Adobe Desktop Service.exe\"\r\n\r\n        if (Test-Path -Path $originalPath) {\r\n            Rename-Item -Path $originalPath -NewName \"Adobe Desktop Service.exe\" -Force\r\n            Write-Host \"Adobe Desktop Service has been restored.\"\r\n        } else {\r\n            Write-Host \"Backup file does not exist. No changes were made.\"\r\n        }\r\n      }\r\n\r\n      function AcrobatUpdates {\r\n        # Default Value:\r\n        # 3 = Automatically download and install updates\r\n\r\n        $rootPath = \"HKLM:\\SOFTWARE\\WOW6432Node\\Adobe\\Adobe ARM\\Legacy\\Acrobat\"\r\n\r\n        # Get all subkeys under the specified root path\r\n        $subKeys = Get-ChildItem -Path $rootPath | Where-Object { $_.PSChildName -like \"{*}\" }\r\n\r\n        # Loop through each subkey\r\n        foreach ($subKey in $subKeys) {\r\n            # Get the full registry path\r\n            $fullPath = Join-Path -Path $rootPath -ChildPath $subKey.PSChildName\r\n            try {\r\n                Set-ItemProperty -Path $fullPath -Name Mode -Value 3\r\n            } catch {\r\n                Write-Host \"Registry Key for changing Acrobat Updates does not exist in $fullPath\"\r\n            }\r\n        }\r\n      }\r\n\r\n      RestoreCCService\r\n      AcrobatUpdates\r\n      "
    ],
    "service": [
      {
        "Name": "AGSService",
        "StartupType": "Disabled",
        "OriginalType": "Automatic"
      },
      {
        "Name": "AGMService",
        "StartupType": "Disabled",
        "OriginalType": "Automatic"
      },
      {
        "Name": "AdobeUpdateService",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "Adobe Acrobat Update",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "Adobe Genuine Monitor Service",
        "StartupType": "Disabled",
        "OriginalType": "Automatic"
      },
      {
        "Name": "AdobeARMservice",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "Adobe Licensing Console",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "CCXProcess",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "AdobeIPCBroker",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "CoreSync",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/z--Advanced-Tweaks---CAUTION/DebloatAdobe"
  },
  "WPFTweaksBlockAdobeNet": {
    "Content": "Adobe Network Block",
    "Description": "Reduce user interruptions by selectively blocking connections to Adobe's activation and telemetry servers. Credit: Ruddernation-Designs",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a021_",
    "InvokeScript": [
      "\r\n      # Define the URL of the remote HOSTS file and the local paths\r\n      $remoteHostsUrl = \"https://raw.githubusercontent.com/Ruddernation-Designs/Adobe-URL-Block-List/master/hosts\"\r\n      $localHostsPath = \"C:\\Windows\\System32\\drivers\\etc\\hosts\"\r\n      $tempHostsPath = \"C:\\Windows\\System32\\drivers\\etc\\temp_hosts\"\r\n\r\n      # Download the remote HOSTS file to a temporary location\r\n      try {\r\n          Invoke-WebRequest -Uri $remoteHostsUrl -OutFile $tempHostsPath\r\n          Write-Output \"Downloaded the remote HOSTS file to a temporary location.\"\r\n      } catch {\r\n          Write-Error \"Failed to download the HOSTS file. Error: $_\"\r\n      }\r\n\r\n      # Check if the AdobeNetBlock has already been started\r\n      try {\r\n          $localHostsContent = Get-Content $localHostsPath -ErrorAction Stop\r\n\r\n          # Check if AdobeNetBlock markers exist\r\n          $blockStartExists = $localHostsContent -like \"*#AdobeNetBlock-start*\"\r\n          if ($blockStartExists) {\r\n              Write-Output \"AdobeNetBlock-start already exists. Skipping addition of new block.\"\r\n          } else {\r\n              # Load the new block from the downloaded file\r\n              $newBlockContent = Get-Content $tempHostsPath -ErrorAction Stop\r\n              $newBlockContent = $newBlockContent | Where-Object { $_ -notmatch \"^\\s*#\" -and $_ -ne \"\" } # Exclude empty lines and comments\r\n              $newBlockHeader = \"#AdobeNetBlock-start\"\r\n              $newBlockFooter = \"#AdobeNetBlock-end\"\r\n\r\n              # Combine the contents, ensuring new block is properly formatted\r\n              $combinedContent = $localHostsContent + $newBlockHeader, $newBlockContent, $newBlockFooter | Out-String\r\n\r\n              # Write the combined content back to the original HOSTS file\r\n              $combinedContent | Set-Content $localHostsPath -Encoding ASCII\r\n              Write-Output \"Successfully added the AdobeNetBlock.\"\r\n          }\r\n      } catch {\r\n          Write-Error \"Error during processing: $_\"\r\n      }\r\n\r\n      # Clean up temporary file\r\n      Remove-Item $tempHostsPath -ErrorAction Ignore\r\n\r\n      # Flush the DNS resolver cache\r\n      try {\r\n          Invoke-Expression \"ipconfig /flushdns\"\r\n          Write-Output \"DNS cache flushed successfully.\"\r\n      } catch {\r\n          Write-Error \"Failed to flush DNS cache. Error: $_\"\r\n      }\r\n      "
    ],
    "UndoScript": [
      "\r\n      # Define the local path of the HOSTS file\r\n      $localHostsPath = \"C:\\Windows\\System32\\drivers\\etc\\hosts\"\r\n\r\n      # Load the content of the HOSTS file\r\n      try {\r\n          $hostsContent = Get-Content $localHostsPath -ErrorAction Stop\r\n      } catch {\r\n          Write-Error \"Failed to load the HOSTS file. Error: $_\"\r\n          return\r\n      }\r\n\r\n      # Initialize flags and buffer for new content\r\n      $recording = $true\r\n      $newContent = @()\r\n\r\n      # Iterate over each line of the HOSTS file\r\n      foreach ($line in $hostsContent) {\r\n          if ($line -match \"#AdobeNetBlock-start\") {\r\n              $recording = $false\r\n          }\r\n          if ($recording) {\r\n              $newContent += $line\r\n          }\r\n          if ($line -match \"#AdobeNetBlock-end\") {\r\n              $recording = $true\r\n          }\r\n      }\r\n\r\n      # Write the filtered content back to the HOSTS file\r\n      try {\r\n          $newContent | Set-Content $localHostsPath -Encoding ASCII\r\n          Write-Output \"Successfully removed the AdobeNetBlock section from the HOSTS file.\"\r\n      } catch {\r\n          Write-Error \"Failed to write back to the HOSTS file. Error: $_\"\r\n      }\r\n\r\n      # Flush the DNS resolver cache\r\n      try {\r\n          Invoke-Expression \"ipconfig /flushdns\"\r\n          Write-Output \"DNS cache flushed successfully.\"\r\n      } catch {\r\n          Write-Error \"Failed to flush DNS cache. Error: $_\"\r\n      }\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/z--Advanced-Tweaks---CAUTION/BlockAdobeNet"
  },
  "WPFTweaksRightClickMenu": {
    "Content": "Set Classic Right-Click Menu ",
    "Description": "Great Windows 11 tweak to bring back good context menus when right clicking things in explorer.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a027_",
    "InvokeScript": [
      "\r\n      New-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Name \"InprocServer32\" -force -value \"\"\r\n      Write-Host Restarting explorer.exe ...\r\n      $process = Get-Process -Name \"explorer\"\r\n      Stop-Process -InputObject $process\r\n      "
    ],
    "UndoScript": [
      "\r\n      Remove-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Recurse -Confirm:$false -Force\r\n      # Restarting Explorer in the Undo Script might not be necessary, as the Registry change without restarting Explorer does work, but just to make sure.\r\n      Write-Host Restarting explorer.exe ...\r\n      $process = Get-Process -Name \"explorer\"\r\n      Stop-Process -InputObject $process\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/z--Advanced-Tweaks---CAUTION/RightClickMenu"
  },
  "WPFTweaksDiskCleanup": {
    "Content": "Run Disk Cleanup",
    "Description": "Runs Disk Cleanup on Drive C: and removes old Windows Updates.",
    "category": "Essential Tweaks",
    "panel": "1",
    "Order": "a009_",
    "InvokeScript": [
      "\r\n      cleanmgr.exe /d C: /VERYLOWDISK\r\n      Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/DiskCleanup"
  },
  "WPFTweaksDeleteTempFiles": {
    "Content": "Delete Temporary Files",
    "Description": "Erases TEMP Folders",
    "category": "Essential Tweaks",
    "panel": "1",
    "Order": "a002_",
    "InvokeScript": [
      "Get-ChildItem -Path \"C:\\Windows\\Temp\" *.* -Recurse | Remove-Item -Force -Recurse\r\n    Get-ChildItem -Path $env:TEMP *.* -Recurse | Remove-Item -Force -Recurse"
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/DeleteTempFiles"
  },
  "WPFTweaksDVR": {
    "Content": "Disable GameDVR",
    "Description": "GameDVR is a Windows App that is a dependency for some Store Games. I've never met someone that likes it, but it's there for the XBOX crowd.",
    "category": "Essential Tweaks",
    "panel": "1",
    "Order": "a005_",
    "registry": [
      {
        "Path": "HKCU:\\System\\GameConfigStore",
        "Name": "GameDVR_FSEBehavior",
        "Value": "2",
        "OriginalValue": "1",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\System\\GameConfigStore",
        "Name": "GameDVR_Enabled",
        "Value": "0",
        "OriginalValue": "1",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\System\\GameConfigStore",
        "Name": "GameDVR_HonorUserFSEBehaviorMode",
        "Value": "1",
        "OriginalValue": "0",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\System\\GameConfigStore",
        "Name": "GameDVR_EFSEFeatureFlags",
        "Value": "0",
        "OriginalValue": "1",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\GameDVR",
        "Name": "AllowGameDVR",
        "Value": "0",
        "OriginalValue": "<RemoveEntry>",
        "Type": "DWord"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/DVR"
  },
  "WPFTweaksIPv46": {
    "Content": "Prefer IPv4 over IPv6",
    "Description": "To set the IPv4 preference can have latency and security benefits on private networks where IPv6 is not configured.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a023_",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "32",
        "OriginalValue": "0",
        "Type": "DWord"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Essential-Tweaks/IPv46"
  },
  "WPFTweaksTeredo": {
    "Content": "Disable Teredo",
    "Description": "Teredo network tunneling is a ipv6 feature that can cause additional latency, but may cause problems with some games",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a023_",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "1",
        "OriginalValue": "0",
        "Type": "DWord"
      }
    ],
    "InvokeScript": [
      "netsh interface teredo set state disabled"
    ],
    "UndoScript": [
      "netsh interface teredo set state default"
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/z--Advanced-Tweaks---CAUTION/Teredo"
  },
  "WPFTweaksDisableipsix": {
    "Content": "Disable IPv6",
    "Description": "Disables IPv6.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a023_",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "255",
        "OriginalValue": "0",
        "Type": "DWord"
      }
    ],
    "InvokeScript": [
      "Disable-NetAdapterBinding -Name \"*\" -ComponentID ms_tcpip6"
    ],
    "UndoScript": [
      "Enable-NetAdapterBinding -Name \"*\" -ComponentID ms_tcpip6"
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/z--Advanced-Tweaks---CAUTION/Disableipsix"
  },
  "WPFTweaksDisableBGapps": {
    "Content": "Disable Background Apps",
    "Description": "Disables all Microsoft Store apps from running in the background, which has to be done individually since Win11",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a024_",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\BackgroundAccessApplications",
        "Name": "GlobalUserDisabled",
        "Value": "1",
        "OriginalValue": "0",
        "Type": "DWord"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/z--Advanced-Tweaks---CAUTION/DisableBGapps"
  },
  "WPFTweaksDisableFSO": {
    "Content": "Disable Fullscreen Optimizations",
    "Description": "Disables FSO in all applications. NOTE: This will disable Color Management in Exclusive Fullscreen",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a024_",
    "registry": [
      {
        "Path": "HKCU:\\System\\GameConfigStore",
        "Name": "GameDVR_DXGIHonorFSEWindowsCompatible",
        "Value": "1",
        "OriginalValue": "0",
        "Type": "DWord"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/z--Advanced-Tweaks---CAUTION/DisableFSO"
  },
  "WPFToggleDarkMode": {
    "Content": "Dark Theme for Windows",
    "Description": "Enable/Disable Dark Mode.",
    "category": "Customize Preferences",
    "panel": "2",
    "Order": "a100_",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        "Name": "AppsUseLightTheme",
        "Value": "0",
        "OriginalValue": "1",
        "DefaultState": "false",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        "Name": "SystemUsesLightTheme",
        "Value": "0",
        "OriginalValue": "1",
        "DefaultState": "false",
        "Type": "DWord"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate\r\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\r\n        Invoke-WinutilThemeChange -theme \"Auto\"\r\n      }\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate\r\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\r\n        Invoke-WinutilThemeChange -theme \"Auto\"\r\n      }\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Customize-Preferences/DarkMode"
  },
  "WPFToggleBingSearch": {
    "Content": "Bing Search in Start Menu",
    "Description": "If enable then includes web search results from Bing in your Start Menu search.",
    "category": "Customize Preferences",
    "panel": "2",
    "Order": "a101_",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "BingSearchEnabled",
        "Value": "1",
        "OriginalValue": "0",
        "DefaultState": "true",
        "Type": "DWord"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Customize-Preferences/BingSearch"
  },
  "WPFToggleNumLock": {
    "Content": "NumLock on Startup",
    "Description": "Toggle the Num Lock key state when your computer starts.",
    "category": "Customize Preferences",
    "panel": "2",
    "Order": "a102_",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKU:\\.Default\\Control Panel\\Keyboard",
        "Name": "InitialKeyboardIndicators",
        "Value": "2",
        "OriginalValue": "0",
        "DefaultState": "false",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\Control Panel\\Keyboard",
        "Name": "InitialKeyboardIndicators",
        "Value": "2",
        "OriginalValue": "0",
        "DefaultState": "false",
        "Type": "DWord"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Customize-Preferences/NumLock"
  },
  "WPFToggleVerboseLogon": {
    "Content": "Verbose Messages During Logon",
    "Description": "Show detailed messages during the login process for troubleshooting and diagnostics.",
    "category": "Customize Preferences",
    "panel": "2",
    "Order": "a103_",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System",
        "Name": "VerboseStatus",
        "Value": "1",
        "OriginalValue": "0",
        "DefaultState": "false",
        "Type": "DWord"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Customize-Preferences/VerboseLogon"
  },
  "WPFToggleStartMenuRecommendations": {
    "Content": "Recommendations in Start Menu",
    "Description": "If disabled then you will not see recommendations in the Start Menu. | Enables 'iseducationenvironment' | Relogin Required.",
    "category": "Customize Preferences",
    "panel": "2",
    "Order": "a104_",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Start",
        "Name": "HideRecommendedSection",
        "Value": "0",
        "OriginalValue": "1",
        "DefaultState": "true",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Education",
        "Name": "IsEducationEnvironment",
        "Value": "0",
        "OriginalValue": "1",
        "DefaultState": "true",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer",
        "Name": "HideRecommendedSection",
        "Value": "0",
        "OriginalValue": "1",
        "DefaultState": "true",
        "Type": "DWord"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Customize-Preferences/WPFToggleStartMenuRecommendations"
  },
  "WPFToggleSnapWindow": {
    "Content": "Snap Window",
    "Description": "If enabled you can align windows by dragging them. | Relogin Required",
    "category": "Customize Preferences",
    "panel": "2",
    "Order": "a105_",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "WindowArrangementActive",
        "Value": "1",
        "OriginalValue": "0",
        "DefaultState": "true",
        "Type": "String"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Customize-Preferences/SnapWindow"
  },
  "WPFToggleSnapFlyout": {
    "Content": "Snap Assist Flyout",
    "Description": "If enabled then Snap preview is disabled when maximize button is hovered.",
    "category": "Customize Preferences",
    "panel": "2",
    "Order": "a106_",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "EnableSnapAssistFlyout",
        "Value": "1",
        "OriginalValue": "0",
        "DefaultState": "true",
        "Type": "DWord"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Customize-Preferences/SnapFlyout"
  },
  "WPFToggleSnapSuggestion": {
    "Content": "Snap Assist Suggestion",
    "Description": "If enabled then you will get suggestions to snap other applications in the left over spaces.",
    "category": "Customize Preferences",
    "panel": "2",
    "Order": "a107_",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "SnapAssist",
        "Value": "1",
        "OriginalValue": "0",
        "DefaultState": "true",
        "Type": "DWord"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Customize-Preferences/SnapSuggestion"
  },
  "WPFToggleMouseAcceleration": {
    "Content": "Mouse Acceleration",
    "Description": "If Enabled then Cursor movement is affected by the speed of your physical mouse movements.",
    "category": "Customize Preferences",
    "panel": "2",
    "Order": "a108_",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseSpeed",
        "Value": "1",
        "OriginalValue": "0",
        "DefaultState": "true",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseThreshold1",
        "Value": "6",
        "OriginalValue": "0",
        "DefaultState": "true",
        "Type": "DWord"
      },
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseThreshold2",
        "Value": "10",
        "OriginalValue": "0",
        "DefaultState": "true",
        "Type": "DWord"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Customize-Preferences/MouseAcceleration"
  },
  "WPFToggleStickyKeys": {
    "Content": "Sticky Keys",
    "Description": "If Enabled then Sticky Keys is activated - Sticky keys is an accessibility feature of some graphical user interfaces which assists users who have physical disabilities or help users reduce repetitive strain injury.",
    "category": "Customize Preferences",
    "panel": "2",
    "Order": "a109_",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Accessibility\\StickyKeys",
        "Name": "Flags",
        "Value": "510",
        "OriginalValue": "58",
        "DefaultState": "true",
        "Type": "DWord"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Customize-Preferences/StickyKeys"
  },
  "WPFToggleHiddenFiles": {
    "Content": "Show Hidden Files",
    "Description": "If Enabled then Hidden Files will be shown.",
    "category": "Customize Preferences",
    "panel": "2",
    "Order": "a200_",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "Hidden",
        "Value": "1",
        "OriginalValue": "0",
        "DefaultState": "false",
        "Type": "DWord"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Customize-Preferences/HiddenFiles"
  },
  "WPFToggleShowExt": {
    "Content": "Show File Extensions",
    "Description": "If enabled then File extensions (e.g., .txt, .jpg) are visible.",
    "category": "Customize Preferences",
    "panel": "2",
    "Order": "a201_",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "HideFileExt",
        "Value": "0",
        "OriginalValue": "1",
        "DefaultState": "false",
        "Type": "DWord"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Customize-Preferences/ShowExt"
  },
  "WPFToggleTaskbarSearch": {
    "Content": "Search Button in Taskbar",
    "Description": "If Enabled Search Button will be on the taskbar.",
    "category": "Customize Preferences",
    "panel": "2",
    "Order": "a202_",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "SearchboxTaskbarMode",
        "Value": "1",
        "OriginalValue": "0",
        "DefaultState": "true",
        "Type": "DWord"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Customize-Preferences/TaskbarSearch"
  },
  "WPFToggleTaskView": {
    "Content": "Task View Button in Taskbar",
    "Description": "If Enabled then Task View Button in Taskbar will be shown.",
    "category": "Customize Preferences",
    "panel": "2",
    "Order": "a203_",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ShowTaskViewButton",
        "Value": "1",
        "OriginalValue": "0",
        "DefaultState": "true",
        "Type": "DWord"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Customize-Preferences/TaskView"
  },
  "WPFToggleTaskbarWidgets": {
    "Content": "Widgets Button in Taskbar",
    "Description": "If Enabled then Widgets Button in Taskbar will be shown.",
    "category": "Customize Preferences",
    "panel": "2",
    "Order": "a204_",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarDa",
        "Value": "1",
        "OriginalValue": "0",
        "DefaultState": "true",
        "Type": "DWord"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Customize-Preferences/TaskbarWidgets"
  },
  "WPFToggleTaskbarAlignment": {
    "Content": "Center Taskbar Items",
    "Description": "[Windows 11] If Enabled then the Taskbar Items will be shown on the Center, otherwise the Taskbar Items will be shown on the Left.",
    "category": "Customize Preferences",
    "panel": "2",
    "Order": "a204_",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarAl",
        "Value": "1",
        "OriginalValue": "0",
        "DefaultState": "true",
        "Type": "DWord"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Customize-Preferences/TaskbarAlignment"
  },
  "WPFToggleDetailedBSoD": {
    "Content": "Detailed BSoD",
    "Description": "If Enabled then you will see a detailed Blue Screen of Death (BSOD) with more information.",
    "category": "Customize Preferences",
    "panel": "2",
    "Order": "a205_",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
        "Name": "DisplayParameters",
        "Value": "1",
        "OriginalValue": "0",
        "DefaultState": "false",
        "Type": "DWord"
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
        "Name": "DisableEmoticon",
        "Value": "1",
        "OriginalValue": "0",
        "DefaultState": "false",
        "Type": "DWord"
      }
    ],
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Customize-Preferences/DetailedBSoD"
  },
  "WPFOOSUbutton": {
    "Content": "Run OO Shutup 10",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a039_",
    "Type": "Button",
    "link": "https://christitustech.github.io/winutil/dev/tweaks/z--Advanced-Tweaks---CAUTION/OOSUbutton"
  },
  "WPFchangedns": {
    "Content": "DNS",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Order": "a040_",
    "Type": "Combobox",
    "ComboItems": "Default DHCP Google Cloudflare Cloudflare_Malware Cloudflare_Malware_Adult Open_DNS Quad9 AdGuard_Ads_Trackers AdGuard_Ads_Trackers_Malware_Adult dns0.eu_Open dns0.eu_ZERO dns0.eu_KIDS",
    "link": "https://christitustech.github.io/winutil/dev/tweaks/z--Advanced-Tweaks---CAUTION/changedns"
  },
  "WPFAddUltPerf": {
    "Content": "Add and Activate Ultimate Performance Profile",
    "category": "Performance Plans",
    "panel": "2",
    "Order": "a080_",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Performance-Plans/AddUltPerf"
  },
  "WPFRemoveUltPerf": {
    "Content": "Remove Ultimate Performance Profile",
    "category": "Performance Plans",
    "panel": "2",
    "Order": "a081_",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://christitustech.github.io/winutil/dev/tweaks/Performance-Plans/RemoveUltPerf"
  }
}
'@ | ConvertFrom-Json
$inputXML = @'
<Window x:Class="WinUtility.MainWindow"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:d="http://schemas.microsoft.com/expression/blend/2008"
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
        xmlns:local="clr-namespace:WinUtility"
        mc:Ignorable="d"
        WindowStartupLocation="CenterScreen"
        UseLayoutRounding="True"
        WindowStyle="None"
        Width="Auto"
        Height="Auto"
        MaxWidth="1380"
        MaxHeight="800"
        Title="Chris Titus Tech's Windows Utility">
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="0" CornerRadius="10"/>
    </WindowChrome.WindowChrome>
    <Window.Resources>
    <Style TargetType="ToolTip">
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="Padding" Value="5"/>
        <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
        <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
    </Style>

    <Style TargetType="{x:Type MenuItem}">
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
        <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        <Setter Property="Padding" Value="5,2,5,2"/>
        <Setter Property="BorderThickness" Value="0"/>
    </Style>

    <!--Scrollbar Thumbs-->
    <Style x:Key="ScrollThumbs" TargetType="{x:Type Thumb}">
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type Thumb}">
                    <Grid x:Name="Grid">
                        <Rectangle HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto" Height="Auto" Fill="Transparent" />
                        <Border x:Name="Rectangle1" CornerRadius="5" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto" Height="Auto"  Background="{TemplateBinding Background}" />
                    </Grid>
                    <ControlTemplate.Triggers>
                        <Trigger Property="Tag" Value="Horizontal">
                            <Setter TargetName="Rectangle1" Property="Width" Value="Auto" />
                            <Setter TargetName="Rectangle1" Property="Height" Value="7" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="TextBlock" x:Key="HoverTextBlockStyle">
        <Setter Property="Foreground" Value="{DynamicResource LinkForegroundColor}" />
        <Setter Property="TextDecorations" Value="Underline" />
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="{DynamicResource LinkHoverForegroundColor}" />
                <Setter Property="TextDecorations" Value="Underline" />
                <Setter Property="Cursor" Value="Hand" />
            </Trigger>
        </Style.Triggers>
    </Style>

    <Style TargetType="Button" x:Key="HoverButtonStyle">
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
        <Setter Property="FontWeight" Value="Normal" />
        <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}" />
        <Setter Property="TextElement.FontFamily" Value="{DynamicResource ButtonFontFamily}"/>
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border Background="{TemplateBinding Background}">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter Property="FontWeight" Value="Bold" />
                            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
                            <Setter Property="Cursor" Value="Hand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!--ScrollBars-->
    <Style x:Key="{x:Type ScrollBar}" TargetType="{x:Type ScrollBar}">
        <Setter Property="Stylus.IsFlicksEnabled" Value="false" />
        <Setter Property="Foreground" Value="{DynamicResource ScrollBarBackgroundColor}" />
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Width" Value="6" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type ScrollBar}">
                    <Grid x:Name="GridRoot" Width="7" Background="{TemplateBinding Background}" >
                        <Grid.RowDefinitions>
                            <RowDefinition Height="0.00001*" />
                        </Grid.RowDefinitions>

                        <Track x:Name="PART_Track" Grid.Row="0" IsDirectionReversed="true" Focusable="false">
                            <Track.Thumb>
                                <Thumb x:Name="Thumb" Background="{TemplateBinding Foreground}" Style="{DynamicResource ScrollThumbs}" />
                            </Track.Thumb>
                            <Track.IncreaseRepeatButton>
                                <RepeatButton x:Name="PageUp" Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="false" />
                            </Track.IncreaseRepeatButton>
                            <Track.DecreaseRepeatButton>
                                <RepeatButton x:Name="PageDown" Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="false" />
                            </Track.DecreaseRepeatButton>
                        </Track>
                    </Grid>

                    <ControlTemplate.Triggers>
                        <Trigger SourceName="Thumb" Property="IsMouseOver" Value="true">
                            <Setter Value="{DynamicResource ScrollBarHoverColor}" TargetName="Thumb" Property="Background" />
                        </Trigger>
                        <Trigger SourceName="Thumb" Property="IsDragging" Value="true">
                            <Setter Value="{DynamicResource ScrollBarDraggingColor}" TargetName="Thumb" Property="Background" />
                        </Trigger>

                        <Trigger Property="IsEnabled" Value="false">
                            <Setter TargetName="Thumb" Property="Visibility" Value="Collapsed" />
                        </Trigger>
                        <Trigger Property="Orientation" Value="Horizontal">
                            <Setter TargetName="GridRoot" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter TargetName="PART_Track" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter Property="Width" Value="Auto" />
                            <Setter Property="Height" Value="8" />
                            <Setter TargetName="Thumb" Property="Tag" Value="Horizontal" />
                            <Setter TargetName="PageDown" Property="Command" Value="ScrollBar.PageLeftCommand" />
                            <Setter TargetName="PageUp" Property="Command" Value="ScrollBar.PageRightCommand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Foreground" Value="{DynamicResource ComboBoxForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource ComboBoxBackgroundColor}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton x:Name="ToggleButton"
                                          Background="{TemplateBinding Background}"
                                          BorderBrush="{TemplateBinding Background}"
                                          BorderThickness="0"
                                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                          ClickMode="Press">
                                <TextBlock Text="{TemplateBinding SelectionBoxItem}"
                                           Foreground="{TemplateBinding Foreground}"
                                           Background="Transparent"
                                           HorizontalAlignment="Center" VerticalAlignment="Center" Margin="2"
                                           />
                            </ToggleButton>
                            <Popup x:Name="Popup"
                                   IsOpen="{TemplateBinding IsDropDownOpen}"
                                   Placement="Bottom"
                                   Focusable="False"
                                   AllowsTransparency="True"
                                   PopupAnimation="Slide">
                                <Border x:Name="DropDownBorder"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{TemplateBinding Foreground}"
                                        BorderThickness="1"
                                        CornerRadius="4">
                                    <ScrollViewer>
                                        <ItemsPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="2"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource LabelBackgroundColor}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        </Style>
        <!-- Category Toggle Button Style for the Apps Window-->
        <Style x:Key="CategoryToggleButtonStyle" TargetType="ToggleButton">
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="FontFamily" Value="{DynamicResource HeaderFontFamily}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSizeHeading}"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Padding" Value="10,2,10,2"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{DynamicResource BorderColor}"
                                BorderThickness="0"
                                CornerRadius="{DynamicResource ButtonCornerRadius}">
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" Margin="{TemplateBinding Padding}">
                                <TextBlock x:Name="PrefixTextBlock"/>
                                <ContentPresenter Content="{TemplateBinding Content}" />
                            </StackPanel>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="PrefixTextBlock" Property="Text" Value="[-] "/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="False">
                                <Setter TargetName="PrefixTextBlock" Property="Text" Value="[+] "/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- TextBlock template -->
        <Style TargetType="TextBlock">
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource LabelBackgroundColor}"/>
        </Style>
        <!-- Toggle button template x:Key="TabToggleButton" -->
        <Style TargetType="{x:Type ToggleButton}">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Content" Value=""/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Grid>
                            <Border x:Name="ButtonGlow"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource ButtonForegroundColor}"
                                        BorderThickness="{DynamicResource ButtonBorderThickness}"
                                        CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <Grid>
                                    <Border x:Name="BackgroundBorder"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource ButtonBackgroundColor}"
                                        BorderThickness="{DynamicResource ButtonBorderThickness}"
                                        CornerRadius="{DynamicResource ButtonCornerRadius}">
                                        <ContentPresenter
                                            HorizontalAlignment="Center"
                                            VerticalAlignment="Center"
                                            Margin="10,2,10,2"/>
                                    </Border>
                                </Grid>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                                <Setter Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Opacity="1" ShadowDepth="5" Color="{DynamicResource CButtonBackgroundMouseoverColor}" Direction="-100" BlurRadius="15"/>
                                    </Setter.Value>
                                </Setter>
                                <Setter Property="Panel.ZIndex" Value="2000"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter Property="BorderBrush" Value="Pink"/>
                                <Setter Property="BorderThickness" Value="2"/>
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Opacity="1" ShadowDepth="2" Color="{DynamicResource CButtonBackgroundMouseoverColor}" Direction="-111" BlurRadius="10"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="False">
                                <Setter Property="BorderBrush" Value="Transparent"/>
                                <Setter Property="BorderThickness" Value="{DynamicResource ButtonBorderThickness}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Button Template -->
        <Style TargetType="Button">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
            <Setter Property="Height" Value="{DynamicResource ButtonHeight}"/>
            <Setter Property="Width" Value="{DynamicResource ButtonWidth}"/>
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border x:Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="10,2,10,2"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ToggleButtonStyle" TargetType="ToggleButton">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
            <Setter Property="Height" Value="{DynamicResource ButtonHeight}"/>
            <Setter Property="Width" Value="{DynamicResource ButtonWidth}"/>
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Grid>
                            <Border x:Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <Grid>
                                    <!-- Toggle Dot Background -->
                                    <Ellipse Width="8" Height="16"
                                            Fill="{DynamicResource ToggleButtonOnColor}"
                                            HorizontalAlignment="Right"
                                            VerticalAlignment="Top"
                                            Margin="0,3,5,0" />

                                    <!-- Toggle Dot with hover grow effect -->
                                    <Ellipse x:Name="ToggleDot"
                                            Width="8" Height="8"
                                            Fill="{DynamicResource ButtonForegroundColor}"
                                            HorizontalAlignment="Right"
                                            VerticalAlignment="Top"
                                            Margin="0,3,5,0"
                                            RenderTransformOrigin="0.5,0.5">
                                        <Ellipse.RenderTransform>
                                            <ScaleTransform ScaleX="1" ScaleY="1"/>
                                        </Ellipse.RenderTransform>
                                    </Ellipse>

                                    <!-- Content Presenter -->
                                    <ContentPresenter HorizontalAlignment="Center"
                                                    VerticalAlignment="Center"
                                                    Margin="10,2,10,2"/>
                                </Grid>
                            </Border>
                        </Grid>

                        <!-- Triggers for ToggleButton states -->
                        <ControlTemplate.Triggers>
                            <!-- Hover effect -->
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <!-- Animation to grow the dot when hovered -->
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.2" Duration="0:0:0.1"/>
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.2" Duration="0:0:0.1"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <!-- Animation to shrink the dot back to original size when not hovered -->
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.0" Duration="0:0:0.1"/>
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.0" Duration="0:0:0.1"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>

                            <!-- IsChecked state -->
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="ToggleDot" Property="VerticalAlignment" Value="Bottom"/>
                                <Setter TargetName="ToggleDot" Property="Margin" Value="0,0,5,3"/>
                            </Trigger>

                            <!-- IsEnabled state -->
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SearchBarClearButtonStyle" TargetType="Button">
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="FontSize" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Content" Value="X"/>
            <Setter Property="Height" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Width" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Foreground" Value="Red"/>
                    <Setter Property="Background" Value="Transparent"/>
                    <Setter Property="BorderThickness" Value="10"/>
                    <Setter Property="Cursor" Value="Hand"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <!-- Checkbox template -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="TextElement.FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid Background="{TemplateBinding Background}" Margin="{DynamicResource CheckBoxMargin}">
                            <BulletDecorator Background="Transparent">
                                <BulletDecorator.Bullet>
                                    <Grid Width="{DynamicResource CheckBoxBulletDecoratorSize}" Height="{DynamicResource CheckBoxBulletDecoratorSize}">
                                        <Border x:Name="Border"
                                                BorderBrush="{TemplateBinding BorderBrush}"
                                                Background="{DynamicResource ButtonBackgroundColor}"
                                                BorderThickness="1"
                                                Width="{DynamicResource CheckBoxBulletDecoratorSize *0.85}"
                                                Height="{DynamicResource CheckBoxBulletDecoratorSize *0.85}"
                                                Margin="2"
                                                SnapsToDevicePixels="True"/>
                                        <Path x:Name="CheckMark"
                                              Stroke="{DynamicResource ToggleButtonOnColor}"
                                              StrokeThickness="2"
                                              Data="M 0 5 L 5 10 L 12 0"
                                              Visibility="Collapsed"/>
                                    </Grid>
                                </BulletDecorator.Bullet>
                                <ContentPresenter Margin="4,0,0,0"
                                                  HorizontalAlignment="Left"
                                                  VerticalAlignment="Center"
                                                  RecognizesAccessKey="True"/>
                            </BulletDecorator>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <!--Setter TargetName="Border" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/-->
                                <Setter Property="Foreground" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                 </Setter.Value>
            </Setter>
        </Style>
    <!-- Collapsed Checkbox Style -->
    <Style x:Key="CollapsedCheckBoxStyle" TargetType="CheckBox">
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="CheckBox">
                    <ContentPresenter Content="{TemplateBinding Content}"
                                    VerticalAlignment="Center"
                                    HorizontalAlignment="Left"
                                    Margin="{TemplateBinding Padding}"/>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <StackPanel Orientation="Horizontal" Margin="{DynamicResource CheckBoxMargin}">
                            <Grid Width="14" Height="14">
                                <Ellipse x:Name="OuterCircle"
                                        Stroke="{DynamicResource ToggleButtonOffColor}"
                                        Fill="{DynamicResource ButtonBackgroundColor}"
                                        StrokeThickness="1"
                                        Width="14"
                                        Height="14"
                                        SnapsToDevicePixels="True"/>
                                <Ellipse x:Name="InnerCircle"
                                        Fill="{DynamicResource ToggleButtonOnColor}"
                                        Width="8"
                                        Height="8"
                                        Visibility="Collapsed"
                                        HorizontalAlignment="Center"
                                        VerticalAlignment="Center"/>
                            </Grid>
                            <ContentPresenter Margin="4,0,0,0"
                                            VerticalAlignment="Center"
                                            RecognizesAccessKey="True"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="InnerCircle" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="OuterCircle" Property="Stroke" Value="{DynamicResource ToggleButtonOnColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ToggleSwitchStyle" TargetType="CheckBox">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel>
                            <Grid>
                                <Border Width="45"
                                        Height="20"
                                        Background="#555555"
                                        CornerRadius="10"
                                        Margin="5,0"
                                />
                                <Border Name="WPFToggleSwitchButton"
                                        Width="25"
                                        Height="25"
                                        Background="Black"
                                        CornerRadius="12.5"
                                        HorizontalAlignment="Left"
                                />
                                <ContentPresenter Name="WPFToggleSwitchContent"
                                                  Margin="10,0,0,0"
                                                  Content="{TemplateBinding Content}"
                                                  VerticalAlignment="Center"
                                />
                            </Grid>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="false">
                                <Trigger.ExitActions>
                                    <RemoveStoryboard BeginStoryboardName="WPFToggleSwitchLeft" />
                                    <BeginStoryboard x:Name="WPFToggleSwitchRight">
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetProperty="Margin"
                                                    Storyboard.TargetName="WPFToggleSwitchButton"
                                                    Duration="0:0:0:0"
                                                    From="0,0,0,0"
                                                    To="28,0,0,0">
                                            </ThicknessAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                                <Setter TargetName="WPFToggleSwitchButton"
                                        Property="Background"
                                        Value="#fff9f4f4"
                                />
                            </Trigger>
                            <Trigger Property="IsChecked" Value="true">
                                <Trigger.ExitActions>
                                    <RemoveStoryboard BeginStoryboardName="WPFToggleSwitchRight" />
                                    <BeginStoryboard x:Name="WPFToggleSwitchLeft">
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetProperty="Margin"
                                                    Storyboard.TargetName="WPFToggleSwitchButton"
                                                    Duration="0:0:0:0"
                                                    From="28,0,0,0"
                                                    To="0,0,0,0">
                                            </ThicknessAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                                <Setter TargetName="WPFToggleSwitchButton"
                                        Property="Background"
                                        Value="#ff060600"
                                />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ColorfulToggleSwitchStyle" TargetType="{x:Type CheckBox}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ToggleButton}">
                        <Grid x:Name="toggleSwitch">

                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <Border Grid.Column="1" x:Name="Border" CornerRadius="8"
                                BorderThickness="1"
                                Width="34" Height="17">
                            <Ellipse x:Name="Ellipse" Fill="{DynamicResource MainForegroundColor}" Stretch="Uniform"
                                    Margin="2,2,2,1"
                                    HorizontalAlignment="Left" Width="10.8"
                                    RenderTransformOrigin="0.5, 0.5">
                                <Ellipse.RenderTransform>
                                    <ScaleTransform ScaleX="1" ScaleY="1" />
                                </Ellipse.RenderTransform>
                            </Ellipse>
                        </Border>
                        </Grid>

                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource MainForegroundColor}" />
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource LinkHoverForegroundColor}"/>
                                <Setter Property="Cursor" Value="Hand" />
                                <Setter Property="Panel.ZIndex" Value="1000"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.1" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.1" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.0" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.0" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                            <Trigger Property="ToggleButton.IsChecked" Value="False">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource MainBackgroundColor}" />
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource ToggleButtonOffColor}" />
                                <Setter TargetName="Ellipse" Property="Fill" Value="{DynamicResource ToggleButtonOffColor}" />
                            </Trigger>

                            <Trigger Property="ToggleButton.IsChecked" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource ToggleButtonOnColor}" />
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource ToggleButtonOnColor}" />
                                <Setter TargetName="Ellipse" Property="Fill" Value="White" />

                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetName="Ellipse"
                                                    Storyboard.TargetProperty="Margin"
                                                    To="18,2,2,2" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetName="Ellipse"
                                                    Storyboard.TargetProperty="Margin"
                                                    To="2,2,2,1" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="VerticalContentAlignment" Value="Center" />
        </Style>

        <Style x:Key="labelfortweaks" TargetType="{x:Type Label}">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Foreground" Value="White" />
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="BorderStyle" TargetType="Border">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="5"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="Margin" Value="5"/>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="ContextMenu">
                <Setter.Value>
                    <ContextMenu>
                        <ContextMenu.Style>
                            <Style TargetType="ContextMenu">
                                <Setter Property="Template">
                                    <Setter.Value>
                                        <ControlTemplate TargetType="ContextMenu">
                                            <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" Padding="5">
                                                <StackPanel>
                                                    <MenuItem Command="Cut" Header="Cut"/>
                                                    <MenuItem Command="Copy" Header="Copy"/>
                                                    <MenuItem Command="Paste" Header="Paste"/>
                                                </StackPanel>
                                            </Border>
                                        </ControlTemplate>
                                    </Setter.Value>
                                </Setter>
                            </Style>
                        </ContextMenu.Style>
                    </ContextMenu>
                </Setter.Value>
            </Setter>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5">
                            <Grid>
                                <ScrollViewer x:Name="PART_ContentHost" />
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="PasswordBox">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="PasswordBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5">
                            <Grid>
                                <ScrollViewer x:Name="PART_ContentHost" />
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ScrollVisibilityRectangle" TargetType="Rectangle">
            <Setter Property="Visibility" Value="Collapsed"/>
            <Style.Triggers>
                <MultiDataTrigger>
                    <MultiDataTrigger.Conditions>
                        <Condition Binding="{Binding Path=ComputedHorizontalScrollBarVisibility, ElementName=scrollViewer}" Value="Visible"/>
                        <Condition Binding="{Binding Path=ComputedVerticalScrollBarVisibility, ElementName=scrollViewer}" Value="Visible"/>
                    </MultiDataTrigger.Conditions>
                    <Setter Property="Visibility" Value="Visible"/>
                </MultiDataTrigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>
    <Grid Background="{DynamicResource MainBackgroundColor}" ShowGridLines="False" Name="WPFMainGrid" Width="Auto" Height="Auto" HorizontalAlignment="Stretch">
        <Grid.RowDefinitions>
            <RowDefinition Height="{DynamicResource TabRowHeightInPixels}"/>
            <RowDefinition Height=".9*"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <DockPanel HorizontalAlignment="Stretch" Background="{DynamicResource MainBackgroundColor}" SnapsToDevicePixels="True" Grid.Row="0" Width="Auto">
            <StackPanel Name="NavLogoPanel" Orientation="Horizontal" HorizontalAlignment="Left" Background="{DynamicResource MainBackgroundColor}" SnapsToDevicePixels="True" Margin="10,0,20,0">
            </StackPanel>
            <ToggleButton Margin="0,0,5,0" HorizontalAlignment="Left" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                Background="{DynamicResource ButtonInstallBackgroundColor}" Foreground="white" FontWeight="Bold" Name="WPFTab1BT">
                <ToggleButton.Content>
                    <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonInstallForegroundColor}" >
                        <Underline>I</Underline>nstall
                    </TextBlock>
                </ToggleButton.Content>
            </ToggleButton>
            <ToggleButton Margin="0,0,5,0" HorizontalAlignment="Left" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                Background="{DynamicResource ButtonTweaksBackgroundColor}" Foreground="{DynamicResource ButtonTweaksForegroundColor}" FontWeight="Bold" Name="WPFTab2BT">
                <ToggleButton.Content>
                    <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonTweaksForegroundColor}">
                        <Underline>T</Underline>weaks
                    </TextBlock>
                </ToggleButton.Content>
            </ToggleButton>
            <ToggleButton Margin="0,0,5,0" HorizontalAlignment="Left" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                Background="{DynamicResource ButtonConfigBackgroundColor}" Foreground="{DynamicResource ButtonConfigForegroundColor}" FontWeight="Bold" Name="WPFTab3BT">
                <ToggleButton.Content>
                    <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonConfigForegroundColor}">
                        <Underline>C</Underline>onfig
                    </TextBlock>
                </ToggleButton.Content>
            </ToggleButton>
            <ToggleButton Margin="0,0,5,0" HorizontalAlignment="Left" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                Background="{DynamicResource ButtonUpdatesBackgroundColor}" Foreground="{DynamicResource ButtonUpdatesForegroundColor}" FontWeight="Bold" Name="WPFTab4BT">
                <ToggleButton.Content>
                    <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonUpdatesForegroundColor}">
                        <Underline>U</Underline>pdates
                    </TextBlock>
                </ToggleButton.Content>
            </ToggleButton>
            <ToggleButton Margin="0,0,5,0" HorizontalAlignment="Left" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                Background="{DynamicResource ButtonUpdatesBackgroundColor}" Foreground="{DynamicResource ButtonUpdatesForegroundColor}" FontWeight="Bold" Name="WPFTab5BT">
                <ToggleButton.Content>
                    <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonUpdatesForegroundColor}">
                        <Underline>M</Underline>icroWin
                    </TextBlock>
                </ToggleButton.Content>
            </ToggleButton>
            <Grid Background="{DynamicResource MainBackgroundColor}" ShowGridLines="False" Width="Auto" Height="Auto" HorizontalAlignment="Stretch">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/> <!-- Main content area -->
                    <ColumnDefinition Width="Auto"/><!-- Space for options button -->
                    <ColumnDefinition Width="Auto"/><!-- Space for close button -->
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <!--
                  TODO:
                    Make this SearchBar TextBox Position itself and still
                    house the Magnifying Glass Character in place,
                    even if that Magnifying Icon changed its Size,
                    it should be positioned relative to the SearchBar.
                    Consider using a Math Solver, will help in making
                    development of these things much easier
                -->
                <TextBox
                    Grid.Column="0"
                    Width="{DynamicResource SearchBarWidth}"
                    Height="{DynamicResource SearchBarHeight}"
                    FontSize="{DynamicResource SearchBarTextBoxFontSize}"
                    VerticalAlignment="Center" HorizontalAlignment="Left"
                    BorderThickness="1"
                    Name="SearchBar"
                    Foreground="{DynamicResource MainForegroundColor}" Background="{DynamicResource MainBackgroundColor}"
                    Padding="3,3,30,0"
                    Margin="5,0,0,0"
                    ToolTip="Press Ctrl-F and type app name to filter application list below. Press Esc to reset the filter">
                </TextBox>
                <TextBlock
                    Grid.Column="0"
                    VerticalAlignment="Center" HorizontalAlignment="Left"
                    FontFamily="Segoe MDL2 Assets"
                    Foreground="{DynamicResource ButtonBackgroundSelectedColor}"
                    FontSize="{DynamicResource IconFontSize}"
                    Margin="180,0,0,0">&#xE721;
                </TextBlock>
                <!--
                  TODO:
                    Make this ClearButton Positioning react to
                    SearchBar Width Value changing, so it'll look correct.
                    Consider using a Math Solver, will help in making
                    development of these things much easier
                -->
                <Button Grid.Column="0"
                    VerticalAlignment="Center" HorizontalAlignment="Left"
                    Name="SearchBarClearButton"
                    Style="{StaticResource SearchBarClearButtonStyle}"
                    Margin="210,0,0,0" Visibility="Collapsed">
                </Button>

                <ProgressBar
                    Grid.Column="1"
                    Minimum="0"
                    Maximum="100"
                    Width="250"
                    Height="{DynamicResource SearchBarHeight}"
                    Foreground="{DynamicResource ProgressBarForegroundColor}" Background="{DynamicResource ProgressBarBackgroundColor}" BorderBrush="{DynamicResource ProgressBarForegroundColor}"
                    Visibility="Collapsed"
                    VerticalAlignment="Center" HorizontalAlignment="Left"
                    Margin="2,0,0,0" BorderThickness="1" Padding="6,2,2,2"
                    Name="ProgressBar">
                </ProgressBar>
                <Label
                    Grid.Column="1"
                    Width="250"
                    Height="{DynamicResource SearchBarHeight}"
                    VerticalAlignment="Center" HorizontalAlignment="Left"
                    FontSize="{DynamicResource SearchBarTextBoxFontSize}"
                    Background="Transparent"
                    Visibility="Collapsed"
                    Margin="2,0,0,0" BorderThickness="0" Padding="6,2,2,2"
                    Name="ProgressBarLabel">
                    <TextBlock
                        TextTrimming="CharacterEllipsis"
                        Background="Transparent"
                        Foreground="{DynamicResource ProgressBarTextColor}">
                    </TextBlock>
                </Label>
                <Button Name="ThemeButton"
                    Style="{StaticResource HoverButtonStyle}"
                    Grid.Column="2" BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Top"
                    Margin="0,5,5,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="N/A"
                    ToolTip="Change the Winutil UI Theme"
                />
                <Popup Grid.Column="2" Name="ThemePopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=ThemeButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Auto" Name="AutoThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Follow the Windows Theme"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Dark" Name="DarkThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Use Dark Theme"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Light" Name="LightThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Use Light Theme"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                        </StackPanel>
                    </Border>
                </Popup>

                <Button Name="SettingsButton"
                    Style="{StaticResource HoverButtonStyle}"
                    Grid.Column="3" BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Top"
                    Margin="5,5,5,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="&#xE713;"/>
                <Popup Grid.Column="3" Name="SettingsPopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=SettingsButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Import" Name="ImportMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Import Configuration from exported file."/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Export" Name="ExportMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Export Selected Elements and copy execution command to clipboard."/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <Separator/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="About" Name="AboutMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Sponsors" Name="SponsorMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </Border>
                </Popup>

            <Button
                Grid.Column="4"
                Content="&#xD7;" BorderThickness="0"
                BorderBrush="Transparent"
                Background="{DynamicResource MainBackgroundColor}"
                Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                HorizontalAlignment="Right" VerticalAlignment="Top"
                Margin="0,5,5,0"
                FontFamily="{DynamicResource FontFamily}"
                Foreground="{DynamicResource MainForegroundColor}" FontSize="{DynamicResource CloseIconFontSize}" Name="WPFCloseButton" />
            </Grid>

        </DockPanel>

        <TabControl Name="WPFTabNav" Background="Transparent" Width="Auto" Height="Auto" BorderBrush="Transparent" BorderThickness="0" Grid.Row="1" Grid.Column="0" Padding="-1">
            <TabItem Header="Install" Visibility="Collapsed" Name="WPFTab1">
                <Grid Background="Transparent" >

                    <Grid Grid.Row="0" Grid.Column="0" Margin="{DynamicResource TabContentMargin}">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="225" />
                            <ColumnDefinition Width="*" />
                        </Grid.ColumnDefinitions>

                        <Grid Name="appscategory" Grid.Column="0" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                        </Grid>

                        <Grid Name="appspanel" Grid.Column="1" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                        </Grid>
                    </Grid>
                </Grid>
            </TabItem>
            <TabItem Header="Tweaks" Visibility="Collapsed" Name="WPFTab2">
                <Grid>
                    <!-- Main content area with a ScrollViewer -->
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="Auto" />
                    </Grid.RowDefinitions>

                    <ScrollViewer VerticalScrollBarVisibility="Auto" Grid.Row="0" Margin="{DynamicResource TabContentMargin}">
                        <Grid Background="Transparent">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="45px"/>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Horizontal" HorizontalAlignment="Left" Grid.Row="0" Grid.Column="0" Grid.ColumnSpan="2" Margin="5">
                                <Label Content="Recommended Selections:" FontSize="{DynamicResource FontSize}" VerticalAlignment="Center" Margin="2"/>
                                <Button Name="WPFstandard" Content=" Standard " Margin="2"/>
                                <Button Name="WPFminimal" Content=" Minimal " Margin="2"/>
                                <Button Name="WPFClearTweaksSelection" Content=" Clear " Margin="2"/>
                                <Button Name="WPFGetInstalledTweaks" Content=" Get Installed " Margin="2"/>
                            </StackPanel>

                            <Grid Name="tweakspanel" Grid.Row="1">
                                <!-- Your tweakspanel content goes here -->
                            </Grid>

                            <Border Grid.ColumnSpan="2" Grid.Row="2" Grid.Column="0" Style="{StaticResource BorderStyle}">
                                <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Horizontal" HorizontalAlignment="Left">
                                    <TextBlock Padding="10">
                                        Note: Hover over items to get a better description. Please be careful as many of these tweaks will heavily modify your system.
                                        <LineBreak/>Recommended selections are for normal users and if you are unsure do NOT check anything else!
                                    </TextBlock>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </ScrollViewer>
                    <Border Grid.Row="1" Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" HorizontalAlignment="Stretch" Padding="10">
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center" Grid.Column="0">
                            <Button Name="WPFTweaksbutton" Content="Run Tweaks" Margin="5"/>
                            <Button Name="WPFUndoall" Content="Undo Selected Tweaks" Margin="5"/>
                        </StackPanel>
                    </Border>
                </Grid>
            </TabItem>
            <TabItem Header="Config" Visibility="Collapsed" Name="WPFTab3">
                <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="{DynamicResource TabContentMargin}">
                    <Grid Name="featurespanel" Grid.Row="1" Background="Transparent">
                    </Grid>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="Updates" Visibility="Collapsed" Name="WPFTab4">
                <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="{DynamicResource TabContentMargin}">
                    <Grid Background="Transparent">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>  <!-- Row for the 3 columns -->
                            <RowDefinition Height="Auto"/>  <!-- Row for Windows Version -->
                        </Grid.RowDefinitions>

                        <!-- Three columns container -->
                        <Grid Grid.Row="0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <!-- Default Settings -->
                            <Border Grid.Column="0" Style="{StaticResource BorderStyle}">
                                <StackPanel>
                                    <Button Name="WPFFixesUpdate"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Content="Default Settings"
                                            Margin="10,5"
                                            Padding="10"/>
                                    <TextBlock Margin="10"
                                             TextWrapping="Wrap"
                                             Foreground="{DynamicResource MainForegroundColor}">
                                        <Run FontWeight="Bold">Default Windows Update Configuration</Run>
                                        <LineBreak/>
                                         - No modifications to Windows defaults
                                        <LineBreak/>
                                         - Removes any custom update settings
                                        <LineBreak/><LineBreak/>
                                        <Run FontStyle="Italic" FontSize="11">Note: This resets your Windows Update settings to default out of the box settings. It removes ANY policy or customization that has been done to Windows Update.</Run>
                                    </TextBlock>
                                </StackPanel>
                            </Border>

                            <!-- Security Settings -->
                            <Border Grid.Column="1" Style="{StaticResource BorderStyle}">
                                <StackPanel>
                                    <Button Name="WPFUpdatessecurity"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Content="Security Settings"
                                            Margin="10,5"
                                            Padding="10"/>
                                    <TextBlock Margin="10"
                                             TextWrapping="Wrap"
                                             Foreground="{DynamicResource MainForegroundColor}">
                                        <Run FontWeight="Bold">Balanced Security Configuration</Run>
                                        <LineBreak/>
                                         - Feature updates delayed by 2 years
                                        <LineBreak/>
                                         - Security updates installed after 4 days
                                        <LineBreak/><LineBreak/>
                                        <Run FontWeight="SemiBold">Feature Updates:</Run> New features and potential bugs
                                        <LineBreak/>
                                        <Run FontWeight="SemiBold">Security Updates:</Run> Critical security patches
                                    <LineBreak/><LineBreak/>
                                    <Run FontStyle="Italic" FontSize="11">Note: This only applies to Pro systems that can use group policy.</Run>
                                    </TextBlock>
                                </StackPanel>
                            </Border>

                            <!-- Disable Updates -->
                            <Border Grid.Column="2" Style="{StaticResource BorderStyle}">
                                <StackPanel>
                                    <Button Name="WPFUpdatesdisable"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Content="Disable All Updates"
                                            Foreground="Red"
                                            Margin="10,5"
                                            Padding="10"/>
                                    <TextBlock Margin="10"
                                             TextWrapping="Wrap"
                                             Foreground="{DynamicResource MainForegroundColor}">
                                        <Run FontWeight="Bold" Foreground="Red">!! Not Recommended !!</Run>
                                        <LineBreak/>
                                         - Disables ALL Windows Updates
                                        <LineBreak/>
                                         - Increases security risks
                                        <LineBreak/>
                                         - Only use for isolated systems
                                        <LineBreak/><LineBreak/>
                                        <Run FontStyle="Italic" FontSize="11">Warning: Your system will be vulnerable without security updates.</Run>
                                    </TextBlock>
                                </StackPanel>
                            </Border>
                        </Grid>

                        <!-- Future Implementation: Add Windows Version to updates panel -->
                        <Grid Name="updatespanel" Grid.Row="1" Background="Transparent">
                        </Grid>
                    </Grid>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="MicroWin" Visibility="Collapsed" Name="WPFTab5">
                <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="{DynamicResource TabContentMargin}">
                <Grid Width="Auto" Height="Auto">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="3*"/>
                    </Grid.ColumnDefinitions>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                    </Grid.RowDefinitions>
                    <Border Grid.Row="0" Grid.Column="0"
                        Style="{StaticResource BorderStyle}"
                        VerticalAlignment="Stretch"
                        HorizontalAlignment="Stretch">
                    <StackPanel Name="MicrowinMain" Background="{DynamicResource MainBackgroundColor}" SnapsToDevicePixels="True" Grid.Column="0" Grid.Row="0">
                        <StackPanel Background="Transparent" SnapsToDevicePixels="True" Margin="1">
                            <CheckBox x:Name="WPFMicrowinDownloadFromGitHub" Content="Download oscdimg.exe from CTT Github repo" IsChecked="True" Margin="{DynamicResource MicrowinCheckBoxMargin}" />
                            <TextBlock Margin="5" Padding="1" TextWrapping="Wrap" Foreground="{DynamicResource ComboBoxForegroundColor}">
                                Choose a Windows ISO file that you've downloaded <LineBreak/>
                                Check the status in the console
                            </TextBlock>
                            <Rectangle Fill="{DynamicResource MainForegroundColor}" Height="2" HorizontalAlignment="Stretch" Margin="0,10,0,10"/>
                            <TextBlock Margin="5" Padding="1" TextWrapping="Wrap" Foreground="{DynamicResource ComboBoxForegroundColor}" ToolTip="Scratch directories act as a custom destination for image files"><Bold>Scratch directory settings (optional)</Bold></TextBlock>
                            <CheckBox x:Name="WPFMicrowinISOScratchDir" Content="Use ISO directory for ScratchDir " IsChecked="False" Margin="{DynamicResource MicrowinCheckBoxMargin}"
                                ToolTip="Check this to use the path of the ISO file you specify as a scratch directory" />
                            <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*" /> <!-- Takes the remaining space -->
                                <ColumnDefinition Width="30" /> <!-- Fixed width for Button -->
                            </Grid.ColumnDefinitions>
                                <TextBox Name="MicrowinScratchDirBox" Background="Transparent" BorderBrush="{DynamicResource MainForegroundColor}"
                                        Text="Scratch"
                                        Margin="2"
                                        IsReadOnly="False"
                                        ToolTip="Specify an alternate path for the scratch directory"
                                        Grid.Column="0"
                                        VerticalAlignment="Center"
                                        Foreground="{DynamicResource LabelboxForegroundColor}">
                                </TextBox>
                                <Button Name="MicrowinScratchDirBT"
                                    Width="Auto"
                                    Height="Auto"
                                    Grid.Column="1"
                                    Margin="2"
                                    Padding="1"  VerticalAlignment="Center">
                                    <Button.Content>
                                    ...
                                    </Button.Content>
                                </Button>
                            </Grid>
                            <Rectangle Fill="{DynamicResource MainForegroundColor}" Height="2" HorizontalAlignment="Stretch" Margin="0,10,0,10"/>
                            <TextBox Name="MicrowinFinalIsoLocation" Background="Transparent" BorderBrush="{DynamicResource MainForegroundColor}"
                                Text="ISO location will be printed here"
                                Margin="2"
                                IsReadOnly="True"
                                TextWrapping="Wrap"
                                Foreground="{DynamicResource LabelboxForegroundColor}"
                            />
                            <RadioButton x:Name="ISOmanual" Content="Select your own ISO" GroupName="Options" Margin="0,10,0,0" IsChecked="True"/>
                            <RadioButton x:Name="ISOdownloader" Content="Get newest ISO automatically" GroupName="Options" Margin="0,5,0,5"/>
                            <ComboBox x:Name="ISORelease" Visibility="Collapsed"/>
                            <ComboBox x:Name="ISOLanguage" Visibility="Collapsed"/>
                            <Button Name="WPFGetIso" Margin="2" Padding="15">
                                <Button.Content>
                                    <TextBlock Background="Transparent" Foreground="{DynamicResource ButtonForegroundColor}">
                                        Get Windows <Underline>I</Underline>SO
                                    </TextBlock>
                                </Button.Content>
                            </Button>
                        </StackPanel>
                        <!-- Visibility="Hidden" -->
                        <StackPanel Name="MicrowinOptionsPanel" HorizontalAlignment="Left" SnapsToDevicePixels="True" Margin="1" Visibility="Hidden">
                            <TextBlock Margin="6" Padding="1" TextWrapping="Wrap">Choose Windows SKU</TextBlock>
                            <ComboBox x:Name = "MicrowinWindowsFlavors" Margin="1" />
                            <Rectangle Fill="{DynamicResource MainForegroundColor}" Height="2" HorizontalAlignment="Stretch" Margin="0,10,0,10"/>
                            <CheckBox Name="MicrowinInjectDrivers" Content="Inject drivers (I KNOW WHAT I'M DOING)" Margin="{DynamicResource MicrowinCheckBoxMargin}" IsChecked="False" ToolTip="Path to unpacked drivers all sys and inf files for devices that need drivers"/>
                            <TextBox Name="MicrowinDriverLocation" Background="Transparent" BorderThickness="1" BorderBrush="{DynamicResource MainForegroundColor}"
                                Margin="6"
                                Text=""
                                IsReadOnly="False"
                                TextWrapping="Wrap"
                                Foreground="{DynamicResource LabelboxForegroundColor}"
                                ToolTip="Path to unpacked drivers all sys and inf files for devices that need drivers"
                            />
                            <CheckBox Name="MicrowinImportDrivers" Content="Import drivers from current system" Margin="{DynamicResource MicrowinCheckBoxMargin}" IsChecked="False" ToolTip="Export all third-party drivers from your system and inject them to the MicroWin image"/>
                            <CheckBox Name="MicrowinCopyVirtIO" Content="Include VirtIO drivers" Margin="{DynamicResource MicrowinCheckBoxMargin}" IsChecked="False" ToolTip="Copy VirtIO Guest Tools drivers to your ISO file. Check this only if you want to use it on QEMU/Proxmox VE"/>
                            <Rectangle Fill="{DynamicResource MainForegroundColor}" Height="2" HorizontalAlignment="Stretch" Margin="0,10,0,10"/>
                            <CheckBox Name="WPFMicrowinCopyToUsb" Content="Copy to Ventoy" Margin="{DynamicResource MicrowinCheckBoxMargin}" IsChecked="False" ToolTip="Copy to USB disk with a label Ventoy"/>
                            <Rectangle Fill="{DynamicResource MainForegroundColor}" Height="2" HorizontalAlignment="Stretch" Margin="0,10,0,10"/>
                            <TextBlock Margin="6" Padding="1" TextWrapping="Wrap"><Bold>Custom user settings (leave empty for default user)</Bold></TextBlock>
                            <TextBlock Margin="6" Padding="1" TextWrapping="Wrap">User name (20 characters max.):</TextBlock>
                            <TextBox Name="MicrowinUserName" Background="Transparent" BorderThickness="1" BorderBrush="{DynamicResource MainForegroundColor}"
                                Margin="6"
                                Text=""
                                IsReadOnly="False"
                                TextWrapping="Wrap"
                                Foreground="{DynamicResource LabelboxForegroundColor}"
                                MaxLength="20"
                            />
                            <TextBlock Margin="6" Padding="1" TextWrapping="Wrap">Password (characters will not be shown for your security):</TextBlock>
                            <PasswordBox Name="MicrowinUserPassword" Background="Transparent" BorderThickness="1" BorderBrush="{DynamicResource MainForegroundColor}"
                                Margin="6"
                                PasswordChar="*"
                                Foreground="{DynamicResource LabelboxForegroundColor}"
                            />
                            <Rectangle Fill="{DynamicResource MainForegroundColor}" Height="2" HorizontalAlignment="Stretch" Margin="0,10,0,10"/>
                            <Button Name="WPFMicrowin" Content="Start the process" Margin="2" Padding="15"/>
                        </StackPanel>
                        <StackPanel HorizontalAlignment="Left" SnapsToDevicePixels="True" Margin="1" Visibility="Collapsed">
                            <TextBlock Name="MicrowinIsoDrive" VerticalAlignment="Center"  Margin="1" Padding="1" TextWrapping="WrapWithOverflow" Foreground="{DynamicResource ComboBoxForegroundColor}"/>
                            <TextBlock Name="MicrowinIsoLocation" VerticalAlignment="Center"  Margin="1" Padding="1" TextWrapping="WrapWithOverflow" Foreground="{DynamicResource ComboBoxForegroundColor}"/>
                            <TextBlock Name="MicrowinMountDir" VerticalAlignment="Center"  Margin="1" Padding="1" TextWrapping="WrapWithOverflow" Foreground="{DynamicResource ComboBoxForegroundColor}"/>
                            <TextBlock Name="MicrowinScratchDir" VerticalAlignment="Center"  Margin="1" Padding="1" TextWrapping="WrapWithOverflow" Foreground="{DynamicResource ComboBoxForegroundColor}"/>
                        </StackPanel>
                    </StackPanel>
                    </Border>
                    <Border
                        Style="{StaticResource BorderStyle}"
                        VerticalAlignment="Stretch"
                        HorizontalAlignment="Stretch"
                        Grid.Row="0" Grid.Column="1">
                        <StackPanel HorizontalAlignment="Left" Background="{DynamicResource MainBackgroundColor}" SnapsToDevicePixels="True" Visibility="Visible">

                            <Grid Name = "BusyMessage" Visibility="Collapsed">
                              <TextBlock Name = "BusyText" Text="NBusy" Padding="22,2,1,1" />
                              <TextBlock VerticalAlignment="Center" HorizontalAlignment="Left" FontFamily="Segoe MDL2 Assets"
                                  FontSize="{DynamicResource IconFontSize}" Margin="16,0,0,0">&#xE701;</TextBlock>
                            </Grid>

                            <TextBlock x:Name = "asciiTextBlock"
                                xml:space ="preserve"
                                HorizontalAlignment = "Center"
                                Margin = "0"
                                VerticalAlignment = "Top"
                                Height = "Auto"
                                Width = "Auto"
                                FontSize = "{DynamicResource MicroWinLogoSize}"
                                FontFamily = "Courier New"
                            >
  /\/\  (_)  ___  _ __   ___  / / /\ \ \(_) _ __
 /    \ | | / __|| '__| / _ \ \ \/  \/ /| || '_ \
/ /\/\ \| || (__ | |   | (_) | \  /\  / | || | | |
\/    \/|_| \___||_|    \___/   \/  \/  |_||_| |_|
                            </TextBlock>

                            <TextBlock Margin="15,15,15,0"
                                Padding="8,8,8,0"
                                VerticalAlignment="Center"
                                TextWrapping="WrapWithOverflow"
                                Height = "Auto"
                                Width = "Auto"
                                Foreground="{DynamicResource ComboBoxForegroundColor}">
                                <Bold>MicroWin features:</Bold><LineBreak/>
                                - Remove Telemetry and Tracking <LineBreak/>
                                - Fast Install using either the "User" local account or the account of your choosing <LineBreak/>
                                - No internet requirement for install <LineBreak/>
                                - Apps debloat <LineBreak/>
                                <LineBreak/>
                                <LineBreak/>

                                <Bold>INSTRUCTIONS</Bold> <LineBreak/>
                                - Download a Windows 11 ISO through the following options: <LineBreak/>
                                    <TextBlock Margin="15,0,0,0" Text="- Select your own ISO: Manually download the latest Windows 11 image from " Foreground="{DynamicResource ComboBoxForegroundColor}"/>
                                    <TextBlock Name="Win11DownloadLink" Style="{StaticResource HoverTextBlockStyle}" ToolTip="https://www.microsoft.com/software-download/windows11">Microsoft</TextBlock>. <LineBreak/>
                                    <TextBlock Margin="15,0,0,0" Text="- Get newest ISO automatically: Choose Windows 11 Edition and preferred language." Foreground="{DynamicResource ComboBoxForegroundColor}"/> <LineBreak/>
                                May take several minutes to process the ISO depending on your machine and connection <LineBreak/>
                                - Put it somewhere on the C:\ drive so it is easily accessible <LineBreak/>
                                - Launch WinUtil and MicroWin  <LineBreak/>
                                - Click on the "Select Windows ISO" button and wait for WinUtil to process the image <LineBreak/>
                                It will be processed and unpacked which may take some time <LineBreak/>
                                - Once complete, choose which Windows flavor you want to base your image on <LineBreak/>
                                - Click the "Start Process" button <LineBreak/>
                                The process of creating the Windows image may take some time, please check the console and wait for it to say "Done" <LineBreak/>
                                - Once complete, the target ISO file will be in the directory you have specified <LineBreak/>
                                - Copy this image to your Ventoy USB Stick, boot to this image, gg
                                <LineBreak/>
                                If you are injecting drivers ensure you put all your inf, sys, and dll files for each driver into a separate directory <LineBreak/><LineBreak/>
                                <Bold>Installing VirtIO drivers</Bold><LineBreak/>
                                If you plan on using your ISO on QEMU/Proxmox VE, you can bundle VirtIO drivers with your ISO to automatically install drivers. Simply tick the "Include VirtIO drivers" checkbox before starting the process. Then, follow these instructions:<LineBreak/><LineBreak/>
                                    <TextBlock TextWrapping="WrapWithOverflow" Margin="15,0,0,0" Text="1. Proceed with Setup until you reach the disk selection screen, in which you won't see any drives" Foreground="{DynamicResource ComboBoxForegroundColor}"/><LineBreak/>
                                    <TextBlock TextWrapping="WrapWithOverflow" Margin="15,0,0,0" Text="2. Click &quot;Load Driver&quot; and click Browse" Foreground="{DynamicResource ComboBoxForegroundColor}"/><LineBreak/>
                                    <TextBlock TextWrapping="WrapWithOverflow" Margin="15,0,0,0" Text="3. In the folder selection dialog, point to this path: &quot;D:\VirtIO\vioscsi\w11\amd64&quot; (replace amd64 with ARM64 if you are using Windows on ARM, and &quot;D:&quot; with the drive letter of the ISO)" Foreground="{DynamicResource ComboBoxForegroundColor}"/><LineBreak/>
                                    <TextBlock TextWrapping="WrapWithOverflow" Margin="15,0,0,0" Text="4. Select all drivers that will appear in the list box and click OK" Foreground="{DynamicResource ComboBoxForegroundColor}"/><LineBreak/>
                            </TextBlock>
                            <TextBlock Margin="15,0,15,15"
                                Padding = "1"
                                TextWrapping="WrapWithOverflow"
                                Height = "Auto"
                                Width = "Auto"
                                VerticalAlignment = "Top"
                                Foreground = "{DynamicResource ComboBoxForegroundColor}"
                                xml:space = "preserve"
                            >
<Bold>Driver structure example:</Bold>
     C:\drivers\
          |-- Driver1\
          |   |-- Driver1.inf
          |   |-- Driver1.sys
          |-- Driver2\
          |   |-- Driver2.inf
          |   |-- Driver2.sys
          |-- OtherFiles...
                            </TextBlock>
                            </StackPanel>
                        </Border>
                    </Grid>
                </ScrollViewer>
            </TabItem>
        </TabControl>
    </Grid>
</Window>

'@
# SPDX-License-Identifier: MIT
# Set the maximum number of threads for the RunspacePool to the number of threads on the machine
$maxthreads = [int]$env:NUMBER_OF_PROCESSORS

# Create a new session state for parsing variables into our runspace
$hashVars = New-object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'sync',$sync,$Null
$InitialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

# Add the variable to the session state
$InitialSessionState.Variables.Add($hashVars)

# Get every private function and add them to the session state
$functions = Get-ChildItem function:\ | Where-Object { $_.Name -imatch 'winutil|Microwin|WPF' }
foreach ($function in $functions) {
    $functionDefinition = Get-Content function:\$($function.name)
    $functionEntry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $($function.name), $functionDefinition

    $initialSessionState.Commands.Add($functionEntry)
}

# Create the runspace pool
$sync.runspace = [runspacefactory]::CreateRunspacePool(
    1,                      # Minimum thread count
    $maxthreads,            # Maximum thread count
    $InitialSessionState,   # Initial session state
    $Host                   # Machine to create runspaces on
)

# Open the RunspacePool instance
$sync.runspace.Open()

# Create classes for different exceptions

class WingetFailedInstall : Exception {
    [string]$additionalData
    WingetFailedInstall($Message) : base($Message) {}
}

class ChocoFailedInstall : Exception {
    [string]$additionalData
    ChocoFailedInstall($Message) : base($Message) {}
}

class GenericException : Exception {
    [string]$additionalData
    GenericException($Message) : base($Message) {}
}


$inputXML = $inputXML -replace 'mc:Ignorable="d"', '' -replace "x:N", 'N' -replace '^<Win.*', '<Window'

[void][System.Reflection.Assembly]::LoadWithPartialName('presentationframework')
[xml]$XAML = $inputXML

# Read the XAML file
$readerOperationSuccessful = $false # There's more cases of failure then success.
$reader = (New-Object System.Xml.XmlNodeReader $xaml)
try {
    $sync["Form"] = [Windows.Markup.XamlReader]::Load( $reader )
    $readerOperationSuccessful = $true
} catch [System.Management.Automation.MethodInvocationException] {
    Write-Host "We ran into a problem with the XAML code.  Check the syntax for this control..." -ForegroundColor Red
    Write-Host $error[0].Exception.Message -ForegroundColor Red

    If ($error[0].Exception.Message -like "*button*") {
        write-Host "Ensure your &lt;button in the `$inputXML does NOT have a Click=ButtonClick property.  PS can't handle this`n`n`n`n" -ForegroundColor Red
    }
} catch {
    Write-Host "Unable to load Windows.Markup.XamlReader. Double-check syntax and ensure .net is installed." -ForegroundColor Red
}

if (-NOT ($readerOperationSuccessful)) {
    Write-Host "Failed to parse xaml content using Windows.Markup.XamlReader's Load Method." -ForegroundColor Red
    Write-Host "Quitting winutil..." -ForegroundColor Red
    $sync.runspace.Dispose()
    $sync.runspace.Close()
    [System.GC]::Collect()
    exit 1
}

# Setup the Window to follow listen for windows Theme Change events and update the winutil theme
# throttle logic needed, because windows seems to send more than one theme change event per change
$lastThemeChangeTime = [datetime]::MinValue
$debounceInterval = [timespan]::FromSeconds(2)
$sync.Form.Add_Loaded({
    $interopHelper = New-Object System.Windows.Interop.WindowInteropHelper $sync.Form
    $hwndSource = [System.Windows.Interop.HwndSource]::FromHwnd($interopHelper.Handle)
    $hwndSource.AddHook({
        param (
            [System.IntPtr]$hwnd,
            [int]$msg,
            [System.IntPtr]$wParam,
            [System.IntPtr]$lParam,
            [ref]$handled
        )
        # Check for the Event WM_SETTINGCHANGE (0x1001A) and validate that Button shows the icon for "Auto" => [char]0xF08C
        if (($msg -eq 0x001A) -and $sync.ThemeButton.Content -eq [char]0xF08C) {
            $currentTime = [datetime]::Now
            if ($currentTime - $lastThemeChangeTime -gt $debounceInterval) {
                Invoke-WinutilThemeChange -theme "Auto"
                $script:lastThemeChangeTime = $currentTime
                $handled = $true
            }
        }
        return 0
    })
})

Invoke-WinutilThemeChange -init $true
# Load the configuration files

$noimage = "https://images.emojiterra.com/google/noto-emoji/unicode-15/color/512px/1f4e6.png"
$noimage = [Windows.Media.Imaging.BitmapImage]::new([Uri]::new($noimage))

$sync.configs.applicationsHashtable = @{}
$sync.configs.applications.PSObject.Properties | ForEach-Object {
    $sync.configs.applicationsHashtable[$_.Name] = $_.Value
}

# Now call the function with the final merged config
Invoke-WPFUIElements -configVariable $sync.configs.appnavigation -targetGridName "appscategory" -columncount 1
# Add logic to handle click to the ToggleView Button on the Install Tab
$sync.WPFToggleView.Add_Click({
    $sync.CompactView = -not $sync.CompactView
    Update-AppTileProperties
    if ($sync.SearchBar.Text -eq "") {
        Set-CategoryVisibility -Category "*"
    }
})
Invoke-WPFUIApps -Apps $sync.configs.applicationsHashtable -targetGridName "appspanel"

Invoke-WPFUIElements -configVariable $sync.configs.tweaks -targetGridName "tweakspanel" -columncount 2
Invoke-WPFUIElements -configVariable $sync.configs.feature -targetGridName "featurespanel" -columncount 2
# Future implementation: Add Windows Version to updates panel
#Invoke-WPFUIElements -configVariable $sync.configs.updates -targetGridName "updatespanel" -columncount 1

#===========================================================================
# Store Form Objects In PowerShell
#===========================================================================

$xaml.SelectNodes("//*[@Name]") | ForEach-Object {$sync["$("$($psitem.Name)")"] = $sync["Form"].FindName($psitem.Name)}

#Persist the Chocolatey preference across winutil restarts
$ChocoPreferencePath = "$env:LOCALAPPDATA\winutil\preferChocolatey.ini"
$sync.ChocoRadioButton.Add_Checked({New-Item -Path $ChocoPreferencePath -Force })
$sync.ChocoRadioButton.Add_Unchecked({Remove-Item $ChocoPreferencePath -Force})
if (Test-Path $ChocoPreferencePath) {
   $sync.ChocoRadioButton.IsChecked = $true
}

$sync.keys | ForEach-Object {
    if($sync.$psitem) {
        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "ToggleButton") {
            $sync["$psitem"].Add_Click({
                [System.Object]$Sender = $args[0]
                Invoke-WPFButton $Sender.name
            })
        }

        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "Button") {
            $sync["$psitem"].Add_Click({
                [System.Object]$Sender = $args[0]
                Invoke-WPFButton $Sender.name
            })
        }

        if ($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "TextBlock") {
            if ($sync["$psitem"].Name.EndsWith("Link")) {
                $sync["$psitem"].Add_MouseUp({
                    [System.Object]$Sender = $args[0]
                    Start-Process $Sender.ToolTip -ErrorAction Stop
                    Write-Debug "Opening: $($Sender.ToolTip)"
                })
            }

        }
    }
}

#===========================================================================
# Setup background config
#===========================================================================

# Load computer information in the background
Invoke-WPFRunspace -ScriptBlock {
    try {
        $oldProgressPreference = $ProgressPreference
        $ProgressPreference = "SilentlyContinue"
        $sync.ConfigLoaded = $False
        $sync.ComputerInfo = Get-ComputerInfo
        $sync.ConfigLoaded = $True
    }
    finally{
        $ProgressPreference = "Continue"
    }

} | Out-Null

#===========================================================================
# Setup and Show the Form
#===========================================================================

# Print the logo
Invoke-WPFFormVariables
$sync.CompactView = $false
$sync.Form.Resources.AppTileWidth = [double]::NaN
$sync.Form.Resources.AppTileCompactVisibility = [Windows.Visibility]::Visible
$sync.Form.Resources.AppTileFontSize = [double]16
$sync.Form.Resources.AppTileMargins = [Windows.Thickness]5
$sync.Form.Resources.AppTileBorderThickness = [Windows.Thickness]0
function Update-AppTileProperties {
    if ($sync.CompactView -eq $true) {
        $sync.Form.Resources.AppTileWidth = [double]::NaN
        $sync.Form.Resources.AppTileCompactVisibility = [Windows.Visibility]::Collapsed
        $sync.Form.Resources.AppTileFontSize = [double]12
        $sync.Form.Resources.AppTileMargins = [Windows.Thickness]2
        $sync.Form.Resources.AppTileBorderThickness = [Windows.Thickness]0
    }
    else {
        $sync.Form.Resources.AppTileWidth = $sync.ItemsControl.ActualWidth -20
        $sync.Form.Resources.AppTileCompactVisibility = [Windows.Visibility]::Visible
        $sync.Form.Resources.AppTileFontSize = [double]16
        $sync.Form.Resources.AppTileMargins = [Windows.Thickness]5
        $sync.Form.Resources.AppTileBorderThickness = [Windows.Thickness]1
    }
}
# We need to update the app tile properties when the form is resized because to fill a WrapPanel update the width of the elemenmt manually (afaik)
$sync.Form.Add_SizeChanged({
    Update-AppTileProperties
})

# Progress bar in taskbaritem > Set-WinUtilProgressbar
$sync["Form"].TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo
Set-WinUtilTaskbaritem -state "None"

# Set the titlebar
$sync["Form"].title = $sync["Form"].title + " " + $sync.version
# Set the commands that will run when the form is closed
$sync["Form"].Add_Closing({
    $sync.runspace.Dispose()
    $sync.runspace.Close()
    [System.GC]::Collect()
})

# Attach the event handler to the Click event
$sync.SearchBarClearButton.Add_Click({
    $sync.SearchBar.Text = ""
    $sync.SearchBarClearButton.Visibility = "Collapsed"
})

# add some shortcuts for people that don't like clicking
$commonKeyEvents = {
    if ($sync.ProcessRunning -eq $true) {
        return
    }

    if ($_.Key -eq "Escape") {
        $sync.SearchBar.SelectAll()
        $sync.SearchBar.Text = ""
        $sync.SearchBarClearButton.Visibility = "Collapsed"
        return
    }

    # don't ask, I know what I'm doing, just go...
    if (($_.Key -eq "Q" -and $_.KeyboardDevice.Modifiers -eq "Ctrl")) {
        $this.Close()
    }
    if ($_.KeyboardDevice.Modifiers -eq "Alt") {
        if ($_.SystemKey -eq "I") {
            Invoke-WPFButton "WPFTab1BT"
        }
        if ($_.SystemKey -eq "T") {
            Invoke-WPFButton "WPFTab2BT"
        }
        if ($_.SystemKey -eq "C") {
            Invoke-WPFButton "WPFTab3BT"
        }
        if ($_.SystemKey -eq "U") {
            Invoke-WPFButton "WPFTab4BT"
        }
        if ($_.SystemKey -eq "M") {
            Invoke-WPFButton "WPFTab5BT"
        }
        if ($_.SystemKey -eq "P") {
            Write-Host "Your Windows Product Key: $((Get-WmiObject -query 'select * from SoftwareLicensingService').OA3xOriginalProductKey)"
        }
    }
    # shortcut for the filter box
    if ($_.Key -eq "F" -and $_.KeyboardDevice.Modifiers -eq "Ctrl") {
        if ($sync.SearchBar.Text -eq "Ctrl-F to filter") {
            $sync.SearchBar.SelectAll()
            $sync.SearchBar.Text = ""
        }
        $sync.SearchBar.Focus()
    }
}

$sync["Form"].Add_PreViewKeyDown($commonKeyEvents)

$sync["Form"].Add_MouseLeftButtonDown({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme")
    $sync["Form"].DragMove()
})

$sync["Form"].Add_MouseDoubleClick({
    if ($_.OriginalSource -is [System.Windows.Controls.Grid] -or
        $_.OriginalSource -is [System.Windows.Controls.StackPanel]) {
            if ($sync["Form"].WindowState -eq [Windows.WindowState]::Normal) {
                $sync["Form"].WindowState = [Windows.WindowState]::Maximized
            }
            else{
                $sync["Form"].WindowState = [Windows.WindowState]::Normal
            }
    }
})

$sync["Form"].Add_Deactivated({
    Write-Debug "WinUtil lost focus"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme")
})

$sync["Form"].Add_ContentRendered({

    try {
        [void][Window]
    } catch {
Add-Type @"
        using System;
        using System.Runtime.InteropServices;
        public class Window {
            [DllImport("user32.dll")]
            public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

            [DllImport("user32.dll")]
            [return: MarshalAs(UnmanagedType.Bool)]
            public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

            [DllImport("user32.dll")]
            [return: MarshalAs(UnmanagedType.Bool)]
            public static extern bool MoveWindow(IntPtr handle, int x, int y, int width, int height, bool redraw);

            [DllImport("user32.dll")]
            public static extern int GetSystemMetrics(int nIndex);
        };
        public struct RECT {
            public int Left;   // x position of upper-left corner
            public int Top;    // y position of upper-left corner
            public int Right;  // x position of lower-right corner
            public int Bottom; // y position of lower-right corner
        }
"@
    }

   foreach ($proc in (Get-Process).where{ $_.MainWindowTitle -and $_.MainWindowTitle -like "*titus*" }) {
        # Check if the process's MainWindowHandle is valid
        if ($proc.MainWindowHandle -ne [System.IntPtr]::Zero) {
            Write-Debug "MainWindowHandle: $($proc.Id) $($proc.MainWindowTitle) $($proc.MainWindowHandle)"
            $windowHandle = $proc.MainWindowHandle
        } else {
            Write-Warning "Process found, but no MainWindowHandle: $($proc.Id) $($proc.MainWindowTitle)"

        }
    }

    $rect = New-Object RECT
    [Window]::GetWindowRect($windowHandle, [ref]$rect)
    $width  = $rect.Right  - $rect.Left
    $height = $rect.Bottom - $rect.Top

    Write-Debug "UpperLeft:$($rect.Left),$($rect.Top) LowerBottom:$($rect.Right),$($rect.Bottom). Width:$($width) Height:$($height)"

    # Load the Windows Forms assembly
    Add-Type -AssemblyName System.Windows.Forms
    $primaryScreen = [System.Windows.Forms.Screen]::PrimaryScreen
    # Check if the primary screen is found
    if ($primaryScreen) {
        # Extract screen width and height for the primary monitor
        $screenWidth = $primaryScreen.Bounds.Width
        $screenHeight = $primaryScreen.Bounds.Height

        # Print the screen size
        Write-Debug "Primary Monitor Width: $screenWidth pixels"
        Write-Debug "Primary Monitor Height: $screenHeight pixels"

        # Compare with the primary monitor size
        if ($width -gt $screenWidth -or $height -gt $screenHeight) {
            Write-Debug "The specified width and/or height is greater than the primary monitor size."
            [void][Window]::MoveWindow($windowHandle, 0, 0, $screenWidth, $screenHeight, $True)
        } else {
            Write-Debug "The specified width and height are within the primary monitor size limits."
        }
    } else {
        Write-Debug "Unable to retrieve information about the primary monitor."
    }

    Invoke-WPFTab "WPFTab1BT"
    $sync["Form"].Focus()

    # maybe this is not the best place to load and execute config file?
    # maybe community can help?
    if ($PARAM_CONFIG) {
        Invoke-WPFImpex -type "import" -Config $PARAM_CONFIG
        if ($PARAM_RUN) {
            while ($sync.ProcessRunning) {
                Start-Sleep -Seconds 5
            }
            Start-Sleep -Seconds 5

            Write-Host "Applying tweaks..."
            Invoke-WPFtweaksbutton
            while ($sync.ProcessRunning) {
                Start-Sleep -Seconds 5
            }
            Start-Sleep -Seconds 5

            Write-Host "Installing features..."
            Invoke-WPFFeatureInstall
            while ($sync.ProcessRunning) {
                Start-Sleep -Seconds 5
            }

            Start-Sleep -Seconds 5
            Write-Host "Installing applications..."
            while ($sync.ProcessRunning) {
                Start-Sleep -Seconds 1
            }
            Invoke-WPFInstall
            Start-Sleep -Seconds 5

            Write-Host "Done."
        }
    }

})

# Add event handlers for the RadioButtons
$sync["ISOdownloader"].add_Checked({
    $sync["ISORelease"].Visibility = [System.Windows.Visibility]::Visible
    $sync["ISOLanguage"].Visibility = [System.Windows.Visibility]::Visible
})

$sync["ISOmanual"].add_Checked({
    $sync["ISORelease"].Visibility = [System.Windows.Visibility]::Collapsed
    $sync["ISOLanguage"].Visibility = [System.Windows.Visibility]::Collapsed
})

$sync["ISORelease"].Items.Add("24H2") | Out-Null
$sync["ISORelease"].SelectedItem = "24H2"

$sync["ISOLanguage"].Items.Add("System Language ($(Microwin-GetLangFromCulture -langName $((Get-Culture).Name)))") | Out-Null
if ($currentCulture -ne "English International") {
    $sync["ISOLanguage"].Items.Add("English International") | Out-Null
}
if ($currentCulture -ne "English") {
    $sync["ISOLanguage"].Items.Add("English") | Out-Null
}
if ($sync["ISOLanguage"].Items.Count -eq 1) {
    $sync["ISOLanguage"].IsEnabled = $false
}
$sync["ISOLanguage"].SelectedIndex = 0

$sync["SearchBar"].Add_TextChanged({
    if ($sync.SearchBar.Text -ne "") {
        $sync.SearchBarClearButton.Visibility = "Visible"
    } else {
        $sync.SearchBarClearButton.Visibility = "Collapsed"
    }
    switch ($sync.currentTab) {
        "Install" {
            Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text
        }
    }
})

$sync["Form"].Add_Loaded({
    param($e)
    $sync.Form.MinWidth = "1000"
    $sync["Form"].MaxWidth = [Double]::PositiveInfinity
    $sync["Form"].MaxHeight = [Double]::PositiveInfinity
})

$NavLogoPanel = $sync["Form"].FindName("NavLogoPanel")
$NavLogoPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size 25)) | Out-Null

# Initialize the hashtable
$winutildir = @{}

# Set the path for the winutil directory
$winutildir["path"] = "$env:LOCALAPPDATA\winutil\"
[System.IO.Directory]::CreateDirectory($winutildir["path"]) | Out-Null

$winutildir["logo.ico"] = $winutildir["path"] + "cttlogo.ico"

if (Test-Path $winutildir["logo.ico"]) {
    $sync["logorender"] = $winutildir["logo.ico"]
} else {
    $sync["logorender"] = (Invoke-WinUtilAssets -Type "Logo" -Size 90 -Render)
}
$sync["checkmarkrender"] = (Invoke-WinUtilAssets -Type "checkmark" -Size 512 -Render)
$sync["warningrender"] = (Invoke-WinUtilAssets -Type "warning" -Size 512 -Render)

Set-WinUtilTaskbaritem -overlay "logo"

$sync["Form"].Add_Activated({
    Set-WinUtilTaskbaritem -overlay "logo"
})

$sync["ThemeButton"].Add_Click({
    Write-Debug "ThemeButton clicked"
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Toggle" }
    $_.Handled = $false
})
$sync["AutoThemeMenuItem"].Add_Click({
    Write-Debug "About clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Auto"
    $_.Handled = $false
})
$sync["DarkThemeMenuItem"].Add_Click({
    Write-Debug "Dark Theme clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Dark"
    $_.Handled = $false
})
$sync["LightThemeMenuItem"].Add_Click({
    Write-Debug "Light Theme clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Light"
    $_.Handled = $false
})


$sync["SettingsButton"].Add_Click({
    Write-Debug "SettingsButton clicked"
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Toggle"; "Theme" = "Hide" }
    $_.Handled = $false
})
$sync["ImportMenuItem"].Add_Click({
    Write-Debug "Import clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Invoke-WPFImpex -type "import"
    $_.Handled = $false
})
$sync["ExportMenuItem"].Add_Click({
    Write-Debug "Export clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Invoke-WPFImpex -type "export"
    $_.Handled = $false
})
$sync["AboutMenuItem"].Add_Click({
    Write-Debug "About clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

    $authorInfo = @"
Author   : <a href="https://github.com/ChrisTitusTech">@christitustech</a>
Runspace : <a href="https://github.com/DeveloperDurp">@DeveloperDurp</a>
MicroWin : <a href="https://github.com/KonTy">@KonTy</a>, <a href="https://github.com/CodingWonders">@CodingWonders</a>
GitHub   : <a href="https://github.com/ChrisTitusTech/winutil">ChrisTitusTech/winutil</a>
Version  : <a href="https://github.com/ChrisTitusTech/winutil/releases/tag/$($sync.version)">$($sync.version)</a>
"@
    Show-CustomDialog -Title "About" -Message $authorInfo
})
$sync["SponsorMenuItem"].Add_Click({
    Write-Debug "Sponsors clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

    $authorInfo = @"
<a href="https://github.com/sponsors/ChrisTitusTech">Current sponsors for ChrisTitusTech:</a>
"@
    $authorInfo += "`n"
    try {
        $sponsors = Invoke-WinUtilSponsors
        foreach ($sponsor in $sponsors) {
            $authorInfo += "<a href=`"https://github.com/sponsors/ChrisTitusTech`">$sponsor</a>`n"
        }
    } catch {
        $authorInfo += "An error occurred while fetching or processing the sponsors: $_`n"
    }
    Show-CustomDialog -Title "Sponsors" -Message $authorInfo -EnableScroll $true
})



$sync["Form"].ShowDialog() | out-null
Stop-Transcript

# SIG # Begin signature block
# MIImbgYJKoZIhvcNAQcCoIImXzCCJlsCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBCqMHcflKFe9xC
# vdkI5HETB4Rv9GA8ZdtLTxhtTS98CqCCH4YwggWNMIIEdaADAgECAhAOmxiO+dAt
# 5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBa
# Fw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lD
# ZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3E
# MB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKy
# unWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsF
# xl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU1
# 5zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJB
# MtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObUR
# WBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6
# nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxB
# YKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5S
# UUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+x
# q4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIB
# NjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwP
# TzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMC
# AYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENB
# LmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0Nc
# Vec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnov
# Lbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65Zy
# oUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFW
# juyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPF
# mCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9z
# twGpn1eqXijiuZQwggYaMIIEAqADAgECAhBiHW0MUgGeO5B5FSCJIRwKMA0GCSqG
# SIb3DQEBDAUAMFYxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0
# ZWQxLTArBgNVBAMTJFNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBSb290IFI0
# NjAeFw0yMTAzMjIwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMFQxCzAJBgNVBAYTAkdC
# MRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3RpZ28gUHVi
# bGljIENvZGUgU2lnbmluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAw
# ggGKAoIBgQCbK51T+jU/jmAGQ2rAz/V/9shTUxjIztNsfvxYB5UXeWUzCxEeAEZG
# bEN4QMgCsJLZUKhWThj/yPqy0iSZhXkZ6Pg2A2NVDgFigOMYzB2OKhdqfWGVoYW3
# haT29PSTahYkwmMv0b/83nbeECbiMXhSOtbam+/36F09fy1tsB8je/RV0mIk8XL/
# tfCK6cPuYHE215wzrK0h1SWHTxPbPuYkRdkP05ZwmRmTnAO5/arnY83jeNzhP06S
# hdnRqtZlV59+8yv+KIhE5ILMqgOZYAENHNX9SJDm+qxp4VqpB3MV/h53yl41aHU5
# pledi9lCBbH9JeIkNFICiVHNkRmq4TpxtwfvjsUedyz8rNyfQJy/aOs5b4s+ac7I
# H60B+Ja7TVM+EKv1WuTGwcLmoU3FpOFMbmPj8pz44MPZ1f9+YEQIQty/NQd/2yGg
# W+ufflcZ/ZE9o1M7a5Jnqf2i2/uMSWymR8r2oQBMdlyh2n5HirY4jKnFH/9gRvd+
# QOfdRrJZb1sCAwEAAaOCAWQwggFgMB8GA1UdIwQYMBaAFDLrkpr/NZZILyhAQnAg
# NpFcF4XmMB0GA1UdDgQWBBQPKssghyi47G9IritUpimqF6TNDDAOBgNVHQ8BAf8E
# BAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDAzAb
# BgNVHSAEFDASMAYGBFUdIAAwCAYGZ4EMAQQBMEsGA1UdHwREMEIwQKA+oDyGOmh0
# dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWduaW5nUm9v
# dFI0Ni5jcmwwewYIKwYBBQUHAQEEbzBtMEYGCCsGAQUFBzAChjpodHRwOi8vY3J0
# LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNDb2RlU2lnbmluZ1Jvb3RSNDYucDdj
# MCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0B
# AQwFAAOCAgEABv+C4XdjNm57oRUgmxP/BP6YdURhw1aVcdGRP4Wh60BAscjW4HL9
# hcpkOTz5jUug2oeunbYAowbFC2AKK+cMcXIBD0ZdOaWTsyNyBBsMLHqafvIhrCym
# laS98+QpoBCyKppP0OcxYEdU0hpsaqBBIZOtBajjcw5+w/KeFvPYfLF/ldYpmlG+
# vd0xqlqd099iChnyIMvY5HexjO2AmtsbpVn0OhNcWbWDRF/3sBp6fWXhz7DcML4i
# TAWS+MVXeNLj1lJziVKEoroGs9Mlizg0bUMbOalOhOfCipnx8CaLZeVme5yELg09
# Jlo8BMe80jO37PU8ejfkP9/uPak7VLwELKxAMcJszkyeiaerlphwoKx1uHRzNyE6
# bxuSKcutisqmKL5OTunAvtONEoteSiabkPVSZ2z76mKnzAfZxCl/3dq3dUNw4rg3
# sTCggkHSRqTqlLMS7gjrhTqBmzu1L90Y1KWN/Y5JKdGvspbOrTfOXyXvmPL6E52z
# 1NZJ6ctuMFBQZH3pwWvqURR8AgQdULUvrxjUYbHHj95Ejza63zdrEcxWLDX6xWls
# /GDnVNueKjWUH3fTv1Y8Wdho698YADR7TNx8X8z2Bev6SivBBOHY+uqiirZtg0y9
# ShQoPzmCcn63Syatatvx157YK9hlcPmVoa1oDE5/L9Uo2bC5a4CH2RwwggZhMIIE
# yaADAgECAhAmzTnZ/yhC019IbbKDBpvFMA0GCSqGSIb3DQEBDAUAMFQxCzAJBgNV
# BAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMTIlNlY3Rp
# Z28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYwHhcNMjIwNTMwMDAwMDAwWhcN
# MjUwNTI5MjM1OTU5WjBVMQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxGjAY
# BgNVBAoMEUNUIFRFQ0ggR1JPVVAgTExDMRowGAYDVQQDDBFDVCBURUNIIEdST1VQ
# IExMQzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALDxiKQHPvjYMWMV
# lH40AhqVOaVq9mWPSezrfgN3UAeuJFj1zwOzQfHD1WZj+eQtej48zIt3YHLKpy0V
# EHvtkFL7yqmuTrXbhGv55PggiMYp0hh0jv7vpFSsnShvwsaneTWBy0v6EaK/qQ8a
# 7tZCwEnfVE4cRepdPdfdpMG0AaiK+GWjfqh/lUdtJT9KW2/SyTOuEFhb/+1ltsnm
# doBSqj6mzk5FYXJIWH4193Gdq65j6EZeSFv0ev7tN3Zp1w7oc/J7odI0zxNZJW/E
# 6v3cG3oBfdwy2mmfl6KBzP7ulzCh/oj1vYFGxpiBvy4wfyblnhYnmk+VU2vwt5Ro
# bQYpFpOU2+b7v6RC8DlCScsFt16QtA7l6sBgf2Sg8OOeBe6x29lRwHvcBni9Ih1V
# FnRJ5T5QkEIqgT18fY5+SLXmMj495fJbEwZkUr1NKIwnivZgnp66ImKgYSwwB7U/
# A4vdCqnAlo8po28vYq+yzuBsaOjUFhi9MWRpPPaaI4aw8UkzwVwdTxYBl1JXYrwT
# xsEA6dIiVxBhKnT3uKJcN6EwEHO3wnQGrWAgxQZWuHXQ+gX5lQb6bdalEdXc0hiI
# Qx7g/Fu2pQTcmzT7Lk//vu43RAOmxJOUOo6rkNmLuzkkaSpPdJftm9GOnQ6J+pbs
# +mZGq07A+EqbX3gwCD2o2fbDkE6PAgMBAAGjggGsMIIBqDAfBgNVHSMEGDAWgBQP
# Kssghyi47G9IritUpimqF6TNDDAdBgNVHQ4EFgQUjnXbLNZOgoZYQySE6eTTsyBb
# MYYwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYB
# BQUHAwMwSgYDVR0gBEMwQTA1BgwrBgEEAbIxAQIBAwIwJTAjBggrBgEFBQcCARYX
# aHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYGZ4EMAQQBMEkGA1UdHwRCMEAwPqA8
# oDqGOGh0dHA6Ly9jcmwuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY0NvZGVTaWdu
# aW5nQ0FSMzYuY3JsMHkGCCsGAQUFBwEBBG0wazBEBggrBgEFBQcwAoY4aHR0cDov
# L2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljQ29kZVNpZ25pbmdDQVIzNi5j
# cnQwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMCEGA1UdEQQa
# MBiBFmNvbnRhY3RAY2hyaXN0aXR1cy5jb20wDQYJKoZIhvcNAQEMBQADggGBADkT
# nvLMHdIb3hPzKixR3B7XaLL/92r0e7mQU6N4p8IZriTi6j0PjZGm9HN7K7UNJjTy
# snBsdeZGat517qfC9BLn6OZyiZjKXSW6EEhTm37Ryg/kmfG+GsolkcY/4QnUz5hi
# zj7Q3HVrIX5RduY1QwrlD/nkwAdycMvEXzHTNH7as9kN3vpWZr6VBy11gXOLLS7+
# kKaxwzndY/0xQER6RozNoKsRW6Vx08qF2nHDXygeXHlaiBz17QpqYZQ+i4aMkkG2
# xMkjzQIjwxOAANbpWEGmSBV4fw/JtEOlBGfEw/kadPsTrUpVf+a+BMMY+QFGV/tY
# BkTYTnIUGEpiR/OgZ6pZLo2uIri4KLYLjwIgV6lip5+QVxdSTYQKuUhWqpUILtnG
# YluaYd4PLgBgMSpYBNS5NEqqMVqbhhwRluPKEPySjwYGpRKP9RT6ke5BHVxuq+FW
# ixnCSoIIXPh/NvCa0eqtRqdCiAy15bi+FkV/Ag5fPoxFFAEDM6FnXN5M3H53bDCC
# Bq4wggSWoAMCAQICEAc2N7ckVHzYR6z9KGYqXlswDQYJKoZIhvcNAQELBQAwYjEL
# MAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3
# LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3RlZCBSb290IEc0
# MB4XDTIyMDMyMzAwMDAwMFoXDTM3MDMyMjIzNTk1OVowYzELMAkGA1UEBhMCVVMx
# FzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJEaWdpQ2VydCBUcnVz
# dGVkIEc0IFJTQTQwOTYgU0hBMjU2IFRpbWVTdGFtcGluZyBDQTCCAiIwDQYJKoZI
# hvcNAQEBBQADggIPADCCAgoCggIBAMaGNQZJs8E9cklRVcclA8TykTepl1Gh1tKD
# 0Z5Mom2gsMyD+Vr2EaFEFUJfpIjzaPp985yJC3+dH54PMx9QEwsmc5Zt+FeoAn39
# Q7SE2hHxc7Gz7iuAhIoiGN/r2j3EF3+rGSs+QtxnjupRPfDWVtTnKC3r07G1decf
# BmWNlCnT2exp39mQh0YAe9tEQYncfGpXevA3eZ9drMvohGS0UvJ2R/dhgxndX7RU
# CyFobjchu0CsX7LeSn3O9TkSZ+8OpWNs5KbFHc02DVzV5huowWR0QKfAcsW6Th+x
# tVhNef7Xj3OTrCw54qVI1vCwMROpVymWJy71h6aPTnYVVSZwmCZ/oBpHIEPjQ2OA
# e3VuJyWQmDo4EbP29p7mO1vsgd4iFNmCKseSv6De4z6ic/rnH1pslPJSlRErWHRA
# KKtzQ87fSqEcazjFKfPKqpZzQmiftkaznTqj1QPgv/CiPMpC3BhIfxQ0z9JMq++b
# Pf4OuGQq+nUoJEHtQr8FnGZJUlD0UfM2SU2LINIsVzV5K6jzRWC8I41Y99xh3pP+
# OcD5sjClTNfpmEpYPtMDiP6zj9NeS3YSUZPJjAw7W4oiqMEmCPkUEBIDfV8ju2Tj
# Y+Cm4T72wnSyPx4JduyrXUZ14mCjWAkBKAAOhFTuzuldyF4wEr1GnrXTdrnSDmuZ
# DNIztM2xAgMBAAGjggFdMIIBWTASBgNVHRMBAf8ECDAGAQH/AgEAMB0GA1UdDgQW
# BBS6FtltTYUvcyl2mi91jGogj57IbzAfBgNVHSMEGDAWgBTs1+OC0nFdZEzfLmc/
# 57qYrhwPTzAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwgwdwYI
# KwYBBQUHAQEEazBpMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5j
# b20wQQYIKwYBBQUHMAKGNWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdp
# Q2VydFRydXN0ZWRSb290RzQuY3J0MEMGA1UdHwQ8MDowOKA2oDSGMmh0dHA6Ly9j
# cmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQuY3JsMCAGA1Ud
# IAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0BAQsFAAOCAgEA
# fVmOwJO2b5ipRCIBfmbW2CFC4bAYLhBNE88wU86/GPvHUF3iSyn7cIoNqilp/GnB
# zx0H6T5gyNgL5Vxb122H+oQgJTQxZ822EpZvxFBMYh0MCIKoFr2pVs8Vc40BIiXO
# lWk/R3f7cnQU1/+rT4osequFzUNf7WC2qk+RZp4snuCKrOX9jLxkJodskr2dfNBw
# CnzvqLx1T7pa96kQsl3p/yhUifDVinF2ZdrM8HKjI/rAJ4JErpknG6skHibBt94q
# 6/aesXmZgaNWhqsKRcnfxI2g55j7+6adcq/Ex8HBanHZxhOACcS2n82HhyS7T6NJ
# uXdmkfFynOlLAlKnN36TU6w7HQhJD5TNOXrd/yVjmScsPT9rp/Fmw0HNT7ZAmyEh
# QNC3EyTN3B14OuSereU0cZLXJmvkOHOrpgFPvT87eK1MrfvElXvtCl8zOYdBeHo4
# 6Zzh3SP9HSjTx/no8Zhf+yvYfvJGnXUsHicsJttvFXseGYs2uJPU5vIXmVnKcPA3
# v5gA3yAWTyf7YGcWoWa63VXAOimGsJigK+2VQbc61RWYMbRiCQ8KvYHZE/6/pNHz
# V9m8BPqC3jLfBInwAM1dwvnQI38AC+R2AibZ8GV2QqYphwlHK+Z/GqSFD/yYlvZV
# VCsfgPrA8g4r5db7qS9EFUrnEw4d2zc4GqEr9u3WfPwwgga8MIIEpKADAgECAhAL
# rma8Wrp/lYfG+ekE4zMEMA0GCSqGSIb3DQEBCwUAMGMxCzAJBgNVBAYTAlVTMRcw
# FQYDVQQKEw5EaWdpQ2VydCwgSW5jLjE7MDkGA1UEAxMyRGlnaUNlcnQgVHJ1c3Rl
# ZCBHNCBSU0E0MDk2IFNIQTI1NiBUaW1lU3RhbXBpbmcgQ0EwHhcNMjQwOTI2MDAw
# MDAwWhcNMzUxMTI1MjM1OTU5WjBCMQswCQYDVQQGEwJVUzERMA8GA1UEChMIRGln
# aUNlcnQxIDAeBgNVBAMTF0RpZ2lDZXJ0IFRpbWVzdGFtcCAyMDI0MIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAvmpzn/aVIauWMLpbbeZZo7Xo/ZEfGMSI
# O2qZ46XB/QowIEMSvgjEdEZ3v4vrrTHleW1JWGErrjOL0J4L0HqVR1czSzvUQ5xF
# 7z4IQmn7dHY7yijvoQ7ujm0u6yXF2v1CrzZopykD07/9fpAT4BxpT9vJoJqAsP8Y
# uhRvflJ9YeHjes4fduksTHulntq9WelRWY++TFPxzZrbILRYynyEy7rS1lHQKFpX
# vo2GePfsMRhNf1F41nyEg5h7iOXv+vjX0K8RhUisfqw3TTLHj1uhS66YX2LZPxS4
# oaf33rp9HlfqSBePejlYeEdU740GKQM7SaVSH3TbBL8R6HwX9QVpGnXPlKdE4fBI
# n5BBFnV+KwPxRNUNK6lYk2y1WSKour4hJN0SMkoaNV8hyyADiX1xuTxKaXN12HgR
# +8WulU2d6zhzXomJ2PleI9V2yfmfXSPGYanGgxzqI+ShoOGLomMd3mJt92nm7Mhe
# ng/TBeSA2z4I78JpwGpTRHiT7yHqBiV2ngUIyCtd0pZ8zg3S7bk4QC4RrcnKJ3Fb
# jyPAGogmoiZ33c1HG93Vp6lJ415ERcC7bFQMRbxqrMVANiav1k425zYyFMyLNyE1
# QulQSgDpW9rtvVcIH7WvG9sqYup9j8z9J1XqbBZPJ5XLln8mS8wWmdDLnBHXgYly
# /p1DhoQo5fkCAwEAAaOCAYswggGHMA4GA1UdDwEB/wQEAwIHgDAMBgNVHRMBAf8E
# AjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMCAGA1UdIAQZMBcwCAYGZ4EMAQQC
# MAsGCWCGSAGG/WwHATAfBgNVHSMEGDAWgBS6FtltTYUvcyl2mi91jGogj57IbzAd
# BgNVHQ4EFgQUn1csA3cOKBWQZqVjXu5Pkh92oFswWgYDVR0fBFMwUTBPoE2gS4ZJ
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0UlNBNDA5
# NlNIQTI1NlRpbWVTdGFtcGluZ0NBLmNybDCBkAYIKwYBBQUHAQEEgYMwgYAwJAYI
# KwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBYBggrBgEFBQcwAoZM
# aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0UlNB
# NDA5NlNIQTI1NlRpbWVTdGFtcGluZ0NBLmNydDANBgkqhkiG9w0BAQsFAAOCAgEA
# Pa0eH3aZW+M4hBJH2UOR9hHbm04IHdEoT8/T3HuBSyZeq3jSi5GXeWP7xCKhVire
# KCnCs+8GZl2uVYFvQe+pPTScVJeCZSsMo1JCoZN2mMew/L4tpqVNbSpWO9QGFwfM
# Ey60HofN6V51sMLMXNTLfhVqs+e8haupWiArSozyAmGH/6oMQAh078qRh6wvJNU6
# gnh5OruCP1QUAvVSu4kqVOcJVozZR5RRb/zPd++PGE3qF1P3xWvYViUJLsxtvge/
# mzA75oBfFZSbdakHJe2BVDGIGVNVjOp8sNt70+kEoMF+T6tptMUNlehSR7vM+C13
# v9+9ZOUKzfRUAYSyyEmYtsnpltD/GWX8eM70ls1V6QG/ZOB6b6Yum1HvIiulqJ1E
# lesj5TMHq8CWT/xrW7twipXTJ5/i5pkU5E16RSBAdOp12aw8IQhhA/vEbFkEiF2a
# bhuFixUDobZaA0VhqAsMHOmaT3XThZDNi5U2zHKhUs5uHHdG6BoQau75KiNbh0c+
# hatSF+02kULkftARjsyEpHKsF7u5zKRbt5oK5YGwFvgc4pEVUNytmB3BpIiowOII
# uDgP5M9WArHYSAR16gc0dP2XdkMEP5eBsX7bf/MGN4K3HP50v/01ZHo/Z5lGLvNw
# Q7XHBx1yomzLP8lx4Q1zZKDyHcp4VQJLu2kWTsKsOqQxggY+MIIGOgIBATBoMFQx
# CzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxKzApBgNVBAMT
# IlNlY3RpZ28gUHVibGljIENvZGUgU2lnbmluZyBDQSBSMzYCECbNOdn/KELTX0ht
# soMGm8UwDQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKA
# ADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYK
# KwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgbdVHYqk3oZccnhSNyHmrmG7RAVWt
# V8td3W5Bp3uyEz8wDQYJKoZIhvcNAQEBBQAEggIAXtxwOH5n9bW1XPgahSKC5huA
# OFn9UJfhaJcfqBOzww3mRhAhmvx2q2JwXYGQvHVvm4/fgWqnXFnNYw3YpS7JudcX
# fuxnbtfojc+jt/GnT8q6F69NMcdzCvB9cU28Chzi8aV9acN6RSMVuByRbVA+DR40
# SK9pyfbByj10XfquW0obKrio+ZwtyqftsQXdYb21SQQUCpU5ZW0jV903nSfXHwLI
# RTPx1kqsYOPJ7SZnkvYE4M6iKdk4ksigi4JUIneEot8xil1NVKVI/6curyfp/8zC
# P/B/7FKExjucU8lWvFLN7CzwN4O2GBkZXcyQD4800P+YKrzlHQGGvKvNGQzj7AIW
# E/nUrN1cz42SvhCzpC8ofMnmk6KPlb2J6z5VXaB+2NRZAwGHCb5UYOFriMIB4LsY
# FrappD7o3y5mD9kztzO2wr8AHVIvtNMJS0ACSlGlJavm7GUlBf+ResRvk03H2LJz
# qgv8ZynzR7zHeH9kLvhg9ng2qSVv9JBqZKUjkA6KfTNBPr9DMnZsqXjxz5h/RdLL
# YwX5WdGo1Hbj9j8vK/tqJWznNZhVvFp7Ddy8Vf/h1Uk0/f34LYCmKjOmVOfnQeYv
# iufM8DfKmr7tCaedItwlt0Tzd8kxjEIeRInGCQCv9xWUQ3OzqCDlAz7Bhcezqku8
# GDzodv9Nw+ltKYbOH3mhggMgMIIDHAYJKoZIhvcNAQkGMYIDDTCCAwkCAQEwdzBj
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMT
# MkRpZ2lDZXJ0IFRydXN0ZWQgRzQgUlNBNDA5NiBTSEEyNTYgVGltZVN0YW1waW5n
# IENBAhALrma8Wrp/lYfG+ekE4zMEMA0GCWCGSAFlAwQCAQUAoGkwGAYJKoZIhvcN
# AQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjUwMzA1MTg0MTQ4WjAv
# BgkqhkiG9w0BCQQxIgQgP1qxspy1440bUmOnV1hvalo290JP8D88wWXl/HuWi6ww
# DQYJKoZIhvcNAQEBBQAEggIAbQi1Pk/GCECvCki589BDpe9JY5HUDJX1RI2iOaWs
# TSACyaZPn3FVjEAQtZNhmGVXBb0sfiD2af4SrgMpKe68vS4Io/LGxZW5TZhcDsYC
# SW0/zoYkrRaKHQYDWd7fgUw4bHzni5KosiEqjWCDM6gQqlnpXj4SkYisJLNme2xz
# iSDDapVQKG3sCBhMg9rPj9nBg4HNbTGmY4uWkD4WquYKZN5hqqfjB7SuUvdMvU9q
# nn1NbST17+4uieHdquu6TOW0VZqr74Hmfsm4BefXIGz25zxHTAPWeu8YJd27bXW1
# 4Jy5RdRDfLiOQwvVP8UI5J05l3iggtdqwtQa8xPANbjowH6DnZPp1WQheqhPHCzX
# LD4BUJ86ltAmontBSUih7UufdA7sxrK8dBv7lWGvrnwm9NwC++y3JCSbOTvYoChH
# aoExGk8yB0vCC7AkVBNJMIXOSHLWHw8dqd8P0vE/I2SUujoaN0P5UjrBe30NB/wN
# a+Z9r9hGzq3OTmhnUpFFU/p/UCvp6nNURHB4gwttY5TrQOykKQY9CA9dCmnXJW3d
# jI1tjFWnUyspcSxzrN9dOsvJjLRSulfKH7lwLr7zXOPsJ1lgDsMz9sNNMh1lSyqR
# 8SFlgANojiGCzqrs0QmLqAPqmSdkmcHPTSxDkX4FnRvW+aRIME9V7m+PG85ed4Zh
# Z1c=
# SIG # End signature block
