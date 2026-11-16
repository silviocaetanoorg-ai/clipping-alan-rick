# Núcleo do clipping: coleta, deduplicação e classificação.
# Usado por servidor.ps1 (local) e coletar.ps1 (GitHub Actions). Compatível com PowerShell 5.1 e 7.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

$Raiz       = $PSScriptRoot
$PastaWeb   = Join-Path $Raiz 'public'
$ArqArquivo = Join-Path $PastaWeb 'noticias.json'

$Config = Get-Content (Join-Path $Raiz 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Utf8   = New-Object System.Text.UTF8Encoding($false)

function Log($msg) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $msg) }

# ---------- utilidades de texto ----------
function Normalizar([string]$s) {
    if (-not $s) { return '' }
    $d = $s.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $d.ToCharArray()) {
        $cat = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($c)
        if ($cat -eq 'NonSpacingMark') { continue }
        if ([char]::IsLetterOrDigit($c)) { [void]$sb.Append($c) } else { [void]$sb.Append(' ') }
    }
    return (($sb.ToString() -replace '\s+', ' ').Trim())
}

function LimparHtml([string]$s) {
    if (-not $s) { return '' }
    $t = $s -replace '(?s)<script.*?</script>', ' ' -replace '(?s)<style.*?</style>', ' ' -replace '<[^>]+>', ' '
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = ($t -replace '\s+', ' ').Trim()
    $t = $t -replace '\s*The post .*? appeared first on .*$', ''
    $t = $t -replace '\s*\[(…|\.\.\.)\]\s*$', '…'
    return $t
}

function Cortar([string]$s, [int]$n) { if ($s.Length -le $n) { $s } else { $s.Substring(0, $n).TrimEnd() + '…' } }

function Hash([string]$s) {
    $md5 = [Security.Cryptography.MD5]::Create()
    $b = $md5.ComputeHash($Utf8.GetBytes($s))
    return (-join ($b[0..7] | ForEach-Object { $_.ToString('x2') }))
}

function LerData([string]$s) {
    if (-not $s) { return $null }
    try { return [DateTimeOffset]::Parse($s.Trim(), [Globalization.CultureInfo]::InvariantCulture).UtcDateTime } catch {}
    try { return [DateTimeOffset]::Parse(($s.Trim() -replace ' [A-Z]{3,4}$', ' +0000'), [Globalization.CultureInfo]::InvariantCulture).UtcDateTime } catch {}
    return $null
}

# PowerShell 7 converte datas ISO do JSON em DateTime; mantemos tudo como texto ISO UTC.
function IsoTexto($v) {
    if ($null -eq $v) { return $null }
    if ($v -is [DateTime]) { return $v.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }
    return [string]$v
}

function No($item, [string]$nome) {
    $n = $item.SelectSingleNode("*[local-name()='$nome']")
    if ($n) { return $n.InnerText } else { return '' }
}

$TermosNorm = @($Config.termosObrigatorios | ForEach-Object { Normalizar $_ })
function MencionaAlvo([string]$texto) {
    $t = Normalizar $texto
    foreach ($termo in $TermosNorm) { if ($t.Contains($termo)) { return $true } }
    return $false
}

$Temas = @()
foreach ($p in $Config.temas.PSObject.Properties) {
    $Temas += [pscustomobject]@{ nome = $p.Name; chaves = @($p.Value | ForEach-Object { Normalizar $_ }) }
}
function Classificar([string]$texto) {
    $t = ' ' + (Normalizar $texto) + ' '
    $r = @()
    foreach ($tema in $Temas) {
        foreach ($k in $tema.chaves) { if ($t.Contains(' ' + $k)) { $r += $tema.nome; break } }
    }
    return ,$r
}

# ---------- coleta ----------
function MontarFontes {
    $lista = @()
    foreach ($b in $Config.buscas) {
        $q = [Uri]::EscapeDataString($b.consulta)
        if ($b.tipo -eq 'google') { $url = "https://news.google.com/rss/search?q=$q&hl=pt-BR&gl=BR&ceid=BR:pt-419" }
        else { $url = "https://www.bing.com/news/search?q=$q&format=rss&setlang=pt-BR&cc=BR" }
        $lista += [pscustomobject]@{ nome = $b.nome; tipo = $b.tipo; url = $url; rotulo = "$($b.nome): $($b.consulta)" }
    }
    foreach ($p in $Config.portais) {
        $lista += [pscustomobject]@{ nome = $p.nome; tipo = 'portal'; url = $p.feed; rotulo = $p.nome }
    }
    return $lista
}

function BaixarTudo($fontes) {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $cli = New-Object System.Net.Http.HttpClient($handler)
    $cli.Timeout = [TimeSpan]::FromSeconds(25)
    $cli.DefaultRequestHeaders.UserAgent.ParseAdd('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36')
    $cli.DefaultRequestHeaders.Accept.ParseAdd('application/rss+xml, application/xml;q=0.9, */*;q=0.8')
    $cli.DefaultRequestHeaders.AcceptLanguage.ParseAdd('pt-BR,pt;q=0.9')
    $tarefas = @(foreach ($f in $fontes) { $cli.GetByteArrayAsync($f.url) })
    try { [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tarefas) } catch {}
    $res = @()
    for ($i = 0; $i -lt $fontes.Count; $i++) {
        $t = $tarefas[$i]
        if ($t.Status -eq 'RanToCompletion') { $res += ,@($fontes[$i], $t.Result, $null) }
        else {
            $err = if ($t.Exception) { $t.Exception.GetBaseException().Message } else { 'tempo esgotado' }
            $res += ,@($fontes[$i], $null, $err)
        }
    }
    $cli.Dispose()
    return $res
}

function ExtrairItens($fonte, [byte[]]$bytes) {
    $doc = New-Object System.Xml.XmlDocument
    $doc.XmlResolver = $null
    $ms = New-Object System.IO.MemoryStream(, $bytes)
    $doc.Load($ms)
    $saida = @()
    foreach ($it in $doc.SelectNodes("//*[local-name()='item']")) {
        $titulo = LimparHtml (No $it 'title')
        $link   = (No $it 'link').Trim()
        $data   = LerData (No $it 'pubDate')
        $desc   = No $it 'description'
        $veiculo = $fonte.nome

        switch ($fonte.tipo) {
            'google' {
                $src = No $it 'source'
                if ($src) {
                    $veiculo = $src.Trim()
                    $suf = ' - ' + $veiculo
                    if ($titulo.EndsWith($suf)) { $titulo = $titulo.Substring(0, $titulo.Length - $suf.Length) }
                }
                $resumo = ''
            }
            'bing' {
                $src = No $it 'Source'
                if ($src) { $veiculo = $src.Trim() }
                $m = [regex]::Match($link, '[?&]url=([^&]+)')
                if ($m.Success) { $link = [Uri]::UnescapeDataString($m.Groups[1].Value) }
                $resumo = LimparHtml $desc
            }
            default {
                $resumo = LimparHtml $desc
                $corpo = LimparHtml (No $it 'encoded')
                if (-not (MencionaAlvo ("$titulo $resumo $corpo"))) { $titulo = '' }
            }
        }
        if (-not $titulo -or -not $link) { continue }
        if ((Normalizar $resumo).StartsWith((Normalizar $titulo))) { $resumo = '' }

        $saida += [pscustomobject]@{
            titulo  = $titulo
            link    = $link
            veiculo = $veiculo
            data    = $data
            resumo  = (Cortar $resumo 400)
            origem  = $fonte.nome
        }
    }
    return $saida
}

# ---------- base acumulada ----------
$Arquivo = @{}   # chave normalizada -> item
$Estado = [pscustomobject]@{ atualizadoEm = $null; fontes = @() }

function CarregarArquivo {
    if (-not (Test-Path $ArqArquivo)) { return }
    try {
        $d = Get-Content $ArqArquivo -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($i in $d.itens) {
            $novo = [pscustomobject]@{
                id          = $i.id
                titulo      = $i.titulo
                link        = $i.link
                veiculo     = $i.veiculo
                data        = IsoTexto $i.data
                resumo      = $i.resumo
                temas       = @($i.temas)
                destaque    = [bool]$i.destaque
                origem      = $i.origem
                origens     = @(if ($i.origens) { $i.origens } else { $i.origem })
                capturadoEm = IsoTexto $i.capturadoEm
            }
            $Arquivo[(Normalizar $novo.titulo)] = $novo
        }
        $Estado.atualizadoEm = IsoTexto $d.atualizadoEm
        if ($d.fontes) { $Estado.fontes = @($d.fontes) }
        Log "Base carregada: $($Arquivo.Count) notícias."
    } catch { Log "Aviso: não foi possível ler $ArqArquivo ($_)" }
}

function SalvarArquivo {
    $itens = @($Arquivo.Values | Sort-Object { $_.data } -Descending)
    $obj = [pscustomobject]@{
        titulo       = $Config.titulo
        atualizadoEm = $Estado.atualizadoEm
        intervaloMin = $Config.atualizarACadaMinutos
        temas        = @($Temas | ForEach-Object { $_.nome })
        fontes       = @($Estado.fontes)
        itens        = $itens
    }
    $json = ConvertTo-Json -InputObject $obj -Depth 6 -Compress
    [IO.File]::WriteAllText($ArqArquivo, $json, $Utf8)
}

function Atualizar {
    Log 'Atualizando fontes...'
    $inicio = Get-Date
    $agoraIso = (Get-Date).ToUniversalTime().ToString('o')
    $baixados = BaixarTudo (MontarFontes)
    $status = @()
    $novas = 0
    foreach ($r in $baixados) {
        $f = $r[0]; $bytes = $r[1]; $err = $r[2]
        $qtd = 0
        if ($bytes) {
            try {
                foreach ($n in (ExtrairItens $f $bytes)) {
                    $qtd++
                    $chave = Normalizar $n.titulo
                    if (-not $chave) { continue }
                    $dataIso = if ($n.data) { $n.data.ToString('o') } else { $agoraIso }
                    if ($Arquivo.ContainsKey($chave)) {
                        $ex = $Arquivo[$chave]
                        if (@($ex.origens) -notcontains $n.origem) { $ex.origens = @($ex.origens) + $n.origem }
                        # prefere link direto ao link de redirecionamento do Google
                        if ($ex.link -like '*news.google.com*' -and $n.link -notlike '*news.google.com*') { $ex.link = $n.link }
                        if (-not $ex.resumo -and $n.resumo) { $ex.resumo = $n.resumo; $ex.temas = Classificar "$($ex.titulo) $($n.resumo)" }
                    } else {
                        $Arquivo[$chave] = [pscustomobject]@{
                            id          = Hash $chave
                            titulo      = $n.titulo
                            link        = $n.link
                            veiculo     = $n.veiculo
                            data        = $dataIso
                            resumo      = $n.resumo
                            temas       = (Classificar "$($n.titulo) $($n.resumo)")
                            destaque    = (MencionaAlvo $n.titulo)
                            origem      = $n.origem
                            origens     = @($n.origem)
                            capturadoEm = $agoraIso
                        }
                        $novas++
                    }
                }
            } catch { $err = "XML inválido: $($_.Exception.Message)" }
        }
        $status += [pscustomobject]@{ fonte = $f.rotulo; ok = (-not $err); itens = $qtd; erro = $err }
    }
    $Estado.fontes = $status
    $Estado.atualizadoEm = $agoraIso
    SalvarArquivo
    Log ("Concluído em {0:N1}s: {1} novas, {2} no total." -f ((Get-Date) - $inicio).TotalSeconds, $novas, $Arquivo.Count)
    return $novas
}

function Desatualizado {
    if (-not $Estado.atualizadoEm) { return $true }
    $ult = [DateTime]::Parse($Estado.atualizadoEm, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    return ((Get-Date).ToUniversalTime() - $ult.ToUniversalTime()).TotalMinutes -ge $Config.atualizarACadaMinutos
}
