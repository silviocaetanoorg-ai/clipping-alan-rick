# Executa uma coleta e grava public/noticias.json (usado pelo GitHub Actions).
. (Join-Path $PSScriptRoot 'clipping.ps1')
CarregarArquivo
[void](Atualizar)
$falhas = @($Estado.fontes | Where-Object { -not $_.ok })
foreach ($f in $falhas) { Log "Falha em $($f.fonte): $($f.erro)" }
