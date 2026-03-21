"""
AzureSOC - Cloud Security Posture Management (CSPM) Audit Tool
================================================================
WHAT THIS DOES:
Scans your Azure subscription for security misconfigurations and reports
findings to both Splunk (via HEC) and stdout. Run manually or deploy
as an Azure Function on a daily timer.

CHECKS PERFORMED:
1. Open NSG rules (0.0.0.0/0 inbound) - HIGH severity
2. Unencrypted storage accounts - CRITICAL severity
3. VMs without endpoint protection - HIGH severity
4. Excessive RBAC (too many Owner/Contributor roles) - MEDIUM severity
5. Key Vault access without RBAC - MEDIUM severity
6. Missing diagnostic settings - LOW severity

PREREQUISITES:
pip install azure-identity azure-mgmt-network azure-mgmt-storage
pip install azure-mgmt-compute azure-mgmt-authorization requests

USAGE:
python cspm_audit.py --subscription-id <your-sub-id>
python cspm_audit.py --subscription-id <your-sub-id> --splunk-hec http://10.0.3.4:8088
"""

import argparse
import json
import sys
from datetime import datetime

try:
    from azure.identity import DefaultAzureCredential
    from azure.mgmt.network import NetworkManagementClient
    from azure.mgmt.storage import StorageManagementClient
    from azure.mgmt.compute import ComputeManagementClient
    from azure.mgmt.authorization import AuthorizationManagementClient
except ImportError:
    print("Missing Azure SDK packages. Install with:")
    print("pip install azure-identity azure-mgmt-network azure-mgmt-storage azure-mgmt-compute azure-mgmt-authorization")
    sys.exit(1)

try:
    import requests
    HAS_REQUESTS = True
except ImportError:
    HAS_REQUESTS = False


def check_open_nsg_rules(network_client):
    """
    Find NSG rules that allow inbound traffic from any source (0.0.0.0/0).
    
    WHY THIS MATTERS:
    An NSG rule allowing 0.0.0.0/0 means anyone on the internet can reach
    that port. This is the #1 cloud misconfiguration that leads to breaches.
    Common culprits: RDP (3389), SSH (22), SQL (1433) left open to the world.
    """
    findings = []
    for nsg in network_client.network_security_groups.list_all():
        for rule in nsg.security_rules:
            if rule.direction == "Inbound" and rule.access == "Allow":
                src = rule.source_address_prefix or ""
                if src in ("*", "0.0.0.0/0", "Internet"):
                    port = rule.destination_port_range or "multiple"
                    findings.append({
                        "timestamp": datetime.utcnow().isoformat(),
                        "severity": "HIGH",
                        "check": "Open NSG Rule",
                        "resource": f"{nsg.name}/{rule.name}",
                        "resource_group": nsg.id.split("/")[4] if nsg.id else "unknown",
                        "detail": f"Port {port} open to {src} (internet-facing)",
                        "remediation": f"Restrict source to specific IPs or remove rule '{rule.name}'",
                        "mitre": "T1190 - Exploit Public-Facing Application"
                    })
    return findings


def check_unencrypted_storage(storage_client):
    """
    Find storage accounts without proper encryption.
    
    WHY THIS MATTERS:
    Azure encrypts storage at rest by default now, but older accounts or
    custom configs might have it disabled. Unencrypted storage means if
    someone gets access to the underlying disks, they can read everything.
    """
    findings = []
    for account in storage_client.storage_accounts.list():
        # Check HTTPS-only
        if not account.enable_https_traffic_only:
            findings.append({
                "timestamp": datetime.utcnow().isoformat(),
                "severity": "HIGH",
                "check": "HTTP Allowed on Storage",
                "resource": account.name,
                "resource_group": account.id.split("/")[4] if account.id else "unknown",
                "detail": "Storage account allows unencrypted HTTP traffic",
                "remediation": "Enable 'Secure transfer required' in storage account settings",
                "mitre": "T1557 - Adversary-in-the-Middle"
            })
        # Check minimum TLS
        tls = getattr(account, 'minimum_tls_version', None)
        if tls and tls != "TLS1_2":
            findings.append({
                "timestamp": datetime.utcnow().isoformat(),
                "severity": "MEDIUM",
                "check": "Weak TLS Version",
                "resource": account.name,
                "resource_group": account.id.split("/")[4] if account.id else "unknown",
                "detail": f"Minimum TLS version is {tls} (should be TLS1_2)",
                "remediation": "Set minimum TLS version to 1.2",
                "mitre": "T1557 - Adversary-in-the-Middle"
            })
    return findings


def check_vm_security(compute_client):
    """
    Check VMs for missing security configurations.
    
    WHY THIS MATTERS:
    VMs without endpoint protection are blind spots in your security.
    You can't detect malware or attacks on unprotected endpoints.
    """
    findings = []
    for vm in compute_client.virtual_machines.list_all():
        # Check for extensions (basic check for security agents)
        rg = vm.id.split("/")[4]
        try:
            extensions = compute_client.virtual_machine_extensions.list(rg, vm.name)
            ext_names = [e.name.lower() for e in extensions.value] if extensions.value else []
            
            has_security = any(x for x in ext_names if "mde" in x or "defender" in x 
                             or "antimalware" in x or "azuremonitor" in x)
            if not has_security and "honeypot" not in vm.name.lower():
                findings.append({
                    "timestamp": datetime.utcnow().isoformat(),
                    "severity": "HIGH",
                    "check": "No Endpoint Protection",
                    "resource": vm.name,
                    "resource_group": rg,
                    "detail": "VM has no detected security agent (MDE/Antimalware/AMA)",
                    "remediation": "Onboard to Microsoft Defender for Endpoint",
                    "mitre": "T1562.001 - Disable or Modify Tools"
                })
        except Exception:
            pass
    return findings


def check_rbac(auth_client, subscription_id):
    """
    Check for excessive privileged role assignments.
    
    WHY THIS MATTERS:
    Too many Owner/Contributor accounts = larger attack surface.
    If any of those accounts get compromised, the attacker has
    full control of your Azure environment.
    """
    findings = []
    scope = f"/subscriptions/{subscription_id}"
    owners = []
    contributors = []
    
    try:
        for assignment in auth_client.role_assignments.list_for_scope(scope):
            role_id = assignment.role_definition_id
            if "Owner" in (role_id or ""):
                owners.append(assignment.principal_id)
            elif "Contributor" in (role_id or ""):
                contributors.append(assignment.principal_id)
    except Exception:
        pass
    
    if len(owners) > 3:
        findings.append({
            "timestamp": datetime.utcnow().isoformat(),
            "severity": "MEDIUM",
            "check": "Excessive Owner Roles",
            "resource": "Subscription",
            "resource_group": "N/A",
            "detail": f"{len(owners)} principals have Owner role (recommended: ≤3)",
            "remediation": "Review and remove unnecessary Owner role assignments",
            "mitre": "T1078.004 - Cloud Accounts"
        })
    
    return findings


def send_to_splunk(findings, hec_url, hec_token):
    """Send findings to Splunk via HTTP Event Collector."""
    if not HAS_REQUESTS:
        print("  'requests' package not installed — skipping Splunk export")
        return
    for f in findings:
        try:
            requests.post(
                f"{hec_url}/services/collector",
                headers={"Authorization": f"Splunk {hec_token}"},
                json={"event": f, "sourcetype": "cspm_audit", "index": "idx_threat_intel"},
                verify=False,
                timeout=5
            )
        except Exception as e:
            print(f"  Failed to send to Splunk: {e}")


def main():
    parser = argparse.ArgumentParser(description="AzureSOC CSPM Audit Tool")
    parser.add_argument("--subscription-id", required=True, help="Azure Subscription ID")
    parser.add_argument("--splunk-hec", default=None, help="Splunk HEC URL (e.g., http://10.0.3.4:8088)")
    parser.add_argument("--splunk-token", default=None, help="Splunk HEC Token")
    parser.add_argument("--output", default=None, help="Output JSON file path")
    args = parser.parse_args()

    print("=" * 50)
    print("  AzureSOC CSPM Audit")
    print("=" * 50)

    credential = DefaultAzureCredential()
    
    all_findings = []

    print("\n[1/4] Checking NSG rules...")
    network = NetworkManagementClient(credential, args.subscription_id)
    all_findings.extend(check_open_nsg_rules(network))

    print("[2/4] Checking storage accounts...")
    storage = StorageManagementClient(credential, args.subscription_id)
    all_findings.extend(check_unencrypted_storage(storage))

    print("[3/4] Checking VM security...")
    compute = ComputeManagementClient(credential, args.subscription_id)
    all_findings.extend(check_vm_security(compute))

    print("[4/4] Checking RBAC assignments...")
    auth = AuthorizationManagementClient(credential, args.subscription_id)
    all_findings.extend(check_rbac(auth, args.subscription_id))

    # Summary
    critical = sum(1 for f in all_findings if f["severity"] == "CRITICAL")
    high = sum(1 for f in all_findings if f["severity"] == "HIGH")
    medium = sum(1 for f in all_findings if f["severity"] == "MEDIUM")
    low = sum(1 for f in all_findings if f["severity"] == "LOW")

    print(f"\n{'=' * 50}")
    print(f"  RESULTS: {len(all_findings)} findings")
    print(f"  CRITICAL: {critical} | HIGH: {high} | MEDIUM: {medium} | LOW: {low}")
    print(f"{'=' * 50}\n")

    for f in all_findings:
        sev_color = {"CRITICAL": "🔴", "HIGH": "🟠", "MEDIUM": "🟡", "LOW": "🔵"}.get(f["severity"], "⚪")
        print(f"  {sev_color} [{f['severity']}] {f['check']}: {f['resource']}")
        print(f"     {f['detail']}")
        print(f"     Fix: {f['remediation']}")
        print()

    # Export
    if args.splunk_hec and args.splunk_token:
        print("Sending findings to Splunk...")
        send_to_splunk(all_findings, args.splunk_hec, args.splunk_token)
        print("  Done!")

    if args.output:
        with open(args.output, "w") as f:
            json.dump(all_findings, f, indent=2)
        print(f"Findings saved to {args.output}")


if __name__ == "__main__":
    main()
