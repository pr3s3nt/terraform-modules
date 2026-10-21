# Terraform modules for Orchestrator

Reusable module sources for [pr3s3nt/poc](https://github.com/pr3s3nt/poc).
Initial release copies the seven packaged modules unchanged from product commit
`99c45bed1cc7ea819e87ebe3f5753c6f00fc79d2` (packaged release `v4-2026.10.15`).

## Use in Resource Definitions

Select a Resource Type, then use the default **Thêm từ Git** source:

- Git HTTPS URL: `https://github.com/pr3s3nt/terraform-modules.git`
- Module directory: choose a path from the table below.
- Tag or commit: `v1.0.0` (inspection resolves it to a full immutable commit).

Click **Kiểm tra module**, configure mappings/inputs and provider bindings, then
save the Definition. Inspecting or saving a Definition does not deploy resources.
The platform computes the content digest; do not enter it by hand.

| Module directory | Resource Type | Provider |
| --- | --- | --- |
| `modules/vpc` | `vpc` | AWS |
| `modules/eks` | `k8s-cluster` | AWS |
| `modules/aurora` | `postgres` | AWS |
| `modules/elasticache` | `redis` | AWS |
| `modules/k8s-namespace` | `k8s-namespace` | Kubernetes |
| `modules/redis-k8s` | `redis` | Kubernetes |
| `modules/postgres-k8s` | `postgres` | Kubernetes |

These modules use the Orchestrator executor contract for credentials, generated
secrets, ownership and resource lifecycle. AWS definitions select a ready Driver
Account and an explicit region. Kubernetes consumers reference a matched cluster
resource. Do not supply raw credentials/passwords in Definition inputs.

The originating release pins Terraform 1.9.8, hashicorp/aws 6.60.0 and
hashicorp/kubernetes 2.38.0. Provider constraints and module input validation are
in each main.tf; the platform release supplies exact provider pins/lock data.
A Git inspection validates the module contract; it does not establish live
provider readiness or authorize deployment.

## Releases

Publish new changes under a new tag; do not move an existing release tag.
Definitions and retained execution state keep their original commit and digest.
The product retains packaged module snapshots for existing pins and cleanup.
