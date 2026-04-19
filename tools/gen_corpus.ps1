$line = "Ghost Engine Sovereign Resilience Test. "
$bytes = [System.Text.Encoding]::ASCII.GetBytes($line)
$f = [System.IO.File]::Create("mixed_sovereign.txt")
for ($i=0; $i -lt 250000; $i++) { $f.Write($bytes, 0, $bytes.Length) }
$f.Close()
