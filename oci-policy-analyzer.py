#!/usr/bin/env python3
"""
OCI User Policy Analyzer
Finds all policy statements that apply to a given user by analyzing their group memberships.
"""

import oci
import sys
import re
from typing import List, Dict, Set
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
            
        except Exception as e:
            print(f"Error initializing OCI clients: {e}")
            sys.exit(1)
    
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
        """Get all compartments in the tenancy."""
        print("Fetching all compartments...")
        compartments = []
        
        try:
            # Get all compartments recursively
            response = self.identity_client.list_compartments(
                compartment_id=self.tenancy_id,
                compartment_id_in_subtree=True,
                access_level="ANY"
            )
            compartments = response.data
            print(f"Found {len(compartments)} compartments")
            
        except Exception as e:
            print(f"Error fetching compartments: {e}")
        
        return compartments
    
    def get_user_groups(self, user_id: str) -> List[oci.identity.models.Group]:
        """Get all groups that a user belongs to."""
        print(f"Fetching groups for user: {user_id}")
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
        
        # Get user's groups
        groups = self.get_user_groups(user_id)
        if not groups:
            print("No groups found for user or error occurred.")
            return
        
        group_names = {group.name for group in groups}
        
        # Get all compartments (including root)
        compartments = self.get_all_compartments()
        all_compartment_ids = [comp.id for comp in compartments] + [self.tenancy_id]
        
        print(f"\nScanning policies in {len(all_compartment_ids)} compartments...\n")
        
        # Collect all relevant policies
        all_relevant_policies = []
        
        for compartment_id in all_compartment_ids:
            policies = self.get_policies_in_compartment(compartment_id)
            relevant_policies = self.filter_policies_for_groups(policies, group_names)
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
        print("Usage: python oci_policy_analyzer.py <user_ocid>")
        print("Example: python oci_policy_analyzer.py ocid1.user.oc1..aaaaaaaa...")
        sys.exit(1)
    
    user_id = sys.argv[1]
    
    # Validate user OCID format
    if not user_id.startswith("ocid1.user."):
        print("Error: Please provide a valid user OCID (should start with 'ocid1.user.')")
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