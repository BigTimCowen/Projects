This repository has handy scripts to simplify working with OCI and GPU Engineering aspects.

For downloading GPU Images quickly to the POC Compartment, use: GPUImager.sh

To check limits related to GPU needed service for SLURM deployments: limitchecks.sh

To create templated POC environments and clean up POC environments: oci-hpc-poc-environment.sh

To analyze Users with their ocid and the policies that are associated to them in all domains: oci-policy-analyzer.py

A simple service limits script that is being phased out in favor of limitcheck.sh: servicelimits.sh

To extract all users in all domains (default and nondefault)
users_in_domains.py
