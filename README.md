# VM Converter Pro Elite

**Company:** Codefyhub Technologies  
**Built by:** Ahmed Bahaa  
**Version:** 3.12.00 (Build 2026-10-21)  
**Edition:** Production (V26)

A Windows PowerShell-based desktop tool for converting virtual machine disk images between **Proxmox** (`.vma.zst` / `.qcow2`) and **VMware** (`.vmdk`), executed through Docker. Available as a GUI application and a headless CLI, and shippable as a single `.exe` (built with PS2EXE using `vm-convert.ico`).

---

## ✨ Features

- Bidirectional conversion
  - **Proxmox → VMware**: `.vma.zst` → `.vmdk`
  - **VMware → Proxmox**: `.vmdk` → `.qcow2`
- Drag-and-drop file selection + browse dialog
- GUI with custom dark theme, progress bar, and live log pane
- Headless/CLI mode for scripting and automation
- Pre-flight source validation (zstd magic check; `qemu-img info` probe)
- Real progress percentage parsing from `qemu-img`
- Disk-space watchdog during conversion
- Atomic output via `.partial` temp filename (VM → PVE)
- Multi-threaded `qemu-img` speed presets (Safe / Balanced / Fast)
- File-lock detection on source and split VMDK segments
- Split VMDK handling with descriptor/extent awareness
- Toast + taskbar flash on completion
- Post-conversion summary dialog ("receipt")
- Structured job history (`vmconvert.history.json`, last 200 jobs)
- Settings dialog persisted to `vmconvert.settings.json`
- One-click support bundle export (system info + log + container state → `.zip`)
- Log levels (DEBUG / INFO / WARN / ERROR) with live filtering
- Toast notifications, settings, and history viewers
- Support for command-line parameters: `-InputPath`, `-OutputPath`, `-Direction`, `-Headless`, `-Force`, `-Quiet`

---

## 📋 Requirements

- Windows 10/11
- **Docker Desktop** installed and running (Docker Engine must be available)
- Source files on a **local fixed drive** (Docker Desktop bind-mount limitation)
- For VMware → Proxmox conversion, the tools image (`alpine:3.19`) pulls `qemu-img` at runtime
- (Optional) VMware Workstation/Player's `vmware-vdiskmanager.exe` for additional disk operations

---

## 🚀 Usage

### GUI
```powershell
.\VM-Convert-ProEdition.ps1
```
Or launch the compiled executable:
```
VM-Convert-ProEdition.exe
```

### Pre-fill input
```powershell
.\VM-Convert-ProEdition.ps1 -InputPath "D:\VMs\web01.vma.zst"
```

### Headless (scripting)
```powershell
.\VM-Convert-ProEdition.ps1 -InputPath "D:\VMs\web01.vmdk" -Headless -Force
```

### Exit codes (headless)
| Code | Meaning |
|------|---------|
| 0 | SUCCESS |
| 1 | FAILED |
| 2 | CANCELLED |
| 3 | UNCERTAIN |

---

## ⚙️ Settings

Stored in `vmconvert.settings.json` next to the script/executable. Includes image names, min output size, log level, qemu mode, preflight toggle, summary dialog, toast, watchdog free space, detailed progress, auto-cleanup, and keep-intermediates-on-failure.

## 📜 History

Stored in `vmconvert.history.json` (last 200 jobs) with source/output paths, direction, sizes, duration, result, and exit code. Viewable via the in-app **HISTORY** button.

## 🛠️ Support Bundle

The **SUPPORT** button exports a `.zip` containing system info, the current log, and container state for troubleshooting.

## 📁 Project Files

- `VM-Convert-ProEdition.ps1` — main script
- `vm-convert.ico` — application icon
- `VM-Convert-ProEdition.exe` — compiled executable (PS2EXE)
- `vmconvert.settings.json` — settings (created at runtime)
- `vmconvert.history.json` — job history (created at runtime)

---

## 🏢 Credits

- **Company:** Codefyhub Technologies
- **Built by:** Ahmed Bahaa
- **Version:** 3.12.00

## 📄 License

Add your license here.