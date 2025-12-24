# PowerShell Script: Mouse Mover and Teams Activity Simulator
# Function: Prevent system sleep and Teams away status on Windows 11
# Usage: .\mouse-mover.ps1 [-Interval <seconds>] [-MoveDistance <pixels>]

param(
    [Parameter(Mandatory=$false)]
    [int]$Interval = 60,  # Move mouse every 60 seconds
    [Parameter(Mandatory=$false)]
    [int]$MoveDistance = 1  # Move 1 pixel (minimal, user won't notice)
)

# Add required .NET types for mouse control
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class MouseMover {
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);
    
    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT lpPoint);
    
    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, int dwExtraInfo);
    
    public const uint MOUSEEVENTF_MOVE = 0x0001;
    
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X;
        public int Y;
    }
    
    public static void MoveMouse(int deltaX, int deltaY) {
        mouse_event(MOUSEEVENTF_MOVE, (uint)deltaX, (uint)deltaY, 0, 0);
    }
}
"@

# Function to simulate keyboard activity (prevents Teams away status)
function Send-Keystroke {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.SendKeys]::SendWait("{SCROLLLOCK}")
    Start-Sleep -Milliseconds 50
    [System.Windows.Forms.SendKeys]::SendWait("{SCROLLLOCK}")
}

# Function to move mouse slightly
function Move-MouseSlightly {
    try {
        $point = New-Object MouseMover+POINT
        [MouseMover]::GetCursorPos([ref]$point)
        
        # Move mouse 1 pixel and back (user won't notice)
        [MouseMover]::MoveMouse($MoveDistance, 0)
        Start-Sleep -Milliseconds 10
        [MouseMover]::MoveMouse(-$MoveDistance, 0)
    } catch {
        Write-Warning "Failed to move mouse: $($_.Exception.Message)"
    }
}

# Function to prevent system sleep
function Set-PreventSleep {
    # Prevent display from turning off
    powercfg /change monitor-timeout-ac 0
    powercfg /change monitor-timeout-dc 0
    
    # Prevent system from sleeping
    powercfg /change standby-timeout-ac 0
    powercfg /change standby-timeout-dc 0
    
    # Prevent disk from turning off
    powercfg /change disk-timeout-ac 0
    powercfg /change disk-timeout-dc 0
}

# Function to restore original power settings
function Restore-PowerSettings {
    Write-Host "Restoring original power settings..." -ForegroundColor Yellow
    # Restore default settings (you may want to customize these)
    powercfg /change monitor-timeout-ac 10
    powercfg /change monitor-timeout-dc 5
    powercfg /change standby-timeout-ac 30
    powercfg /change standby-timeout-dc 15
    powercfg /change disk-timeout-ac 0
    powercfg /change disk-timeout-dc 0
}

# Setup signal handler for graceful exit
$null = Register-EngineEvent PowerShell.Exiting -Action {
    Restore-PowerSettings
}

# Trap Ctrl+C
$null = Register-ObjectEvent -InputObject ([System.Console]) -EventName CancelKeyPress -Action {
    Restore-PowerSettings
    exit
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Mouse Mover and Teams Activity Simulator" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Interval: $Interval seconds" -ForegroundColor Green
Write-Host "Move Distance: $MoveDistance pixels" -ForegroundColor Green
Write-Host ""
Write-Host "Press Ctrl+C to stop and restore settings" -ForegroundColor Yellow
Write-Host ""

# Prevent system sleep
Set-PreventSleep
Write-Host "Power settings configured to prevent sleep" -ForegroundColor Green

# Main loop
$counter = 0
try {
    while ($true) {
        $counter++
        $currentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        
        # Move mouse
        Move-MouseSlightly
        
        # Simulate keyboard activity (every 2 intervals to prevent Teams away)
        if ($counter % 2 -eq 0) {
            Send-Keystroke
            Write-Host "[$currentTime] Mouse moved + Keyboard activity simulated (Run #$counter)" -ForegroundColor Gray
        } else {
            Write-Host "[$currentTime] Mouse moved (Run #$counter)" -ForegroundColor Gray
        }
        
        Start-Sleep -Seconds $Interval
    }
} catch {
    Write-Host "`nError occurred: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    Restore-PowerSettings
    Write-Host "`nScript stopped. Power settings restored." -ForegroundColor Yellow
}

