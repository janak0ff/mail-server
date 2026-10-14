# Universal IMAP Email Migration Tool (`sync.sh`) v2.0.0

A production-grade, interactive terminal tool built to migrate mailboxes between IMAP email providers using [imapsync](https://imapsync.lamiral.info/). 

Supports **Gmail**, **Zimbra / Zextras Carbonio**, **Outlook / Office 365**, **Yahoo Mail**, and any standard **IMAP server**. Features single-user migrations, parallel batch processing, non-destructive dry-runs, folder regex filtering, exponential backoff retries, secret isolation, and profile management—all through an interactive terminal interface.

---

## 📋 Table of Contents

- [Key Features](#-key-features)
- [Architecture & Directory Structure](#-architecture--directory-structure)
- [Requirements & Dependencies](#-requirements--dependencies)
- [Quick Start](#-quick-start)
- [Command Line Options (CLI)](#-command-line-options-cli)
- [Interactive Main Menu Reference](#-interactive-main-menu-reference)
  - [1. Migrate Single User](#1-migrate-single-user)
  - [2. Batch Migration (Sequential & Parallel)](#2-batch-migration)
  - [3. Check Migration Status](#3-check-migration-status)
  - [4. Verify Sync (Dry Run)](#4-verify-sync-dry-run)
  - [5. Resume Failed Migrations](#5-resume-failed-migrations)
  - [6. Manage User Lists](#6-manage-user-lists)
  - [7. View Reports](#7-view-reports)
  - [8. Manage Profiles](#8-manage-profiles)
  - [9. Log Cleanup](#9-log-cleanup)
- [Security & Credentials Management](#-security--credentials-management)
- [Advanced Usage Examples](#-advanced-usage-examples)
  - [User Mapping (`source:destination`)](#user-mapping-sourcedestination)
  - [Folder Include/Exclude Regex Filters](#folder-includeexclude-regex-filters)
  - [Bandwidth Throttling](#bandwidth-throttling)
- [Troubleshooting](#-troubleshooting)

---

## ✨ Key Features

- 🚀 **Universal IMAP Support & Provider Presets**: Native configuration helpers for Gmail/Google Workspace, Office 365/Exchange, Zimbra/Carbonio, Yahoo Mail, and custom IMAP servers.
- ⚡ **Parallel Batch Migration**: Multi-threaded execution using IPC semaphore control (supports up to 20 concurrent worker jobs).
- 🔁 **Automated Retries with Exponential Backoff**: Configurable retry attempts with dynamic backoff delay for batch and resume runs.
- 🛡️ **Zero Plaintext Credentials Leakage**: Passwords stored in `chmod 600` secret files or prompted per-session, supplied via `--passfile` options. Never exposed in process tables (`ps aux`) or logs.
- 📊 **Real-time Progress & ETA Tracking**: Interactive progress bar displaying completion percentage, elapsed time, item count, and dynamic ETA estimation.
- 🧪 **Non-Destructive Dry Runs**: Verify mailbox differences, item counts, and size metrics prior to actual migration.
- 📂 **Regex Folder Filtering**: Include or exclude specific mail folders (e.g., exclude `^Spam$`, `^Trash$`, or `^\[Gmail\]/All Mail`).
- 🗂️ **Profile Management (Full CRUD + Import/Export)**: Save connection details per client or environment. Supports exporting and importing profiles (with optional base64-encoded secret payloads).
- 🧹 **Integrated Log Maintenance**: Inspect log disk usage, cleanup logs by age or specific user, and view top largest log files.

---

## 🏗 Architecture & Directory Structure

All runtime configurations, credentials, logs, and reports live inside the base working directory (defaults to `~/migration_tool` or custom path):

```text
~/migration_tool/
├── profiles/          # Saved connection profiles (*.conf) - host/port/user details
├── .secrets/          # Restricted directory (chmod 700) holding chmod 600 password files
├── LOGS/              # Detailed timestamped logs per migration/verify session
├── reports/           # Batch migration summaries and resume reports (*.txt)
└── user_lists/        # Saved user email lists and mapping files (*.txt)
```

---

## ⚙️ Requirements & Dependencies

| Tool / Dependency | Purpose | Required? |
| :--- | :--- | :--- |
| `bash` **4.0+** | Script execution & associative array support | **Yes** |
| `imapsync` | Underlying engine for IMAP protocol transfer | **Yes** |
| `bc` | Floating-point calculator for byte/size conversions | **Yes** |
| `root` (`sudo`) | System privilege check for secret/log management | **Yes** |
| `zmprov` | Zimbra CLI utility for checking destination mailbox status/quota | Optional (degrades gracefully) |
| `shred` | Secure file shredding for temporary session password files | Optional (falls back to `rm -f`) |

Prerequisite installation command (Debian/Ubuntu):
```bash
sudo apt update && sudo apt install -y imapsync bc grep sed coreutils
```

---

## 🚀 Quick Start

### Option 1: Direct One-Liner (Recommended)

Run the script directly from GitHub without cloning:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/janak0ff/script-forest/imapsync/sync.sh)"
```

### Option 2: Local Execution

If you have cloned the repository locally:

```bash
chmod +x sync.sh
sudo ./sync.sh
```

---

### First-Run Interactive Walkthrough:
1. **Base Working Directory**: Set where logs, profiles, and reports are stored (default: `~/migration_tool`).
2. **Profile Creation**:
   - Provide a Profile Name (e.g., `company_migration`).
   - Select Source Provider (Gmail, Zimbra, O365, Yahoo, Custom).
   - Input Source Authentication Admin User (e.g., `admin@source.com`).
   - Select Destination Provider.
   - Input Destination Authentication Admin User (e.g., `admin@dest.com`).
3. **Password Security Option**:
   - `1) Store in secrets file`: Save passwords securely under `.secrets/` (`chmod 600`).
   - `2) Prompt me each time`: Enter passwords per session into temporary shredded files.

---

## 💻 Command Line Options (CLI)

`sync.sh` can be executed interactively or launched with CLI flags:

```bash
Usage:
  sudo ./sync.sh [OPTIONS]

Options:
  -h, --help           Show help message and exit
  -v, --version        Show version information and exit
  --profile NAME       Directly load a saved profile by name, skipping the profile picker menu
```

### Examples:
```bash
# Launch interactive profile selection
sudo ./sync.sh

# Directly load the 'production_gsuite' profile
sudo ./sync.sh --profile production_gsuite

# Display version
./sync.sh --version
```

---

## 📖 Interactive Main Menu Reference

```text
╔══════════════════════════════════════════════════════════════╗
║  UNIVERSAL EMAIL MIGRATION TOOL  v2.0.0                      ║
╚══════════════════════════════════════════════════════════════╝

  ┌─────────────────────────────────────────────────────────┐
  │  1.  Migrate Single User                               │
  │  2.  Batch Migration                                   │
  │  3.  Check Migration Status                            │
  │  4.  Verify Sync (Dry Run)                             │
  │  5.  Resume Failed Migrations                          │
  │  6.  Manage User Lists                                 │
  │  7.  View Reports                                      │
  │  8.  Manage Profiles                                   │
  │  9.  Log Cleanup                                       │
  │  0.  Exit                                              │
  └─────────────────────────────────────────────────────────┘
```

---

### 1. Migrate Single User
Migrates mail from one source mailbox to one destination mailbox.
- Prompts for **Source Email** and **Destination Email**.
- Optional **Folder Filters** (Includes / Excludes regex).
- Optional **Bandwidth Throttle** (Bytes/sec).
- Optional **Timeout** limit in seconds (`0` for unlimited).
- Outputs progress bars and displays total transferred messages/bytes upon completion.

### 2. Batch Migration
Process multiple mailboxes automatically from a user list or mapping file.
- **List Sources**: Choose from saved files in `user_lists/`, create a new list inline, or specify a mapping file (`source_email:dest_email`).
- **Parallel Migration**: Choose between sequential execution (`1`) or parallel workers (up to `20` parallel processes running simultaneously via IPC semaphore).
- **Auto-Retries**: Specify max retry attempts on failed transfers with exponential backoff delay.
- **Graceful Interrupt**: Pressing `Ctrl+C` (`SIGINT`) safely stops pending launches and writes a partial report.
- Saves a summary report in `reports/batch_report_<timestamp>.txt`.

### 3. Check Migration Status
Inspect mailbox status on the destination server.
- Performs `zmprov` queries if connected to Zimbra (Mailbox Size, Quota, Last Login, Account Status).
- Searches historical migration logs in `LOGS/` matching the requested user email.
- Displays the tail end of the most recent log file.

### 4. Verify Sync (Dry Run)
Executes `imapsync` in non-destructive `--dry` mode.
- Compares source and destination mailboxes without writing or deleting any messages.
- Displays calculated diffs, message counts, and size metrics.

### 5. Resume Failed Migrations
Retry failed mailboxes from previous batch runs without re-migrating successful ones.
- Lists previous batch reports and their failure counts.
- Parses exact `FAILED` entries from the selected report.
- Supports retry attempts and backoff delay.
- Generates a new report in `reports/resume_report_<timestamp>.txt`.

### 6. Manage User Lists
Create and maintain user lists in `user_lists/`:
- Option 1: Create single email list (one email per line).
- Option 2: Create mapping file (`source_email:destination_email`).
- Option 3: View file contents with line numbers.
- Option 4: Delete lists.
- Option 5: Import existing text files into `user_lists/`.

### 7. View Reports
Browse, select, and view full contents of batch and resume migration report files directly inside the terminal.

### 8. Manage Profiles
Full CRUD management for server profile configurations:
1. **Switch profile**: Load another existing configuration.
2. **Create new profile**: Add connection parameters for a new source/destination pair.
3. **Edit current profile**: Change server hostnames, admin usernames, ports, or update saved secrets.
4. **Delete a profile**: Safely remove profiles (prevents accidental deletion of the currently active profile).
5. **Export profile**: Export profile settings into a standalone `.conf` file (with option to include base64-encoded secret payloads).
6. **Import profile**: Load a profile exported from another workstation.

### 9. Log Cleanup
Inspect and manage disk space consumed by log files under `LOGS/`:
- Delete logs older than $N$ days.
- Delete all log files.
- Delete logs matching a specific user email.
- View top 10 largest log files on disk.

---

## 🔒 Security & Credentials Management

Security is a primary design goal of `sync.sh`:

1. **Process Isolation**: Password credentials are passed to `imapsync` using `--passfile1` and `--passfile2`. They never appear as command-line arguments, keeping them hidden from `ps aux` or `/proc` monitoring by non-root users.
2. **File Permissions**:
   - `profiles/`: `chmod 600` (readable only by owner/root).
   - `.secrets/`: Directory `chmod 700`, files `chmod 600`.
3. **Session Secrets Shredding**: In "Prompt Each Time" mode, passwords are stored in temporary files generated by `mktemp`. When the script exits, a Bash `EXIT` trap executes `shred -u` (or `rm -f`) to securely erase the temporary files from disk.

---

## 💡 Advanced Usage Examples

### User Mapping (`source:destination`)

When migrating to a new domain or where usernames differ between source and destination, create a mapping file in `user_lists/domain_mapping.txt`:

```text
# Format: source_user@olddomain.com:dest_user@newdomain.com
john.doe@oldcompany.com:jdoe@newcompany.com
alice.smith@oldcompany.com:asmith@newcompany.com
```

Select **Option 2 (Batch Migration)** -> **Option 3 (Use mapping file)** in the main menu to run migrations with these pair mappings.

### Folder Include/Exclude Regex Filters

During single user or batch migrations, you can define regex folder rules:

- **Exclude Spam and Trash**:
  ```text
  exclude> ^Trash$
  exclude> ^Spam$
  exclude> ^Junk$
  ```
- **Exclude Gmail All Mail and Starred system folders**:
  ```text
  exclude> ^\[Gmail\]/All Mail$
  exclude> ^\[Gmail\]/Trash$
  ```
- **Include INBOX only**:
  ```text
  include> ^INBOX$
  ```

### Bandwidth Throttling

To prevent consuming all available network bandwidth during large migrations, enter a maximum bytes-per-second rate when prompted:

- `1048576` = 1 MB/s
- `5242880` = 5 MB/s
- `0` = Unlimited (default)

---

## ❓ Troubleshooting

### 1. `ERROR: Bash 4.0+ required`
Your environment is using an outdated shell. Verify your version with `bash --version`. On macOS, install an updated version via `brew install bash`.

### 2. `Please run as root.`
The script requires root privileges to manage permission-restricted secrets (`.secrets/`) and execute administrative commands. Run with:
```bash
sudo ./sync.sh
```

### 3. `Missing: imapsync bc`
Install missing packages:
```bash
sudo apt update && sudo apt install -y imapsync bc
```

### 4. Gmail / Google Workspace Authentication Failures
- **2FA Enabled**: You must generate and use an **App Password** from Google Account Security settings instead of the main account password.
- Ensure **IMAP Access** is enabled in Gmail settings (`Settings` -> `See all settings` -> `Forwarding and POP/IMAP` -> `Enable IMAP`).

### 5. Office 365 / Outlook Authentication Errors
- Office 365 requires enabling Basic Authentication for IMAP or generating an App Password depending on your tenant's security defaults and Conditional Access policies.

---