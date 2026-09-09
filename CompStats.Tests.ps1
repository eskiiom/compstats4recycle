# Pester tests for CompStats.ps1
#
# These target the pure computation functions where real bugs were found
# during development (SMART value parsing, disk/battery classification,
# HTML escaping, the Windows 11 / BitLocker tri-state checks) rather than
# the I/O-heavy collection functions (Get-BatteryInfo, Get-SMARTData,
# Get-HDDInfo, ...) which shell out to powercfg/smartctl/WMI and are better
# covered by actually running the script (see validation-syntax.ps1 for a
# structural sanity check, and README.md for manual verification notes).
#
# Run with: Invoke-Pester (from this directory)

$scriptPath = Join-Path $PSScriptRoot "CompStats.ps1"
. $scriptPath

Describe "Get-SmartNumericValue" {
    Context "ATA attribute table rows (value is the LAST number, not the ID)" {
        $ataOutput = @(
            "ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE",
            "  5 Reallocated_Sector_Ct   0x0033   100   100   010    Pre-fail  Always       -       0",
            "  9 Power_On_Hours          0x0032   100   100   000    Old_age   Always       -       12345",
            "194 Temperature_Celsius     0x0022   062   038   000    Old_age   Always       -       30 (Min/Max 20/45)",
            "177 Wear_Leveling_Count     0x0013   094   094   000    Pre-fail  Always       -       35"
        )

        It "reads the reallocated sector RAW_VALUE, not the attribute ID (5)" {
            (Get-SmartNumericValue -Output $ataOutput -Patterns @('Reallocated_Sector_Ct') -Trailing) | Should Be "0"
        }
        It "reads the power-on hours RAW_VALUE, not the attribute ID (9)" {
            (Get-SmartNumericValue -Output $ataOutput -Patterns @('Power_On_Hours', 'Power-On_Hours') -Trailing) | Should Be "12345"
        }
        It "ignores the (Min/Max ...) suffix on the temperature line" {
            (Get-SmartNumericValue -Output $ataOutput -Patterns @('Temperature_Celsius') -Trailing) | Should Be "30"
        }
        It "reads the wear-leveling RAW_VALUE, not the attribute ID (177)" {
            (Get-SmartNumericValue -Output $ataOutput -Patterns @('Percent_Lifetime_Remain', 'Wear_Leveling_Count') -Trailing) | Should Be "35"
        }
    }

    Context "NVMe log fields (label: value, comma-formatted numbers)" {
        $nvmeOutput = @(
            "Temperature:                       35 Celsius",
            "Percentage Used:                   1%",
            "Power On Hours:                    1,234",
            "Media and Data Integrity Errors:   0"
        )

        It "reads the temperature" {
            (Get-SmartNumericValue -Output $nvmeOutput -Patterns @('Temperature:')) | Should Be "35"
        }
        It "reads power-on hours and strips the thousands separator" {
            (Get-SmartNumericValue -Output $nvmeOutput -Patterns @('^Power On Hours:')) | Should Be "1234"
        }
        It "reads the wear percentage" {
            (Get-SmartNumericValue -Output $nvmeOutput -Patterns @('Percentage Used')) | Should Be "1"
        }
        It "reads the integrity error count" {
            (Get-SmartNumericValue -Output $nvmeOutput -Patterns @('Media and Data Integrity Errors:')) | Should Be "0"
        }
    }

    It "returns null when no pattern matches" {
        (Get-SmartNumericValue -Output @("nothing relevant here") -Patterns @('Reallocated_Sector_Ct') -Trailing) | Should Be $null
    }
}

Describe "Get-DiskHealthStatus" {
    It "reports OK when SMART data isn't a hashtable (e.g. WMI failure string)" {
        (Get-DiskHealthStatus -Smart "Unable to read SMART data").Status | Should Be "OK"
    }

    It "reports KO when reallocated sectors are present" {
        $smart = @{ Errors = "3"; Temp = "N/A"; Health = "Unknown" }
        $result = Get-DiskHealthStatus -Smart $smart -TempThreshold 50
        $result.Status | Should Be "KO"
        $result.CssClass | Should Be "health-bad"
    }

    It "reports Attention (not KO) for a hot but otherwise error-free disk" {
        # This used to disagree between the summary badge (KO) and the detailed
        # disk table (Attention) because each had its own copy of this logic
        $smart = @{ Errors = "0"; Temp = "62"; Health = "Unknown" }
        $result = Get-DiskHealthStatus -Smart $smart -TempThreshold 50
        $result.Status | Should Be "Attention"
        $result.CssClass | Should Be "health-warning"
    }

    It "respects a custom temperature threshold" {
        $smart = @{ Errors = "0"; Temp = "55"; Health = "Unknown" }
        (Get-DiskHealthStatus -Smart $smart -TempThreshold 60).Status | Should Be "OK"
        (Get-DiskHealthStatus -Smart $smart -TempThreshold 50).Status | Should Be "Attention"
    }

    It "reports Attention for a WMI 'Warning' health status" {
        $smart = @{ Errors = "N/A"; Temp = "N/A"; Health = "Warning" }
        (Get-DiskHealthStatus -Smart $smart).Status | Should Be "Attention"
    }

    It "reports OK when everything is nominal" {
        $smart = @{ Errors = "0"; Temp = "35"; Health = "OK" }
        (Get-DiskHealthStatus -Smart $smart).Status | Should Be "OK"
    }
}

Describe "Get-GlobalAssessment" {
    It "scores a perfectly healthy machine at 100 (Bon etat)" {
        $result = Get-GlobalAssessment -diskStatuses @("OK", "OK") -hasBattery $true -batteryHealthValue 95
        $result.Score | Should Be 100
        $result.Label | Should Be "Bon etat"
    }

    It "deducts for a KO disk and low battery, without going below 0" {
        $result = Get-GlobalAssessment -diskStatuses @("KO", "KO", "KO") -hasBattery $true -batteryHealthValue 10
        $result.Score | Should Be 0
        $result.Label | Should Be "Critique"
    }

    It "ignores battery health when there is no battery (desktop)" {
        $result = Get-GlobalAssessment -diskStatuses @("OK") -hasBattery $false -batteryHealthValue 0
        $result.Score | Should Be 100
    }

    It "honors custom score thresholds" {
        $result = Get-GlobalAssessment -diskStatuses @("Attention") -hasBattery $false -batteryHealthValue 100 -ScoreGoodThreshold 95
        # score is 88 (100 - 12), below a raised "good" bar of 95
        $result.Label | Should Be "Attention"
    }

    It "honors custom battery thresholds" {
        # 70% battery: "critical" under default thresholds only below 40, so no
        # deduction there - but treat 70 as already-critical with a raised bar
        $result = Get-GlobalAssessment -diskStatuses @() -hasBattery $true -batteryHealthValue 70 -BatteryCriticalThreshold 75
        $result.Score | Should Be 65
    }
}

Describe "ConvertTo-HtmlSafe" {
    It "escapes angle brackets and ampersands" {
        ConvertTo-HtmlSafe '<script>a&b</script>' | Should Be '&lt;script&gt;a&amp;b&lt;/script&gt;'
    }
    It "returns an empty string for null" {
        ConvertTo-HtmlSafe $null | Should Be ""
    }
    It "leaves plain text untouched" {
        ConvertTo-HtmlSafe "Samsung SSD 970 EVO" | Should Be "Samsung SSD 970 EVO"
    }
}

Describe "Get-Windows11Compatibility" {
    $ramOk = @{ Total = "16 GB" }
    $hddsOk = @(@{ Size = "256 GB" })

    Context "TPM 2.0 and active Secure Boot" {
        Mock Get-CimInstance { [PSCustomObject]@{ SpecVersion = "2.0, 0, 1.38" } } -ParameterFilter { $ClassName -eq "Win32_Tpm" }
        Mock Confirm-SecureBootUEFI { $true }

        It "reports a Compatible verdict" {
            $result = Get-Windows11Compatibility -ram $ramOk -hdds $hddsOk
            $result.TpmOk | Should Be $true
            $result.SecureBootOk | Should Be $true
            $result.Compatible | Should Be $true
            $result.VerdictClass | Should Be "health-good"
        }
    }

    Context "legacy BIOS (a verified, distinguishable failure) with a TPM query that merely errors out" {
        # Any exception from the TPM namespace query is treated as indeterminate,
        # not "no TPM present" - unlike Secure Boot, there's no reliably
        # distinguishable exception type to tell "no TPM chip" apart from "query
        # failed for some other unrelated reason", so the safer conservative
        # choice is to never report a hard "false" from a caught exception alone
        Mock Get-CimInstance { throw "some CIM error" } -ParameterFilter { $ClassName -eq "Win32_Tpm" }
        # PlatformNotSupportedException specifically means "not UEFI" - a real,
        # verified signal, unlike a bare access-denied error
        Mock Confirm-SecureBootUEFI { throw (New-Object System.PlatformNotSupportedException) }

        It "still reports a definitive Non compatible verdict, driven by Secure Boot alone" {
            $result = Get-Windows11Compatibility -ram $ramOk -hdds $hddsOk
            $result.TpmOk | Should Be $null
            $result.SecureBootOk | Should Be $false
            $result.Compatible | Should Be $false
            $result.VerdictClass | Should Be "health-bad"
        }
    }

    Context "TPM/Secure Boot can't be queried without admin rights" {
        Mock Get-CimInstance { throw "Access to a CIM resource was not available for the client" } -ParameterFilter { $ClassName -eq "Win32_Tpm" }
        Mock Confirm-SecureBootUEFI { throw (New-Object System.UnauthorizedAccessException) }

        It "reports Indetermine, NOT a false Non compatible" {
            $result = Get-Windows11Compatibility -ram $ramOk -hdds $hddsOk
            $result.TpmOk | Should Be $null
            $result.SecureBootOk | Should Be $null
            $result.Compatible | Should Be $false
            $result.VerdictClass | Should Be "health-warning"
            $result.Verdict | Should Match "Indetermine"
        }
    }

    Context "insufficient RAM" {
        Mock Get-CimInstance { [PSCustomObject]@{ SpecVersion = "2.0, 0, 1.38" } } -ParameterFilter { $ClassName -eq "Win32_Tpm" }
        Mock Confirm-SecureBootUEFI { $true }

        It "fails on RAM regardless of TPM/Secure Boot" {
            $result = Get-Windows11Compatibility -ram @{ Total = "2 GB" } -hdds $hddsOk
            $result.RamOk | Should Be $false
            $result.Compatible | Should Be $false
        }
    }
}

Describe "Get-EncryptionInfo" {
    Context "BitLocker module not present (e.g. Windows Home)" {
        Mock Get-BitLockerVolume { throw "The term 'Get-BitLockerVolume' is not recognized" }
        Mock Get-Command { $null } -ParameterFilter { $Name -eq "Get-BitLockerVolume" }

        It "reports Status Unavailable" {
            (Get-EncryptionInfo).Status | Should Be "Unavailable"
        }
    }

    Context "BitLocker present but access denied (needs admin)" {
        Mock Get-BitLockerVolume { throw "Access to a CIM resource was not available for the client" }
        Mock Get-Command { [PSCustomObject]@{ Name = "Get-BitLockerVolume" } } -ParameterFilter { $Name -eq "Get-BitLockerVolume" }

        It "reports Status AccessDenied, not an empty (falsely reassuring) volume list" {
            $result = Get-EncryptionInfo
            $result.Status | Should Be "AccessDenied"
            $result.Volumes.Count | Should Be 0
        }
    }

    Context "BitLocker available, one encrypted volume on physical disk 0" {
        Mock Get-BitLockerVolume {
            @([PSCustomObject]@{ MountPoint = "C:"; ProtectionStatus = "On"; EncryptionMethod = "XtsAes256"; VolumeStatus = "FullyEncrypted" })
        }
        Mock Get-Partition { @([PSCustomObject]@{ DriveLetter = "C"; DiskNumber = 0 }) }

        It "maps the volume to physical disk 0 (an int, not the string '0')" {
            $result = Get-EncryptionInfo
            $result.Status | Should Be "OK"
            $result.Volumes[0].ProtectionStatus | Should Be "Chiffre"
            $result.Volumes[0].PhysicalDiskNumber | Should Be 0
        }
    }
}

Describe "Remove-OldReports" {
    It "deletes only html/json reports older than the cutoff, never the CSV log" {
        $dir = Join-Path $TestDrive "Rapports"
        New-Item -ItemType Directory -Path $dir | Out-Null

        $oldHtml = Join-Path $dir "old.html"
        $oldJson = Join-Path $dir "old.json"
        $recentHtml = Join-Path $dir "recent.html"
        $csv = Join-Path $dir "resume.csv"
        "x" | Out-File $oldHtml
        "x" | Out-File $oldJson
        "x" | Out-File $recentHtml
        "x" | Out-File $csv

        (Get-Item $oldHtml).LastWriteTime = (Get-Date).AddDays(-100)
        (Get-Item $oldJson).LastWriteTime = (Get-Date).AddDays(-100)
        (Get-Item $recentHtml).LastWriteTime = (Get-Date).AddDays(-1)
        (Get-Item $csv).LastWriteTime = (Get-Date).AddDays(-100)

        $removed = Remove-OldReports -ReportsDir $dir -MaxAgeDays 30

        $removed.Count | Should Be 2
        Test-Path $oldHtml | Should Be $false
        Test-Path $oldJson | Should Be $false
        Test-Path $recentHtml | Should Be $true
        Test-Path $csv | Should Be $true
    }

    It "deletes nothing when MaxAgeDays is 0 (disabled by default)" {
        $dir = Join-Path $TestDrive "RapportsDisabled"
        New-Item -ItemType Directory -Path $dir | Out-Null
        $file = Join-Path $dir "ancient.html"
        "x" | Out-File $file
        (Get-Item $file).LastWriteTime = (Get-Date).AddDays(-1000)

        Remove-OldReports -ReportsDir $dir -MaxAgeDays 0

        Test-Path $file | Should Be $true
    }

    It "does not error when the reports folder does not exist yet" {
        { Remove-OldReports -ReportsDir (Join-Path $TestDrive "DoesNotExist") -MaxAgeDays 30 } | Should Not Throw
    }
}
