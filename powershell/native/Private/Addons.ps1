$Script:AapAvailableAddons = @(
  'mcp-server', 'portal', 'setup-pah', 'ao', 'apme-eap', 'local-cache'
)

function Test-AapWslBashPath {
  param(
    [Parameter(Mandatory)][string]$Path,
    [string]$WindowsDir = $env:WINDIR
  )

  $full = $Path -replace '/', '\'
  if ($full -match '(?i)\\WindowsApps\\') { return $true }
  if ($WindowsDir) {
    $win = ($WindowsDir -replace '/', '\').TrimEnd('\')
    foreach ($sub in @('System32', 'SysNative', 'SysWOW64')) {
      if ($full.StartsWith("$win\$sub\", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
  }
  return $false
}

function Resolve-AapGitBashPath {
  param(
    [string]$Override,
    [string[]]$GitCommandPaths = @(),
    [string[]]$InstallRoots = @(),
    [string]$WindowsDir = $env:WINDIR
  )

  $candidates = New-Object System.Collections.ArrayList
  if ($Override) { [void]$candidates.Add($Override) }
  foreach ($git in $GitCommandPaths) {
    if (-not $git) { continue }
    # git.exe lives in <root>\cmd, <root>\bin or <root>\mingw64\bin of a Git for Windows install.
    $dir = Split-Path -Parent $git
    for ($i = 0; $i -lt 3 -and $dir; $i++) {
      [void]$candidates.Add((Join-Path $dir 'bin\bash.exe'))
      $dir = Split-Path -Parent $dir
    }
  }
  foreach ($root in $InstallRoots) {
    if ($root) { [void]$candidates.Add((Join-Path $root 'bin\bash.exe')) }
  }

  foreach ($candidate in $candidates) {
    if (Test-AapWslBashPath -Path $candidate -WindowsDir $WindowsDir) {
      if ($Override -and $candidate -eq $Override) {
        throw "AAP_DEMO_BASH points at WSL bash ('$Override'); set it to Git for Windows bin\bash.exe."
      }
      continue
    }
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    if ($Override -and $candidate -eq $Override) {
      throw "AAP_DEMO_BASH '$Override' does not exist."
    }
  }
  return $null
}

function Get-AapGitBashPath {
  $gitPaths = @(Get-Command git -CommandType Application -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
  $roots = @()
  foreach ($base in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if ($base) { $roots += (Join-Path $base 'Git') }
  }
  if ($env:LOCALAPPDATA) { $roots += (Join-Path $env:LOCALAPPDATA 'Programs\Git') }
  return Resolve-AapGitBashPath -Override $env:AAP_DEMO_BASH -GitCommandPaths $gitPaths -InstallRoots $roots
}

function Invoke-AapAddonDeployScript {
  param(
    [Parameter(Mandatory)][string]$Addon,
    [string[]]$ScriptArgs = @()
  )

  $deploySh = Join-Path $Script:AapDemoRepoRoot "addons/$Addon/deploy.sh"
  if (-not (Test-Path -LiteralPath $deploySh)) {
    throw "Addon '$Addon' has no deploy.sh"
  }

  $bash = Get-AapGitBashPath
  if (-not $bash) {
    throw "Addon '$Addon' requires Git for Windows Bash (WSL bash.exe is not supported). Install Git for Windows (winget install --id Git.Git -e), set AAP_DEMO_BASH to its bin\bash.exe, or use Linux/macOS."
  }

  & $bash $deploySh @ScriptArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Addon '$Addon' deploy failed (exit code: $LASTEXITCODE)"
  }
}
function Invoke-AapEnsureClusterReady {
  Invoke-AapEnsureCluster
  Set-AapIngressCaEnvFromSaved
}

function Invoke-AapDeployMcpServerAddon {
  param(
    [string]$Namespace = $Script:AapDemoDefaultNamespace
  )

  $csvResult = Invoke-AapOcCapture @('get', 'csv', '-n', $Namespace, '--no-headers')
  if (-not (Test-AapOcHasListOutput $csvResult) -or ($csvResult.Output -notmatch 'aap-operator')) {
    Write-AapWarn "AAP operator not found in namespace '$Namespace'"
    Write-Host '  Deploy AAP first: aap-demo deploy'
    Write-Host '  Proceeding anyway (CR will reconcile once operator is ready)...'
  }

  if ((Invoke-AapOcQuiet @('get', 'crd', 'ansiblemcpservers.mcpserver.ansible.com')) -ne 0) {
    Write-AapWarn 'AnsibleMCPServer CRD not found (requires AAP operator 2.6+)'
    Write-Host '  Proceeding anyway (CR will be applied once CRD is available)...'
  }

  if ((Invoke-AapOcQuiet @('get', 'secret', 'redhat-operators-pull-secret', '-n', $Namespace)) -ne 0) {
    Write-AapWarn "Pull secret 'redhat-operators-pull-secret' not found in $Namespace"
    Write-Host '  MCP server pod may fail to pull images without it'
  }

  Write-Host 'Deploying AAP MCP Server...'

  $manifest = Read-AapManifest 'addons/mcp-server/mcp-server.yaml'
  $manifest = $manifest -replace '(?m)^  namespace: aap-operator$', "  namespace: $Namespace"
  $manifest = $manifest -replace 'aap-mcp-aap-operator', "aap-mcp-$Namespace"
  $manifest = $manifest -replace 'aap-aap-operator', "aap-$Namespace"

  $temp = [System.IO.Path]::GetTempFileName()
  try {
    Set-AapUtf8Content -Path $temp -Value $manifest
    Invoke-AapOc @('apply', '-f', $temp) | Out-Null
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }

  $mcpRoute = "aap-mcp-$Namespace.apps.127.0.0.1.nip.io"
  $aapRoute = "aap-$Namespace.apps.127.0.0.1.nip.io"
  Write-AapStep 'AAP MCP Server deployed'
  Write-Host ''
  Write-Host "  MCP Endpoint: https://$mcpRoute/mcp"
  Write-Host "  AAP Instance: https://$aapRoute"
  Write-Host ''
  Write-Host "  Status:  oc get ansiblemcpserver -n $Namespace"
  Write-Host "  Logs:    oc logs -n $Namespace -l app.kubernetes.io/name=aap-mcp-server"
  Write-Host ''
  Write-Host '  Connect your MCP client to:'
  Write-Host "    https://$mcpRoute/mcp"
  Write-Host ''
}

function Invoke-AapRemoveMcpServerAddon {
  param(
    [string]$Namespace = $Script:AapDemoDefaultNamespace
  )

  Write-Host 'Removing AAP MCP Server...'
  Invoke-AapOcQuiet @(
    'delete', 'ansiblemcpserver', 'aap-mcp-server', '-n', $Namespace, '--timeout=60s'
  ) | Out-Null
  Write-AapStep 'MCP Server removed'
}

function Invoke-AapAddonEnable {
  param(
    [Parameter(Mandatory)][string]$Addon,
    [string]$Namespace = $Script:AapDemoDefaultNamespace
  )

  switch ($Addon) {
    'mcp-server' { Invoke-AapDeployMcpServerAddon -Namespace $Namespace }
    'portal' { Invoke-AapDeployPortalAddon -Namespace $Namespace }
    default { Invoke-AapAddonDeployScript -Addon $Addon }
  }
}

function Get-AapMcpServerRouteHost {
  param([string]$Namespace = $Script:AapDemoDefaultNamespace)

  $result = Invoke-AapOcCapture @(
    'get', 'ansiblemcpserver', 'aap-mcp-server', '-n', $Namespace,
    '-o', 'jsonpath={.spec.route_host}'
  )
  if ($result.ExitCode -ne 0) { return $null }
  $routeHost = $result.Output.Trim()
  if ($routeHost -and $routeHost -notmatch '\s' -and $routeHost -notmatch ':') {
    return $routeHost
  }
  return $null
}

function Get-AapAddonEnableCommand {
  param([Parameter(Mandatory)][string]$Addon)
  return "aap-demo enable $Addon"
}

function Get-AapAddonStatusLabel {
  param(
    [Parameter(Mandatory)][string]$Addon,
    [string]$Namespace = $Script:AapDemoDefaultNamespace,
    [Parameter(Mandatory)][bool]$Enabled
  )

  if (-not $Enabled) { return 'disabled' }

  switch ($Addon) {
    'mcp-server' {
      $mcpHost = Get-AapMcpServerRouteHost -Namespace $Namespace
      if ($mcpHost) { return "https://$mcpHost/mcp" }
      return 'not-deployed'
    }
    'portal' {
      $portalHost = Get-AapPortalRouteHost -AapNamespace $Namespace
      if ($portalHost) { return "https://$portalHost" }
      return 'not-deployed'
    }
    default { return $null }  }
}

function Get-AapMcpServerRouteHost {
  param([string]$Namespace = $Script:AapDemoDefaultNamespace)

  $result = Invoke-AapOcCapture @(
    'get', 'ansiblemcpserver', 'aap-mcp-server', '-n', $Namespace,
    '-o', 'jsonpath={.spec.route_host}'
  )
  if ($result.ExitCode -ne 0) { return $null }
  $routeHost = $result.Output.Trim()
  if ($routeHost -and $routeHost -notmatch '\s' -and $routeHost -notmatch ':') {
    return $routeHost
  }
  return $null
}

function Get-AapAddonEnableCommand {
  param([Parameter(Mandatory)][string]$Addon)
  return "aap-demo enable $Addon"
}

function Get-AapAddonStatusLabel {
  param(
    [Parameter(Mandatory)][string]$Addon,
    [string]$Namespace = $Script:AapDemoDefaultNamespace,
    [Parameter(Mandatory)][bool]$Enabled
  )

  if (-not $Enabled) { return 'disabled' }

  switch ($Addon) {
    'mcp-server' {
      $mcpHost = Get-AapMcpServerRouteHost -Namespace $Namespace
      if ($mcpHost) { return "https://$mcpHost/mcp" }
      return 'not-deployed'
    }
    'portal' {
      $portalHost = Get-AapPortalRouteHost -AapNamespace $Namespace
      if ($portalHost) { return "https://$portalHost" }
      return 'not-deployed'
    }
    default { return $null }
  }
}

function Invoke-AapAddonDisable {
  param(
    [Parameter(Mandatory)][string]$Addon,
    [string]$Namespace = $Script:AapDemoDefaultNamespace
  )

  switch ($Addon) {
    'mcp-server' { Invoke-AapRemoveMcpServerAddon -Namespace $Namespace }
    'portal' { Invoke-AapRemovePortalAddon -Namespace $Namespace }
    default { Invoke-AapAddonDeployScript -Addon $Addon -ScriptArgs @('--delete') }  }
}
