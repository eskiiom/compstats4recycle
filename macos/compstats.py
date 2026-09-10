#!/usr/bin/env python3
"""CompStats for Recycle - macOS

Generates an HTML/JSON/CSV report with system, CPU, GPU, RAM, disk (with
SMART/diskutil health), battery, network and FileVault info, for assessing a
Mac before recycling/reuse. Companion to windows/CompStats.ps1 and
linux/compstats.sh - same idea, each using its OS's own native tools.

Copyright (c) 2026 Guillaume COQUEBLIN (esquimo.org)
Project homepage: https://github.com/eskiiom/compstats4recycle
"""

import argparse
import csv
import html
import json
import plistlib
import re
import shutil
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path

SCRIPT_VERSION = "0.1"
SCRIPT_DATE = "2026-09-10"


# --------------------------------------------------------------------------
# Shell helpers
# --------------------------------------------------------------------------

def run_command(args, timeout=15):
    """Run a command, returning its stdout as text, or None on any failure.

    Every data-collection function below treats a missing/failing command as
    "field not available" rather than crashing, mirroring the Windows
    script's try/catch-everywhere approach - a technician recycling a wide
    variety of Mac models and macOS versions will hit commands that behave
    differently or aren't present far more often than on a single, known
    Windows fleet.
    """
    try:
        result = subprocess.run(
            args, capture_output=True, text=True, timeout=timeout, check=False
        )
        if result.returncode != 0:
            return None
        return result.stdout
    except (OSError, subprocess.SubprocessError):
        return None


def run_command_json(args, timeout=15):
    """Like run_command, but parses the output as JSON. Returns None if the
    command fails or the output isn't valid JSON (an older macOS version
    without -json support, for instance)."""
    output = run_command(args, timeout=timeout)
    if not output:
        return None
    try:
        return json.loads(output)
    except json.JSONDecodeError:
        return None


def find_numbers(text):
    """All digit groups in a string, as a list of strings (commas stripped)."""
    return [m.replace(",", "") for m in re.findall(r"[\d][\d,]*", text or "")]


def html_safe(value):
    """Escape a value coming from hardware/vendor strings before embedding
    it in the HTML report - mirrors ConvertTo-HtmlSafe in the Windows script."""
    if value is None:
        return ""
    return html.escape(str(value), quote=True)


# --------------------------------------------------------------------------
# System / CPU / GPU / RAM
# --------------------------------------------------------------------------

def get_system_info():
    data = run_command_json(["system_profiler", "SPHardwareDataType", "-json"])
    hw = {}
    if data and data.get("SPHardwareDataType"):
        hw = data["SPHardwareDataType"][0]

    return {
        "Brand": "Apple",
        "Model": hw.get("machine_name") or hw.get("machine_model") or "N/A",
        "ModelIdentifier": hw.get("machine_model", "N/A"),
        "SerialNumber": hw.get("serial_number", "N/A"),
        "BootRomVersion": hw.get("boot_rom_version", "N/A"),
    }


def get_cpu_info():
    data = run_command_json(["system_profiler", "SPHardwareDataType", "-json"])
    hw = {}
    if data and data.get("SPHardwareDataType"):
        hw = data["SPHardwareDataType"][0]

    # Apple Silicon reports "chip_type" (e.g. "Apple M1 Pro"); Intel Macs
    # report "cpu_type" (e.g. "Intel Core i7") plus a separate clock speed
    if hw.get("chip_type"):
        return {"Brand": "Apple", "Model": hw["chip_type"], "Speed": "N/A"}

    model = hw.get("cpu_type", "N/A")
    speed = hw.get("current_processor_speed", "N/A")
    return {"Brand": "Intel" if "Intel" in model else "N/A", "Model": model, "Speed": speed}


def get_gpu_info():
    data = run_command_json(["system_profiler", "SPDisplaysDataType", "-json"])
    if not data or not data.get("SPDisplaysDataType"):
        return []

    gpus = []
    for gpu in data["SPDisplaysDataType"]:
        # Apple Silicon GPUs share unified memory with the CPU and don't
        # report a separate VRAM figure the way a discrete Intel/AMD/NVIDIA
        # GPU does
        vram = gpu.get("spdisplays_vram") or gpu.get("spdisplays_vram_shared")
        if not vram and gpu.get("sppci_model", "").startswith("Apple"):
            vram = "Memoire unifiee (partagee avec la RAM)"
        gpus.append({
            "Name": gpu.get("sppci_model") or gpu.get("_name") or "N/A",
            "VRAM": vram or "N/A",
            "Resolution": (gpu.get("_spdisplays_resolution")
                            or (gpu.get("spdisplays_ndrvs", [{}])[0].get("_spdisplays_resolution")
                                if gpu.get("spdisplays_ndrvs") else None)
                            or "N/A"),
        })
    return gpus


def get_ram_info():
    data = run_command_json(["system_profiler", "SPMemoryDataType", "-json"])
    mem = {}
    if data and data.get("SPMemoryDataType"):
        mem = data["SPMemoryDataType"][0]

    total = mem.get("SPMemoryDataType", mem.get("dimm_size")) or "N/A"

    # Apple Silicon Macs report unified memory as a single top-level item
    # with no per-slot breakdown - same "integrated, nothing to enumerate"
    # situation as soldered RAM on a Windows laptop
    items = mem.get("_items")
    if not items:
        total_bytes = None
        try:
            total_bytes = int(subprocess.run(
                ["sysctl", "-n", "hw.memsize"], capture_output=True, text=True, timeout=5
            ).stdout.strip())
        except (ValueError, OSError, subprocess.SubprocessError):
            pass
        total_gb = round(total_bytes / (1024 ** 3), 2) if total_bytes else "N/A"
        return {"Total": f"{total_gb} GB", "Modules": [], "Integrated": True}

    modules = []
    for i, item in enumerate(items):
        modules.append({
            "Slot": item.get("_name", f"Slot {i + 1}"),
            "Manufacturer": item.get("dimm_manufacturer", "N/A"),
            "Capacity": item.get("dimm_size", "N/A"),
            "Status": "Occupe" if item.get("dimm_size", "Empty") != "Empty" else "Vide",
        })
    return {"Total": total, "Modules": modules, "Integrated": False}


# --------------------------------------------------------------------------
# Disks + SMART
# --------------------------------------------------------------------------

def get_disk_list():
    """Whole physical disks (not partitions/volumes) via diskutil."""
    data = run_command_json(["diskutil", "list", "-plist"])
    if not data:
        # diskutil doesn't support -json; -plist is the structured form,
        # parsed with plistlib below since it's XML, not JSON
        raw = run_command(["diskutil", "list", "-plist"])
        if not raw:
            return []
        try:
            data = plistlib.loads(raw.encode("utf-8"))
        except Exception:
            return []
    return data.get("WholeDisks", []) if isinstance(data, dict) else []


def get_disk_info(device_id):
    raw = run_command(["diskutil", "info", "-plist", device_id])
    if not raw:
        return None
    try:
        info = plistlib.loads(raw.encode("utf-8"))
    except Exception:
        return None

    size_bytes = info.get("TotalSize", 0)
    return {
        "DeviceID": device_id,
        "Type": "SSD" if info.get("SolidState") else "HDD",
        "BusProtocol": info.get("BusProtocol", "N/A"),
        "Size": f"{round(size_bytes / (1024 ** 3), 2)} GB",
        "MediaName": info.get("MediaName", "N/A"),
        "SmartStatus": info.get("SMARTStatus", "N/A"),  # "Verified" / "Failing" / "Not Supported"
        "SMART": None,  # filled in by get_smart_data() when smartctl is available
    }


def smart_numeric_value(lines, patterns, trailing=False):
    """Port of Get-SmartNumericValue: ATA attribute-table rows put the value
    we want at the END of the line (the first number is the attribute ID,
    e.g. 5 for Reallocated_Sector_Ct) - NVMe log fields are simple
    "label: value" lines where the first number after the colon is correct."""
    for pattern in patterns:
        for line in lines:
            if not re.search(pattern, line):
                continue
            if trailing:
                # Strip a trailing "(Min/Max 20/45)" annotation some
                # versions of smartctl append to the temperature line
                stripped = re.sub(r"\s*\([^)]*\)\s*$", "", line.strip())
                match = re.search(r"(\d[\d,]*)\s*$", stripped)
            else:
                match = re.search(r":\s*(\d[\d,]*)", line)
            if match:
                return match.group(1).replace(",", "")
    return None


def get_smart_data(device_id, bus_protocol):
    smartctl = shutil.which("smartctl")
    if not smartctl:
        return None

    device_path = f"/dev/{device_id}"
    device_types = ["nvme", "ata", "sat", "scsi"] if "PCI" in (bus_protocol or "") else ["sat", "ata", "nvme", "scsi"]

    for dev_type in device_types:
        output = run_command(["sudo", "-n", smartctl, "-d", dev_type, "-a", device_path])
        if not output:
            output = run_command([smartctl, "-d", dev_type, "-a", device_path])
        if not output:
            continue
        lines = output.splitlines()
        if not any(re.search(p, output) for p in
                   ["Reallocated_Sector_Ct", "Power_On_Hours", "Power-On_Hours",
                    "Data Units Written", "Percentage Used"]):
            continue

        errors = smart_numeric_value(lines, ["Reallocated_Sector_Ct"], trailing=True)
        if errors is None:
            errors = smart_numeric_value(lines, ["Media and Data Integrity Errors:"])

        hours = smart_numeric_value(lines, ["Power_On_Hours", "Power-On_Hours"], trailing=True)
        if hours is None:
            hours = smart_numeric_value(lines, [r"^Power On Hours:"])

        temp = smart_numeric_value(lines, ["Temperature:"])
        if temp is None:
            temp = smart_numeric_value(lines, ["Temperature_Celsius"], trailing=True)
        temp_val = None
        if temp is not None and 0 < int(temp) < 100:
            temp_val = int(temp)

        wear = smart_numeric_value(lines, ["Percent_Lifetime_Remain", "Wear_Leveling_Count"], trailing=True)
        wear_level = f"{wear}% restant" if wear is not None else None
        if wear_level is None:
            used = smart_numeric_value(lines, ["Percentage Used"])
            if used is not None:
                wear_level = f"{used}% use"

        model_match = re.search(r"(?:Device Model|Model Number):\s*(.+)", output)
        serial_match = re.search(r"Serial Number:\s*(.+)", output)
        firmware_match = re.search(r"Firmware Version:\s*(.+)", output)

        return {
            "Errors": errors or "N/A",
            "Hours": hours or "N/A",
            "Temp": temp_val if temp_val is not None else "N/A",
            "WearLevel": wear_level or "N/A",
            "Source": "smartctl",
            "Model": model_match.group(1).strip() if model_match else None,
            "Serial": serial_match.group(1).strip() if serial_match else None,
            "Firmware": firmware_match.group(1).strip() if firmware_match else None,
        }

    return None


def get_disk_health_status(disk, temp_threshold=50):
    """Same classification used for the summary badge and the detailed disk
    card, so the two can't disagree - port of Get-DiskHealthStatus."""
    smart = disk.get("SMART")
    if smart:
        errors = smart.get("Errors")
        if errors not in (None, "N/A", "0"):
            try:
                if int(errors) > 0:
                    return {"Status": "KO", "Label": "Probleme detecte", "CssClass": "health-bad",
                             "AlertMessage": "Secteurs realloues detectes"}
            except ValueError:
                pass
        temp = smart.get("Temp")
        if temp not in (None, "N/A"):
            try:
                if int(temp) > temp_threshold:
                    return {"Status": "Attention", "Label": "Temperature elevee", "CssClass": "health-warning",
                             "AlertMessage": f"Temperature > {temp_threshold}C"}
            except ValueError:
                pass

    smart_status = disk.get("SmartStatus")
    if smart_status and smart_status not in ("Verified", "Not Supported", "N/A"):
        return {"Status": "Attention", "Label": smart_status, "CssClass": "health-warning", "AlertMessage": ""}

    return {"Status": "OK", "Label": "OK", "CssClass": "health-good", "AlertMessage": ""}


# --------------------------------------------------------------------------
# Battery
# --------------------------------------------------------------------------

def get_battery_info(good_threshold=80, warning_threshold=60, critical_threshold=40):
    output = run_command(["system_profiler", "SPPowerDataType"])
    if not output:
        return None

    def find(pattern):
        m = re.search(pattern, output)
        return m.group(1).strip() if m else None

    cycle_count = find(r"Cycle Count:\s*(\d+)")
    max_capacity_pct = find(r"Maximum Capacity:\s*(\d+)%")
    condition = find(r"Condition:\s*(.+)")
    serial = find(r"Battery Information:.*?Serial Number:\s*(\S+)")
    manufacturer = find(r"Manufacturer:\s*(.+)")

    if max_capacity_pct is None:
        # No battery (desktop Mac) or the field genuinely isn't reported
        return None

    health = float(max_capacity_pct)
    if health >= good_threshold:
        health_status = "Excellent"
    elif health >= warning_threshold:
        health_status = "Bon"
    elif health >= critical_threshold:
        health_status = "Attention"
    else:
        health_status = "Critique"

    return {
        "SerialNumber": serial or "Non detecte",
        "Manufacturer": manufacturer or "Non detecte",
        "Age": f"{cycle_count} cycles" if cycle_count else "Inconnu",
        "Condition": condition or "Non detectee",
        "Health": f"{health}%",
        "HealthValue": health,
        "HealthStatus": health_status,
    }


# --------------------------------------------------------------------------
# Network / FileVault
# --------------------------------------------------------------------------

def get_network_info():
    data = run_command_json(["system_profiler", "SPNetworkDataType", "-json"])
    if not data or not data.get("SPNetworkDataType"):
        return []

    adapters = []
    for iface in data["SPNetworkDataType"]:
        mac = None
        for key in ("Ethernet", "IEEE80211", "AirPort"):
            section = iface.get(key)
            if isinstance(section, dict) and section.get("MAC Address"):
                mac = section["MAC Address"]
                break
        if not mac:
            continue
        adapters.append({"Name": iface.get("_name", "N/A"), "MACAddress": mac})
    return adapters


def get_encryption_info():
    output = run_command(["fdesetup", "status"])
    if output is None:
        return {"Status": "Unavailable", "Volumes": []}

    on = "FileVault is On" in output
    return {
        "Status": "OK",
        "Volumes": [{"MountPoint": "/ (systeme)", "ProtectionStatus": "Chiffre" if on else "Non chiffre",
                     "EncryptionMethod": "FileVault"}],
    }


def get_os_info():
    version = run_command(["sw_vers", "-productVersion"])
    build = run_command(["sw_vers", "-buildVersion"])
    return {
        "Name": "macOS",
        "Version": (version or "N/A").strip(),
        "Build": (build or "N/A").strip(),
    }


# --------------------------------------------------------------------------
# Global assessment (identical scoring logic to the Windows script)
# --------------------------------------------------------------------------

def get_global_assessment(disk_statuses, has_battery, battery_health_value,
                           battery_good=80, battery_warning=60, battery_critical=40,
                           score_good=80, score_warning=50):
    score = 100
    for status in disk_statuses:
        if status == "KO":
            score -= 35
        elif status == "Attention":
            score -= 12

    if has_battery:
        if battery_health_value < battery_critical:
            score -= 35
        elif battery_health_value < battery_warning:
            score -= 20
        elif battery_health_value < battery_good:
            score -= 8

    score = max(0, min(100, score))

    if score >= score_good:
        label, recommendation, badge_class = "Bon etat", "Reemploi possible", "status-ok"
    elif score >= score_warning:
        label, recommendation, badge_class = "Attention", "Verifier avant reemploi", "status-warning"
    else:
        label, recommendation, badge_class = "Critique", "Recyclage recommande", "status-bad"

    return {"Score": score, "Label": label, "Recommendation": recommendation, "BadgeClass": badge_class}


# --------------------------------------------------------------------------
# Reports folder maintenance
# --------------------------------------------------------------------------

def remove_old_reports(reports_dir: Path, max_age_days: int):
    removed = []
    if max_age_days <= 0 or not reports_dir.is_dir():
        return removed
    cutoff = datetime.now() - timedelta(days=max_age_days)
    for f in reports_dir.iterdir():
        if f.suffix in (".html", ".json") and f.is_file():
            try:
                if datetime.fromtimestamp(f.stat().st_mtime) < cutoff:
                    f.unlink()
                    removed.append(f.name)
            except OSError:
                pass
    return removed


def update_report_index(reports_dir: Path):
    json_files = sorted(reports_dir.glob("*.json"), key=lambda f: f.stat().st_mtime, reverse=True)
    if not json_files:
        return None

    rows = []
    for jf in json_files:
        html_file = jf.with_suffix(".html")
        if not html_file.exists():
            continue
        try:
            data = json.loads(jf.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue

        system = data.get("System", {})
        ga = data.get("GlobalAssessment", {})
        rows.append(
            "<tr>"
            f"<td>{html_safe(data.get('GeneratedAt'))}</td>"
            f"<td>{html_safe(data.get('AssetTag'))}</td>"
            f"<td>{html_safe(system.get('Brand'))} {html_safe(system.get('Model'))}</td>"
            f"<td>{html_safe(system.get('SerialNumber'))}</td>"
            f"<td><span class='status-badge {ga.get('BadgeClass', '')}'>"
            f"{ga.get('Score', '?')}/100 - {html_safe(ga.get('Label'))}</span></td>"
            f"<td>{html_safe(ga.get('Recommendation'))}</td>"
            f"<td><a href='{html.escape(html_file.name)}'>Ouvrir</a></td>"
            "</tr>"
        )

    if not rows:
        return None

    index_html = f"""<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <title>Index des rapports - CompStats for Recycle</title>
    <style>
        body {{ font-family: -apple-system, 'Segoe UI', Tahoma, Verdana, sans-serif; margin: 20px; background-color: #f4f4f4; color: #333; }}
        .container {{ max-width: 1400px; margin: auto; background: white; padding: 20px; border-radius: 8px; box-shadow: 0 0 10px rgba(0,0,0,0.1); }}
        h1 {{ text-align: center; color: #2c3e50; }}
        table {{ border-collapse: collapse; width: 100%; margin-top: 10px; }}
        th, td {{ border: 1px solid #ddd; padding: 10px; text-align: left; }}
        th {{ background-color: #f8f9fa; font-weight: bold; }}
        tr:nth-child(even) {{ background-color: #f8f9fa; }}
        .status-badge {{ display: inline-block; padding: 2px 8px; border-radius: 4px; font-weight: bold; font-size: 0.9em; }}
        .status-ok {{ background: #27ae60; color: white; }}
        .status-warning {{ background: #f39c12; color: white; }}
        .status-bad {{ background: #e74c3c; color: white; }}
        a {{ color: #3498db; }}
    </style>
</head>
<body>
    <div class="container">
        <h1>Index des rapports ({len(rows)})</h1>
        <table>
            <tr><th>Date</th><th>Reference</th><th>Modele</th><th>Numero de serie</th><th>Etat</th><th>Recommandation</th><th></th></tr>
            {"".join(rows)}
        </table>
    </div>
</body>
</html>
"""
    index_path = reports_dir / "index.html"
    index_path.write_text(index_html, encoding="utf-8")
    return index_path


# --------------------------------------------------------------------------
# HTML report
# --------------------------------------------------------------------------

REPORT_CSS = """
body { font-family: -apple-system, 'Segoe UI', Tahoma, Verdana, sans-serif; margin: 20px; background-color: #f4f4f4; color: #333; }
.container { max-width: 1200px; margin: auto; background: white; padding: 20px; border-radius: 8px; box-shadow: 0 0 10px rgba(0,0,0,0.1); }
h1 { text-align: center; color: #2c3e50; }
.section { margin-bottom: 30px; }
h2 { border-bottom: 2px solid #3498db; padding-bottom: 5px; color: #2c3e50; }
table { border-collapse: collapse; width: 100%; margin-top: 10px; }
th, td { border: 1px solid #ddd; padding: 12px; text-align: left; }
th { background-color: #f8f9fa; font-weight: bold; }
tr:nth-child(even) { background-color: #f8f9fa; }
.health-good { color: green; }
.health-warning { color: orange; }
.health-bad { color: red; }
.summary-card { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 20px; border-radius: 10px; margin-bottom: 30px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); }
.summary-card h2 { border: none; color: white; margin-top: 0; font-size: 1.2em; }
.summary-grid { display: flex; flex-wrap: wrap; gap: 15px; margin-top: 15px; }
.summary-item { background: rgba(255,255,255,0.2); padding: 10px 15px; border-radius: 5px; flex: 1; min-width: 150px; }
.summary-label { font-weight: bold; font-size: 0.9em; opacity: 0.9; }
.summary-value { font-size: 1.1em; margin-top: 5px; }
.status-badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-weight: bold; font-size: 0.9em; }
.status-ok { background: #27ae60; color: white; }
.status-warning { background: #f39c12; color: white; }
.status-bad { background: #e74c3c; color: white; }
.disk-card { margin-bottom: 20px; border: 1px solid #ddd; padding: 10px; border-radius: 5px; }
@media print {
    body { background: white; }
    .container { box-shadow: none; max-width: 100%; }
    .summary-card { background: white; color: #333; border: 2px solid #667eea; box-shadow: none; }
    .summary-card h2, .summary-label { color: #333; }
    .summary-item { background: #f4f4f4; }
    .status-ok, .status-warning, .status-bad { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    .section, .disk-card { page-break-inside: avoid; }
}
"""


def build_html_report(system, cpu, gpu, ram, disks, disk_healths, battery, network,
                       encryption, os_info, global_assessment, summary_disks_html,
                       summary_battery_html, script_version):
    ram_html = (
        "<p><em>RAM integree/soudee detectee : detail par module non disponible.</em></p>"
        if ram.get("Integrated")
        else "<table><tr><th>Slot</th><th>Statut</th><th>Marque</th><th>Capacite</th></tr>" + "".join(
            f"<tr><td>{html_safe(m.get('Slot'))}</td><td>{html_safe(m.get('Status'))}</td>"
            f"<td>{html_safe(m.get('Manufacturer'))}</td><td>{html_safe(m.get('Capacity'))}</td></tr>"
            for m in ram.get("Modules", [])
        ) + "</table>"
    )

    gpu_html = "".join(
        f"<table style='margin-bottom: 10px;'><tr><th>Modele</th><td>{html_safe(g.get('Name'))}</td></tr>"
        f"<tr><th>Memoire video</th><td>{html_safe(g.get('VRAM'))}</td></tr>"
        f"<tr><th>Resolution</th><td>{html_safe(g.get('Resolution'))}</td></tr></table>"
        for g in gpu
    ) or "<p>Non detectee</p>"

    disk_cards = []
    for disk, health in zip(disks, disk_healths):
        smart = disk.get("SMART")
        rows = [
            f"<tr><th>Type</th><td>{html_safe(disk.get('Type'))}</td></tr>",
            f"<tr><th>Taille</th><td>{html_safe(disk.get('Size'))}</td></tr>",
            f"<tr><th>Modele</th><td>{html_safe(disk.get('MediaName'))}</td></tr>",
            f"<tr><th>Bus</th><td>{html_safe(disk.get('BusProtocol'))}</td></tr>",
        ]
        if smart:
            if smart.get("Model"):
                rows.append(f"<tr><th>Modele (SMART)</th><td>{html_safe(smart['Model'])}</td></tr>")
            if smart.get("Serial"):
                rows.append(f"<tr><th>Numero de serie</th><td>{html_safe(smart['Serial'])}</td></tr>")
            if smart.get("Firmware"):
                rows.append(f"<tr><th>Firmware</th><td>{html_safe(smart['Firmware'])}</td></tr>")
            rows.append(f"<tr><th>Secteurs realloues</th><td class='{health['CssClass']}'>{html_safe(smart.get('Errors'))}</td></tr>")
            rows.append(f"<tr><th>Heures utilisation</th><td>{html_safe(smart.get('Hours'))}</td></tr>")
            rows.append(f"<tr><th>Temperature</th><td class='{health['CssClass']}'>{html_safe(smart.get('Temp'))}</td></tr>")
            rows.append(f"<tr><th>Niveau d'usure</th><td>{html_safe(smart.get('WearLevel'))}</td></tr>")
        else:
            rows.append(f"<tr><th>Statut SMART (diskutil)</th><td class='{health['CssClass']}'>{html_safe(disk.get('SmartStatus'))}</td></tr>")
        rows.append(f"<tr><th>Etat de sante</th><td class='{health['CssClass']}'><strong>{html_safe(health['Label'])}</strong></td></tr>")
        if health.get("AlertMessage"):
            rows.append(f"<tr><th>Alerte</th><td class='health-bad'>{html_safe(health['AlertMessage'])}</td></tr>")
        disk_cards.append(f"<div class='disk-card'><table>{''.join(rows)}</table></div>")
    disks_html = "".join(disk_cards) or "<p>Aucun disque detecte</p>"

    if battery:
        battery_health_class = ("health-good" if battery["HealthValue"] >= 80
                                 else "health-warning" if battery["HealthValue"] >= 60 else "health-bad")
        battery_html = (
            "<table>"
            f"<tr><th>Fabricant</th><td>{html_safe(battery.get('Manufacturer'))}</td></tr>"
            f"<tr><th>Numero de serie</th><td>{html_safe(battery.get('SerialNumber'))}</td></tr>"
            f"<tr><th>Age approximatif</th><td>{html_safe(battery.get('Age'))}</td></tr>"
            f"<tr><th>Condition (macOS)</th><td>{html_safe(battery.get('Condition'))}</td></tr>"
            f"<tr><th>Etat de sante</th><td class='{battery_health_class}'>{battery['Health']} ({battery['HealthStatus']})</td></tr>"
            "</table>"
        )
    else:
        battery_html = "<p>Aucune batterie detectee</p>"

    network_html = "<table><tr><th>Interface</th><th>Adresse MAC</th></tr>" + "".join(
        f"<tr><td>{html_safe(n.get('Name'))}</td><td>{html_safe(n.get('MACAddress'))}</td></tr>" for n in network
    ) + "</table>"

    if encryption["Status"] == "OK":
        encryption_html = "<table><tr><th>Volume</th><th>Statut</th><th>Methode</th></tr>" + "".join(
            f"<tr><td>{html_safe(v.get('MountPoint'))}</td>"
            f"<td class='{'health-warning' if v.get('ProtectionStatus') == 'Chiffre' else 'health-good'}'>{html_safe(v.get('ProtectionStatus'))}</td>"
            f"<td>{html_safe(v.get('EncryptionMethod'))}</td></tr>" for v in encryption["Volumes"]
        ) + "</table>"
    else:
        encryption_html = "<p><em>Statut FileVault non verifie (commande fdesetup indisponible).</em></p>"

    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    return f"""<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <title>CompStats for Recycle</title>
    <style>{REPORT_CSS}</style>
</head>
<body>
    <div class="container">
        <h1>Statistiques Ordinateur pour Recyclage</h1>
        <p><strong>Date de generation:</strong> {generated_at}</p>

        <div class="summary-card">
            <h2>Resume de Sante</h2>
            <div class="summary-grid">
                <div class="summary-item">
                    <div class="summary-label">Etat global</div>
                    <div class="summary-value"><span class='status-badge {global_assessment['BadgeClass']}'>{global_assessment['Score']}/100 - {html_safe(global_assessment['Label'])}</span></div>
                </div>
                <div class="summary-item">
                    <div class="summary-label">Modele</div>
                    <div class="summary-value">{html_safe(system['Model'])} ({html_safe(system['SerialNumber'])})</div>
                </div>
                <div class="summary-item">
                    <div class="summary-label">Disques</div>
                    <div class="summary-value">{summary_disks_html}</div>
                </div>
                <div class="summary-item">
                    <div class="summary-label">Batterie</div>
                    <div class="summary-value">{summary_battery_html}</div>
                </div>
            </div>
            <p style="margin-top: 15px; margin-bottom: 0;"><strong>Recommandation :</strong> {html_safe(global_assessment['Recommendation'])}</p>
        </div>

        <div class="section">
            <h2>Systeme</h2>
            <table>
                <tr><th>Marque</th><td>{html_safe(system['Brand'])}</td></tr>
                <tr><th>Modele</th><td>{html_safe(system['Model'])} ({html_safe(system.get('ModelIdentifier'))})</td></tr>
                <tr><th>Numero de serie</th><td>{html_safe(system['SerialNumber'])}</td></tr>
                <tr><th>macOS</th><td>{html_safe(os_info['Version'])} (build {html_safe(os_info['Build'])})</td></tr>
            </table>
        </div>

        <div class="section">
            <h2>CPU</h2>
            <table>
                <tr><th>Marque</th><td>{html_safe(cpu['Brand'])}</td></tr>
                <tr><th>Modele</th><td>{html_safe(cpu['Model'])}</td></tr>
                <tr><th>Vitesse</th><td>{html_safe(cpu['Speed'])}</td></tr>
            </table>
        </div>

        <div class="section">
            <h2>Carte graphique</h2>
            {gpu_html}
        </div>

        <div class="section">
            <h2>Reseau</h2>
            {network_html}
        </div>

        <div class="section">
            <h2>RAM</h2>
            <p><strong>Total:</strong> {html_safe(ram['Total'])}</p>
            {ram_html}
        </div>

        <div class="section">
            <h2>Disques</h2>
            {disks_html}
        </div>

        <div class="section">
            <h2>Chiffrement (FileVault)</h2>
            {encryption_html}
        </div>

        <div class="section">
            <h2>Batterie</h2>
            {battery_html}
        </div>
    </div>
    <footer style="text-align: center; margin-top: 30px; padding: 15px; background: #f8f9fa; border-radius: 5px; font-size: 0.9em; color: #666;">
        <p><strong>CompStats for Recycle v{script_version} (macOS)</strong> - Copyright (c) 2026 Guillaume COQUEBLIN (esquimo.org)</p>
        <p><a href="https://github.com/eskiiom/compstats4recycle" target="_blank">https://github.com/eskiiom/compstats4recycle</a></p>
    </footer>
</body>
</html>
"""


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="CompStats for Recycle - macOS")
    parser.add_argument("--no-json", action="store_true", help="Ne pas ecrire l'export JSON")
    parser.add_argument("--no-csv-log", action="store_true", help="Ne pas ajouter de ligne au CSV consolide")
    parser.add_argument("--no-index", action="store_true", help="Ne pas regenerer Rapports/index.html")
    parser.add_argument("--asset-tag", default="", help="Reference d'inventaire interne optionnelle")
    parser.add_argument("--battery-good-threshold", type=float, default=80)
    parser.add_argument("--battery-warning-threshold", type=float, default=60)
    parser.add_argument("--battery-critical-threshold", type=float, default=40)
    parser.add_argument("--disk-temp-warning-threshold", type=int, default=50)
    parser.add_argument("--score-good-threshold", type=int, default=80)
    parser.add_argument("--score-warning-threshold", type=int, default=50)
    parser.add_argument("--purge-reports-older-than-days", type=int, default=0)
    return parser.parse_args(argv)


def safe_filename_part(value):
    return re.sub(r'[\\/:*?"<>|]', "_", str(value))


def main(argv=None):
    if sys.platform != "darwin":
        print("Attention : ce script est concu pour macOS (sys.platform == 'darwin').", file=sys.stderr)

    args = parse_args(argv)

    print("======================================")
    print(f"CompStats for Recycle v{SCRIPT_VERSION} macOS ({SCRIPT_DATE})")
    print("Copyright (c) 2026 Guillaume COQUEBLIN")
    print("https://github.com/eskiiom/compstats4recycle")
    print("======================================\n")

    system = get_system_info()
    cpu = get_cpu_info()
    gpu = get_gpu_info()
    ram = get_ram_info()
    network = get_network_info()
    encryption = get_encryption_info()
    os_info = get_os_info()
    battery = get_battery_info(args.battery_good_threshold, args.battery_warning_threshold,
                                args.battery_critical_threshold)

    disks = []
    for device_id in get_disk_list():
        info = get_disk_info(device_id)
        if not info:
            continue
        info["SMART"] = get_smart_data(device_id, info.get("BusProtocol"))
        disks.append(info)

    disk_healths = [get_disk_health_status(d, args.disk_temp_warning_threshold) for d in disks]
    disk_statuses = [h["Status"] for h in disk_healths]

    summary_disks_parts = []
    summary_disks_plain_parts = []
    for i, (disk, health) in enumerate(zip(disks, disk_healths), start=1):
        badge = {"OK": "status-ok", "Attention": "status-warning", "KO": "status-bad"}[health["Status"]]
        size = disk["Size"].replace(" GB", "")
        summary_disks_parts.append(
            f"Disque {i} {size}GB : <span class='status-badge {badge}'>{health['Status']}</span>"
        )
        summary_disks_plain_parts.append(f"Disque {i} {size}GB : {health['Status']}")
    summary_disks_html = " | ".join(summary_disks_parts) or "Aucun disque"
    summary_disks_plain = " | ".join(summary_disks_plain_parts) or "Aucun disque"

    has_battery = battery is not None
    battery_health_value = battery["HealthValue"] if has_battery else 100
    if has_battery:
        badge = ("status-ok" if battery_health_value >= args.battery_good_threshold
                  else "status-warning" if battery_health_value >= args.battery_warning_threshold else "status-bad")
        summary_battery_html = f"<span class='status-badge {badge}'>{battery['Health']}</span>"
    else:
        summary_battery_html = "N/A"

    global_assessment = get_global_assessment(
        disk_statuses, has_battery, battery_health_value,
        args.battery_good_threshold, args.battery_warning_threshold, args.battery_critical_threshold,
        args.score_good_threshold, args.score_warning_threshold,
    )

    reports_dir = Path(__file__).resolve().parent / "Rapports"
    reports_dir.mkdir(exist_ok=True)

    if args.purge_reports_older_than_days > 0:
        for name in remove_old_reports(reports_dir, args.purge_reports_older_than_days):
            print(f"Rapport ancien supprime ({args.purge_reports_older_than_days}+ jours): {name}")

    date_str = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    asset_prefix = f"{safe_filename_part(args.asset_tag)}_" if args.asset_tag else ""
    filename_base = f"{asset_prefix}{safe_filename_part(system['Brand'])}_{safe_filename_part(system['Model'])}_{safe_filename_part(system['SerialNumber'])}_{date_str}_CS4Rv{SCRIPT_VERSION}"

    html_report = build_html_report(
        system, cpu, gpu, ram, disks, disk_healths, battery, network,
        encryption, os_info, global_assessment, summary_disks_html,
        summary_battery_html, SCRIPT_VERSION,
    )
    html_path = reports_dir / f"{filename_base}.html"
    html_path.write_text(html_report, encoding="utf-8")
    print(f"Rapport genere a {html_path}")

    if not args.no_json:
        report_data = {
            "GeneratedAt": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "ScriptVersion": SCRIPT_VERSION,
            "AssetTag": args.asset_tag,
            "System": system,
            "CPU": cpu,
            "GPU": gpu,
            "Network": network,
            "RAM": ram,
            "Disks": disks,
            "Encryption": encryption,
            "Battery": battery,
            "OS": os_info,
            "GlobalAssessment": global_assessment,
        }
        json_path = reports_dir / f"{filename_base}.json"
        json_path.write_text(json.dumps(report_data, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"Export JSON genere a {json_path}")

    if not args.no_csv_log:
        csv_path = reports_dir / "resume.csv"
        is_new = not csv_path.exists()
        with csv_path.open("a", newline="", encoding="utf-8-sig") as f:
            writer = csv.writer(f)
            if is_new:
                writer.writerow(["DateHeure", "ReferenceInventaire", "Marque", "Modele", "NumeroSerie",
                                  "CPU", "RAM", "Disques", "BatterieSante", "ScoreGlobal", "Recommandation"])
            writer.writerow([
                datetime.now().strftime("%Y-%m-%d %H:%M:%S"), args.asset_tag, system["Brand"], system["Model"],
                system["SerialNumber"], cpu["Model"], ram["Total"], summary_disks_plain,
                battery["Health"] if has_battery else "N/A", global_assessment["Score"],
                global_assessment["Recommendation"],
            ])
        print(f"Ligne ajoutee au resume: {csv_path}")

    if not args.no_index and not args.no_json:
        index_path = update_report_index(reports_dir)
        if index_path:
            print(f"Index des rapports mis a jour: {index_path}")

    print("\n======================================")
    print("Resume")
    print("======================================")
    print(f"Score global    : {global_assessment['Score']}/100 - {global_assessment['Label']}")
    print(f"Recommandation  : {global_assessment['Recommendation']}")
    print(f"Disques         : {summary_disks_plain}")
    print(f"Batterie        : {battery['Health'] + ' (' + battery['HealthStatus'] + ')' if has_battery else 'N/A'}")
    if encryption["Status"] != "OK":
        print("Chiffrement     : non verifie")


if __name__ == "__main__":
    main()
