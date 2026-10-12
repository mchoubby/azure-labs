[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Diagnose', 'Load', 'DeletePod', 'Drain')]
    [string]$Scenario = 'Diagnose',
    [string]$ResourceGroup = 'rg-aksdemo-dev',
    [string]$ClusterName = 'aks-aksdemo-dev',
    [ValidatePattern('^[a-z0-9][a-z0-9.-]*\.azurecr\.io/[a-z0-9/._-]+@sha256:[a-f0-9]{64}$')]
    [string]$TestImage,
    [ValidateRange(30, 600)]
    [int]$DurationSeconds = 180,
    [ValidateRange(1, 32)]
    [int]$Concurrency = 8,
    [ValidatePattern('^[a-z0-9][a-z0-9.-]*$')]
    [string]$PodName,
    [ValidatePattern('^[a-z0-9][a-z0-9.-]*$')]
    [string]$NodeName
)

$ErrorActionPreference = 'Stop'
$runId = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$jobNames = @()
$nodeCordoned = $false
$temporaryFiles = @()

function Invoke-Cluster {
    param([string]$Script)

    $scriptPath = Join-Path ([IO.Path]::GetTempPath()) "p6-$([Guid]::NewGuid().ToString('N')).sh"
    $script:temporaryFiles += $scriptPath
    [IO.File]::WriteAllText($scriptPath, ("set -eu`n" + $Script).Replace("`r`n", "`n"), [Text.Encoding]::ASCII)
    $arguments = @('aks', 'command', 'invoke', '-g', $ResourceGroup, '-n', $ClusterName,
        '--command', "sh $([IO.Path]::GetFileName($scriptPath))", '--file', $scriptPath)
    $result = & az @arguments --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "az aks command invoke a échoué (code $LASTEXITCODE)." }
    $response = ($result -join "`n") | ConvertFrom-Json
    Write-Host $response.logs
    if ($response.provisioningState -ne 'Succeeded' -or $null -eq $response.exitCode -or $response.exitCode -ne 0) {
        throw "Commande distante en échec : state=$($response.provisioningState), exitCode=$($response.exitCode)."
    }
}

function Start-TestJob {
    param([string]$Name, [string]$Command)

    $job = @{
        apiVersion = 'batch/v1'; kind = 'Job'
        metadata = @{ name = $Name; namespace = 'demo-app'; labels = @{ 'phase6-test' = $runId } }
        spec = @{
            backoffLimit = 0; activeDeadlineSeconds = $DurationSeconds + 120; ttlSecondsAfterFinished = 600
            template = @{
                metadata = @{ labels = @{ 'phase6-test' = $runId } }
                spec = @{
                    restartPolicy = 'Never'; automountServiceAccountToken = $false
                    securityContext = @{ runAsNonRoot = $true; runAsUser = 1000; runAsGroup = 1000; seccompProfile = @{ type = 'RuntimeDefault' } }
                    containers = @(@{
                        name = 'test'; image = $TestImage; command = @('sh', '-c', $Command)
                        securityContext = @{ allowPrivilegeEscalation = $false; readOnlyRootFilesystem = $true; capabilities = @{ drop = @('ALL') } }
                        resources = @{ requests = @{ cpu = '100m'; memory = '32Mi' }; limits = @{ cpu = '500m'; memory = '128Mi' } }
                        volumeMounts = @(@{ name = 'tmp'; mountPath = '/tmp' })
                    })
                    volumes = @(@{ name = 'tmp'; emptyDir = @{} })
                }
            }
        }
    }
    $manifest = $job | ConvertTo-Json -Depth 15
    $script:jobNames += $Name
    Invoke-Cluster @"
cat > $Name.json <<'PHASE6_MANIFEST'
$manifest
PHASE6_MANIFEST
kubectl create -f $Name.json
"@
}

try {
    if ($Scenario -eq 'Diagnose') {
        Invoke-Cluster @'
kubectl get nodes -L kubernetes.azure.com/agentpool,topology.kubernetes.io/zone
kubectl get pods -n demo-app -l app=demo-app -o wide
kubectl get deploy,hpa,pdb -n demo-app
kubectl top pods -n demo-app
kubectl get --raw /apis/metrics.k8s.io/v1beta1/namespaces/demo-app/pods
kubectl get pods -n kube-system | grep ama-metrics
kubectl get kustomizations -n flux-system
for p in $(kubectl get pods -n demo-app -l app=demo-app -o name); do
  kubectl exec -n demo-app "$p" -- test -s /mnt/secrets-store/api-key
  echo "$p : secret CSI present et non vide"
done
'@
        return
    }

    if (-not $TestImage) { throw 'TestImage est requis : image BusyBox dans ACR, epinglee par digest.' }
    if ($Scenario -eq 'DeletePod' -and -not $PodName) { throw 'PodName explicite requis.' }
    if ($Scenario -eq 'Drain' -and -not $NodeName) { throw 'NodeName explicite requis.' }
    if (-not $PSCmdlet.ShouldProcess("$ClusterName / demo-app", "$Scenario : charge/sonde temporaire et perturbation éventuelle")) { return }

    Invoke-Cluster @'
test "$(kubectl get deploy demo-app -n demo-app -o jsonpath='{.status.readyReplicas}')" -ge 2
kubectl get pdb demo-app -n demo-app
kubectl get hpa demo-app -n demo-app
kubectl get pods -n demo-app -l app=demo-app -o wide
'@
    if ($Scenario -eq 'Drain') {
        Invoke-Cluster @"
test "`$(kubectl get node $NodeName -o jsonpath='{.metadata.labels.kubernetes\.azure\.com/agentpool}')" = user
test "`$(kubectl get node $NodeName -o jsonpath='{.spec.unschedulable}')" != true
test "`$(kubectl get nodes -l kubernetes.azure.com/agentpool=user --field-selector spec.unschedulable=false -o name | wc -l)" -ge 2 || { echo 'Drain refusé : moins de deux nodes user planifiables' >&2; exit 1; }
kubectl get pods -A --field-selector spec.nodeName=$NodeName -o wide
kubectl get pdb -A
"@
    }
    if ($Scenario -eq 'DeletePod') {
        Invoke-Cluster @"
test "`$(kubectl get pod $PodName -n demo-app -o jsonpath='{.metadata.labels.app}')" = demo-app
test "`$(kubectl get pod $PodName -n demo-app -o jsonpath='{.metadata.ownerReferences[0].kind}')" = ReplicaSet
"@
    }

    $probe = "p6-probe-$runId"
    $probeCommand = @'
end=$(($(date +%s) + DURATION))
total=0; failed=0
while [ "$(date +%s)" -lt "$end" ]; do
  total=$((total+1))
  if wget -S -T 3 -O /dev/null http://demo-app/healthz 2>/tmp/http; then
    code=$(awk '/HTTP\// {code=$2} END {print code}' /tmp/http)
    echo "request=$total status=$code"
  else
    failed=$((failed+1)); echo "request=$total FAILED"; cat /tmp/http
  fi
  sleep 1
done
echo "TOTAL=$total FAILED=$failed"
test "$failed" -eq 0
'@.Replace('DURATION', "$DurationSeconds")
    Start-TestJob -Name $probe -Command $probeCommand
    Invoke-Cluster "kubectl wait -n demo-app --for=condition=Ready pod -l job-name=$probe --timeout=60s"

    $availabilityMonitor = @"
monitor_availability() {
  for i in `$(seq 1 $([Math]::Ceiling(($DurationSeconds + 120) / 5))); do
    ready=`$(kubectl get deploy demo-app -n demo-app -o jsonpath='{.status.readyReplicas}')
    echo "readyReplicas=`${ready:-0}"
    test "`${ready:-0}" -ge 1 || { echo 'ECHEC : aucun replica Ready.' >&2; return 1; }
    succeeded=`$(kubectl get job $probe -n demo-app -o jsonpath='{.status.succeeded}')
    failed=`$(kubectl get job $probe -n demo-app -o jsonpath='{.status.failed}')
    if [ "`${succeeded:-0}" -eq 1 ] || [ "`${failed:-0}" -gt 0 ]; then return 0; fi
    sleep 5
  done
  echo 'ECHEC : deadline de la sonde depassee.' >&2
  return 1
}
"@
    switch ($Scenario) {
        'Load' {
            $load = "p6-load-$runId"
            $loadCommand = @'
end=$(($(date +%s) + DURATION))
worker() {
  while [ "$(date +%s)" -lt "$end" ]; do
    wget -q -T 3 -O /dev/null http://demo-app/ || { echo "LOAD request failed" >&2; return 1; }
  done
}
pids=""
for i in $(seq 1 CONCURRENCY); do worker & pids="$pids $!"; done
failed=0
for pid in $pids; do wait "$pid" || failed=1; done
exit "$failed"
'@.Replace('DURATION', "$DurationSeconds").Replace('CONCURRENCY', "$Concurrency")
            Start-TestJob -Name $load -Command $loadCommand
            Invoke-Cluster @"
expanded=0
for i in `$(seq 1 $([Math]::Ceiling($DurationSeconds / 10))); do
  kubectl top pods -n demo-app
  kubectl get hpa demo-app -n demo-app
  ready=`$(kubectl get deploy demo-app -n demo-app -o jsonpath='{.status.readyReplicas}')
  desired=`$(kubectl get hpa demo-app -n demo-app -o jsonpath='{.status.desiredReplicas}')
  test "`${ready:-0}" -ge 1
  test "`$desired" -le 5
  if [ "`$desired" -gt 2 ] && [ "`$ready" -gt 2 ]; then expanded=1; fi
  sleep 10
done
kubectl logs -n demo-app job/$load
test "`$expanded" -eq 1 || { echo 'ECHEC : aucun scale-out mesure ; ajuster la charge bornee.' >&2; exit 1; }
test "`$(kubectl get job $load -n demo-app -o jsonpath='{.status.succeeded}')" = 1
"@
        }
        'DeletePod' {
            Invoke-Cluster @"
$availabilityMonitor
monitor_availability &
watcher=`$!
kubectl delete pod $PodName -n demo-app --wait=true --timeout=60s
wait "`$watcher"
"@
        }
        'Drain' {
            $nodeCordoned = $true
            Invoke-Cluster @"
$availabilityMonitor
monitor_availability &
watcher=`$!
kubectl drain $NodeName --ignore-daemonsets --delete-emptydir-data --timeout=180s
wait "`$watcher"
"@
        }
    }
    Invoke-Cluster @"
available=1
for i in `$(seq 1 $([Math]::Ceiling(($DurationSeconds + 120) / 5))); do
  ready=`$(kubectl get deploy demo-app -n demo-app -o jsonpath='{.status.readyReplicas}')
  echo "readyReplicas=`${ready:-0}"
  if [ "`${ready:-0}" -lt 1 ]; then available=0; fi
  succeeded=`$(kubectl get job $probe -n demo-app -o jsonpath='{.status.succeeded}')
  failed=`$(kubectl get job $probe -n demo-app -o jsonpath='{.status.failed}')
  if [ "`${succeeded:-0}" -eq 1 ] || [ "`${failed:-0}" -gt 0 ]; then break; fi
  sleep 5
done
kubectl logs -n demo-app job/$probe
test "`$available" -eq 1 || { echo 'ECHEC : aucun replica Ready observe.' >&2; exit 1; }
test "`${succeeded:-0}" -eq 1 || {
  kubectl logs -n demo-app job/$probe
  exit 1
}
"@
    if ($nodeCordoned) {
        Invoke-Cluster "kubectl uncordon $NodeName"
        $nodeCordoned = $false
    }
    Invoke-Cluster @'
kubectl rollout status deployment/demo-app -n demo-app --timeout=180s
kubectl get pods -n demo-app -l app=demo-app -o wide
for p in $(kubectl get pods -n demo-app -l app=demo-app -o name); do
  kubectl exec -n demo-app "$p" -- test -s /mnt/secrets-store/api-key
  echo "$p : secret CSI present et non vide"
done
'@
}
finally {
    try {
        if ($nodeCordoned) { Invoke-Cluster "kubectl uncordon $NodeName" }
    }
    finally {
        try {
            if ($jobNames.Count -gt 0) {
                Invoke-Cluster "kubectl delete job -n demo-app $($jobNames -join ' ') --ignore-not-found=true --wait=true --timeout=60s"
            }
        }
        finally {
            foreach ($file in $temporaryFiles) {
                if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
            }
        }
    }
}
