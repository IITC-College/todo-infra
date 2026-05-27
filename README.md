# todo-infra — EKS Cluster Infrastructure

AWS account: 050752632489 | Region: eu-west-1 | Cluster: iitc-todo-cluster | EKS: 1.31

---

## Prerequisites

| Tool | Min version | Install |
|------|-------------|---------|
| AWS CLI | 2.x | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| eksctl | 0.180+ | https://eksctl.io/installation/ |
| kubectl | 1.31+ | https://kubernetes.io/docs/tasks/tools/ |
| helm | 3.x | https://helm.sh/docs/intro/install/ |

Confirm your identity before starting:

```bash
aws sts get-caller-identity
```

---

## Repository layout

```
todo-infra/
  cluster/
    eksctl-cluster.yaml          # Full eksctl ClusterConfig
  addons/
    alb-controller-values.yaml   # Helm values for AWS Load Balancer Controller
    metrics-server.yaml          # Kustomization referencing upstream manifest
    gp3-storageclass.yaml        # gp3 StorageClass + default annotation
  scripts/
    bootstrap.sh                 # Full provisioning script (idempotent)
    destroy.sh                   # Tear-down script
  README.md
```

---

## Phase 1 — Create the EKS cluster

> Cluster creation takes approximately 15 minutes.

```bash
eksctl create cluster -f cluster/eksctl-cluster.yaml
```

eksctl will:
- Create the VPC, subnets, and security groups via CloudFormation
- Launch 2x t3.medium managed nodes (ng-main)
- Enable OIDC for IRSA
- Create IAM service accounts for the ALB controller and EBS CSI driver
- Install vpc-cni, coredns, kube-proxy, and aws-ebs-csi-driver as managed addons

Verify nodes are ready:

```bash
aws eks update-kubeconfig --name iitc-todo-cluster --region eu-west-1
kubectl get nodes
```

---

## Phase 2 — Install AWS Load Balancer Controller

Resolve the VPC ID:

```bash
VPC_ID=$(aws eks describe-cluster \
  --name iitc-todo-cluster \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)
echo $VPC_ID
```

Edit `addons/alb-controller-values.yaml` and replace `<VPC_ID>` with the value above, then install:

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm upgrade --install aws-load-balancer-controller \
  eks/aws-load-balancer-controller \
  -n kube-system \
  -f addons/alb-controller-values.yaml \
  --wait --timeout 5m
```

Verify:

```bash
kubectl get deployment aws-load-balancer-controller -n kube-system
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

---

## Phase 3 — Install metrics-server

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

Verify:

```bash
kubectl get deployment metrics-server -n kube-system
kubectl top nodes
```

---

## Phase 4 — Configure gp3 StorageClass (default)

Apply the gp3 StorageClass and demote gp2:

```bash
kubectl apply -f addons/gp3-storageclass.yaml

kubectl patch storageclass gp2 \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

Verify (gp3 must show `(default)`, gp2 must not):

```bash
kubectl get storageclass
```

---

## Phase 5 — Full automated bootstrap (phases 1-4 in one command)

The bootstrap script is idempotent and handles all phases above:

```bash
chmod +x scripts/bootstrap.sh
./scripts/bootstrap.sh
```

---

## Destroying the cluster

> This deletes all application resources, load balancers, PVCs, EBS volumes (reclaimPolicy:Retain volumes are NOT deleted), and the cluster itself.

```bash
chmod +x scripts/destroy.sh
./scripts/destroy.sh
```

The destroy script:
1. Deletes all Ingress objects (triggers ALB deprovisioning)
2. Waits 30s for ALBs to be removed by the controller
3. Uninstalls the ALB controller Helm release
4. Deletes all workloads in user namespaces
5. Deletes all PVCs and remaining PVs
6. Removes the gp3 StorageClass
7. Runs `eksctl delete cluster --wait`

---

## Notes

- The IAM service account `aws-load-balancer-controller` uses `ElasticLoadBalancingFullAccess` for course convenience. Production clusters should use the scoped `AWSLoadBalancerControllerIAMPolicy` from the upstream AWS documentation.
- The `aws-ebs-csi-driver` addon service account ARN in `eksctl-cluster.yaml` is constructed from the eksctl naming convention. eksctl creates this role automatically during cluster creation.
- `gp3` StorageClass uses `reclaimPolicy: Retain` — EBS volumes survive PVC deletion. Change to `Delete` for stateless/dev workloads to avoid orphaned volumes.
