"""Unit tests for compstats.py (macOS).

Mocks subprocess.run so these can run on any OS - can't validate real
system_profiler/diskutil/smartctl output without an actual Mac (none
available while writing this), so treat this suite as validating the
*parsing logic* against representative sample output, not as proof the
script works end-to-end on real hardware. Run on a real Mac and compare
against the generated report before relying on it.

Run with: python3 -m unittest test_compstats -v
"""

import json
import subprocess
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import compstats


class TestSmartNumericValue(unittest.TestCase):
    ata_lines = [
        "ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE",
        "  5 Reallocated_Sector_Ct   0x0033   100   100   010    Pre-fail  Always       -       0",
        "  9 Power_On_Hours          0x0032   100   100   000    Old_age   Always       -       12345",
        "194 Temperature_Celsius     0x0022   062   038   000    Old_age   Always       -       30 (Min/Max 20/45)",
        "177 Wear_Leveling_Count     0x0013   094   094   000    Pre-fail  Always       -       35",
    ]
    nvme_lines = [
        "Temperature:                       35 Celsius",
        "Percentage Used:                   1%",
        "Power On Hours:                    1,234",
        "Media and Data Integrity Errors:   0",
    ]

    def test_ata_reallocated_sectors_not_the_attribute_id(self):
        self.assertEqual(
            compstats.smart_numeric_value(self.ata_lines, ["Reallocated_Sector_Ct"], trailing=True), "0"
        )

    def test_ata_power_on_hours_not_the_attribute_id(self):
        self.assertEqual(
            compstats.smart_numeric_value(self.ata_lines, ["Power_On_Hours"], trailing=True), "12345"
        )

    def test_ata_temperature_ignores_min_max_suffix(self):
        self.assertEqual(
            compstats.smart_numeric_value(self.ata_lines, ["Temperature_Celsius"], trailing=True), "30"
        )

    def test_ata_wear_leveling_not_the_attribute_id(self):
        self.assertEqual(
            compstats.smart_numeric_value(self.ata_lines, ["Wear_Leveling_Count"], trailing=True), "35"
        )

    def test_nvme_temperature(self):
        self.assertEqual(compstats.smart_numeric_value(self.nvme_lines, ["Temperature:"]), "35")

    def test_nvme_power_on_hours_strips_thousands_separator(self):
        self.assertEqual(compstats.smart_numeric_value(self.nvme_lines, [r"^Power On Hours:"]), "1234")

    def test_no_match_returns_none(self):
        self.assertIsNone(compstats.smart_numeric_value(["nothing relevant"], ["Reallocated_Sector_Ct"], trailing=True))


class TestGetDiskHealthStatus(unittest.TestCase):
    def test_ko_when_reallocated_sectors_present(self):
        result = compstats.get_disk_health_status({"SMART": {"Errors": "3", "Temp": "N/A"}})
        self.assertEqual(result["Status"], "KO")

    def test_attention_not_ko_for_hot_but_error_free_disk(self):
        result = compstats.get_disk_health_status({"SMART": {"Errors": "0", "Temp": "62"}}, temp_threshold=50)
        self.assertEqual(result["Status"], "Attention")

    def test_respects_custom_temperature_threshold(self):
        disk = {"SMART": {"Errors": "0", "Temp": "55"}}
        self.assertEqual(compstats.get_disk_health_status(disk, temp_threshold=60)["Status"], "OK")
        self.assertEqual(compstats.get_disk_health_status(disk, temp_threshold=50)["Status"], "Attention")

    def test_falls_back_to_diskutil_smart_status(self):
        result = compstats.get_disk_health_status({"SMART": None, "SmartStatus": "Failing"})
        self.assertEqual(result["Status"], "Attention")

    def test_ok_when_nominal(self):
        result = compstats.get_disk_health_status({"SMART": {"Errors": "0", "Temp": "35"}, "SmartStatus": "Verified"})
        self.assertEqual(result["Status"], "OK")


class TestGetGlobalAssessment(unittest.TestCase):
    def test_perfect_machine_scores_100(self):
        result = compstats.get_global_assessment(["OK", "OK"], has_battery=True, battery_health_value=95)
        self.assertEqual(result["Score"], 100)
        self.assertEqual(result["Label"], "Bon etat")

    def test_score_does_not_go_below_zero(self):
        result = compstats.get_global_assessment(["KO", "KO", "KO"], has_battery=True, battery_health_value=10)
        self.assertEqual(result["Score"], 0)
        self.assertEqual(result["Label"], "Critique")

    def test_ignores_battery_when_none(self):
        result = compstats.get_global_assessment(["OK"], has_battery=False, battery_health_value=0)
        self.assertEqual(result["Score"], 100)

    def test_custom_thresholds(self):
        result = compstats.get_global_assessment(
            [], has_battery=True, battery_health_value=70, battery_critical=75
        )
        self.assertEqual(result["Score"], 65)


class TestHtmlSafe(unittest.TestCase):
    def test_escapes_angle_brackets_and_ampersand(self):
        self.assertEqual(
            compstats.html_safe("<script>a&b</script>"),
            "&lt;script&gt;a&amp;b&lt;/script&gt;",
        )

    def test_none_becomes_empty_string(self):
        self.assertEqual(compstats.html_safe(None), "")

    def test_plain_text_untouched(self):
        self.assertEqual(compstats.html_safe("Apple SSD"), "Apple SSD")


def _completed(stdout="", returncode=0):
    return subprocess.CompletedProcess(args=[], returncode=returncode, stdout=stdout, stderr="")


class TestGetSystemInfo(unittest.TestCase):
    @patch("compstats.subprocess.run")
    def test_apple_silicon(self, mock_run):
        payload = {"SPHardwareDataType": [{
            "machine_name": "MacBook Pro", "machine_model": "MacBookPro18,3",
            "serial_number": "C02ZX0AAAAAA", "boot_rom_version": "1234.5.6",
        }]}
        mock_run.return_value = _completed(json.dumps(payload))
        info = compstats.get_system_info()
        self.assertEqual(info["Model"], "MacBook Pro")
        self.assertEqual(info["SerialNumber"], "C02ZX0AAAAAA")

    @patch("compstats.subprocess.run")
    def test_missing_command_does_not_crash(self, mock_run):
        mock_run.side_effect = FileNotFoundError()
        info = compstats.get_system_info()
        self.assertEqual(info["Model"], "N/A")


class TestGetCpuInfo(unittest.TestCase):
    @patch("compstats.subprocess.run")
    def test_apple_silicon_uses_chip_type(self, mock_run):
        payload = {"SPHardwareDataType": [{"chip_type": "Apple M1 Pro"}]}
        mock_run.return_value = _completed(json.dumps(payload))
        cpu = compstats.get_cpu_info()
        self.assertEqual(cpu["Model"], "Apple M1 Pro")

    @patch("compstats.subprocess.run")
    def test_intel_uses_cpu_type_and_speed(self, mock_run):
        payload = {"SPHardwareDataType": [{
            "cpu_type": "Intel Core i7", "current_processor_speed": "2.6 GHz",
        }]}
        mock_run.return_value = _completed(json.dumps(payload))
        cpu = compstats.get_cpu_info()
        self.assertEqual(cpu["Model"], "Intel Core i7")
        self.assertEqual(cpu["Speed"], "2.6 GHz")


class TestGetBatteryInfo(unittest.TestCase):
    SAMPLE = """
Hardware:

Battery Information:
      Model Information:
          Serial Number: D8644XXXXXXXXX
          Manufacturer: SDI
      Charge Information:
          Full Charge Capacity (mAh): 5900
      Health Information:
          Cycle Count: 245
          Condition: Normal
          Maximum Capacity: 87%
"""

    @patch("compstats.run_command")
    def test_parses_health_fields(self, mock_run):
        mock_run.return_value = self.SAMPLE
        battery = compstats.get_battery_info()
        self.assertEqual(battery["HealthValue"], 87.0)
        self.assertEqual(battery["HealthStatus"], "Excellent")
        self.assertEqual(battery["Age"], "245 cycles")

    @patch("compstats.run_command")
    def test_no_battery_returns_none(self, mock_run):
        mock_run.return_value = "Hardware:\n\n"
        self.assertIsNone(compstats.get_battery_info())

    @patch("compstats.run_command")
    def test_command_unavailable_returns_none(self, mock_run):
        mock_run.return_value = None
        self.assertIsNone(compstats.get_battery_info())


class TestGetEncryptionInfo(unittest.TestCase):
    @patch("compstats.run_command")
    def test_filevault_on(self, mock_run):
        mock_run.return_value = "FileVault is On.\n"
        result = compstats.get_encryption_info()
        self.assertEqual(result["Status"], "OK")
        self.assertEqual(result["Volumes"][0]["ProtectionStatus"], "Chiffre")

    @patch("compstats.run_command")
    def test_filevault_off(self, mock_run):
        mock_run.return_value = "FileVault is Off.\n"
        result = compstats.get_encryption_info()
        self.assertEqual(result["Volumes"][0]["ProtectionStatus"], "Non chiffre")

    @patch("compstats.run_command")
    def test_command_unavailable(self, mock_run):
        mock_run.return_value = None
        result = compstats.get_encryption_info()
        self.assertEqual(result["Status"], "Unavailable")


class TestRemoveOldReports(unittest.TestCase):
    def test_deletes_only_old_html_json_never_csv(self):
        with TemporaryDirectory() as tmp:
            d = Path(tmp)
            old_html = d / "old.html"
            old_json = d / "old.json"
            recent_html = d / "recent.html"
            csv_file = d / "resume.csv"
            for f in (old_html, old_json, recent_html, csv_file):
                f.write_text("x")

            old_time = (datetime.now() - timedelta(days=100)).timestamp()
            recent_time = (datetime.now() - timedelta(days=1)).timestamp()
            import os
            os.utime(old_html, (old_time, old_time))
            os.utime(old_json, (old_time, old_time))
            os.utime(recent_html, (recent_time, recent_time))
            os.utime(csv_file, (old_time, old_time))

            removed = compstats.remove_old_reports(d, 30)

            self.assertEqual(set(removed), {"old.html", "old.json"})
            self.assertFalse(old_html.exists())
            self.assertFalse(old_json.exists())
            self.assertTrue(recent_html.exists())
            self.assertTrue(csv_file.exists())

    def test_disabled_by_default(self):
        with TemporaryDirectory() as tmp:
            d = Path(tmp)
            f = d / "ancient.html"
            f.write_text("x")
            old_time = (datetime.now() - timedelta(days=1000)).timestamp()
            import os
            os.utime(f, (old_time, old_time))
            compstats.remove_old_reports(d, 0)
            self.assertTrue(f.exists())


class TestUpdateReportIndex(unittest.TestCase):
    def test_builds_row_for_report_with_matching_html(self):
        with TemporaryDirectory() as tmp:
            d = Path(tmp)
            data = {
                "GeneratedAt": "2026-09-10 10:00:00", "AssetTag": "REF-42",
                "System": {"Brand": "Apple", "Model": "MacBook Pro", "SerialNumber": "ABC123"},
                "GlobalAssessment": {"Score": 80, "Label": "Bon etat", "Recommendation": "Reemploi possible", "BadgeClass": "status-ok"},
            }
            (d / "report.json").write_text(json.dumps(data))
            (d / "report.html").write_text("<html></html>")

            index_path = compstats.update_report_index(d)
            self.assertIsNotNone(index_path)
            content = index_path.read_text()
            self.assertIn("MacBook Pro", content)
            self.assertIn("REF-42", content)
            self.assertIn("80/100", content)

    def test_skips_orphan_json_without_html(self):
        with TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "orphan.json").write_text(json.dumps({"System": {}, "GlobalAssessment": {}}))
            self.assertIsNone(compstats.update_report_index(d))

    def test_no_reports_returns_none(self):
        with TemporaryDirectory() as tmp:
            self.assertIsNone(compstats.update_report_index(Path(tmp)))

    def test_html_escapes_report_data(self):
        with TemporaryDirectory() as tmp:
            d = Path(tmp)
            data = {
                "GeneratedAt": "x", "AssetTag": "<script>alert(1)</script>",
                "System": {"Brand": "A & B", "Model": "X", "SerialNumber": "1"},
                "GlobalAssessment": {"Score": 1, "Label": "", "Recommendation": "", "BadgeClass": ""},
            }
            (d / "r.json").write_text(json.dumps(data))
            (d / "r.html").write_text("<html></html>")
            content = compstats.update_report_index(d).read_text()
            self.assertNotIn("<script>", content)
            self.assertIn("&amp; B", content)


if __name__ == "__main__":
    unittest.main()
