# zfs_disk_map

A bash utility for TrueNAS/Linux systems that maps all active ZFS pool member disks to their physical serial numbers, partition UUIDs, vdev GUIDs, pool topology, and drive state. Optionally generates Brother P-Touch Editor `.lbx` label files for physical drive tray labeling.

## Features

- **Resilver-safe** — captures `zpool status` output to memory before parsing; no hanging on degraded pools
- **Drive state** — pulls ONLINE/DEGRADED/FAULTED/etc. per vdev directly from `zpool status`, color-coded in terminal output
- **4-method serial detection** — lsblk, smartctl, hdparm, sysfs fallback
- **Handles complex topologies** — raidz, mirror, `replacing-N` vdevs, spares, cache devices
- **Multiple output modes** — terminal table, brief status view, plain text labels, and three P-Touch tape formats
- **Clean default behavior** — no files written unless a flag is passed

## Requirements

| Tool | Required | Notes |
|---|---|---|
| bash 4+ | Yes | |
| lsblk, blkid, zpool, zdb | Yes | Standard on TrueNAS |
| smartctl | No | Improves serial detection |
| hdparm | No | Improves serial detection |
| 7z (p7zip) | For LBX output | `/usr/bin/7z` on TrueNAS |

## Installation

```bash
curl -o zfs_disk_map.sh https://raw.githubusercontent.com/nnhck/zfs_disk_map/main/zfs_disk_map.sh
chmod +x zfs_disk_map.sh
```

## Usage

```bash
sudo ./zfs_disk_map.sh                  # Reference table only (default)
sudo ./zfs_disk_map.sh --brief          # Brief 4-column status view (DISK, STATE, SERIAL, POOL)
sudo ./zfs_disk_map.sh --labels         # Table + .txt tray label files
sudo ./zfs_disk_map.sh --lbx-12         # Table + 12mm TZe tape .lbx files
sudo ./zfs_disk_map.sh --lbx-18         # Table + 18mm TZe tape .lbx files (2.5" max width)
sudo ./zfs_disk_map.sh --lbx-24         # Table + 24mm / 1" TZe tape .lbx files
sudo ./zfs_disk_map.sh --lbx-all        # Table + all three LBX formats
sudo ./zfs_disk_map.sh --all            # Table + .txt + all three LBX formats
sudo ./zfs_disk_map.sh --help           # Show usage
```

## Output

All label files are written under `./zfs_labels/`:

| Directory | Tape | Layout |
|---|---|---|
| `txt/` | — | Full field dump, one file per drive |
| `lbx-12/` | 12mm TZe | Serial (large bold, left) \| divider \| part / role / model (right, all-caps) |
| `lbx-18/` | 18mm TZe | Serial (left) \| divider \| part / role / mfr / model (right-justified, 2.5" fixed width) |
| `lbx-24/` | 24mm TZe | 5-line full-detail label with border frame |

One `.lbx` file per physical drive, named by serial number. Files overwrite on re-run.

## Label Compatibility

- Brother P-Touch Editor 5.4+ (Windows/macOS)
- Tested on Brother PT-2430PC
- 12mm: TZe tape, auto-length
- 18mm: TZe tape, fixed 2.5" width
- 24mm: TZe tape, auto-length, framed

## Fields Collected

| Field | Description |
|---|---|
| DISK | Block device (sda, sdb, etc.) — kernel enumeration order, may change with re-cabling |
| PART | Partition device (sda2, etc.) |
| STATE | vdev state from `zpool status` (ONLINE, DEGRADED, FAULTED, REMOVED, UNAVAIL, OFFLINE) |
| SERIAL | Physical serial number |
| MODEL | Drive model string |
| SIZE | Drive capacity |
| POOL | ZFS pool name |
| VDEV ROLE | Topology role (raidz1-0:pos-2, mirror-0:pos-1, spare, cache, etc.) |
| PART UUID | Partition UUID (PARTUUID or filesystem UUID fallback) |
| ZFS GUID | vdev GUID from zdb |
| ZPOOL STATUS PATH | Exact device path shown in `zpool status` output |

## Notes

- Run as root for full output (zdb GUIDs, blkid PARTUUIDs)
- Safe to run during resilver
- If the script exits silently on first run, retry — `zpool status` can return incomplete data mid-resilver
- `sda`/`sdb` device names reflect kernel enumeration order (controller port), not physical slot — they may change if drives are re-cabled
- Terminal STATE column is color-coded: green = ONLINE, yellow = DEGRADED, red = FAULTED/UNAVAIL/OFFLINE/REMOVED
