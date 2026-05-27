# IAM Setup for GitHub Actions OIDC (Keyless CI/CD)

Account: 050752632489 | Region: eu-west-1

---

## Step 1 — Create the GitHub OIDC Provider (one-time per AWS account)

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
  --region eu-west-1
```

Expected ARN: `arn:aws:iam::050752632489:oidc-provider/token.actions.githubusercontent.com`

Skip this step if the provider already exists (check: `aws iam list-open-id-connect-providers`).

---

## Step 2 — Create the IAM Role with the Trust Policy

```bash
aws iam create-role \
  --role-name GHActionsTodoDeploy \
  --assume-role-policy-document file://github-oidc-trust-policy.json
```

The trust policy (`github-oidc-trust-policy.json`) allows only pushes to `main` in any `IITC-College/todo-*` repository to assume this role.

---

## Step 3 — Create and Attach the Permissions Policy

```bash
aws iam create-policy \
  --policy-name GHActionsTodoECREKSPolicy \
  --policy-document file://github-actions-ecr-eks-policy.json
```

```bash
aws iam attach-role-policy \
  --role-name GHActionsTodoDeploy \
  --policy-arn arn:aws:iam::050752632489:policy/GHActionsTodoECREKSPolicy
```

---

## Step 4 — Grant the Role Access to EKS (aws-auth ConfigMap)

```bash
kubectl edit cm aws-auth -n kube-system
```

Add the following entry under `mapRoles:`:

```yaml
- rolearn: arn:aws:iam::050752632489:role/GHActionsTodoDeploy
  username: github-actions
  groups:
    - system:masters
```

WARNING: `system:masters` is cluster-admin. Acceptable for a course environment.
In production, use a scoped ClusterRole limited to `get/patch` on the specific deployments in `todo-app`.

---

## Step 5 — Retrieve the Role ARN

```bash
aws iam get-role --role-name GHActionsTodoDeploy --query "Role.Arn" --output text
```

Output: `arn:aws:iam::050752632489:role/GHActionsTodoDeploy`

---

## Step 6 — Add Secrets to Each GitHub Repo

Go to each repo (todo-frontend, todo-backend, todo-database):
Settings > Secrets and variables > Actions > New repository secret

| Secret name      | Value                                                      |
|------------------|------------------------------------------------------------|
| AWS_ROLE_ARN     | arn:aws:iam::050752632489:role/GHActionsTodoDeploy         |

The workflows hard-code `AWS_REGION=eu-west-1` and `EKS_CLUSTER_NAME=iitc-todo-cluster`.
Add them as secrets too if you prefer to keep values out of the workflow YAML.

---

## ECR Repository URIs

| Repo            | URI                                                              |
|-----------------|------------------------------------------------------------------|
| todo-frontend   | 050752632489.dkr.ecr.eu-west-1.amazonaws.com/todo-frontend      |
| todo-backend    | 050752632489.dkr.ecr.eu-west-1.amazonaws.com/todo-backend       |
| todo-database   | 050752632489.dkr.ecr.eu-west-1.amazonaws.com/todo-database      |
