# Inbound rule for llama-server, scoped to the WSL subnet only (decision doc s7.4).
# NOT "Any": llama-server runs without auth (apiKey EMPTY), so an open port
# would hand the model and the GPU to anyone on the LAN.
$ErrorActionPreference = "Stop"
$name = "llama-server 8080 (WSL only)"

Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule `
    -DisplayName $name `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalPort 8080 `
    -RemoteAddress "172.16.0.0/12" `
    -Profile Any | Out-Null

Write-Host "rule created:"
Get-NetFirewallRule -DisplayName $name |
    Format-List DisplayName, Enabled, Direction, Action, Profile
Get-NetFirewallRule -DisplayName $name |
    Get-NetFirewallAddressFilter |
    Format-List RemoteAddress
