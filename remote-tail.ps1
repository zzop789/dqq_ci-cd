param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$Tail = 30,
    [string]$Filter = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Streams the file and keeps only the tail so a large log never has to be
# transferred. Read only: nothing is created, moved or deleted.
$queue = New-Object 'Collections.Generic.Queue[string]'
$reader = [IO.File]::OpenText($Path)
try {
    while ($null -ne ($line = $reader.ReadLine())) {
        if ($Filter -and $line -notmatch $Filter) { continue }
        $queue.Enqueue($line)
        if ($queue.Count -gt $Tail) { [void]$queue.Dequeue() }
    }
} finally {
    $reader.Dispose()
}
foreach ($line in $queue) { Write-Output $line }
Write-Output ('--- lines returned: ' + $queue.Count + ' ---')
