#!/usr/bin/env python3
"""
OCI Domains and Users Listing Script

This script lists all OCI domains in a tenancy and all users within each domain.
Supports both legacy IAM (root tenancy) and modern Identity Domains.

Dependencies will be automatically installed if missing.
"""

import subprocess
import sys
import importlib
from datetime import datetime

def install_package(package):
    """Install a package using pip"""
    print(f"Installing {package}...")
    try:
        subprocess.check_call([sys.executable, "-m", "pip", "install", package])
        print(f"Successfully installed {package}")
    except subprocess.CalledProcessError as e:
        print(f"Failed to install {package}: {e}")
        sys.exit(1)

def import_or_install(package, import_name=None):
    """Import a package, installing it if necessary"""
    if import_name is None:
        import_name = package
    
    try:
        return importlib.import_module(import_name)
    except ImportError:
        install_package(package)
        try:
            return importlib.import_module(import_name)
        except ImportError:
            print(f"Failed to import {import_name} after installation")
            sys.exit(1)

# Auto-install and import required packages
print("Checking dependencies...")
oci = import_or_install("oci")
tabulate_module = import_or_install("tabulate")
tabulate = tabulate_module.tabulate

# Import other standard library modules
import argparse
import time


def get_oci_config(profile_name="DEFAULT"):
    """Load OCI configuration from ~/.oci/config or use default"""
    try:
        # Try loading from config file first
        config = oci.config.from_file(profile_name=profile_name)
        oci.config.validate_config(config)
        return config
    except Exception as e:
        # If config file fails, try using default/instance principal (for Cloud Shell)
        try:
            config = oci.config.from_file()
            return config
        except Exception:
            # If that fails too, create a minimal config for Cloud Shell
            print(f"Using instance principal authentication...")
            # This will work in Cloud Shell
            return {}


def get_all_domains(identity_client, compartment_id):
    """Get all identity domains in the tenancy"""
    try:
        domains = identity_client.list_domains(compartment_id=compartment_id)
        return domains.data
    except Exception as e:
        print(f"Error listing domains: {e}")
        return []


def get_legacy_users(identity_client, tenancy_id, filter_username=None):
    """Get all users from the root tenancy (legacy IAM)"""
    try:
        users = identity_client.list_users(compartment_id=tenancy_id)
        user_list = []
        
        for user in users.data:
            # Apply username filter if provided
            if filter_username:
                if (filter_username.lower() not in user.name.lower() and 
                    filter_username.lower() not in (user.email or '').lower()):
                    continue
            
            user_list.append({
                'username': user.name,
                'email': user.email or 'N/A',
                'user_id': user.id,
                'status': user.lifecycle_state,
                'created': user.time_created.strftime('%Y-%m-%d %H:%M:%S') if user.time_created else 'N/A',
                'description': user.description or 'N/A'
            })
        
        return user_list
    except Exception as e:
        print(f"Error getting legacy users: {e}")
        return []


def create_identity_domains_client(config, domain_url):
    """Create Identity Domains client for a specific domain"""
    try:
        # Identity Domains client requires service_endpoint parameter
        return oci.identity_domains.IdentityDomainsClient(
            config=config,
            service_endpoint=domain_url
        )
    except Exception as e:
        print(f"Error creating Identity Domains client: {e}")
        return None


def get_identity_domain_users(domain_client, filter_username=None):
    """Get all users from an identity domain"""
    try:
        # Get all users with pagination support
        users = []
        start_index = 1
        count = 100  # Max items per page
        
        # If filtering by username, use SCIM filter for efficiency
        scim_filter = None
        if filter_username:
            # Create SCIM filter for username or email contains
            scim_filter = f'userName co "{filter_username}" or emails.value co "{filter_username}"'
        
        while True:
            if scim_filter:
                response = domain_client.list_users(
                    start_index=start_index,
                    count=count,
                    filter=scim_filter,
                    attributes="userName,displayName,emails,active,meta,name"
                )
            else:
                response = domain_client.list_users(
                    start_index=start_index,
                    count=count,
                    attributes="userName,displayName,emails,active,meta,name"
                )
            
            if not response.data.resources:
                break
                
            for user in response.data.resources:
                # Apply additional client-side filtering if needed
                if filter_username and not scim_filter:
                    user_email = user.emails[0].value if user.emails else ''
                    if (filter_username.lower() not in user.user_name.lower() and 
                        filter_username.lower() not in user_email.lower()):
                        continue
                
                # Extract user information
                email = user.emails[0].value if user.emails else 'N/A'
                display_name = getattr(user, 'display_name', 'N/A')
                created_date = 'N/A'
                
                # Try to get creation date from meta
                if hasattr(user, 'meta') and user.meta:
                    if hasattr(user.meta, 'created'):
                        try:
                            created_date = user.meta.created.strftime('%Y-%m-%d %H:%M:%S')
                        except:
                            created_date = str(user.meta.created)
                
                users.append({
                    'username': user.user_name,
                    'display_name': display_name,
                    'email': email,
                    'user_id': user.id,
                    'status': 'Active' if user.active else 'Inactive',
                    'created': created_date
                })
            
            # Check if there are more pages
            if len(response.data.resources) < count:
                break
            start_index += count
            
            # Small delay to avoid rate limiting
            time.sleep(0.2)
        
        return users
    except Exception as e:
        if "NotAuthorizedOrNotFound" in str(e) or "authorization failed" in str(e).lower():
            print(f"  No access to list users in this identity domain")
        elif "404" in str(e):
            print(f"  Domain endpoint not accessible")
        else:
            print(f"  Error getting identity domain users: {e}")
        return []


def print_domain_summary(domains_info, filter_username=None):
    """Print a summary table of all domains"""
    print("\n" + "=" * 80)
    if filter_username:
        print(f"DOMAINS SUMMARY - FILTERED BY USERNAME: '{filter_username}'")
    else:
        print("DOMAINS SUMMARY")
    print("=" * 80)
    
    summary_data = []
    total_users = 0
    
    for domain_info in domains_info:
        user_count = len(domain_info['users'])
        total_users += user_count
        
        # Only show domains with users if filtering
        if filter_username and user_count == 0:
            continue
        
        summary_data.append([
            domain_info['name'],
            domain_info['type'],
            user_count,
            domain_info['status'],
            domain_info['id']  # Full OCID - no truncation
        ])
    
    if summary_data:
        headers = ['Domain Name', 'Type', 'User Count', 'Status', 'Domain ID']
        print(tabulate(summary_data, headers=headers, tablefmt='grid'))
        
        if filter_username:
            print(f"\nDomains with matches: {len(summary_data)}")
            print(f"Total matching users: {total_users}")
        else:
            print(f"\nTotal Domains: {len(domains_info)}")
            print(f"Total Users Across All Domains: {total_users}")
    else:
        print("No domains found with matching users.")


def print_detailed_domain_info(domains_info, show_users=True, filter_username=None):
    """Print detailed information for each domain"""
    domains_to_show = domains_info
    
    # If filtering, only show domains with users
    if filter_username:
        domains_to_show = [d for d in domains_info if d['users']]
    
    for idx, domain_info in enumerate(domains_to_show, 1):
        print(f"\n" + "=" * 80)
        print(f"[{idx}] DOMAIN: {domain_info['name']}")
        if filter_username:
            print(f"    MATCHING USERS FOR: '{filter_username}'")
        print("=" * 80)
        print(f"Type: {domain_info['type']}")
        print(f"Status: {domain_info['status']}")
        print(f"User Count: {len(domain_info['users'])}")
        print(f"Domain ID: {domain_info['id']}")  # Full OCID
        if 'url' in domain_info:
            print(f"Domain URL: {domain_info['url']}")
        
        if show_users and domain_info['users']:
            print(f"\nUSERS IN {domain_info['name']}:")
            print("-" * 80)
            
            # Prepare user table data
            user_data = []
            for user in domain_info['users']:
                if domain_info['type'] == 'Legacy IAM':
                    user_data.append([
                        user['username'],
                        user['email'],
                        user['status'],
                        user['created'],
                        user['user_id']
                    ])
                else:
                    user_data.append([
                        user['username'],
                        user.get('display_name', 'N/A'),
                        user['email'],
                        user['status'],
                        user['created'],
                        user['user_id']
                    ])
            
            # Different headers for different domain types
            if domain_info['type'] == 'Legacy IAM':
                headers = ['Username', 'Email', 'Status', 'Created', 'User OCID']
            else:
                headers = ['Username', 'Display Name', 'Email', 'Status', 'Created', 'User ID']
            
            print(tabulate(user_data, headers=headers, tablefmt='grid'))
        elif show_users:
            print(f"\nNo users found in {domain_info['name']}")
    
    if filter_username and not domains_to_show:
        print(f"\nNo domains contain users matching '{filter_username}'")


def main():
    parser = argparse.ArgumentParser(description='List all OCI domains and their users')
    parser.add_argument('--profile', default='DEFAULT', help='OCI config profile to use')
    parser.add_argument('--summary-only', action='store_true', help='Show only domain summary, not individual users')
    parser.add_argument('--export-csv', help='Export results to CSV file')
    parser.add_argument('--username', help='Filter results to show only users matching this username (partial match)')
    
    args = parser.parse_args()
    
    # Load OCI configuration
    config = get_oci_config(args.profile)
    
    # Initialize Identity client
    try:
        identity_client = oci.identity.IdentityClient(config)
    except Exception as e:
        print(f"Error creating identity client: {e}")
        print("Trying with instance principal for Cloud Shell...")
        try:
            # For Cloud Shell - use instance principal
            config = {}
            identity_client = oci.identity.IdentityClient(config, signer=oci.auth.signers.InstancePrincipalsSecurityTokenSigner())
        except Exception as e2:
            print(f"Error with instance principal: {e2}")
            sys.exit(1)
    
    # Get tenancy OCID
    try:
        tenancy_response = identity_client.get_tenancy(identity_client.base_client.config['tenancy'] if 'tenancy' in identity_client.base_client.config else identity_client.list_compartments(identity_client.base_client.config.get('tenancy', 'ocid1.tenancy')))
        tenancy_id = identity_client.base_client.config.get('tenancy') or 'AUTO_DETECT'
    except:
        # Fallback - try to get from environment or use a basic call
        try:
            tenancy_info = identity_client.get_tenancy()
            tenancy_id = tenancy_info.data.id
        except:
            print("Could not determine tenancy OCID")
            sys.exit(1)
    
    print(f"Scanning OCI Tenancy for Domains and Users...")
    if args.username:
        print(f"Filtering by username: '{args.username}'")
    print(f"Tenancy ID: {tenancy_id}")
    print(f"Profile: {args.profile}")
    print(f"Timestamp: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    
    domains_info = []
    
    # Get legacy users from root tenancy
    print(f"\nScanning Legacy IAM (Root Tenancy)...")
    legacy_users = get_legacy_users(identity_client, tenancy_id, args.username)
    domains_info.append({
        'name': 'Root Tenancy (Legacy IAM)',
        'type': 'Legacy IAM',
        'id': tenancy_id,
        'status': 'Active',
        'users': legacy_users
    })
    
    if args.username:
        print(f"Found {len(legacy_users)} matching legacy users")
    else:
        print(f"Found {len(legacy_users)} legacy users")
    
    # Get all identity domains
    print(f"\nScanning Identity Domains...")
    domains = get_all_domains(identity_client, tenancy_id)
    
    if domains:
        print(f"Found {len(domains)} identity domain(s)")
        
        for domain in domains:
            print(f"\nProcessing domain: {domain.display_name}")
            
            # Create Identity Domains client
            domain_client = create_identity_domains_client(config, domain.url)
            if domain_client:
                users = get_identity_domain_users(domain_client, args.username)
                if args.username:
                    print(f"Found {len(users)} matching users in {domain.display_name}")
                else:
                    print(f"Found {len(users)} users in {domain.display_name}")
            else:
                users = []
                print(f"Could not access {domain.display_name}")
            
            domains_info.append({
                'name': domain.display_name,
                'type': 'Identity Domain',
                'id': domain.id,  # Full OCID
                'url': domain.url,
                'status': domain.lifecycle_state,
                'users': users
            })
            
            # Small delay between domains
            time.sleep(0.5)
    else:
        print("No identity domains found or no access to list domains")
    
    # Print results
    print_domain_summary(domains_info, args.username)
    
    if not args.summary_only:
        print_detailed_domain_info(domains_info, show_users=True, filter_username=args.username)
    
    # Export to CSV if requested
    if args.export_csv:
        try:
            import csv
            with open(args.export_csv, 'w', newline='', encoding='utf-8') as csvfile:
                writer = csv.writer(csvfile)
                if args.username:
                    writer.writerow(['# Filtered results for username:', args.username])
                    writer.writerow([])  # Empty row
                
                writer.writerow(['Domain Name', 'Domain Type', 'Domain ID', 'Username', 'Display Name', 'Email', 'Status', 'Created', 'User ID'])
                
                for domain_info in domains_info:
                    for user in domain_info['users']:
                        writer.writerow([
                            domain_info['name'],
                            domain_info['type'],
                            domain_info['id'],  # Full OCID
                            user['username'],
                            user.get('display_name', 'N/A'),
                            user['email'],
                            user['status'],
                            user['created'],
                            user['user_id']  # Full OCID/ID
                        ])
            
            print(f"\nResults exported to: {args.export_csv}")
        except Exception as e:
            print(f"Error exporting to CSV: {e}")


if __name__ == "__main__":
    main()