# mdss_archive.sh

Interactive script for NCI Gadi that archives a folder, uploads it to massdata (`mdss`), checks the upload, and optionally cleans up the local files.

## What it does

1. Packs your folder into a single `.tar.gz` (or `.tar`) in a staging directory
2. Checks the archive is readable and holds the same number of files as the source
3. Creates the destination folders on massdata (if missing) and uploads the archive with `mdss put`
4. Verifies the upload (your choice of method, see below)
5. Deletes the local archive, and optionally the original folder

massdata works best with a few large files, which is why the folder is packed into one archive first.

## Requirements

- A Gadi account with a massdata allocation for the project you upload to
- Run it on a Gadi login node (`mdss` is only available there and in `copyq` jobs)
- `tar` and `sha256sum` (standard on Gadi). `pigz` is used automatically if available, for faster gzip

## Usage

```bash
bash mdss_archive.sh
```

You will be prompted for the following. Press Enter to accept the default shown in `[brackets]`.

| Prompt | Default | Notes |
|---|---|---|
| Folder to archive | current directory | Must exist |
| NCI project | `$PROJECT` | Used for `mdss -P <project>` |
| Destination on massdata | `$USER/<foldername>` | Relative to the project's massdata space. Missing folders are created |
| Compression | tar.gz | Choose tar only if the data is already compressed (e.g. deflated NetCDF) |
| Staging directory | `/scratch/<project>/$USER/mdss_staging` | Needs space for one copy of the archive (about twice that during full verification). Cannot be inside the source folder |
| Verification | quick | See below |
| Delete original folder? | no | Asks you to type the folder name to confirm |
| Where to run | copyq if the folder is over about 5 GB, otherwise login node | See below |

## Verification modes

| Mode | What it does | Download needed? | Can delete original? |
|---|---|---|---|
| **1. quick** (default) | Runs `mdss verify` on the uploaded file and compares its size with the local archive | No | Yes |
| **2. full** | Downloads the archive back and compares SHA-256 checksums with the original | Yes (time and staging space) | Yes |
| **3. none** | No check. The local archive is deleted once `mdss put` succeeds | No | **No**, the original is never deleted |

Notes on quick mode: `mdss verify` is documented only briefly (a 2012 NCI presentation shows it returning `OK`), so the exact comparison it makes is not confirmed. Before trusting it with data you cannot re-create, test it on a small folder and check `mdss --help verify`.

## Deletion safeguards

- The original folder is deleted only if you opted in **and** the verification passed (quick or full)
- You must type the folder name to confirm, at the start
- If the archive check, upload, verification, or size comparison fails, nothing is deleted and the local archive is kept
- The script refuses to delete top-level paths such as `$HOME`, `/scratch/<project>`, or `/scratch/<project>/$USER`
- Deletion is permanent (`rm -rf`)

## Running as a copyq job

`copyq` is Gadi's data-movement queue. Jobs there run in the background with a set walltime, so they suit large folders. The login node has CPU and memory limits and can kill long-running work.

If you choose the copyq option, the script asks for walltime (default 6:00:00), memory (default 8GB) and CPUs. It then writes a job script to `$TMPDIR` (or `/tmp`) and submits it with `qsub`.

- Check progress: `qstat -u $USER`
- Log file: `mdss_archive.o<jobid>`, in the directory you ran the script from
- If you chose to delete the original, the job deletes it only after verification passes. The confirmation happens when you answer the prompts, not inside the job

The job's `#PBS -l storage=` line is built from your source path, staging path, and `massdata/<project>`. If a job fails on storage access, edit that line in the generated job script and resubmit.

## Naming

The archive is named `<foldername>_YYYYMMDD_HHMMSS.tar.gz`, so re-running never overwrites an earlier upload.

## Getting your data back

```bash
mdss -P <project> get <destination>/<archive-name> /path/to/restore/
tar -xzf <archive-name>        # use -xf for plain .tar
```

To list what is on massdata: `mdss -P <project> ls -l <destination>/`

## Troubleshooting

| Problem | Likely cause / fix |
|---|---|
| `mdss: command not found` | Not on a Gadi login node or copyq job |
| `Could not create or access <project>:<dest> on massdata` | Wrong project code, no massdata allocation, or no write permission |
| `File count mismatch` | Files changed while archiving, or the folder contains special files (sockets, etc.). Nothing is deleted |
| `mdss verify did not report OK` | Re-run, or use full verification. Nothing is deleted |
| `Staging dir is inside the source folder` | Choose a staging directory outside the folder being archived |
| copyq job killed for time | Re-submit with a longer walltime. Large archives with full verification take longest |
| Out of space in staging | Use a different staging directory, or avoid full verification |

## Limitations

- Only archives a single folder per run
- Paths containing newlines are not supported
- Tested against a mock `mdss` only. Try it on a small folder first
