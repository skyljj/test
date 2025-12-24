# PowerShell Script: Mouse Mover and Teams Activity Simulator
# Function: Simulate mouse and keyboard activity to prevent Teams away status on Windows 11
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

# Trap Ctrl+C for graceful exit
$null = Register-ObjectEvent -InputObject ([System.Console]) -EventName CancelKeyPress -Action {
    exit
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Mouse Mover and Teams Activity Simulator" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Interval: $Interval seconds" -ForegroundColor Green
Write-Host "Move Distance: $MoveDistance pixels" -ForegroundColor Green
Write-Host ""
Write-Host "Press Ctrl+C to stop" -ForegroundColor Yellow
Write-Host ""

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
    Write-Host "`nScript stopped." -ForegroundColor Yellow
}

