[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-aksdemo-dev',
    [string]$ClusterName = 'aks-aksdemo-dev'
)

$ErrorActionPreference = 'Stop'
$temporaryFiles = @()

function Invoke-ClusterRead {
    param([string]$Command)

    $file = Join-Path ([IO.Path]::GetTempPath()) "p7-$([Guid]::NewGuid().ToString('N')).sh"
    $script:temporaryFiles += $file
    [IO.File]::WriteAllText($file, "set -eu`n$Command", [Text.Encoding]::ASCII)
    $result = & az aks command invoke -g $ResourceGroup -n $ClusterName `
        --command "sh $([IO.Path]::GetFileName($file))" --file $file --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Lecture AKS en echec (code $LASTEXITCODE)." }
    $response = ($result -join "`n") | ConvertFrom-Json
    if ($response.provisioningState -ne 'Succeeded' -or $null -eq $response.exitCode -or $response.exitCode -ne 0) {
        throw "Lecture distante en echec : $($response.logs)"
    }
    return $response.logs.Trim()
}

function Assert-Condition {
    param($Resource, [object[]]$Conditions, [string]$Type)

    $condition = @($Conditions | Where-Object { $_.type -eq $Type })
    if ($condition.Count -ne 1 -or $condition[0].status -ne 'True' -or
        $condition[0].observedGeneration -ne $Resource.metadata.generation) {
        throw "$($Resource.kind)/$($Resource.metadata.name) : $Type non valide pour la generation courante."
    }
}

function Get-HttpStatus {
    param([string]$Url, [string[]]$ExtraArguments = @())

    $result = & curl.exe --silent --show-error --connect-timeout 10 --max-time 20 `
        --output NUL --write-out '%{http_code}' @ExtraArguments $Url
    if ($LASTEXITCODE -ne 0) { throw "Requete $Url en echec (curl=$LASTEXITCODE)." }
    return ($result -join '').Trim()
}

try {
    $gateway = Invoke-ClusterRead 'kubectl get gateway demo-ingress -n demo-app -o json' | ConvertFrom-Json
    Assert-Condition $gateway $gateway.status.conditions 'Accepted'
    Assert-Condition $gateway $gateway.status.conditions 'Programmed'
    foreach ($name in @('http', 'https')) {
        $listeners = @($gateway.status.listeners | Where-Object { $_.name -eq $name })
        if ($listeners.Count -ne 1) { throw "Gateway : listener $name absent ou ambigu." }
        $listener = $listeners[0]
        Assert-Condition $gateway $listener.conditions 'Accepted'
        Assert-Condition $gateway $listener.conditions 'ResolvedRefs'
        Assert-Condition $gateway $listener.conditions 'Programmed'
    }
    foreach ($name in @('demo-http-redirect', 'demo-https')) {
        $route = Invoke-ClusterRead "kubectl get httproute $name -n demo-app -o json" | ConvertFrom-Json
        $parent = @($route.status.parents | Where-Object {
            $_.parentRef.name -eq 'demo-ingress' -and
            $_.controllerName -eq 'alb.networking.azure.io/alb-controller'
        })
        if ($parent.Count -ne 1) { throw "HTTPRoute/$name : parent ALB absent ou ambigu." }
        Assert-Condition $route $parent[0].conditions 'Accepted'
        Assert-Condition $route $parent[0].conditions 'ResolvedRefs'
    }
    $certificate = Invoke-ClusterRead 'kubectl get certificate demo-ingress -n demo-app -o json' | ConvertFrom-Json
    Assert-Condition $certificate $certificate.status.conditions 'Ready'

    $fqdn = $gateway.status.addresses[0].value
    if ($fqdn -notmatch '^[a-z0-9.-]+\.alb\.azure\.com$') {
        throw "Adresse AGC inattendue : $fqdn"
    }
    $publicCertificate = Invoke-ClusterRead "kubectl get secret demo-ingress-tls -n demo-app -o jsonpath='{.data.tls\.crt}'"
    $certificatePath = Join-Path ([IO.Path]::GetTempPath()) "p7-$([Guid]::NewGuid().ToString('N')).pem"
    $temporaryFiles += $certificatePath
    [IO.File]::WriteAllBytes($certificatePath, [Convert]::FromBase64String($publicCertificate))

    $headersPath = Join-Path ([IO.Path]::GetTempPath()) "p7-$([Guid]::NewGuid().ToString('N')).headers"
    $temporaryFiles += $headersPath
    $redirect = Get-HttpStatus "http://$fqdn/healthz" @('--dump-header', $headersPath)
    if ($redirect -ne '301') { throw "Redirection HTTP attendue 301, recue $redirect." }
    $location = @(Get-Content $headersPath | Where-Object { $_ -match '^Location:\s*' })
    if ($location.Count -ne 1 -or $location[0] -notmatch "^Location:\s*https://$([regex]::Escape($fqdn))(?::443)?/healthz\s*$") {
        throw "Destination de redirection inattendue : $($location -join ', ')"
    }
    Write-Host 'HTTP -> HTTPS : 301, hostname et chemin conserves.'

    $status = Get-HttpStatus "https://$fqdn/healthz" @('--cacert', $certificatePath)
    if ($status -ne '200') { throw "HTTPS attendu 200, recu $status." }
    Write-Host 'HTTPS /healthz : 200, certificat et hostname verifies sans -k.'

    $blocked = Get-HttpStatus "https://$fqdn/healthz" @(
        '--cacert', $certificatePath, '--header', 'X-Demo-WAF-Test: block'
    )
    if ($blocked -ne '403') { throw "Blocage WAF attendu 403, recu $blocked." }
    Write-Host 'WAF : en-tete de test bloque (403).'
    Write-Host 'Tests fonctionnels Phase 7 reussis. Verifier aussi les logs access/WAF dans Log Analytics.'
}
finally {
    foreach ($file in $temporaryFiles) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
}
