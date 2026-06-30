# Define the file path
$filePath = "\\Hexar-file03\hexardfs\Hexarmor Shared\IT\FTP_Test\"

# Today's date stamp for file names (e.g. 20250630)
$dateStamp = Get-Date -Format "yyyyMMdd"

# Folder where zipped copies of each CSV are placed
$zipFolder = "\\Hexar-file03\hexardfs\Hexarmor Shared\IT\FTP_Test\zipped_files"
if (-not (Test-Path $zipFolder)) {
    New-Item -ItemType Directory -Path $zipFolder -Force | Out-Null
}

# --- Azure Blob Storage (CSV upload) configuration ---
# Requires the Az modules: Install-Module Az.Accounts, Az.Storage -Scope CurrentUser
$storageAccountName = "devetleastus"
$blobContainer      = "factoring"                  # target blob container
$blobPrefix         = ""                           # optional virtual folder, e.g. "factoring/" (leave "" for root)
$tenantId           = "deced3bd-a4d3-43c1-96fe-d6f3935a878a"   # Entra (Azure AD) tenant ID
$appId              = "55c15124-aec0-49f4-902b-7fcf96d28c69"   # factoring-blob-upload app (client) ID
$certThumbprint     = "2EC1B7255DD9471A77569A90915051513D3E5262"   # cert in CurrentUser\My (factoring-blob-upload)

# Authenticate as the service principal using a certificate (nothing secret stored in this script).
# The cert's public key must be uploaded to the app registration, and the private key must be
# installed in the cert store the scheduled-task account can read (CurrentUser\My or LocalMachine\My).
# The SP must have the "Storage Blob Data Contributor" role on the container/account.
Connect-AzAccount -ServicePrincipal -Tenant $tenantId -ApplicationId $appId -CertificateThumbprint $certThumbprint | Out-Null
$blobContext  = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount

# Run the SQL command and store the results in a variable.
# NOTE: column values are returned raw (unquoted). Export-Csv adds the CSV quoting,
# so do NOT wrap values in quotes here or fields end up double/triple-quoted.
$CL_results = Invoke-Sqlcmd -ServerInstance HEXAR-SQL04 -Database Hex_Armor_ProductionDB  -Query @'
SELECT
    -- Debtor Information
    ISNULL(T0.Cardcode,'')                                                       AS "Debtor ID",
    ISNULL(T0.Cardname,'')                                                       AS "Debtor Name",
    -- Debtor Country is Type Jdx. (ISO-3166, 2 alpha)
    ISNULL(T0.Country,'')                                                        AS "Debtor Country",
    -- NULLIF: empty FatherCard -> NULL so fallback to CardCode fires (fixed ~135 blank Trust IDs)
    ISNULL(NULLIF(T0.FatherCard,''), T0.CardCode)                               AS "Trust ID",
    ISNULL((SELECT CardName FROM OCRD WHERE CardCode = NULLIF(T0.FatherCard,'')), T0.CardName) AS "Trust Name",
    -- Debtor Address
    ISNULL(T1.StreetNo,'')                                                       AS "Debtor Address 1",
    ISNULL(T1.Street,'')                                                         AS "Debtor Address 2",
    ISNULL(T1.Block,'')                                                          AS "Debtor Address 3",
    ISNULL(T1.Address2,'')                                                       AS "Debtor Address 4",
    ISNULL(T1.City,'')                                                           AS "Debtor City",
    ISNULL(T1.ZipCode,'')                                                        AS "Debtor Postal Code",
    -- Flags: DTD order, defaulted to 'N'
    'N'                                                                          AS "Intercompany Flag",
    'N'                                                                          AS "Soletrader Flag",
    'N'                                                                          AS "Ineligible Debtor Flag",
    'N'                                                                          AS "Government Debtor Flag",
    ISNULL(T0.LicTradNum,'')                                                     AS "DUNS-VAT Code",
    ''                                                                           AS "Supplier ID",
    CAST(ISNULL(T0.CreditLine, 0) AS VARCHAR(30))                                AS "Debtor Limit Amount",
    (CASE WHEN ISNULL(T0.Currency,'') = '$' THEN 'USD' ELSE '' END)              AS "Debtor Limit Currency"
FROM OCRD T0
LEFT JOIN CRD1 T1
       ON T0.CardCode = T1.CardCode
      AND T1.AdresType = 'B'
      AND T1.Address   = T0.BillToDef
WHERE
      T0.validFor = 'Y'
  AND T0.CardType = 'C'
'@

$OI_results = Invoke-Sqlcmd -ServerInstance HEXAR-SQL04 -Database Hex_Armor_ProductionDB  -Query @'
-- INVOICES (INV)
SELECT
    CAST(T0.DocNum AS VARCHAR(20))                               AS "Item ID",
    '5290'                                                       AS "Seller Code",
    ISNULL(T0.CardCode,'')                                       AS "Debtor ID",
    CONVERT(CHAR(8), T0.DocDate,    112)                         AS "Issue Date",
    CONVERT(CHAR(8), T0.DocDueDate, 112)                         AS "Due Date",
    'INV'                                                        AS "Item Type",
    'USD'                                                        AS "Item Currency",
    CAST((T0.DocTotal - T0.PaidToDate) AS DECIMAL(19,6))         AS "Amount Outstanding",
    ''                                                           AS "VAT Amount",
    'O'                                                          AS "Item Status",
    'N'                                                          AS "Dispute Code",
    (CASE WHEN ISNULL(T0.Indicator,'') = '' THEN 'N' ELSE 'Y' END) AS "Ineligible Invoice Flag",
    CAST((T0.DocTotal - T0.PaidToDate) AS DECIMAL(19,6))         AS "Amount In Base Currency"
FROM OINV T0
INNER JOIN OCRD T2 ON T0.CardCode = T2.CardCode
WHERE T0.DocStatus = 'O' AND T0.CANCELED = 'N' AND (T0.DocTotal - T0.PaidToDate) <> 0

UNION ALL
-- AR CREDIT MEMOS (NCD / negative)
SELECT
    CAST(T0.DocNum AS VARCHAR(20)),
    '5290',
    ISNULL(T0.CardCode,''),
    CONVERT(CHAR(8), T0.DocDate,    112),
    CONVERT(CHAR(8), T0.DocDueDate, 112),
    'NCD',
    'USD',
    CAST((T0.DocTotal - T0.PaidToDate) * -1 AS DECIMAL(19,6)),
    '',
    'O',
    'N',
    (CASE WHEN ISNULL(T0.Indicator,'') = '' THEN 'N' ELSE 'Y' END),
    CAST((T0.DocTotal - T0.PaidToDate) * -1 AS DECIMAL(19,6))
FROM ORIN T0
INNER JOIN OCRD T2 ON T0.CardCode = T2.CardCode
WHERE T0.DocStatus = 'O' AND T0.CANCELED = 'N' AND (T0.DocTotal - T0.PaidToDate) <> 0

UNION ALL
-- UNAPPLIED INCOMING PAYMENTS (UNC / negative)
SELECT
    CAST(T0.DocNum AS VARCHAR(20)),
    '5290',
    ISNULL(T0.CardCode,''),
    CONVERT(CHAR(8), T0.DocDate, 112),
    CONVERT(CHAR(8), T0.DocDate, 112),
    'UNC',
    'USD',
    CAST(T0.OpenBal * -1 AS DECIMAL(19,6)),
    '',
    'O',
    'N',
    'N',
    CAST(T0.OpenBal * -1 AS DECIMAL(19,6))
FROM ORCT T0
INNER JOIN OCRD T2 ON T0.CardCode = T2.CardCode
WHERE T0.CANCELED = 'N' AND T0.OpenBal <> 0;
'@

$MOV_results = Invoke-Sqlcmd -ServerInstance HEXAR-SQL04 -Database Hex_Armor_ProductionDB  -Query @'
-- INVOICES (INV) -- new docs since yesterday
SELECT
    CAST(T0.DocNum AS VARCHAR(20))                               AS "Item ID",
    '5290'                                                       AS "Seller Code",
    ISNULL(T0.CardCode,'')                                       AS "Debtor ID",
    CONVERT(CHAR(8), T0.DocDate,    112)                         AS "Issue Date",
    CONVERT(CHAR(8), T0.DocDueDate, 112)                         AS "Due Date",
    'INV'                                                        AS "Item Type",
    'USD'                                                        AS "Item Currency",
    CAST((T0.DocTotal - T0.PaidToDate) AS DECIMAL(19,6))         AS "Amount Outstanding",
    ''                                                           AS "VAT Amount",
    'O'                                                          AS "Item Status",
    'N'                                                          AS "Dispute Code",
    (CASE WHEN ISNULL(T0.Indicator,'') = '' THEN 'N' ELSE 'Y' END) AS "Ineligible Invoice Flag",
    CAST((T0.DocTotal - T0.PaidToDate) AS DECIMAL(19,6))         AS "Amount In Base Currency"
FROM OINV T0
INNER JOIN OCRD T2 ON T0.CardCode = T2.CardCode
WHERE T0.DocStatus = 'O' AND T0.CANCELED = 'N' AND (T0.DocTotal - T0.PaidToDate) <> 0
  AND T0.DocDate >= CAST(GETDATE()-1 AS DATE)

UNION ALL
-- AR CREDIT MEMOS (NCD / negative)
SELECT
    CAST(T0.DocNum AS VARCHAR(20)),
    '5290',
    ISNULL(T0.CardCode,''),
    CONVERT(CHAR(8), T0.DocDate,    112),
    CONVERT(CHAR(8), T0.DocDueDate, 112),
    'NCD',
    'USD',
    CAST((T0.DocTotal - T0.PaidToDate) * -1 AS DECIMAL(19,6)),
    '',
    'O',
    'N',
    (CASE WHEN ISNULL(T0.Indicator,'') = '' THEN 'N' ELSE 'Y' END),
    CAST((T0.DocTotal - T0.PaidToDate) * -1 AS DECIMAL(19,6))
FROM ORIN T0
INNER JOIN OCRD T2 ON T0.CardCode = T2.CardCode
WHERE T0.DocStatus = 'O' AND T0.CANCELED = 'N' AND (T0.DocTotal - T0.PaidToDate) <> 0
  AND T0.DocDate >= CAST(GETDATE()-1 AS DATE)

UNION ALL
-- UNAPPLIED INCOMING PAYMENTS (UNC / negative)
SELECT
    CAST(T0.DocNum AS VARCHAR(20)),
    '5290',
    ISNULL(T0.CardCode,''),
    CONVERT(CHAR(8), T0.DocDate, 112),
    CONVERT(CHAR(8), T0.DocDate, 112),
    'UNC',
    'USD',
    CAST(T0.OpenBal * -1 AS DECIMAL(19,6)),
    '',
    'O',
    'N',
    'N',
    CAST(T0.OpenBal * -1 AS DECIMAL(19,6))
FROM ORCT T0
INNER JOIN OCRD T2 ON T0.CardCode = T2.CardCode
WHERE T0.CANCELED = 'N' AND T0.OpenBal <> 0
  AND T0.DocDate >= CAST(GETDATE()-1 AS DATE);
'@

# Check if there are rows in the OI_results
if ($OI_results.Count -gt 0) {
    # Export the OI_results to a CSV file
    $OI_csv = "\\Hexar-file03\hexardfs\Hexarmor Shared\IT\FTP_Test\HEXARMOR_OI_$dateStamp.csv"
    $OI_results | Export-Csv $OI_csv -NoTypeInformation
    Write-Output "OI CSV file created successfully."
    # Upload the CSV to Azure Blob Storage
    Set-AzStorageBlobContent -File $OI_csv -Container $blobContainer -Blob "$blobPrefix`HEXARMOR_OI_$dateStamp.csv" -Context $blobContext -Force | Out-Null
    Write-Output "Uploaded to blob: $blobPrefix`HEXARMOR_OI_$dateStamp.csv"
    # Zip the CSV into the zipped_files subfolder
    Compress-Archive -Path $OI_csv -DestinationPath "$zipFolder\HEXARMOR_OI_$dateStamp.zip" -Force
    Write-Output "OI Zip file created: HEXARMOR_OI_$dateStamp.zip"
    # Create zero-byte signal (.sig) file to indicate the data file is ready for FIS
    New-Item -ItemType File -Path "$zipFolder\HEXARMOR_OI_$dateStamp.sig" -Force | Out-Null
    Write-Output "Signal file created: HEXARMOR_OI_$dateStamp.sig"
} else {
    Write-Output "No data to export. CSV file was not created."
}

# Check if there are rows in the CL_results
if ($CL_results.Count -gt 0) {
    # Export the CL_results to a CSV file
    $CL_csv = "\\Hexar-file03\hexardfs\Hexarmor Shared\IT\FTP_Test\HEXARMOR_CL_$dateStamp.csv"
    $CL_results | Export-Csv $CL_csv -NoTypeInformation
    Write-Output "CL CSV file created successfully."
    # Upload the CSV to Azure Blob Storage
    Set-AzStorageBlobContent -File $CL_csv -Container $blobContainer -Blob "$blobPrefix`HEXARMOR_CL_$dateStamp.csv" -Context $blobContext -Force | Out-Null
    Write-Output "Uploaded to blob: $blobPrefix`HEXARMOR_CL_$dateStamp.csv"
    # Zip the CSV into the zipped_files subfolder
    Compress-Archive -Path $CL_csv -DestinationPath "$zipFolder\HEXARMOR_CL_$dateStamp.zip" -Force
    Write-Output "CL Zip file created: HEXARMOR_CL_$dateStamp.zip"
    # Create zero-byte signal (.sig) file to indicate the data file is ready for FIS
    New-Item -ItemType File -Path "$zipFolder\HEXARMOR_CL_$dateStamp.sig" -Force | Out-Null
    Write-Output "Signal file created: HEXARMOR_CL_$dateStamp.sig"
} else {
    Write-Output "No data to export. CSV file was not created."
}

# Check if there are rows in the MOV_results
if ($MOV_results.Count -gt 0) {
    # Export the MOV_results to a CSV file
    $MOV_csv = "\\Hexar-file03\hexardfs\Hexarmor Shared\IT\FTP_Test\HEXARMOR_MOV_$dateStamp.csv"
    $MOV_results | Export-Csv $MOV_csv -NoTypeInformation
    Write-Output "MOV CSV file created successfully."
    # Upload the CSV to Azure Blob Storage
    Set-AzStorageBlobContent -File $MOV_csv -Container $blobContainer -Blob "$blobPrefix`HEXARMOR_MOV_$dateStamp.csv" -Context $blobContext -Force | Out-Null
    Write-Output "Uploaded to blob: $blobPrefix`HEXARMOR_MOV_$dateStamp.csv"
    # Zip the CSV into the zipped_files subfolder
    Compress-Archive -Path $MOV_csv -DestinationPath "$zipFolder\HEXARMOR_MOV_$dateStamp.zip" -Force
    Write-Output "MOV Zip file created: HEXARMOR_MOV_$dateStamp.zip"
    # Create zero-byte signal (.sig) file to indicate the data file is ready for FIS
    New-Item -ItemType File -Path "$zipFolder\HEXARMOR_MOV_$dateStamp.sig" -Force | Out-Null
    Write-Output "Signal file created: HEXARMOR_MOV_$dateStamp.sig"
} else {
    Write-Output "No data to export. CSV file was not created."
}
