# Factoring File Movement — `Factoring_File_Movement.ps1`

## Overview

This PowerShell script extracts accounts-receivable data from the SAP Business One
production database and delivers it to **FIS** (the factoring platform) in the
required file format. On each run it produces three data files, archives them, writes
the FIS "ready to process" signal files, and uploads copies to Azure Blob Storage.

It is designed to run **unattended on a schedule** (e.g. Windows Task Scheduler) once
per day.

---

## What it produces

For each run, three datasets are generated. File names are stamped with the run date
in `yyyyMMdd` format (e.g. `20250630`).

| Dataset | File name pattern | Contents |
|---|---|---|
| **CL** – Client / debtor master | `HEXARMOR_CL_<yyyyMMdd>.csv` | All active customers (debtors) and their details |
| **OI** – Open items | `HEXARMOR_OI_<yyyyMMdd>.csv` | All open AR items: invoices, credit memos, unapplied payments |
| **MOV** – Movements | `HEXARMOR_MOV_<yyyyMMdd>.csv` | The same open items, but only documents dated since yesterday |

For **each** dataset the script creates:

1. A **`.csv`** data file on the FTP share.
2. A copy of that CSV uploaded to **Azure Blob Storage**.
3. A **`.zip`** archive of the CSV in the local archive folder.
4. A zero-byte **`.sig`** signal file (tells FIS the data file upload is complete and
   ready to process).

---

## Data flow

```
SAP B1 (HEXAR-SQL04 / Hex_Armor_ProductionDB)
        │  3 read-only SELECT queries
        ▼
PowerShell result sets  (CL / OI / MOV)
        │
        ├─► CSV written to FTP share  ── \\Hexar-file03\...\FTP_Test\
        ├─► CSV uploaded to Azure Blob ── devetleastus / container "factoring"
        ├─► ZIP written to archive folder
        └─► .SIG signal file written
```

The script connects to Azure **first**, then runs the queries, then processes each
dataset in turn.

---

## Prerequisites

The host running the script needs:

| Requirement | Notes |
|---|---|
| **Windows PowerShell 5.1** (or later) | Standard on Windows Server |
| **`SqlServer` module** | Provides `Invoke-Sqlcmd`. Install: `Install-Module SqlServer -Scope CurrentUser` |
| **`Az.Accounts` + `Az.Storage` modules** | For the Azure Blob upload. Install: `Install-Module Az.Accounts, Az.Storage -Scope CurrentUser` |
| **Network access** to `HEXAR-SQL04` | And read permission on `Hex_Armor_ProductionDB` |
| **Write access** to the FTP share and the local archive folder | |
| **Outbound HTTPS** to Azure Storage | |
| **The authentication certificate** | Installed in the cert store of the account that runs the script (see Authentication) |

---

## Configuration

All settings live in clearly labelled variables at the top of the script. Review these
when deploying to a new environment.

| Variable | Purpose | Current value |
|---|---|---|
| `$dateStamp` | Date suffix for all file names | `Get-Date -Format "yyyyMMdd"` (auto) |
| `$zipFolder` | Local folder for `.zip` and `.sig` files (created if missing) | `...\Factoring\zipped_files` |
| `$storageAccountName` | Azure Storage account | `devetleastus` |
| `$blobContainer` | Target blob container | `factoring` |
| `$blobPrefix` | Optional virtual folder inside the container | *(empty = container root)* |
| `$tenantId` | Entra (Azure AD) tenant ID | `deced3bd-…-d6f3935a878a` |
| `$appId` | Service principal (app registration) client ID | `55c15124-…-7fcf96d28c69` |
| `$certThumbprint` | Thumbprint of the auth certificate | `2EC1B7255DD9471A77569A90915051513D3E5262` |

The destination FTP share path (`\\Hexar-file03\hexardfs\Hexarmor Shared\IT\FTP_Test\`)
is set on each `Export-Csv` line.

> **Note:** `$zipFolder` is an absolute path. Confirm it is valid on the host where the
> script actually runs; the script will create the folder if it does not exist.

---

## Authentication (Azure Blob Storage)

The script authenticates to Azure as a **service principal using a certificate** — no
passwords or secrets are stored in the file.

- **App registration:** `factoring-blob-upload` (in Entra ID → App registrations)
- **Credential:** an X.509 certificate. The **public key** is uploaded to the app
  registration; the **private key** lives in the cert store of the account that runs
  the script (`Cert:\CurrentUser\My` for a user account, or `Cert:\LocalMachine\My`
  for a service account).
- **Authorization:** the service principal is granted the **Storage Blob Data
  Contributor** role on the `devetleastus` storage account (or the `factoring`
  container).

At runtime:

```powershell
Connect-AzAccount -ServicePrincipal -Tenant $tenantId `
    -ApplicationId $appId -CertificateThumbprint $certThumbprint
$blobContext = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
```

`-UseConnectedAccount` makes the blob upload use the signed-in service principal's
Entra identity (RBAC), rather than an account key or SAS token.

---

## CSV format notes

- Column values are returned **raw** from SQL. `Export-Csv` applies the CSV quoting.
  The SQL deliberately does **not** wrap values in quotes — doing so would cause
  double/triple-quoted fields (e.g. `"""5290"""`).
- `Export-Csv -NoTypeInformation` is used so the file contains only the header row and
  data (no `#TYPE` line).
- Windows PowerShell 5.1's `Export-Csv` quotes every field. If FIS requires only some
  columns quoted, the export method would need to change (PowerShell 7
  `-UseQuotes AsNeeded`, or a custom writer).

---

## Running the script

### Manually (for testing)

From a PowerShell prompt **on the host**, logged in as the account that owns the
certificate:

```powershell
& "D:\PowerShell_Scripts_For_SSMS\Factoring_File_Movement.ps1"
```

To capture all output and errors to a log file for review:

```powershell
Start-Transcript -Path "D:\PowerShell_Scripts_For_SSMS\factoring_test.log"
& "D:\PowerShell_Scripts_For_SSMS\Factoring_File_Movement.ps1"
Stop-Transcript
```

If blocked by execution policy:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\PowerShell_Scripts_For_SSMS\Factoring_File_Movement.ps1"
```

### Scheduled (production)

Configure Windows Task Scheduler to run:

```
Program/script:  powershell.exe
Arguments:       -NoProfile -ExecutionPolicy Bypass -File "D:\PowerShell_Scripts_For_SSMS\Factoring_File_Movement.ps1"
```

Run the task as the account whose cert store holds the certificate (or use
`LocalMachine\My` and a service account). Set the schedule to run once per day.

---

## Verifying a run

```powershell
$d = Get-Date -Format yyyyMMdd

# CSVs on the share
Get-Content "\\Hexar-file03\hexardfs\Hexarmor Shared\IT\FTP_Test\HEXARMOR_OI_$d.csv" -TotalCount 3

# Local zip + sig files
Get-ChildItem "<zipFolder>" | Where-Object Name -like "*$d*"

# Blobs uploaded
$ctx = New-AzStorageContext -StorageAccountName "devetleastus" -UseConnectedAccount
Get-AzStorageBlob -Container "factoring" -Context $ctx | Where-Object Name -like "*$d*"
```

Expected console output per dataset:

```
CSV file created successfully.
Uploaded to blob: HEXARMOR_OI_<date>.csv
Zip file created: HEXARMOR_OI_<date>.zip
Signal file created: HEXARMOR_OI_<date>.sig
```

If a dataset returns no rows, that dataset is skipped with:
`No data to export. CSV file was not created.`

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `Connect-AzAccount` fails at startup | Cert not uploaded to the app registration, wrong run-as account, or expired cert. Verify the cert exists: `Get-ChildItem Cert:\CurrentUser\My\<thumbprint>` |
| Blob upload returns **403 / AuthorizationFailure** | The service principal is missing the **Storage Blob Data Contributor** role on `devetleastus`, or the role assignment hasn't propagated yet (wait a few minutes) |
| `Invoke-Sqlcmd` not recognized | `SqlServer` module not installed |
| `Set-AzStorageBlobContent` not recognized | `Az.Storage` / `Az.Accounts` modules not installed |
| CSV values show tripled quotes (`"""..."""`) | SQL is re-introducing manual quoting — values must be returned raw; `Export-Csv` adds the quotes |
| Script "won't run" / red parser error | Confirm the three SQL blocks use literal here-strings (`@'` … `'@`) with the closing `'@` at column 0 |
| No files produced, no error | The queries returned zero rows (check the "No data to export" messages) |

---

## Maintenance

- **Certificate renewal:** the auth certificate has an expiry date. Before it expires,
  generate a new certificate, upload its public key to the `factoring-blob-upload` app
  registration, install the private key in the run-as account's cert store, and update
  `$certThumbprint` in the script. Check the expiry with:
  `Get-ChildItem Cert:\CurrentUser\My\<thumbprint> | Select-Object NotAfter`
- **Secrets:** none are stored in the script. Authentication is certificate-based.
- **Queries:** the three SQL statements are embedded in the script as here-strings and
  can be edited in place. Keep values **unquoted** so the CSV formatting stays correct.

---

## Related resources

- **SAP source tables:** `OCRD` (business partners), `CRD1` (BP addresses),
  `OINV` (AR invoices), `ORIN` (AR credit memos), `ORCT` (incoming payments)
- **Azure resources:** storage account `devetleastus`, container `factoring`,
  app registration `factoring-blob-upload`
- **Script location:** `D:\PowerShell_Scripts_For_SSMS\Factoring_File_Movement.ps1`
