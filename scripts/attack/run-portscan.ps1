param([string]$ResourceGroup = "rg-azuresoc")

Write-Host "Installing attack tools and running port scan..." -ForegroundColor Yellow

$script = @'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

# Enable universe repo (needed for nmap, nikto, hydra)
add-apt-repository -y universe 2>/dev/null
apt-get update -qq

# Install tools
apt-get install -y nmap nikto hydra smbclient netcat-openbsd 2>&1 | tail -5

echo ""
echo "=== TOOL CHECK ==="
which nmap && nmap --version | head -1 || echo "nmap: NOT INSTALLED"
which nikto && echo "nikto: OK" || echo "nikto: NOT INSTALLED"
which hydra && echo "hydra: OK" || echo "hydra: NOT INSTALLED"

# If nmap still not found, try snap
if ! command -v nmap &> /dev/null; then
    echo "Trying snap install..."
    snap install nmap 2>/dev/null
    which nmap || echo "nmap still not available"
fi

echo ""
echo "=== PORT SCAN of DC (10.0.1.4) ==="
if command -v nmap &> /dev/null; then
    nmap -sV 10.0.1.4 2>&1 | head -40
else
    echo "Using bash TCP scanner instead..."
    for port in 22 53 80 88 135 139 389 443 445 636 3389 5985 5986 8080 9389; do
        (echo >/dev/tcp/10.0.1.4/${port}) 2>/dev/null && echo "OPEN: port ${port}" || echo "CLOSED: port ${port}"
    done
fi
echo "=== SCAN COMPLETE ==="
'@

az vm run-command invoke -g $ResourceGroup --name vm-splunk --command-id RunShellScript --scripts $script

Write-Host ""
Write-Host "Done! Check the scan results above." -ForegroundColor Green
