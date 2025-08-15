#!/usr/bin/env python3
"""
OCI User Policy Analyzer
Finds all policy statements that apply to a given user by analyzing their group memberships.
Supports both Legacy IAM (full OCIDs) and Identity Domain users (short IDs).
"""

import oci
import sys
import re
from typing import List, Dict, Set, Optional, Tuple
from collections import defaultdict

class OCIPolicyAnalyzer:
    def __init__(self, config_file="~/.oci/config", profile="DEFAULT"):
        """Initialize OCI clients with config file authentication."""
        try:
            self.config = oci.config.from_file(config_file, profile)
            self.identity_client = oci.identity.IdentityClient(self.config)
            
            # Get tenancy info
            self.tenancy_id = self.config["tenancy"]
            print(f"Connected to tenancy: {self.tenancy_id}")
            
            # Cache for compartment names to avoid repeated API calls
            self.compartment_cache = {}
            # Cache for identity domains
            self.domains_cache = None
            
        except Exception as e:
            print(f"Error initializing OCI clients: {e}")
            sys.exit(1)
    
    def get_identity_domains(self) -> List[oci.identity.models.Domain]:
        """Get all identity domains in the tenancy."""
        if self.domains_cache is not None:
            return self.domains_cache
        
        try:
            print("Fetching identity domains...")
            response = self.identity_client.list_domains(compartment_id=self.tenancy_id)
            active_domains = [d for d in response.data if d.lifecycle_state == 'ACTIVE']
            print(f"Found {len(active_domains)} active identity domains")
            self.domains_cache = active_domains
            return active_domains
        except Exception as e:
            print(f"Error fetching identity domains: {e}")
            return []
    
    def detect_user_id_type(self, user_id: str) -> Tuple[str, Optional[str]]:
        """
        Detect if user_id is a Legacy IAM OCID or Identity Domain user ID.
        Returns: (type, domain_url) where type is 'legacy' or 'identity_domain'
        """
        if user_id.startswith("ocid1.user."):
            return ("legacy", None)
        
        # For Identity Domain users, we need to find which domain they belong to
        # This requires checking each domain
        domains = self.get_identity_domains()
        
        for domain in domains:
            try:
                # Try to create a client for this domain and check if user exists
                domain_client = oci.identity_domains.IdentityDomainsClient(
                    config=self.config,
                    service_endpoint=domain.url
                )
                
                # Try to get the user - if successful, they exist in this domain
                user_response = domain_client.get_user(user_id=user_id)
                if user_response.data:
                    print(f"Found user in domain: {domain.display_name}")
                    return ("identity_domain", domain.url)
                    
            except Exception:
                # User not found in this domain, continue searching
                continue
        
        # If we get here, user not found in any domain
        raise ValueError(f"User ID '{user_id}' not found in any identity domain or legacy IAM")
    
    def get_user_info_legacy(self, user_id: str) -> Dict:
        """Get user information from Legacy IAM."""
        try:
            user = self.identity_client.get_user(user_id)
            return {
                'name': user.data.name,
                'email': user.data.email,
                'id': user.data.id,
                'type': 'legacy'
            }
        except Exception as e:
            print(f"Error fetching legacy user info: {e}")
            return None
    
    def get_user_info_identity_domain(self, user_id: str, domain_url: str) -> Dict:
        """Get user information from Identity Domain."""
        try:
            domain_client = oci.identity_domains.IdentityDomainsClient(
                config=self.config,
                service_endpoint=domain_url
            )
            
            user = domain_client.get_user(user_id=user_id)
            email = user.data.emails[0].value if user.data.emails else 'N/A'
            
            return {
                'name': user.data.user_name,
                'email': email,
                'id': user.data.id,
                'type': 'identity_domain',
                'domain_url': domain_url
            }
        except Exception as e:
            print(f"Error fetching identity domain user info: {e}")
            return None
    
    def get_compartment_name(self, compartment_id: str) -> str:
        """Get compartment name from OCID, with caching."""
        if compartment_id in self.compartment_cache:
            return self.compartment_cache[compartment_id]
        
        try:
            if compartment_id == self.tenancy_id:
                name = "root"
            else:
                compartment = self.identity_client.get_compartment(compartment_id)
                name = compartment.data.name
            
            self.compartment_cache[compartment_id] = name
            return name
        except Exception as e:
            print(f"Warning: Could not resolve compartment {compartment_id}: {e}")
            return compartment_id
    
    def get_all_compartments(self) -> List[oci.identity.models.Compartment]:
        """Get all ACTIVE compartments in the tenancy."""
        print("Fetching all active compartments...")
        compartments = []
        
        try:
            # Get all compartments recursively
            response = self.identity_client.list_compartments(
                compartment_id=self.tenancy_id,
                compartment_id_in_subtree=True,
                access_level="ANY"
            )
            
            # Filter for only ACTIVE compartments
            active_compartments = [
                comp for comp in response.data 
                if comp.lifecycle_state == 'ACTIVE'
            ]
            
            compartments = active_compartments
            print(f"Found {len(compartments)} active compartments")
            
        except Exception as e:
            print(f"Error fetching compartments: {e}")
        
        return compartments
    
    def get_user_groups_legacy(self, user_id: str) -> List[oci.identity.models.Group]:
        """Get all groups that a Legacy IAM user belongs to."""
        print(f"Fetching groups for legacy user: {user_id}")
        groups = []
        
        try:
            response = self.identity_client.list_user_group_memberships(
                compartment_id=self.tenancy_id,
                user_id=user_id
            )
            
            # Get full group details
            group_ids = [membership.group_id for membership in response.data]
            for group_id in group_ids:
                group = self.identity_client.get_group(group_id)
                groups.append(group.data)
            
            print(f"User belongs to {len(groups)} groups:")
            for group in groups:
                print(f"  - {group.name} ({group.id})")
                
        except Exception as e:
            print(f"Error fetching user groups: {e}")
            return []
        
        return groups
    
    def get_user_groups_identity_domain(self, user_id: str, domain_url: str) -> List[Dict]:
        """Get all groups that an Identity Domain user belongs to."""
        print(f"Fetching groups for identity domain user: {user_id}")
        groups = []
        
        try:
            domain_client = oci.identity_domains.IdentityDomainsClient(
                config=self.config,
                service_endpoint=domain_url
            )
            
            # Get user and check groups
            user = domain_client.get_user(user_id=user_id, attributes="groups")
            
            if hasattr(user.data, 'groups') and user.data.groups:
                for group_ref in user.data.groups:
                    # Get full group details
                    try:
                        group = domain_client.get_group(group_id=group_ref.value)
                        groups.append({
                            'name': group.data.display_name,
                            'id': group.data.id,
                            'type': 'identity_domain'
                        })
                    except Exception as e:
                        print(f"Warning: Could not fetch group details for {group_ref.value}: {e}")
            
            print(f"User belongs to {len(groups)} groups:")
            for group in groups:
                print(f"  - {group['name']} ({group['id']})")
                
        except Exception as e:
            print(f"Trying alternative method to find user groups...")
            # Try alternative method - list all groups and check membership
            return self.get_identity_domain_groups_alternative(user_id, domain_url)
        
        return groups
    
    def get_identity_domain_groups_alternative(self, user_id: str, domain_url: str) -> List[Dict]:
        """Alternative method to get Identity Domain user groups by checking all groups."""
        print("Trying alternative method to find user groups...")
        groups = []
        
        try:
            domain_client = oci.identity_domains.IdentityDomainsClient(
                config=self.config,
                service_endpoint=domain_url
            )
            
            # List all groups in the domain
            all_groups_response = domain_client.list_groups()
            
            # Check each group for membership
            for group in all_groups_response.data.resources:
                try:
                    # Get group members
                    group_detail = domain_client.get_group(
                        group_id=group.id,
                        attributes="members"
                    )
                    
                    if hasattr(group_detail.data, 'members') and group_detail.data.members:
                        member_ids = [member.value for member in group_detail.data.members]
                        if user_id in member_ids:
                            groups.append({
                                'name': group.display_name,
                                'id': group.id,
                                'type': 'identity_domain'
                            })
                            
                except Exception as e:
                    print(f"Warning: Could not check group {group.display_name}: {e}")
                    continue
            
            print(f"Found {len(groups)} groups via alternative method:")
            for group in groups:
                print(f"  - {group['name']} ({group['id']})")
                
        except Exception as e:
            print(f"Error with alternative group detection: {e}")
        
        return groups
    
    def get_policies_in_compartment(self, compartment_id: str) -> List[oci.identity.models.Policy]:
        """Get all policies in a specific compartment."""
        try:
            response = self.identity_client.list_policies(compartment_id=compartment_id)
            return response.data
        except Exception as e:
            print(f"Warning: Could not fetch policies in compartment {compartment_id}: {e}")
            return []
    
    def translate_compartment_ids_in_statement(self, statement: str) -> str:
        """Replace compartment OCIDs in policy statements with human-readable names."""
        # Pattern to match compartment OCIDs in policy statements
        compartment_pattern = r'compartment\s+(ocid1\.compartment\.[a-zA-Z0-9\._-]+)'
        
        def replace_compartment(match):
            compartment_id = match.group(1)
            compartment_name = self.get_compartment_name(compartment_id)
            return f'compartment {compartment_name}'
        
        return re.sub(compartment_pattern, replace_compartment, statement, flags=re.IGNORECASE)
    
    def filter_policies_for_groups(self, policies: List[oci.identity.models.Policy], 
                                 group_names: Set[str]) -> List[tuple]:
        """Filter policies that contain statements referencing the user's groups."""
        relevant_policies = []
        
        for policy in policies:
            policy_compartment_name = self.get_compartment_name(policy.compartment_id)
            
            for statement in policy.statements:
                # Check if statement mentions any of the user's groups
                statement_lower = statement.lower()
                
                for group_name in group_names:
                    # Look for patterns like "group GroupName" or "group 'GroupName'"
                    group_patterns = [
                        f"group {group_name.lower()}",
                        f"group '{group_name.lower()}'",
                        f'group "{group_name.lower()}"'
                    ]
                    
                    if any(pattern in statement_lower for pattern in group_patterns):
                        translated_statement = self.translate_compartment_ids_in_statement(statement)
                        relevant_policies.append((
                            policy.name,
                            policy_compartment_name,
                            translated_statement
                        ))
                        break
        
        return relevant_policies
    
    def analyze_user_policies(self, user_id: str):
        """Main method to analyze all policies that apply to a user."""
        print(f"\n=== OCI Policy Analysis for User: {user_id} ===\n")
        
        # Detect user type and get user info
        try:
            user_type, domain_url = self.detect_user_id_type(user_id)
            print(f"Detected user type: {user_type}")
            
            if user_type == "legacy":
                user_info = self.get_user_info_legacy(user_id)
                groups = self.get_user_groups_legacy(user_id)
                group_names = {group.name for group in groups}
            else:  # identity_domain
                user_info = self.get_user_info_identity_domain(user_id, domain_url)
                groups = self.get_user_groups_identity_domain(user_id, domain_url)
                group_names = {group['name'] for group in groups}
            
            if user_info:
                print(f"User: {user_info['name']} ({user_info['email']})")
            
        except ValueError as e:
            print(f"Error: {e}")
            return
        except Exception as e:
            print(f"Unexpected error: {e}")
            return
        
        if not groups:
            print("No groups found for user or error occurred.")
            return
        
        # Get all active compartments (including root)
        compartments = self.get_all_compartments()
        # Add root tenancy to the list (root is always active)
        all_compartment_ids = [self.tenancy_id] + [comp.id for comp in compartments]
        
        print(f"\nScanning policies in {len(all_compartment_ids)} active compartments:")
        print(f"  - Root tenancy: {self.tenancy_id}")
        for comp in compartments:
            print(f"  - {comp.name} ({comp.lifecycle_state}): {comp.id}")
        print()
        
        # Collect all relevant policies
        all_relevant_policies = []
        
        for compartment_id in all_compartment_ids:
            compartment_name = self.get_compartment_name(compartment_id)
            print(f"Checking policies in: {compartment_name}")
            policies = self.get_policies_in_compartment(compartment_id)
            print(f"  Found {len(policies)} policies")
            relevant_policies = self.filter_policies_for_groups(policies, group_names)
            print(f"  {len(relevant_policies)} policies apply to user's groups")
            all_relevant_policies.extend(relevant_policies)
        
        # Display results
        if not all_relevant_policies:
            print("No policy statements found that apply to this user's groups.")
            return
        
        print(f"Found {len(all_relevant_policies)} policy statements that apply to this user:\n")
        print("=" * 80)
        
        # Group by policy and compartment for cleaner output
        policy_groups = defaultdict(list)
        for policy_name, compartment_name, statement in all_relevant_policies:
            policy_groups[(policy_name, compartment_name)].append(statement)
        
        for (policy_name, compartment_name), statements in policy_groups.items():
            print(f"\nPolicy: {policy_name}")
            print(f"Compartment: {compartment_name}")
            print("-" * 40)
            for statement in statements:
                print(f"  {statement}")
        
        print("\n" + "=" * 80)
        print(f"Analysis complete. Total statements: {len(all_relevant_policies)}")


def main():
    if len(sys.argv) != 2:
        print("Usage: python oci_policy_analyzer.py <user_id>")
        print("Examples:")
        print("  Legacy IAM: python oci_policy_analyzer.py ocid1.user.oc1..aaaaaaaa...")
        print("  Identity Domain: python oci_policy_analyzer.py 81a9295fd751480daec690c975029513")
        sys.exit(1)
    
    user_id = sys.argv[1]
    
    # Basic validation
    if not user_id or len(user_id) < 10:
        print("Error: Please provide a valid user ID")
        sys.exit(1)
    
    try:
        analyzer = OCIPolicyAnalyzer()
        analyzer.analyze_user_policies(user_id)
    except KeyboardInterrupt:
        print("\nAnalysis interrupted by user.")
    except Exception as e:
        print(f"Error during analysis: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()