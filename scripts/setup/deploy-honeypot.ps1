param([string]$ResourceGroup = "rg-azuresoc")

# Base64 encode the HTML to avoid ALL shell quoting issues
$html = @"
<html>
<head><title>AZURESOC Corp - Employee Portal</title></head>
<body style="font-family:Arial;max-width:420px;margin:100px auto;text-align:center;">
<div style="border:1px solid #ddd;padding:30px;border-radius:8px;">
<h2 style="color:#0078D4;">AZURESOC Corp</h2>
<h3>Employee Portal Login</h3>
<form method="POST" action="/login.php">
<input type="text" name="user" placeholder="Username" style="width:90%;padding:10px;margin:8px 0;border:1px solid #ccc;border-radius:4px;"><br>
<input type="password" name="pass" placeholder="Password" style="width:90%;padding:10px;margin:8px 0;border:1px solid #ccc;border-radius:4px;"><br>
<button type="submit" style="width:94%;padding:12px;background:#0078D4;color:white;border:none;border-radius:4px;cursor:pointer;font-size:16px;margin-top:10px;">Sign In</button>
</form>
<p style="color:gray;font-size:11px;margin-top:20px;">WARNING: Authorized access only. All login attempts are logged and monitored by the Security Operations Center.</p>
</div>
</body>
</html>
"@

$bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
$b64 = [System.Convert]::ToBase64String($bytes)

$splunkIP = az vm show -g $ResourceGroup -n vm-splunk -d --query publicIps -o tsv 2>$null

Write-Host "Deploying honeypot login page..." -ForegroundColor Yellow

az vm run-command invoke -g $ResourceGroup --name vm-splunk --command-id RunShellScript `
    --scripts "systemctl start apache2; echo $b64 | base64 -d > /var/www/html/index.html; systemctl restart apache2; echo 'SIZE:'; wc -c /var/www/html/index.html; echo 'CONTENT:'; head -3 /var/www/html/index.html" `
    --only-show-errors

Write-Host ""
Write-Host "Done! Open http://${splunkIP} (Ctrl+Shift+R to hard refresh)" -ForegroundColor Green
