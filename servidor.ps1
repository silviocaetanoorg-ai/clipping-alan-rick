# Clipping de notícias: servidor local (PowerShell 5.1, sem dependências)
# Uso: powershell -ExecutionPolicy Bypass -File servidor.ps1

. (Join-Path $PSScriptRoot 'clipping.ps1')

$Mimes = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'application/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.ico' = 'image/x-icon'; '.json' = 'application/json; charset=utf-8' }

function Responder($ctx, [int]$codigo, [string]$tipo, $corpo) {
    $resp = $ctx.Response
    $resp.StatusCode = $codigo
    $resp.ContentType = $tipo
    $resp.Headers['Cache-Control'] = 'no-store'
    $bytes = if ($corpo -is [byte[]]) { $corpo } else { $Utf8.GetBytes([string]$corpo) }
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $resp.OutputStream.Close()
}

function Tratar($ctx) {
    $req = $ctx.Request
    $caminho = $req.Url.AbsolutePath

    if ($caminho -eq '/api/atualizar' -and $req.HttpMethod -eq 'POST') {
        $novas = Atualizar
        return Responder $ctx 200 'application/json; charset=utf-8' "{`"novas`":$novas}"
    }

    if ($caminho -eq '/') { $caminho = '/index.html' }
    $rel = [Uri]::UnescapeDataString($caminho.TrimStart('/')) -replace '/', '\'
    $arq = [IO.Path]::GetFullPath((Join-Path $PastaWeb $rel))
    if ($arq.StartsWith($PastaWeb, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path $arq -PathType Leaf)) {
        $ext = [IO.Path]::GetExtension($arq).ToLowerInvariant()
        $mime = if ($Mimes.ContainsKey($ext)) { $Mimes[$ext] } else { 'application/octet-stream' }
        return Responder $ctx 200 $mime ([IO.File]::ReadAllBytes($arq))
    }
    Responder $ctx 404 'text/plain; charset=utf-8' 'Não encontrado'
}

CarregarArquivo

$porta = if ($env:CLIPPING_PORTA) { [int]$env:CLIPPING_PORTA } else { [int]$Config.porta }
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$porta/")
$listener.Start()
Log "Clipping no ar: http://localhost:$porta/  (Ctrl+C para encerrar)"

try {
    if (Desatualizado) { [void](Atualizar) }
    while ($listener.IsListening) {
        $tarefa = $listener.GetContextAsync()
        while (-not $tarefa.Wait(500)) {
            if (Desatualizado) { try { [void](Atualizar) } catch { Log "Erro na atualização: $_" } }
        }
        $ctx = $tarefa.Result
        try { Tratar $ctx }
        catch {
            Log "Erro em $($ctx.Request.Url.AbsolutePath): $_"
            try { Responder $ctx 500 'application/json; charset=utf-8' (ConvertTo-Json @{ erro = "$_" } -Compress) } catch {}
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
