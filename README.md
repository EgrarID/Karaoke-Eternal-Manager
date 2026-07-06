[KARAOKE_ETERNAL_MANAGER_NOTES_v5.10.1.md](https://github.com/user-attachments/files/29703800/KARAOKE_ETERNAL_MANAGER_NOTES_v5.10.1.md)
# Karaoke Eternal Docker Manager v5.10.1

This guide documents the **v5.10.1** Ubuntu Server manager for Karaoke Eternal.

Version 5.10.1 keeps the Docker, tmux, backup, Samba, ZIP integrity checker, Fast Scan, restore, and `KES_SCAN` startup-scan workflows from v5.9.9. It focuses on the ZIP error-review workflow: handled files no longer reappear in the review list, multiple ZIP errors can be selected safely, quarantine/delete confirmations are stronger, and restore now respects both the default media folder and the configured `KES_MEDIA_PATH`.

## Main changes in v5.10.1

- Menu item 16 now builds an **unresolved ZIP error review list** from the latest scan plus `zip-error-actions.log`.
- Files already marked kept, quarantined, deleted, or restored are hidden from future review lists and exit-code summaries without modifying the original scan report.
- ZIP error selection now accepts one number, comma lists, ranges, and mixed selections, such as `1`, `1-5`, `1,2,3,10`, or `1-5,8,12`.
- Bulk quarantine is supported and uses one timestamped batch folder with the shell PID included, reducing collision risk.
- Bulk delete requires a safer exact confirmation phrase: `DELETE N FILES`, where `N` is the selected file count.
- The keep action is now a **keep / mark resolved** action, so stale entries can be cleared safely when the administrator decides not to move or delete the file.
- Quarantine refuses to overwrite an existing destination file.
- Restore-index safety now accepts original media paths under either `/data/karaoke-eternal/media` or the configured `KES_MEDIA_PATH`.
- Added an orphaned-quarantine recovery path for ZIP files that are physically present under `/data/karaoke-eternal-quarantine` but are missing from the normal action-log restore index.
- Added a separate restored media holding folder: `/data/karaoke-eternal/restored-media`.
- Orphan recovery moves files into the restored media folder for manual inspection instead of placing them directly back into the live Karaoke Eternal media tree.
- Added restore-menu options to list orphaned quarantined ZIPs, recover all orphaned ZIPs, or recover one orphaned quarantine batch/folder.
- Added direct commands `--list-orphan-quarantine`, `--recover-orphan-quarantine`, and `--recover-orphan-quarantine-batch`.
- `--verify-zips-by-folder` now opens the immediate-subfolder picker directly instead of opening the full ZIP scan menu.
- Normal restart now force-recreates the container so a previous temporary `KES_SCAN` startup-scan environment is removed reliably.
- ZIP tests now check readability from the service account, not only from root.
- Directory traversal warnings are recorded in the report and cause a nonzero scan result when no per-file ZIP errors were found.

- Added a **Restore quarantined ZIP media files** routine.
- New main-menu item 17 opens the quarantine restore workflow directly.
- Menu item 16 now includes restore access from the ZIP error-review submenu.
- Restore uses the existing `zip-error-actions.log`, so it can restore ZIPs quarantined by previous v5.9.x builds as long as the quarantined file still exists.
- Restore refuses to overwrite an existing file at the original media path.
- Restore refuses unsafe paths outside `/data/karaoke-eternal/media`, the configured media path, or `/data/karaoke-eternal-quarantine`.
- Added direct commands `--list-quarantine`, `--restore-quarantine`, and `--restore-quarantine-folder FOLDER`.
- Added restore history logging to `/data/karaoke-eternal/reports/zip-restore-actions.log`.

- Added a Start submenu under menu item 5.
- Menu item 5 can now start Karaoke Eternal normally, start/recreate with `KES_SCAN=all`, or start/recreate with a custom comma-separated `KES_SCAN` pathId list.
- Added direct command `--start-scan [TARGET]`; default target is `all`.
- The scan-on-start routine uses a temporary Docker Compose override so the saved base `compose.yaml` remains normal.
- The implementation follows the official Karaoke Eternal CLI/ENV reference: `KES_SCAN` runs the media scanner at startup and accepts `all` or a comma-separated list of path IDs.
- Added scroll-safe viewing for long ZIP error lists, media-subfolder lists, ZIP reports, unzip detail files, ZIP action history, and backup lists.
- Menu 16 option 5 now opens long folder + exit-code result lists in a scrollable viewer instead of printing the whole list straight to the screen and cutting off the top.
- Added a `v` option in ZIP error review screens to re-open the current result list before selecting a file.
- Added `less` to prerequisite checks and prerequisite installation so long interactive lists can be browsed with Arrow keys, PageUp/PageDown, Home/End, and `q` to return.
- Added a reconnectable tmux-safe launcher for the interactive manager menu.
- Running `sudo karaoke-eternal-manager` now starts or reconnects to a fixed tmux session named `karaoke-eternal-manager`, when tmux is installed and the command is running in an interactive SSH terminal.
- If an existing manager tmux session is found, the launcher offers to reconnect, start a separate session, kill the stale session and start clean, run once outside tmux, or exit.
- Added direct commands: `--attach-manager`, `--manager-tmux-status`, and `--no-tmux`.
- Added prerequisite utilities to system maintenance checks, including `tmux`, `less`, `unzip`, `timeout`, `base64`, and other tools used by the manager.
- Added direct commands: `--check-prereqs` and `--install-prereqs`.
- Menu item 1 now includes prerequisite checking and prerequisite install/repair before the normal apt update/upgrade choices.
- `install_host_prerequisites` now installs `tmux`, `less`, `unzip`, and `procps` in addition to the previous Ubuntu utility packages.
- Full diagnostics now display manager prerequisite status.
- Menu item 1 is now **Ubuntu system diagnostics and package updates**.
- Added package-index refresh with `apt-get update`.
- Added installed-package upgrades with `apt-get update` followed by `apt-get upgrade -y`.
- Removed the previous menu item 15 deep ZIP preflight implementation.
- Removed the previous menu item 16 advanced all-media preflight implementation.
- New menu item 15 recursively finds every `.zip` file and tests it with `unzip -tqq`.
- Every ZIP failure is recorded in a timestamped readable log and machine-readable error index.
- Menu item 16 opens the unresolved ZIP error review list and lets the administrator:
  - keep / mark one or more entries resolved;
  - move one or more files outside the media tree to quarantine; or
  - permanently delete one or more files after the required confirmation.
- Menu item 16 can summarize failures by exact per-file `unzip` exit code.
- Administrators can select one exit code and review only the matching files.
- Menu item 15 can select one immediate subfolder under `/data/karaoke-eternal/media`, scan only that folder recursively, and then optionally review failures by exit code.
- Added **Fast Scan** under menu item 15: choose a folder, scan recursively, show an exit-code summary, choose one exact code, then immediately keep, quarantine, or delete matching files.
- Menu item 16 can now filter existing errors by both media folder and exact exit code before offering keep, quarantine, or delete.
- Added direct commands for folder-based scanning, Fast Scan, and folder+exit-code review.
- The guarded keep, quarantine, and permanent-delete actions are reused for filtered results, and multiple selected entries can be handled in one pass.
- Added direct commands for exit-code summaries and filtered review.
- The simplified ZIP checker does not modify the Karaoke Eternal database.
- Existing Samba support continues to share only the configured media directory.
- Corrected an unbound positional-parameter error in the ZIP path/mount checker (`$3: unbound variable`).
- Menu item 15 and `--verify-zips` now default predictably to `/data/karaoke-eternal/media`.
- The saved `KES_MEDIA_PATH` and active Docker `/mnt/karaoke` source remain visible as optional choices.
- Added defensive defaults to the mount-check helper so omitted optional arguments cannot terminate the manager under `set -u`.
- Corrected the downloadable "latest" aliases to contain the v5.10.1 build.
- Added an Info-ZIP `unzip` exit-code reference table with manager-specific timeout/readability statuses and recommended actions.

## Installation or upgrade

```bash
chmod +x karaoke_eternal_manager_v5.10.1.sh

sudo install -m 0755 \
  karaoke_eternal_manager_v5.10.1.sh \
  /usr/local/sbin/karaoke-eternal-manager
```

Open the manager:

```bash
sudo karaoke-eternal-manager
```

Starting with v5.10.1, this opens the menu inside a reconnectable tmux session when possible. If your SSH connection drops, log back in and run the same command again to reconnect.

Check the installed version:

```bash
sudo karaoke-eternal-manager --version
```

Expected result:

```text
5.10.1
```

## Reconnectable safe manager launcher

The interactive manager now uses a fixed tmux session name:

```text
karaoke-eternal-manager
```

Normal usage:

```bash
sudo karaoke-eternal-manager
```

If no manager session exists, the script starts one and opens the menu. Detach without stopping the manager:

```text
Ctrl-b then d
```

If your SSH session disconnects, log back in and run:

```bash
sudo karaoke-eternal-manager
```

or explicitly attach with:

```bash
sudo karaoke-eternal-manager --attach-manager
```

If an existing session is found, the launcher offers:

```text
1) Reconnect to existing manager session
2) Start a new separate manager session
3) Kill the existing session, then start a new one
4) Run once in this SSH session without tmux
0) Exit
```

Use option 1 for normal reconnects. Use option 3 only when you know the old manager session is stale or stuck.

Show manager tmux sessions:

```bash
sudo karaoke-eternal-manager --manager-tmux-status
```

Bypass tmux for one run:

```bash
sudo karaoke-eternal-manager --no-tmux
```

The bypass option is useful for testing, but it is not reconnectable after an SSH disconnect.

Important: manager sessions created before v5.10.1 outside tmux cannot be reattached. The tmux launcher protects new interactive sessions going forward.

## Prerequisite utility checks

Menu item 1 now includes prerequisite checks and repair:

```text
1) Run full system diagnostics
2) Check manager prerequisite utilities
3) Install/repair manager prerequisites, including tmux, less, and unzip
4) Refresh package indexes (apt-get update)
5) Update installed system packages (apt-get update + apt-get upgrade -y)
6) Check whether a reboot is required
0) Return
```

Check prerequisites from the command line:

```bash
sudo karaoke-eternal-manager --check-prereqs
```

Install or repair prerequisite packages:

```bash
sudo karaoke-eternal-manager --install-prereqs
```

The checked manager utilities include:

```text
curl
python3
ip
ss
findmnt
mountpoint
tar
gzip
realpath
runuser
getent
timeout
base64
find
unzip
tmux
CA certificates
```

`tmux` is required for reconnectable manager sessions. `less` is used for scrollable long lists and reports. `unzip` is required for ZIP integrity testing. `timeout` is used so one bad ZIP cannot hang the entire ZIP scan indefinitely.

## Main menu

```text
  1) Ubuntu system diagnostics and package updates
  2) Install / repair / update Docker Engine
  3) Apply safe Docker daemon optimizations
  4) Install or reconfigure Karaoke Eternal
  5) Start Karaoke Eternal / scan media on startup
  6) Stop Karaoke Eternal
  7) Restart Karaoke Eternal
  8) Status, paths, storage, and web test
  9) View live logs
 10) Update Karaoke Eternal
 11) Back up database and configuration
 12) Restore a backup safely
 13) Check media and backup paths
 14) Check ports and firewall behavior
 15) Test ZIPs / Fast Scan by media folder
 16) Filter/review ZIP errors: keep, quarantine, delete, or restore
 17) Restore quarantined ZIP media files
 18) Samba share for the configured media folder
 19) Show saved configuration
 20) Remove container while keeping data
 21) Fully remove Karaoke Eternal data
  0) Exit
```

## Start submenu: Karaoke Eternal / scan media on startup

Menu item 5 opens a start submenu:

```text
Start Karaoke Eternal

  1) Start normally
  2) Start/recreate with media scan on startup (KES_SCAN=all)
  3) Start/recreate with custom KES_SCAN pathIds
  4) View live logs
  0) Return
```

## Normal start

Normal start keeps the existing saved configuration and runs:

```bash
sudo karaoke-eternal-manager --start
```

Internally this performs the standard preflight checks and then starts the Docker Compose service detached in the background.

## Start with media scan on startup

Karaoke Eternal supports the startup scanner through the official CLI/ENV option:

```text
--scan / KES_SCAN
```

The official server reference describes `KES_SCAN` as running the media scanner at startup. It accepts a comma-separated list of path IDs, or `all`.

Use the menu option:

```text
2) Start/recreate with media scan on startup (KES_SCAN=all)
```

Or run directly:

```bash
sudo karaoke-eternal-manager --start-scan
```

This recreates the container with:

```text
KES_SCAN=all
```

and then starts Karaoke Eternal detached with Docker Compose.

## Start with a custom scan target

Use this only when you know the Karaoke Eternal media-folder path IDs. A custom target should be either:

```text
all
```

or a comma-separated list such as:

```text
abc123,def456
```

Direct command example:

```bash
sudo karaoke-eternal-manager --start-scan all
```

```bash
sudo karaoke-eternal-manager --start-scan abc123,def456
```

The manager rejects empty values and values containing spaces or unsafe shell/YAML characters.

## Important scan-on-start behavior

`KES_SCAN` matters when the Karaoke Eternal server process starts. The manager therefore uses a temporary Compose override and recreates the container with the requested `KES_SCAN` value.

The saved base Compose file remains normal. However, the running container that was created with `KES_SCAN=all` keeps that environment value until it is recreated again. If Docker restarts that same container before you do a normal recreate, it may scan again at container startup.

To return the running container to normal no-scan startup behavior, use the normal restart/recreate routine:

```bash
sudo karaoke-eternal-manager --restart
```

For Docker installs, scanner output is visible through Docker logs:

```bash
sudo karaoke-eternal-manager --logs
```

# 1. Ubuntu diagnostics and package updates

Menu item 1 opens:

```text
  1) Run full system diagnostics
  2) Check manager prerequisite utilities
  3) Install/repair manager prerequisites, including tmux, less, and unzip
  4) Refresh package indexes (apt-get update)
  5) Update installed system packages (apt-get update + apt-get upgrade -y)
  6) Check whether a reboot is required
  0) Return
```

## Refresh package indexes

```bash
sudo karaoke-eternal-manager --apt-update
```

Equivalent operation:

```bash
sudo apt-get update
```

## Upgrade installed Ubuntu packages

```bash
sudo karaoke-eternal-manager --system-update
```

The manager runs:

```bash
sudo apt-get update
sudo apt-get upgrade -y
```

The upgrade is run noninteractively. The manager reports whether Ubuntu created:

```text
/var/run/reboot-required
```

This is a normal package upgrade. It does not perform a release upgrade to another Ubuntu version and does not run `dist-upgrade` or `full-upgrade`.

# 2. Simplified recursive ZIP integrity test

Menu item 15 now uses this canonical default media root:

```text
/data/karaoke-eternal/media
```

All `.zip` files below that directory are discovered recursively, including ZIPs in nested artist, disc, or collection folders.

The menu also displays two diagnostics:

```text
Saved KES_MEDIA_PATH: value stored in /data/karaoke-eternal/.env
Docker /mnt/karaoke: active host bind source reported by docker inspect
```

The available choices are:

```text
1) Scan /data/karaoke-eternal/media recursively (default)
2) Select an immediate subfolder under the default ZIP media root
3) Scan the saved KES_MEDIA_PATH
4) Scan the active Docker /mnt/karaoke source
5) Enter another absolute media folder
6) Fast Scan: choose folder -> scan -> summarize -> review one exit code
0) Cancel
```

Pressing Enter selects option 1.

Option 2 lists the immediate folders under the default ZIP media root and shows how many `.zip` files each folder contains recursively. You can optionally type a folder-name filter first, then select one folder to scan. This is useful when the media library is organized by language, disc set, artist, collection, or upload batch.

Run the canonical default directly:

```bash
sudo karaoke-eternal-manager --verify-zips
```

Test a different directory explicitly:

```bash
sudo karaoke-eternal-manager --verify-zips /path/to/media
```

Set a custom per-file timeout in seconds:

```bash
sudo karaoke-eternal-manager --verify-zips /path/to/media 600
```

The default timeout is 300 seconds per ZIP file. Accepted values are 10 through 3600 seconds.

## Test ZIPs by folder

From menu item 15, choose option 2 to list the immediate folders under:

```text
/data/karaoke-eternal/media
```

The manager shows each folder with the number of ZIP files below it, then scans only the selected folder recursively.

Direct interactive command:

```bash
sudo karaoke-eternal-manager --verify-zips-by-folder
```

Use a different root folder for the subfolder picker:

```bash
sudo karaoke-eternal-manager --verify-zips-by-folder /data/karaoke-eternal/media
```

Set a custom timeout while using the subfolder picker:

```bash
sudo karaoke-eternal-manager --verify-zips-by-folder /data/karaoke-eternal/media 600
```

If errors are found, the manager prints the exit-code summary for that folder and can immediately open the filtered keep/quarantine/delete review workflow.

## ZIP error review behavior in v5.10.1

Menu item 16 reviews unresolved entries only. The original scan TSV is preserved for audit/history, but review screens and exit-code summaries are filtered through the action log:

```text
/data/karaoke-eternal/reports/zip-error-actions.log
```

The following actions mark an entry as handled for future review lists:

```text
KEPT
QUARANTINED
DELETED
RESTORED
```

Selection examples:

```text
1
1-5
1,2,3,10
1-5,8,12
```

Bulk quarantine moves selected files into one batch folder under:

```text
/data/karaoke-eternal-quarantine/YYYYMMDD-HHMMSS-PID/
```

Bulk delete is intentionally harder to confirm. For example, if seven files are selected, the manager requires this exact phrase:

```text
DELETE 7 FILES
```

Use quarantine instead of delete when you are not fully sure the media files are disposable.

## Fast Scan combined workflow

Fast Scan is available from menu item 15, option 6:

```text
Fast Scan: choose folder -> scan -> summarize -> review one exit code
```

It combines the safer separate steps into one guided routine:

```text
Choose folder
-> scan recursively
-> show exit-code summary
-> choose one exact exit code
-> immediately review matching files
-> keep, quarantine, or delete each selected file
```

Fast Scan still does not automatically modify ZIP files during the scan. File actions happen only after the review screen appears and you choose an action for a specific matching file.

Direct interactive command:

```bash
sudo karaoke-eternal-manager --zip-fast-scan
```

Fast Scan a specific folder directly:

```bash
sudo karaoke-eternal-manager \
  --zip-fast-scan \
  /data/karaoke-eternal/media/FolderName
```

Use a custom per-file timeout:

```bash
sudo karaoke-eternal-manager \
  --zip-fast-scan \
  /data/karaoke-eternal/media/FolderName \
  600
```

When errors are found, the summary is based on the machine-readable TSV index from that exact scan. If you choose exit code `9`, only files under the Fast Scan folder with exact exit code `9` are shown. It will not match `90`, `91`, or any other code.

## Positional-argument correction retained from v5.9.2

Earlier v5.9.1 code called the mount-validation helper with arguments in the wrong order and omitted its third and fourth parameters. Because the manager uses `set -u`, Bash terminated with an error similar to:

```text
line 611: $3: unbound variable
```

v5.10.1 retains the corrected call form:

```bash
check_expected_mount "$path" "$mode" "$expected_mount" "media"
```

The helper also uses defensive defaults for optional arguments. Missing values now produce a controlled validation message instead of terminating the whole script.

## What the ZIP test does

The manager:

1. Confirms the media directory exists and is readable.
2. Checks the expected external mount when the configured media path uses one.
3. Installs Ubuntu's `unzip` package when the command is missing.
4. Recursively finds regular files whose names end in `.zip`, case-insensitively.
5. Tests each archive with:

```bash
unzip -tqq -P '' /path/to/file.zip
```

6. Applies a timeout to each test so one archive cannot leave the manager stuck indefinitely.
7. Logs every archive that returns a nonzero exit status.
8. Records directory traversal warnings separately.
9. Prints totals for discovered, tested, passed, and failed archives.

`unzip -t` reads and tests every member in the archive and verifies stored CRC information. This catches common problems such as:

- truncated archives;
- damaged central directories;
- CRC failures;
- unreadable ZIP files;
- invalid files renamed with a `.zip` extension;
- incomplete multi-part archives;
- password-protected archives, which are reported instead of prompting interactively; and
- archives that exceed the configured test timeout.

## Info-ZIP `unzip` test exit codes

The manager records the **per-file exit code** returned by `unzip -tqq -P ''` in the fourth field of the machine-readable ZIP error index:

```text
/data/karaoke-eternal/reports/zip-errors-latest.tsv
```

The manager's own overall scan exit code is separate. A full scan may return `2` simply because one or more files failed, while each failing ZIP has its own stored `unzip` exit code.

Use this table when reviewing Fast Scan results, folder-filtered results, or menu item 16 exit-code filters.

| Exit code | Meaning from `unzip` | What it usually means for Karaoke ZIP media | Suggested action |
|---:|---|---|---|
| `0` | Normal; no errors or warnings detected | The archive passed the ZIP integrity test | No action needed |
| `1` | Warning errors occurred, but processing completed | May include skipped files, unsupported method warning, or encrypted member warning | Inspect details first; usually keep or repack |
| `2` | Generic ZIP-format error | Archive structure is suspicious or partly malformed | Quarantine first; retest or replace |
| `3` | Severe ZIP-format error | Archive is likely corrupt and may fail immediately | Quarantine; replace from a clean copy if available |
| `4` | Could not allocate memory during initialization | Server resource issue, not necessarily a bad ZIP | Keep file; retry when system load is lower |
| `5` | Could not allocate memory or obtain a TTY for passwords | Resource/password-prompt problem | Keep file; inspect details and retry |
| `6` | Could not allocate memory during decompression to disk | Server memory/resource problem | Keep file; retry later |
| `7` | Could not allocate memory during in-memory decompression | Server memory/resource problem | Keep file; retry later |
| `8` | Currently unused by Info-ZIP | Not expected in normal testing | Inspect details; do not auto-delete |
| `9` | Specified ZIP file was not found | File moved, deleted, renamed, or disappeared during scan | Rerun scan; keep if still present |
| `10` | Invalid command-line options | Script/tool invocation issue | Do not act on media; check manager command |
| `11` | No matching files were found | Archive/file pattern mismatch case | Inspect details; usually keep |
| `50` | Disk was full during extraction/test processing | Host storage issue, not necessarily bad media | Free space and rerun scan |
| `51` | End of ZIP archive encountered prematurely | Truncated or incomplete ZIP | Quarantine; replace or re-copy file |
| `80` | User aborted `unzip` | Interrupted scan | Rerun scan; no media action needed |
| `81` | Unsupported compression or unsupported decryption | ZIP may use unsupported compression/encryption | Repack as standard non-encrypted ZIP/Deflate |
| `82` | No files processed because of bad password(s) | Password-protected/encrypted archive or bad password | Repack without password; do not delete automatically |

### Manager-added statuses

These are not standard Info-ZIP archive result meanings, but the manager may record them when the wrapper around `unzip` detects a condition before or around the test:

| Exit/status | Meaning in this manager | Suggested action |
|---:|---|---|
| `124` / `TIMEOUT` | The per-file test exceeded the configured timeout | Retry with a longer timeout; quarantine only if it repeatedly hangs |
| `126` / `UNREADABLE` | The ZIP exists but the server could not read it | Check Linux permissions, ownership, mount state, or disk health |
| `137` / `TIMEOUT` or killed process | Test process was killed, often from timeout or system pressure | Retry with a longer timeout and check memory/load |

### Recommended filters

Likely corrupt ZIPs:

```bash
sudo karaoke-eternal-manager --review-zip-exit-code 2
sudo karaoke-eternal-manager --review-zip-exit-code 3
sudo karaoke-eternal-manager --review-zip-exit-code 51
```

Folder-specific corrupt ZIP review:

```bash
sudo karaoke-eternal-manager \
  --review-zip-folder-exit-code \
  /data/karaoke-eternal/media/FolderName \
  51
```

Encrypted or unsupported ZIPs that should usually be repacked instead of deleted:

```bash
sudo karaoke-eternal-manager --review-zip-exit-code 81
sudo karaoke-eternal-manager --review-zip-exit-code 82
```

Storage, permission, resource, or interrupted-scan codes that should usually be fixed and rescanned before touching media:

```text
4, 5, 6, 7, 9, 10, 50, 80, 124, 126, 137
```

**Safe policy:** never bulk-delete by exit code. Use the review menu to inspect details and prefer quarantine over permanent deletion.


## What the simplified ZIP test does not do

The v5.10.1 checker intentionally does not attempt to reproduce Karaoke Eternal's Node.js metadata scanner. It does not check:

- whether a ZIP contains a top-level MP3 or M4A;
- whether a ZIP contains a top-level CDG;
- artist/title filename parsing;
- `_kes.v2.json` parsing;
- audio duration metadata;
- standalone MP3/M4A and CDG pairing;
- MP4 metadata; or
- Karaoke Eternal database insertion.

It is a focused ZIP-read and archive-integrity check only.

## Scrollable long lists and reports

Starting with v5.10.1, long selection lists and long reports are not dumped straight to the terminal by default. When the output is longer than the visible terminal height and `less` is installed, the manager opens a scrollable viewer.

Use these keys inside the viewer:

```text
Arrow Up / Arrow Down    Move one line
PageUp / PageDown        Move one page
Home / End               Jump to top or bottom
/ search-text            Search within the list
n / N                    Next or previous search match
q                        Return to the manager prompt
```

The scrollable viewer is used for:

- menu 16 ZIP error result lists;
- menu 16 option 5 folder + exit-code result lists;
- media-subfolder selection lists under ZIP scanning and Fast Scan;
- latest ZIP integrity reports;
- individual unzip error detail files;
- keep/quarantine/delete action history;
- backup restore candidate lists.

If `less` is not installed, the manager falls back to normal `cat` output. Run this to install missing prerequisites:

```bash
sudo karaoke-eternal-manager --install-prereqs
```

In ZIP error review screens and media-subfolder picker screens, type:

```text
v
```

to view the current list again before selecting a numbered file.

# 3. ZIP reports

Reports are stored under:

```text
/data/karaoke-eternal/reports/
```

Each run creates:

```text
zip-test-YYYYMMDD-HHMMSS.log
zip-errors-YYYYMMDD-HHMMSS.tsv
zip-test-details-YYYYMMDD-HHMMSS/
```

The readable log contains each failing ZIP and the output from `unzip`.

The TSV file stores a safely encoded path index used by the review menu. Paths are Base64 encoded so filenames containing spaces, tabs, or unusual characters do not break the index format.

Each non-comment TSV row contains five fields:

```text
scanned-root path status unzip-exit-code detail-log
```

The root, file path, and detail-log path are Base64 encoded. The fourth field is the exact numeric exit code returned for that individual ZIP test. Menu item 16 uses this field for exact filtering; it does not parse the human-readable text report.

Convenience links point to the latest test:

```text
/data/karaoke-eternal/reports/zip-test-latest.log
/data/karaoke-eternal/reports/zip-errors-latest.tsv
```

Show the latest readable report:

```bash
sudo karaoke-eternal-manager --zip-report
```

A scan that finds errors returns exit status `2`. This lets administrators use the command in scheduled or scripted checks.

# 4. Filter and review ZIP errors

Open menu item 16. The submenu is:

```text
  1) Show the latest ZIP test report
  2) Show error counts grouped by exit code
  3) Review all files recorded with errors
  4) Filter by one exit code, then keep/quarantine/delete
  5) Filter by media folder and exit code, then keep/quarantine/delete
  6) Run a new recursive ZIP integrity test
  7) Restore quarantined media files
  8) Show keep/quarantine/delete/restore action history
  0) Return
```

## Summarize errors by exit code

```bash
sudo karaoke-eternal-manager --zip-exit-summary
```

For a specific historical index:

```bash
sudo karaoke-eternal-manager \
  --zip-exit-summary \
  /data/karaoke-eternal/reports/zip-errors-YYYYMMDD-HHMMSS.tsv
```

Example output:

```text
Exit code   Files
---------   -----
3           4
51          2
82          1
```

The count comes from the exact fourth field in the machine-readable TSV index.

Summarize only errors under one folder:

```bash
sudo karaoke-eternal-manager \
  --zip-exit-summary-folder \
  /data/karaoke-eternal/media/FolderName
```

Summarize one folder from a historical index:

```bash
sudo karaoke-eternal-manager \
  --zip-exit-summary-folder \
  /data/karaoke-eternal/media/FolderName \
  /data/karaoke-eternal/reports/zip-errors-YYYYMMDD-HHMMSS.tsv
```

## Review all errors

```bash
sudo karaoke-eternal-manager --review-zip-errors
```

Review a specific index:

```bash
sudo karaoke-eternal-manager \
  --review-zip-errors \
  /data/karaoke-eternal/reports/zip-errors-YYYYMMDD-HHMMSS.tsv
```

## Filter by one exact exit code

From menu item 16, select option 4. The manager displays the available exit-code counts, asks for one numeric code, and then lists only matching files.

Direct command:

```bash
sudo karaoke-eternal-manager --review-zip-exit-code 3
```

Use a specific historical report:

```bash
sudo karaoke-eternal-manager \
  --review-zip-exit-code 51 \
  /data/karaoke-eternal/reports/zip-errors-YYYYMMDD-HHMMSS.tsv
```

The filter is exact. Selecting code `3` does not also select `30`, `31`, or `51`. Accepted filter values are integers from `0` through `255`. A code with no matching entries returns a controlled informational message and makes no media changes.

## Filter by folder and one exact exit code

From menu item 16, select option 5. The manager lets you choose an immediate media subfolder, shows the exit-code counts for that folder, asks for one exact exit code, and then offers actions only for matching files inside that folder.

Direct command:

```bash
sudo karaoke-eternal-manager \
  --review-zip-folder-exit-code \
  /data/karaoke-eternal/media/FolderName \
  3
```

Use a specific historical report:

```bash
sudo karaoke-eternal-manager \
  --review-zip-folder-exit-code \
  /data/karaoke-eternal/media/FolderName \
  51 \
  /data/karaoke-eternal/reports/zip-errors-YYYYMMDD-HHMMSS.tsv
```

This filter is exact on both conditions: the media path must be inside the selected folder, and the per-file `unzip` exit code must match the selected code.

For every selected file, the review screen displays:

- the full media path;
- failure classification;
- exact per-file `unzip` exit status; and
- captured `unzip` output.

It then offers:

```text
  1) Keep the file
  2) Move the file to quarantine
  3) Permanently delete the file
  4) Show unzip error details again
  0) Return to the filtered error list
```

A keep, quarantine, or delete decision removes that entry from the current in-memory review list. It does not rewrite the original report, which remains an immutable record of the test run.

## Keep

The ZIP remains in the media folder. The decision is recorded in the action log.

## Quarantine

The ZIP is moved outside the scanned media tree under:

```text
/data/karaoke-eternal-quarantine/YYYYMMDD-HHMMSS/
```

The original path relative to the scanned media root is preserved.

For example:

```text
Media file:
/data/karaoke-eternal/media/English/Artist/Bad Song.zip

Quarantined file:
/data/karaoke-eternal-quarantine/20260625-140000/English/Artist/Bad Song.zip
```

Quarantine is the recommended first action because it removes the archive from future Karaoke Eternal scans without destroying it.

## Restore quarantined ZIP media files

Starting with v5.10.1, quarantined ZIPs can be restored from inside the manager. The restore routine reads the existing action log:

```text
/data/karaoke-eternal/reports/zip-error-actions.log
```

That means it can restore files quarantined by previous v5.9.x builds, not only files quarantined after installing v5.10.1. A file can be restored if:

- the action log still contains the original `QUARANTINED` entry;
- the quarantined ZIP still exists under `/data/karaoke-eternal-quarantine`;
- the original restore path is still inside `/data/karaoke-eternal/media` or the configured media path;
- the original path does not already contain a file; and
- both the original path and quarantine path are `.zip` files.

The restore routine never overwrites an existing media file. If the original path already exists, the entry is shown as:

```text
CONFLICT_ORIGINAL_EXISTS
```

If the quarantined file is already gone, the entry is shown as:

```text
MISSING_QUARANTINE_FILE
```

Open from the main menu:

```text
17) Restore quarantined ZIP media files
```

Or from menu item 16:

```text
7) Restore quarantined media files
```

The restore submenu is:

```text
  1) List quarantined ZIP files recorded in the action log
  2) Restore one available logged quarantined ZIP
  3) Restore all available logged ZIPs from one quarantine batch
  4) Restore one available logged ZIP by original media folder
  5) List orphaned ZIPs physically found in the quarantine folder
  6) Recover all orphaned ZIPs into the restored media folder
  7) Recover orphaned ZIPs from one quarantine batch/folder into the restored media folder
  8) Show restore/action history
  0) Return
```

## Orphaned quarantine recovery and restored media folder

Some older or manually moved quarantined ZIP files may still exist in:

```text
/data/karaoke-eternal-quarantine
```

but may not have a usable `QUARANTINED` record in:

```text
/data/karaoke-eternal/reports/zip-error-actions.log
```

v5.10.1 adds an orphan recovery path for that situation. The manager scans the quarantine folder itself and finds `.zip` files that are not usable through the normal logged restore index.

Recovered orphan files are moved to:

```text
/data/karaoke-eternal/restored-media
```

The original quarantine tree is preserved under that folder when possible. Example:

```text
Quarantine file:
/data/karaoke-eternal-quarantine/oldbatch/Artist/Song.zip

Recovered file:
/data/karaoke-eternal/restored-media/oldbatch/Artist/Song.zip
```

This is intentionally outside the live Karaoke Eternal media folder. It gives you a safe holding area where you can inspect, retest, rename, or manually move files back later. The manager refuses to overwrite an existing file in the restored media folder.

For one orphaned ZIP, the manager asks for confirmation. For multiple orphaned ZIPs, it requires an exact typed confirmation:

```text
RECOVER N FILES
```

where `N` is the number of files being recovered.

Orphan recovery actions are logged to:

```text
/data/karaoke-eternal/reports/zip-restore-actions.log
/data/karaoke-eternal/reports/zip-error-actions.log
```

Direct commands:

```bash
sudo karaoke-eternal-manager --list-quarantine
```

```bash
sudo karaoke-eternal-manager --restore-quarantine
```

```bash
sudo karaoke-eternal-manager \
  --restore-quarantine-folder \
  /data/karaoke-eternal/media/FolderName
```

```bash
sudo karaoke-eternal-manager --list-orphan-quarantine
```

```bash
sudo karaoke-eternal-manager --recover-orphan-quarantine
```

```bash
sudo karaoke-eternal-manager --recover-orphan-quarantine-batch
```

Restore actions are recorded in two places:

```text
/data/karaoke-eternal/reports/zip-error-actions.log
/data/karaoke-eternal/reports/zip-restore-actions.log
```

The first file remains the combined ZIP action history. The second is a restore-focused history.

## Permanent deletion

The manager shows the exact path and requires the administrator to type:

```text
DELETE
```

No ZIP file is deleted automatically. Single-file deletion requires `DELETE`; multi-file deletion requires `DELETE N FILES`, where `N` is the selected count.

## Action history

Keep, quarantine, delete, and restore decisions are written to:

```text
/data/karaoke-eternal/reports/zip-error-actions.log
```

The manager verifies that a selected file:

- still exists;
- is not a directory;
- has a `.zip` extension; and
- remains within the media root recorded by the scan.

This prevents the error index from being used to modify arbitrary files outside the tested media directory.

# 5. Karaoke Eternal Docker layout

The default manager layout remains:

```text
Application directory:  /data/karaoke-eternal
Database/config:        /data/karaoke-eternal/config
Default media:          /data/karaoke-eternal/media
Backups:                /data/karaoke-eternal/backups
Reports:                /data/karaoke-eternal/reports
Compose file:           /data/karaoke-eternal/compose.yaml
Environment file:       /data/karaoke-eternal/.env
```

The container sees:

```text
/config
/mnt/karaoke
```

The media directory remains mounted read-only inside the Karaoke Eternal container.

The Compose service uses:

```yaml
restart: unless-stopped
```

Docker and containerd are enabled at startup by the Docker installation workflow.

# 6. Main Docker commands

```bash
sudo karaoke-eternal-manager --install-docker
sudo karaoke-eternal-manager --optimize-docker
sudo karaoke-eternal-manager --install
sudo karaoke-eternal-manager --start
sudo karaoke-eternal-manager --start-scan        # KES_SCAN=all
sudo karaoke-eternal-manager --start-scan all
sudo karaoke-eternal-manager --stop
sudo karaoke-eternal-manager --restart
sudo karaoke-eternal-manager --status
sudo karaoke-eternal-manager --logs
sudo karaoke-eternal-manager --update
```

The Restart action uses:

```bash
docker compose up -d --remove-orphans
```

This applies saved Compose and environment changes instead of merely restarting an existing container with stale settings.

# 7. Backups

Create a backup:

```bash
sudo karaoke-eternal-manager --backup
```

Restore a backup:

```bash
sudo karaoke-eternal-manager --restore
```

Backups include the Karaoke Eternal database and application configuration. The media library is intentionally excluded because it may be very large.

Backup retention and the backup destination are stored in the manager configuration.

# 8. Media, mount, network, and firewall checks

```bash
sudo karaoke-eternal-manager --check-paths
sudo karaoke-eternal-manager --check-network
sudo karaoke-eternal-manager --diagnostics
```

The manager checks:

- Ubuntu and CPU architecture compatibility;
- Docker Engine and Compose state;
- filesystem space and inodes;
- configured media and backup paths;
- expected external mounts;
- selected bind address;
- TCP port conflicts;
- Docker-published ports;
- UFW state; and
- Docker firewall chains.

# 9. Samba media-only share

Menu item 17 manages an authenticated Samba share for the configured Karaoke Eternal media folder only.

Direct commands:

```bash
sudo karaoke-eternal-manager --samba-setup
sudo karaoke-eternal-manager --samba-status
sudo karaoke-eternal-manager --samba-password
sudo karaoke-eternal-manager --samba-remove
```

The Samba workflow:

- shares only `KES_MEDIA_PATH`;
- never shares `/config`, the database, reports, or backups;
- disables guest access;
- requires an existing non-root Ubuntu account;
- supports read-only or read-write access;
- checks Linux permissions before enabling the share;
- validates changes with `testparm`;
- backs up `/etc/samba/smb.conf`;
- rolls back a failed configuration;
- preserves unrelated Samba shares; and
- can restrict UFW access to a selected LAN subnet.

Windows clients connect using:

```text
\\SERVER-IP\KaraokeMedia
```

# 10. Removal options

Remove only the container and keep persistent data:

```bash
sudo karaoke-eternal-manager --remove-container
```

Fully remove Karaoke Eternal application data:

```bash
sudo karaoke-eternal-manager --full-remove
```

Full removal asks for explicit confirmation. When a manager-owned Samba media share exists, the manager attempts to remove that share before deleting the application directory.

# 11. Complete command summary

```bash
sudo karaoke-eternal-manager --diagnostics
sudo karaoke-eternal-manager --apt-update
sudo karaoke-eternal-manager --system-update
sudo karaoke-eternal-manager --install-docker
sudo karaoke-eternal-manager --optimize-docker
sudo karaoke-eternal-manager --install
sudo karaoke-eternal-manager --start
sudo karaoke-eternal-manager --stop
sudo karaoke-eternal-manager --restart
sudo karaoke-eternal-manager --status
sudo karaoke-eternal-manager --logs
sudo karaoke-eternal-manager --update
sudo karaoke-eternal-manager --backup
sudo karaoke-eternal-manager --restore
sudo karaoke-eternal-manager --check-paths
sudo karaoke-eternal-manager --check-network
sudo karaoke-eternal-manager --verify-zips [DIR] [TIMEOUT]
sudo karaoke-eternal-manager --verify-zips-by-folder [ROOT] [TIMEOUT]
sudo karaoke-eternal-manager --zip-fast-scan [DIR] [TIMEOUT]
sudo karaoke-eternal-manager --zip-report
sudo karaoke-eternal-manager --zip-exit-summary [INDEX]
sudo karaoke-eternal-manager --zip-exit-summary-folder FOLDER [INDEX]
sudo karaoke-eternal-manager --review-zip-errors [INDEX]
sudo karaoke-eternal-manager --review-zip-exit-code CODE [INDEX]
sudo karaoke-eternal-manager --review-zip-folder-exit-code FOLDER CODE [INDEX]
sudo karaoke-eternal-manager --samba-setup
sudo karaoke-eternal-manager --samba-status
sudo karaoke-eternal-manager --samba-password
sudo karaoke-eternal-manager --samba-remove
sudo karaoke-eternal-manager --config
sudo karaoke-eternal-manager --remove-container
sudo karaoke-eternal-manager --full-remove
```

# 12. Validation performed

The v5.10.1 build was checked with:

- `bash -n` syntax validation;
- version and help-output tests;
- duplicate-function-name checks;
- confirmation that the previous deep and advanced preflight functions and command routes were removed;
- recursive discovery of ZIP filenames containing spaces;
- successful testing of a valid ZIP;
- detection of a truncated ZIP;
- detection of a non-ZIP file renamed with a `.zip` extension;
- readable and machine-readable report creation;
- Base64 path decoding;
- quarantine workflow testing;
- typed-confirmation permanent deletion testing;
- action-history logging;
- quarantine restore listing from existing action logs;
- single quarantined ZIP restore workflow;
- restore-by-original-folder workflow;
- batch restore workflow;
- conflict detection when the original media file already exists;
- missing-quarantine-file detection;
- restore history logging;
- orphaned quarantine ZIP listing from files physically present under `/data/karaoke-eternal-quarantine`;
- single-file orphan recovery into `/data/karaoke-eternal/restored-media`;
- bulk orphan recovery with exact `RECOVER N FILES` confirmation;
- orphan batch/folder recovery, including batch names containing spaces;
- verification that logged quarantines are excluded from the orphan list and stay in the normal restore list;
- folder-based subfolder picker testing;
- folder-filtered exit-code summary testing;
- folder + exact-exit-code review testing;
- Fast Scan direct-folder workflow testing;
- Fast Scan interactive folder-picker workflow testing;
- Fast Scan no-error workflow testing;
- Fast Scan filtered keep, quarantine, and typed-confirmation deletion workflow testing;
- EOF/no-extra-input review-loop testing to prevent repeated invalid-selection loops;
- exact exit-code count summaries;
- exact-code filtering with codes `3`, `51`, and a no-match code;
- rejection of invalid filter values outside `0` through `255`;
- filtered keep, quarantine, and typed-confirmation deletion workflows;
- Bash dynamic-scope regression testing so the summary loop cannot overwrite the selected code;
- menu and command-routing inspection; and
- Compose and Samba feature regression inspection.

The package-upgrade action was not executed in the build environment because it would modify the sandbox operating system. The action uses standard Ubuntu `apt-get update` and `apt-get upgrade -y` commands and is restricted by the script's supported-Ubuntu validation.

# Conclusion

Version 5.10.1 keeps the predictable archive-integrity workflow based on Ubuntu's `unzip -tqq`, plus folder-based scanning, Fast Scan, folder + exit-code review, guarded keep/quarantine/delete/restore actions, and orphaned-quarantine recovery into a separate restored media folder. It adds a tmux-safe launcher so interactive manager sessions can be reconnected after SSH disconnects, and it adds prerequisite checks/repair for tools such as `tmux`, `less`, and `unzip`. It also adds scroll-safe viewing so long selection lists and reports can be browsed from the top instead of scrolling off-screen. The Docker, backup, path, network, and media-only Samba features remain available.
