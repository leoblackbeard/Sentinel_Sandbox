# Rapyd Sentinel — Split Architecture PoC

Two isolated AWS VPCs, one EKS cluster in each, connected privately through VPC peering. A public NGINX proxy in the **gateway** cluster forwards requests to an internal service in the **backend** cluster, which is never exposed to the internet. Everything is provisioned and deployed by GitHub Actions.

```
curl http://<gateway NLB hostname>
Hello from backend
```

Region: `eu-central-1` · AZs: `eu-central-1a`, `eu-central-1b` · Kubernetes 1.31 · Terraform 1.10.3

---

## Architecture

```mermaid
flowchart LR
    U[Internet client] -->|TCP 80| PNLB

    subgraph GW["vpc-gateway 10.10.0.0/16"]
        PNLB["Public NLB<br/>public subnets 1a + 1b"]
        NGX["NGINX proxy pods<br/>private subnets 1a + 1b<br/>(eks-gateway)"]
        PNLB --> NGX
    end

    subgraph BE["vpc-backend 10.20.0.0/16"]
        INLB["Internal NLB<br/>private subnets 1a + 1b<br/>source: 10.10.0.0/16 only"]
        APP["http-echo pods<br/>'Hello from backend'<br/>(eks-backend)"]
        INLB --> APP
    end

    NGX -->|"TCP 8080 over VPC peering"| INLB
```

| Component | vpc-gateway | vpc-backend |
| --- | --- | --- |
| VPC CIDR | 10.10.0.0/16 | 10.20.0.0/16 |
| Private subnets (EKS nodes, pods) | 10.10.10.0/24 (1a), 10.10.11.0/24 (1b) | 10.20.10.0/24 (1a), 10.20.11.0/24 (1b) |
| Public subnets (NAT, public NLB) | 10.10.0.0/24 (1a), 10.10.1.0/24 (1b) | 10.20.0.0/24 (1a), 10.20.1.0/24 (1b) |
| NAT Gateway | 1 (in 1a) | 1 (in 1a) |
| EKS cluster | `eks-gateway`, 2 × t3.medium | `eks-backend`, 2 × t3.medium |
| Workload | NGINX reverse proxy, 2 replicas | `hashicorp/http-echo`, 2 replicas |
| Exposure | Internet-facing NLB, port 80 | Internal NLB, port 8080 |

**No public EC2 instances.** Worker nodes live only in private subnets (`map_public_ip_on_launch = false`). The only public endpoints are managed services: the NAT Gateways and the gateway NLB.

---

## Repository layout

```
terraform/
  bootstrap/              # one-off: GitHub OIDC deploy role (see "Limitations")
  environments/sandbox/   # root module: wires the modules together
  modules/
    vpc/                  # VPC, subnets, IGW, NAT, route tables, ELB subnet tags
    peering/              # VPC peering + routes in both private route tables
    eks/                  # cluster, node group, IAM roles, access entries,
                          # Pod Identity + IAM role for the AWS LB Controller
k8s/
  backend/                # namespace, http-echo Deployment, internal NLB Service
  gateway/                # namespace, NGINX ConfigMap (templated), Deployment, public NLB Service
scripts/                  # helpers used by the workflows
.github/workflows/
  deploy.yml              # main pipeline (push to main)
  diagnose.yml            # manual: read-only health check of the whole path
  oidc-debug.yml          # manual: OIDC federation troubleshooting
  destroy.yml             # manual, typed confirmation: tear everything down
```

### Terraform modules

| Module | Key inputs | Key outputs |
| --- | --- | --- |
| `vpc` | `name_prefix`, `vpc_cidr`, `azs`, `public_subnet_cidrs`, `private_subnet_cidrs`, `tags` | `vpc_id`, `vpc_cidr`, `private_subnet_ids`, `public_subnet_ids`, `private_route_table_id`, `nat_gateway_id` |
| `peering` | `requester_vpc_id`, `accepter_vpc_id`, both CIDRs, both private route table IDs | `peering_connection_id` |
| `eks` | `cluster_name`, `cluster_version`, `vpc_id`, `private_subnet_ids`, node sizing, `allowed_peer_cidr_blocks`, `allowed_peer_port` | `cluster_name`, `cluster_endpoint`, `cluster_ca_certificate`, `node_role_arn` |

State is stored remotely in Terraform Cloud (organization `sentinel-leoblackbeard`, workspace `sentinel-sandbox`).

---

## How to clone and run

### Prerequisites

- An AWS account and IAM credentials with the permissions provided for this challenge.
- A Terraform Cloud organization/workspace and an API token.
- GitHub repository secrets:

| Secret | Purpose |
| --- | --- |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | AWS access for the pipeline |
| `TF_API_TOKEN` | Terraform Cloud remote state |
| `AWS_ROLE_ARN` | OIDC deploy role (only for `oidc-debug.yml`; see Limitations) |

### Deploy

```bash
git clone https://github.com/leoblackbeard/Sentinel_Sandbox.git
cd Sentinel_Sandbox
# make a change, then:
git push origin main
```

Every push to `main` runs the full pipeline. It can also be started manually from **Actions → Sentinel Deploy → Run workflow**. Terraform is never applied from a local machine (the one exception is the bootstrap role; see Limitations).

### Verify

The `validate-e2e` job does this automatically. Manually:

```bash
HOST=$(aws elbv2 describe-load-balancers --names sentinel-gateway-nlb \
  --query 'LoadBalancers[0].DNSName' --output text)
curl http://$HOST        # -> Hello from backend
```

### Tear down

Run **Actions → Sentinel Destroy → Run workflow** and type `destroy-sentinel`. It deletes the Kubernetes namespaces first, so the AWS Load Balancer Controller removes the NLBs and their security groups, waits for them to disappear, and then runs `terraform destroy`. The reverse order would leave controller-owned resources inside the VPCs and block their deletion. To rebuild from scratch, run **Sentinel Deploy → Run workflow**. With the challenge permissions, the two LB Controller IAM roles and their inline policies cannot be deleted (`iam:DeleteRolePolicy` is not granted): the destroy run removes everything else and fails on those two, which stay in state and are reused by the next deploy.

For a full read-only health report (NLB AZs, target health, security groups, routes, in-pod tests), run **Actions → Diagnose e2e → Run workflow** (~1 minute).

---

## Networking between the VPCs and clusters

1. **Non-overlapping CIDRs** (10.10.0.0/16 and 10.20.0.0/16), a prerequisite for peering.
2. **VPC peering** (`modules/peering`), same account and region, `auto_accept = true`. Traffic stays on the AWS backbone and never touches the internet.
3. **Routes.** Each VPC's private route table has `0.0.0.0/0 → NAT Gateway` plus `<other VPC CIDR> → peering connection`. Pods use the VPC CNI, so pod IPs are VPC IPs and are routed like any other address.
4. **Subnet tags** let the AWS Load Balancer Controller place load balancers: `kubernetes.io/role/elb` on public subnets and `kubernetes.io/role/internal-elb` on private subnets.

## How the proxy reaches the backend

1. A client calls the gateway NLB hostname on port 80. The NLB is `internet-facing`, spans both public subnets, has cross-zone load balancing enabled, and forwards to NGINX pod IPs (`nlb-target-type: ip`).
2. NGINX runs `proxy_pass http://<internal NLB hostname>:8080`. The pipeline injects the hostname into the ConfigMap with `envsubst` after the backend NLB is provisioned.
3. The internal NLB hostname resolves to private 10.20.x.x addresses. The gateway's private route table sends 10.20.0.0/16 through the peering connection.
4. The internal NLB accepts the connection only from 10.10.0.0/16 and forwards it to the http-echo pods, which answer `Hello from backend`.
5. The reply follows the reverse route (backend private route table: 10.10.0.0/16 → peering).

### Security groups: the backend accepts traffic only from the gateway VPC

| Layer | Rule |
| --- | --- |
| Backend NLB (internal) | Scheme `internal`: no public address at all |
| Backend NLB security group | Ingress TCP 8080 **only from 10.10.0.0/16**, via `loadBalancerSourceRanges` in `k8s/backend/02-service.yaml` (by default an internal NLB only allows its own VPC) |
| Backend cluster security group | Ingress TCP 8080 from the NLB security group (managed by the controller) and from 10.10.0.0/16 (Terraform, `allowed_peer_cidr_blocks`) |
| Gateway NLB security group | Ingress TCP 80 from 0.0.0.0/0, because it is the public entry point |

### AWS Load Balancer Controller

Both clusters run the AWS Load Balancer Controller, which turns `type: LoadBalancer` Services into NLBs.

- **Permissions** come from **EKS Pod Identity**. Terraform creates the `eks-pod-identity-agent` add-on, the `eks-<cluster>-lbc-role` IAM role (inline policy, upstream `iam_policy.json`), and the association with `kube-system/aws-load-balancer-controller`.
- Node-role credentials are not an option on AL2023, because the IMDSv2 hop limit is 1 and pods cannot reach it. IRSA would need an IAM OIDC provider per cluster.
- **Installation**: `scripts/install-lbc.sh` installs the Helm chart with explicit `clusterName`, `region` and `vpcId`, and with `keepTLSSecret=true`.

---

## CI/CD pipeline (`.github/workflows/deploy.yml`)

Trigger: `push` to `main` (and `workflow_dispatch`). A `concurrency` group prevents two applies from running at the same time.

| Job | Steps |
| --- | --- |
| `lint` | `tflint --recursive` over every module with the recommended preset (`.tflint.hcl`); the pipeline stops here on any finding |
| `terraform` | `init` → `validate` → `plan -out=tfplan` → `apply tfplan` → export cluster names and VPC IDs as job outputs |
| `deploy-backend` | kubeconfig → install/upgrade LB Controller → `kubectl apply --dry-run=server` on `k8s/backend/` → apply → wait for rollout → wait for the internal NLB hostname |
| `deploy-gateway` | kubeconfig → install/upgrade LB Controller → render NGINX ConfigMap with the backend hostname → `kubectl apply --dry-run=server` on the rendered manifests → apply `k8s/gateway/` → restart NGINX only if its ConfigMap changed → wait until the pods are healthy in the NLB → wait for the public NLB hostname |
| `validate-e2e` | up to 40 × `curl` the public NLB, expecting `Hello from backend`, logging live target health on every attempt. On failure, `scripts/diagnose-e2e.sh` dumps NLB AZs, target health, security groups and routes, and tests each leg from inside an NGINX pod |

Both namespaces carry the label `elbv2.k8s.aws/pod-readiness-gate-inject: enabled`. The controller then adds a readiness gate to every pod: a pod only counts as Ready once the NLB reports it healthy, so `kubectl rollout status` waits for real traffic and a rollout never removes old pods before the new ones are serving.

Values flow between jobs through job `outputs`, because each job runs on a fresh runner.

---

## Trade-offs and limitations

### Decisions made for the time limit

| Decision | Why | Cost / risk | Production alternative |
| --- | --- | --- | --- |
| One NAT Gateway per VPC | Half the NAT cost; meets the requirement | Losing AZ 1a removes outbound internet for nodes in 1b | One NAT per AZ |
| VPC peering | Simple, no hourly charge | Does not scale to many VPCs; non-transitive | Transit Gateway, or PrivateLink for service-level exposure |
| Backend hostname injected with `envsubst` | No shared DNS or mesh needed | A recreated backend NLB requires redeploying the gateway | Route 53 private hosted zone with a stable name |
| Public EKS API endpoint | GitHub-hosted runners must reach `kubectl` | Larger attack surface | Private endpoint + self-hosted runners in the VPC |
| Plan and apply in the same run | Fast iteration | No human review of the plan | Plan on PR, apply on merge with a protected environment |
| Static AWS keys in CI | The OIDC role's trust policy cannot be corrected with the granted permissions (below) | Long-lived credentials | GitHub OIDC federation |

### Permission constraints encountered

| Constraint | Impact | Workaround applied | In a real environment |
| --- | --- | --- | --- |
| `iam:CreatePolicy` denied | No customer-managed policies | Inline policies on the `eks-*` roles | Versioned managed policies owned by a platform team |
| Only `eks-*` / `sentinel-*` roles can be created or passed | Role names are constrained | `eks-<cluster>-{cluster,node,lbc}-role`, `sentinel-leoblackbeard-gha-deploy` | Same; it is a sensible guardrail |
| `iam:DeleteRolePolicy` denied on `eks-*` roles | `terraform destroy` cannot remove the LB Controller roles' inline policies, so `eks-eks-{gateway,backend}-lbc-role` survive a teardown | They stay in Terraform state and are reused by the next deploy; everything else is destroyed and recreated | Grant the delete counterpart of every create permission, or attach managed policies instead of inline ones |
| `iam:UpdateAssumeRolePolicy` denied on `sentinel-*` roles | The OIDC role's trust policy cannot be fixed after creation, so OIDC stays unusable | Static IAM user keys stored as GitHub secrets | Have the platform team apply the corrected trust policy, then remove the static keys |

### GitHub OIDC (bonus): root cause found, fix blocked by permissions

The OIDC plumbing is in place: the GitHub OIDC provider exists in the account, the role `sentinel-leoblackbeard-gha-deploy` exists with scoped permissions and an EKS access entry, and `AWS_ROLE_ARN` points to it. `AssumeRoleWithWebIdentity` still returned `AccessDenied`, so the pipeline uses static IAM user keys.

**Root cause.** `oidc-debug.yml` decodes the job's token. GitHub issues the subject with immutable owner and repository IDs:

```
sub = repo:leoblackbeard@316173717/Sentinel_Sandbox@1412442294:ref:refs/heads/main
```

The trust policy expected `repo:leoblackbeard/Sentinel_Sandbox:*`, so the condition never matched.

**Fix (in code, not applied).** `terraform/bootstrap/main.tf` now accepts both subject formats. Pinning the numeric IDs is also safer: a deleted and re-created repository with the same name cannot inherit the role. Applying it failed with:

```
not authorized to perform: iam:UpdateAssumeRolePolicy on resource: role sentinel-leoblackbeard-gha-deploy
```

Per the challenge rules, I did not work around this (for example by deleting and re-creating the role). In a real environment I would ask the platform team to apply the corrected trust policy, or to grant `iam:UpdateAssumeRolePolicy` on `sentinel-*` roles. Then I would switch the workflows to `role-to-assume` and delete the static keys; that change is a few lines per job.

### Local applies (honest disclosure)

`terraform/bootstrap` creates the OIDC deploy role that the pipeline would assume, so it cannot be applied by that same pipeline (chicken-and-egg). It was applied from a local machine on 2026-10-10 to create the role and on 2026-10-11 to extend its policy for the LB Controller roles. A third apply on 2026-10-11, to fix the trust policy, was denied (above) and changed nothing. Everything under `terraform/environments/` is applied only by GitHub Actions.

### Issues found and fixed along the way

- **Services stuck in `<pending>`**: the manifests target the AWS Load Balancer Controller (`aws-load-balancer-type: external`), which was not installed. Fixed by installing it with Pod Identity.
- **Public NLB in a single AZ**: with only one public subnet, NGINX pods in the other AZ were `Target.NotInUse`. A second public subnet was added; `moved` blocks kept the existing subnet and NAT intact. The controller keeps an existing NLB's subnets unless the `aws-load-balancer-subnets` annotation is set, so both subnets are now pinned explicitly.
- **Controller webhook certificate rotated on every `helm upgrade`** (`x509: certificate signed by unknown authority`), which stalled target registration. Fixed with `keepTLSSecret=true`.
- **Intermittent e2e timeouts after green deploys**: every run restarted NGINX (new pod IPs) and the controller, so the public NLB had to re-register targets while `validate-e2e` was already probing it. Fixed by restarting NGINX only when its config changes and by pod readiness gates, so the deploy job finishes only when the NLB has healthy targets.

---

## What I would add next

- **TLS** on the public NLB (ACM certificate, TLS listener) and HTTPS redirect.
- **OIDC federation** in CI instead of static keys.
- **Observability**: CloudWatch Container Insights or Prometheus + Grafana, NLB and VPC Flow Logs, alarms on unhealthy targets.
- **NetworkPolicies** inside each cluster (e.g. only the NGINX pods may egress to 10.20.0.0/16).
- **Service mesh / mTLS** between clusters (or PrivateLink) for zero-trust service-to-service traffic.
- **HA networking**: one NAT Gateway per AZ.
- **Pipeline hardening**: plan on pull requests, manual approval before apply, Helm chart version pinning, reusable composite actions.
- **Autoscaling**: Cluster Autoscaler or Karpenter, and HPA on the proxy.
