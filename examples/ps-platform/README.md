# PS architecture on the Orchestrator

Resource Types, Resource Definitions and developer Score files that let a
developer deploy the PS application by themselves:

```text
Mobile -> Route 53 -> AWS WAF -> public ALB -> gateway
gateway -> internal ALB -> auth | cmn | relay          (path routes /auth/*, /cmn/*, /relay/*)
auth, cmn, relay -> Aurora MySQL (JDBC, port 43306)     (private DB subnets)
relay -> DynamoDB (VPC gateway endpoint), private S3, Firebase/WNS (NAT Gateway)
ALB access logs -> S3; Aurora error/slow query logs -> CloudWatch Logs; CloudWatch dashboards
```

The services run on **EKS** (score-k8s workloads), not ECS Fargate: the
Orchestrator renders workloads to Kubernetes only.

## What the Platform Engineer registers

| Resource Type | Definition | Module | Who declares it |
| --- | --- | --- | --- |
| `vpc` | `ps-vpc` | `modules/vpc-nat` | pulled in by references |
| `k8s-cluster` (class `eks`) | `ps-eks` | `modules/eks` (v1.0.0 content) | pulled in by references |
| `k8s-namespace` | `ps-namespace` | `modules/k8s-namespace` | pulled in by references |
| `workload` | `ps-workload` | score-k8s render bundle | every Score |
| `public-endpoint` | `ps-public-endpoint` | `modules/public-alb` | gateway Score |
| `internal-alb` | `ps-internal-alb` | `modules/internal-alb` | gateway Score (`id: internal-alb`) |
| `internal-route` | `ps-internal-route` | `modules/internal-route` | auth/cmn/relay Score |
| `mysql` | `ps-aurora-mysql` | `modules/aurora-mysql` | auth/cmn/relay Score (`id: ps-aurora`) |
| `workload-identity` | `ps-workload-identity` | `modules/workload-identity` | pulled in by S3/DynamoDB |
| `dynamodb-table` | `ps-dynamodb` | `modules/dynamodb-table` | relay Score |
| `s3-bucket` | `ps-s3` | `modules/s3-bucket` | relay Score |

[catalog.json](catalog.json) holds the exact Types and Definitions.
[register.sh](register.sh) inspects every module from Git (the server pins
commit and digest), then registers Types and Definitions through the API:

```bash
AWS_ACCOUNT=<ready AWS Driver Account key> \
EGRESS_CIDR=<executor public IPv4>/32 \
AWS_REGION=us-east-1 \
HOSTED_ZONE_ID=<optional Route 53 zone> DOMAIN_NAME=<optional api.example.com> \
ORCH_URL=http://localhost:8080 ./register.sh
```

`TYPES_ONLY=1` registers only the Types (no AWS account needed). Existing keys
are skipped; change a registered Definition in the Console.

## What the developer does

Create an Application, then add the four workloads from [score/](score/) with
their own images (replace `REGISTRY/...`), Preview and Deploy. Only the Score
is needed: VPC, EKS, namespace and the application IAM role are pulled in by
the Definitions. Deploy the gateway together with (or before) the backends: it
declares the shared internal ALB the routes attach to.

| Workload | Score resources | Environment variables |
| --- | --- | --- |
| gateway | `public-endpoint`, `internal-alb` | `BACKEND_URL`, `PUBLIC_URL` |
| auth, cmn | `internal-route`, `mysql` | `DB_URL` (JDBC), `DB_USERNAME`, `DB_PASSWORD` (Kubernetes Secret) |
| relay | `internal-route`, `mysql`, `dynamodb-table`, `s3-bucket` | DB, `DYNAMODB_TABLE`, `S3_BUCKET`, `AWS_REGION` |

Firebase/WNS credentials are application secrets: store them in the
Environment configuration (secret store), not in Score or Definitions.
AWS access (S3, DynamoDB, `cloudwatch:PutMetricData` in namespace `PS`) comes
from EKS Pod Identity on the namespace `default` ServiceAccount; use the AWS
SDK default credential chain. Mobile upload/download uses presigned URLs that
relay signs; the bucket stays private.

## Design notes and limits

- Traffic path without an in-cluster controller: each route/endpoint creates a
  NodePort Service selecting `app.kubernetes.io/name=<workload>`, an instance
  target group attached to the EKS node group Auto Scaling group, and the
  security group rules from the ALB to the cluster security group. The workload
  name comes from `${context.res.id}`, so `public-endpoint` and
  `internal-route` must be workload-private (no `id`).
- `public-alb` and `internal-route` use both the AWS and the Kubernetes
  provider in one module (AWS Driver Account + EKS cluster binding).
- `ps-eks` sets `ebs_csi_driver = true` because that also installs the EKS Pod
  Identity agent that `workload-identity` needs. The v1.0.0 EKS module has one
  fixed node; size `node_instance_type` for all four services.
- `allow_destroy = true` in the dev Definitions lets the platform cleanup remove
  Aurora (no final snapshot), DynamoDB, S3 and log buckets with their data. Set
  it to false for production Definitions.
- Verify `engine_version` exists in your region before Deploy:
  `aws rds describe-db-engine-versions --engine aurora-mysql --query 'DBEngineVersions[].EngineVersion'`.
- One NAT Gateway by default (`single_nat_gateway`); set false for one per zone.
- No Container Insights: dashboards cover the ALBs, WAF and Aurora; services
  publish their own metrics to namespace `PS`.
