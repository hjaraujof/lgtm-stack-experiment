# Runbook: create the bootstrap publish role

**When you need this:** once, before the first `publish-bootstrap` run. Also
when the GitHub repository moves, because the trust policy pins the repo path.

**What it is:** an IAM role that GitHub Actions assumes through OIDC to write
the boot archive into the bootstrap bucket.

## Why this role is created out of band

The bootstrap bucket holds what the instance **executes at boot**. Write access
to it is therefore equivalent to code execution on the host.

`bootstrap.tf` deliberately does not create this role. If the stack's own
Terraform could grant write access to its own boot source, then anyone who can
run that Terraform can take over the instance without touching the instance.
Splitting the two means compromising the deploy pipeline is not the same as
compromising the boot chain.

## Prerequisites

- An IAM OIDC identity provider for `token.actions.githubusercontent.com` in
  the account. Create it once per account, not once per role.
- The bootstrap bucket exists. Run `terraform apply` first and read the
  `lgtm_bootstrap_bucket` output.

## Steps

1. Get the bucket name.

   ```bash
   BUCKET=$(terraform output -raw lgtm_bootstrap_bucket)
   ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
   ```

2. Write the trust policy. Replace `YOUR-ORG/YOUR-REPO`.

   > **The `sub` condition is the security boundary.** With `repo:*` any
   > repository in GitHub could assume this role. Pin the repository, and pin
   > the ref if you can.

   ```bash
   cat > /tmp/trust.json <<EOF
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": { "Federated": "arn:aws:iam::$ACCOUNT:oidc-provider/token.actions.githubusercontent.com" },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {
         "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
         "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:YOUR-ORG/YOUR-REPO:ref:refs/heads/main" }
       }
     }]
   }
   EOF
   ```

3. Write the permission policy. Two objects, `PutObject` only.

   ```bash
   cat > /tmp/perms.json <<EOF
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Sid": "PublishBootstrapArchive",
       "Effect": "Allow",
       "Action": ["s3:PutObject"],
       "Resource": [
         "arn:aws:s3:::$BUCKET/lgtm_stack.tar.gz",
         "arn:aws:s3:::$BUCKET/lgtm_stack.sha256"
       ]
     }]
   }
   EOF
   ```

   Do not add `s3:DeleteObject`, and do not widen the resource to `/*`. The
   instance reads exactly these two keys, so nothing else needs writing.

4. Create the role and attach the policy.

   ```bash
   aws iam create-role \
     --role-name GitHubActionsLgtmPublish \
     --assume-role-policy-document file:///tmp/trust.json

   aws iam put-role-policy \
     --role-name GitHubActionsLgtmPublish \
     --policy-name publish-bootstrap-archive \
     --policy-document file:///tmp/perms.json
   ```

5. Set the two repository variables in GitHub, under
   Settings → Secrets and variables → Actions → Variables.

   ```bash
   gh variable set AWS_PUBLISH_ROLE_ARN --body "arn:aws:iam::$ACCOUNT:role/GitHubActionsLgtmPublish"
   gh variable set BOOTSTRAP_BUCKET     --body "$BUCKET"
   ```

6. Publish once by hand, so the instance has something to boot from.

   ```bash
   gh workflow run publish-bootstrap
   gh run watch
   ```

7. Confirm both objects exist.

   ```bash
   aws s3 ls "s3://$BUCKET/"
   # expect: lgtm_stack.sha256 and lgtm_stack.tar.gz
   ```

   ```bash
   rm -f /tmp/trust.json /tmp/perms.json
   ```

## Verify the boot path end to end

Replace the instance and read the setup log.

> **`terraform apply` on a changed `user_data` REPLACES the instance.** That
> destroys the root volume. Trace and metric blocks live in S3 and survive;
> anything only on the root volume does not.

```bash
aws ssm start-session --target "$INSTANCE_ID"
sudo grep -E 'Fetching stack archive|sha256|Stack fetch exit code' /tmp/git-clone-setup.log
```

Expect `Stack fetch exit code: 0`. A checksum failure prints
`FATAL: bootstrap archive checksum mismatch` and starts nothing — which is the
intended behaviour, not a bug to work around.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The `sub` condition does not match. Check org, repo and branch spelling against the actual workflow run. |
| `An error occurred (AccessDenied) ... s3:PutObject` | The bucket name in `BOOTSTRAP_BUCKET` does not match the resource ARNs in the permission policy. |
| Boot logs show `checksum mismatch` on every boot | A partial or interrupted upload. Re-run `publish-bootstrap`. |
| Boot logs show `AccessDenied` on `aws s3 cp` | `aws_iam_role_policy.lgtm_bootstrap_read` in `bootstrap.tf` was not applied. |
| The workflow logs `AWS_PUBLISH_ROLE_ARN ... not set; skipping` | Step 5 was not done, or the variables were set as secrets rather than variables. |
