# NimbusCart — REPORT

## Stack declaration

- **API framework:** Flask (`app/api/app.py`), served by gunicorn in the container.
- **Database engine:** PostgreSQL 16 (via `psycopg2`).

> **A note on how this report was produced:** the assistant environment used to write this
> project has no network access (no Docker daemon, no AWS credentials, no internet). The
> code in this repo — frontend, API, Dockerfile, and every Terraform file — is complete and
> was checked for syntax (`python -m py_compile` on the API, manual review of the HCL), but
> it has **not** been run end-to-end against real AWS or a real local Postgres container.
> The two demonstration items below (Task A's manual VPC-peering exercise) describe exactly
> what to run and what you should observe; you'll need to execute them yourself in the AWS
> console / CLI and paste your actual terminal output and screenshots in their place before
> submitting, since this environment cannot produce genuine AWS output.

---

## Task A — Manual VPC Peering Exercise

### Setup performed (manual, in the console, torn down afterward)

Two throwaway VPCs, `test-vpc-a` (10.0.0.0/16, one subnet, one EC2 instance) and
`test-vpc-b` (10.1.0.0/16, one subnet, one EC2 instance), peered via
`pcx-xxxxxxxx`, `auto_accept`. A route `10.1.0.0/16 -> pcx-xxxxxxxx` was added to
`test-vpc-a`'s route table. Connectivity was tested with `ping` and `nc` between the
two instances' private IPs (security groups opened for ICMP/TCP between the two CIDRs
for the test).

### Q1. What happens if you forget the return route in data-vpc's route table?

**What breaks, and in which direction:** the *request* succeeds, the *response* does not.

Concretely: from the instance in `test-vpc-a`, `ping <vpc-b-private-ip>` or
`curl <vpc-b-instance>:port` hangs and times out. But if you instead SSH into the
`test-vpc-b` instance and run `tcpdump -i eth0 icmp` (or watch a listener on the test
port) while the ping runs, you **do** see the ICMP echo request arrive. The packet gets
across the peering connection just fine on the way in, because `test-vpc-a`'s route
table has the `10.1.0.0/16 -> pcx-xxxxxxxx` route. But `test-vpc-b`'s route table has
no route back to `10.0.0.0/16`, so when the OS in `test-vpc-b` tries to send the ICMP
echo *reply*, it has no route for that destination and drops it (or sends it out
whatever the default route is, which isn't the peering connection). The client in
`test-vpc-a` never sees a reply and the ping simply times out with 100% packet loss.

**Demonstrated failure (fill in with your actual output):**
```
$ ping -c 4 10.1.1.50
PING 10.1.1.50: 56 data bytes
--- 10.1.1.50 ping statistics ---
4 packets transmitted, 0 packets received, 100% packet loss
```
```
# on the 10.1.1.50 instance, tcpdump shows the request arriving:
$ sudo tcpdump -i eth0 icmp
IP 10.0.1.20 > 10.1.1.50: ICMP echo request, id 1, seq 1, length 64
# ...but nothing ever leaves 10.1.1.50 destined back to 10.0.0.0/16
```

**Direction that breaks:** the peering connection itself is symmetric (it's a single
bidirectional pipe), but **routing is per-VPC and independent in each direction**.
Here it's specifically the `data-vpc -> app-vpc` direction that's missing, so traffic
*initiated from* `app-vpc` reaches `data-vpc` but nothing *from* `data-vpc` (including
replies to that traffic) can find its way back. This is why `main.tf` in this repo adds
both `aws_route.private_to_data` **and** `aws_route.data_to_app` — one route per route
table, one in each VPC.

### Q2. Why does the DB subnet need no NAT Gateway at all, even though it must be reachable from another VPC? "Reachable from" vs "can initiate connections to."

These are two different capabilities and VPC peering / route tables only ever grant
the first one:

- **"Reachable from"** means another VPC can address this subnet directly (has a route
  to its CIDR and, if security allows, can open a connection to it). The DB subnet
  *is* reachable from `app-vpc` purely through the **peering route** —
  `10.0.0.0/16 -> pcx-xxxxxxxx` in `data-vpc`'s route table plus the `db-sg` ingress
  rule that allows the DB port from `app-sg`. No NAT Gateway is involved in this at
  all; NAT Gateways have nothing to do with *inbound* reachability from a peered VPC.

- **"Can initiate connections to"** (specifically, to the public internet) is what a
  NAT Gateway provides: it lets instances in a private subnet with no public IP
  originate outbound connections to `0.0.0.0/0` (e.g., to download OS patches) while
  remaining unaddressable from the internet.

The DB subnet has zero legitimate reason to initiate anything to the internet — RDS
doesn't need to `curl` external endpoints, download packages, or reach ECR. Its only
network relationship is: **accept inbound connections from the app tier**, over the
peering link, on the DB port. That's a pure "reachable from a specific peer" need,
which is satisfied entirely by peering routes + security groups. Adding a NAT Gateway
here would only add cost and an unnecessary internet-egress path with no matching
requirement, so `aws_route_table.data_rt` in this repo has no `0.0.0.0/0` route of any
kind — no IGW, no NAT — only the peering return route.

---

## Task C — Conceptual Questions

### 1. Why must the DB subnet group span multiple AZs even for a single-AZ RDS instance? What breaks if it doesn't?

`aws_db_subnet_group` is a *capability declaration*, not a placement guarantee — it
tells RDS "here is the full set of subnets you're allowed to use if you ever need to
place or move an instance." RDS enforces a hard requirement of at least two subnets in
at least two different AZs for any subnet group, even when `multi_az = false` and the
instance itself only ever runs in one AZ.

What breaks if the group only has one AZ: first, `terraform apply` / the RDS API
outright rejects the subnet group creation ("DB Subnet Group doesn't meet Availability
Zone coverage requirement"), so you never even get to deploy. Even if you engineer
around that, single-AZ coverage means you've architecturally boxed yourself out of two
things you'll almost certainly want later without a rebuild: (a) *failover* — turning
on `multi_az = true` for a standby replica needs a second AZ's subnet available
immediately, and (b) AWS-initiated *maintenance/recovery* — if the AZ hosting your
instance has a problem, RDS may need to relaunch the instance in a different AZ using
the subnet group, and with only one AZ present there's nowhere for it to go. The
two-AZ requirement exists precisely so a subnet group is always "failover-ready" even
if you're not paying for failover today.

### 2. Contrast VPC Peering with a Transit Gateway for this use case. At what point would you recommend switching?

**VPC Peering** (used here): a direct, point-to-point, non-transitive connection
between exactly two VPCs. Each side manages its own routes to the other's CIDR. It's
free of any additional per-hour infrastructure cost, has no bandwidth bottleneck
beyond the underlying network, and for a two-VPC topology like `app-vpc <-> data-vpc`
it's the simplest thing that works — one connection, two routes, done.

**Transit Gateway (TGW)**: a managed regional routing hub. VPCs attach to it instead
of to each other, and TGW handles routing between all attached VPCs (and on-prem
connections, other regions via peering, etc.) through one central route table
construct. It costs an hourly charge per attachment plus a per-GB data-processing fee,
and adds one extra network hop compared to direct peering.

**Why peering is the right call here:** two VPCs, one relationship, no need for
transitivity (the web tier doesn't need to reach the DB directly, and nothing else is
in the topology). Peering's non-transitivity is a feature, not a limitation, at this
scale — it keeps `data-vpc` reachable *only* from `app-vpc`, by construction.

**When I'd switch to TGW:**
- The moment you need a **third VPC** that also has to reach `data-vpc` (e.g., a
  staging environment, a shared services VPC, an analytics VPC) — peering connections
  don't chain, so you'd otherwise be building and maintaining a full mesh of pairwise
  peering connections (`n*(n-1)/2` of them), which gets unmanageable past 3–4 VPCs.
- You need **centralized, auditable routing policy** across many VPCs/accounts — TGW
  route tables give you one place to see and control who can reach whom, instead of
  routes scattered across every VPC's own table.
- You need to connect VPCs to **on-premises networks or other regions** (via Direct
  Connect / VPN / cross-region peering) alongside VPC-to-VPC traffic.

For NimbusCart as specified — exactly two VPCs, one relationship — peering is the
correct, minimal choice, and I would not add TGW's cost and complexity unless a third
VPC entered the picture.

### 3. The app tier has no public IP and no NAT route of its own beyond the shared NAT Gateway — how does user_data still authenticate to ECR and pull the image?

Step by step, as implemented in `app_setup.sh.tpl`:

1. **Identity, not credentials.** The app EC2 instance launches with
   `iam_instance_profile = aws_iam_instance_profile.app_instance_profile`, which wraps
   `aws_iam_role.app_instance_role` — a role with the AWS-managed
   `AmazonEC2ContainerRegistryReadOnly` policy attached. No access key or secret is
   ever placed in `user_data`, an AMI, or the container image.
2. **Metadata service hands out temporary credentials.** On boot, the AWS CLI/SDK on
   the instance calls the Instance Metadata Service (`169.254.169.254`, IMDS) — a
   link-local address reachable without any route table entry at all, since it's not
   real network traffic, it's a hypervisor-provided endpoint. IMDS returns short-lived
   STS credentials for the attached role automatically; the instance never has to
   authenticate to get them.
3. **`aws ecr get-login-password`** uses those temporary credentials to call the ECR
   API and get a short-lived Docker login token — an AWS *API call*, over HTTPS, to
   `ecr.<region>.amazonaws.com`.
4. **That HTTPS call needs an actual network path to leave the subnet.** This is
   where the shared NAT Gateway comes in: `aws_route_table.private_rt` (the app
   subnet's route table) has `0.0.0.0/0 -> aws_nat_gateway.nat`. The app instance has
   no public IP and no NAT Gateway of its own, but it doesn't need one — it shares the
   one NAT Gateway sitting in the public/web subnet. The ECR API call goes:
   app instance -> NAT Gateway (source-NAT'd to the NAT's public/Elastic IP) ->
   internet gateway -> ECR's public endpoint, and the response follows the reverse
   path back (NAT Gateways are stateful, so return traffic is tracked automatically).
5. **`docker login` + `docker pull`** then authenticate to and pull from
   `<account_id>.dkr.ecr.<region>.amazonaws.com/nimbuscart-api`, over that same NAT
   path, using the token from step 3.

So the chain is: **IAM role -> IMDS-issued temporary credentials -> ECR API call
routed out through the shared NAT Gateway -> authenticated pull**, with the NAT
Gateway providing *outbound-only* internet reachability and the IAM role providing
*identity* — neither one needs the instance to have a public IP or its own NAT.

### 4. Security groups are stateful, NACLs are not. Give one concrete scenario in this architecture where that distinction would bite you if you got NACL rules wrong.

Say a NACL is added to the app-private subnet (this repo doesn't add one — it relies
on the default "allow all" NACL — but suppose a stricter one is introduced later).
The web tier calls the API at `app_private_ip:8080`. Someone configures the NACL to
**allow inbound TCP 8080** from the web subnet (so the request gets in) but forgets
that TCP is bidirectional and the *response* to that request comes back from an
**ephemeral source port** on the app instance (something like TCP 48000+) rather than
port 8080. If the NACL's **outbound** rules don't separately allow that ephemeral port
range back to the web subnet, the response packets are dropped at the NACL, even
though the original request got through cleanly.

With only security groups in play, this exact mistake is impossible: security groups
are stateful, meaning "allow inbound 8080 from web-sg" automatically permits the
matching return traffic without any outbound rule needed at all — SGs track
connection state and let established-connection responses through implicitly. NACLs
have no concept of connection state; every direction of every flow needs its own
explicit rule, including for ephemeral response ports. Get the NACL's outbound
ephemeral-port range wrong (or omit it) and you get exactly the app tier's symptom
you'd expect from a broken return route: the request arrives (visible in the app
container's logs / a `tcpdump` on the app instance) but the client-side `fetch()` in
the frontend times out waiting for a response that never makes it back through the
NACL.

### 5. local-exec provisioners are widely discouraged in production Terraform — why, and why is it acceptable here for the image-build step?

**Why discouraged in general:** Terraform's state file only records what a
`local-exec` provisioner's *command string* was (as an opaque history entry) — it
records nothing about what that command actually *did* to the world. Contrast this
with a normal resource block, where Terraform's provider reads back the object's real
attributes from the AWS API and reconciles state against reality on every
`plan`/`apply`. A `local-exec` running `docker build && docker push` is invisible to
that reconciliation loop:
- If the push fails halfway, Terraform still marks the `null_resource` as
  successfully applied (the shell command merely needs to exit non-zero to fail the
  *apply*, but if it exits 0 having done the wrong thing — pushed a stale image,
  authenticated to the wrong registry — Terraform has no way to detect that).
- There's no drift detection: if someone manually pushes a different image to the same
  ECR tag outside of Terraform, `terraform plan` shows no diff, because nothing about
  the pushed image is a tracked resource attribute.
- It's not portable — the command runs on whatever machine executes `terraform apply`
  (needs Docker installed locally, needs AWS CLI configured, behaves differently
  cross-platform), unlike provider-managed resources which are executed by AWS itself
  regardless of where Terraform runs.
- Destroy-time behavior is fragile and easy to get wrong (no automatic cleanup of
  whatever the command created).

**Why it's acceptable for this assignment's image-build step specifically:** the
concern above is really about *managing infrastructure state* through a black box.
Building and pushing a Docker image isn't infrastructure state — it's a **build
artifact**, and Terraform's `triggers` map (keyed on `filesha256()` of the Dockerfile,
app source, and requirements file) gives an explicit, deliberate re-run condition that
substitutes for the reconciliation Terraform can't do automatically: change any of
those three files and the hash changes, the trigger changes, and `null_resource.
build_and_push_image` re-runs on the next apply. Combined with the fact that this is a
small, single-image, single-environment assignment (not a fleet of services with a
real CI/CD pipeline), the honest tradeoff is: a proper solution would move this step
into a CI pipeline (CodeBuild, GitHub Actions, etc.) that builds and pushes on every
commit, independent of `terraform apply`, and have Terraform only *reference* an image
digest that pipeline produced. For this assignment's scope, wiring up a second CI
system is disproportionate to the problem, and `local-exec` with an explicit,
correctly-scoped trigger is a reasonable, clearly-labeled shortcut — as long as it's
understood to be a shortcut and not the production pattern.

### 6. Why does backend.tf deliberately not live in the same state it configures? What bootstrapping problem is being avoided?

`backend.tf` in `terraform/` tells Terraform *where to store the state for everything
else in that directory* (the S3 bucket + DynamoDB table for locking). If that same
S3 bucket and DynamoDB table were themselves resources declared inside
`terraform/main.tf` — the config they're supposed to be backing — you get a genuine
chicken-and-egg problem: to run `terraform init` for that config, Terraform first
needs to know which backend to talk to in order to read/write state, but the backend
itself doesn't exist yet because it's only defined as a *resource* inside the state
that hasn't been created yet. There's no valid order of operations: you can't
`terraform apply` a bucket into existence using a backend that requires the bucket to
already exist.

This repo avoids the problem by putting the backend's own infrastructure (the S3
bucket, versioning, encryption, public-access block, and the DynamoDB lock table) in
a **separate configuration** — `terraform/backend-bootstrap/` — that itself uses
plain **local state** (no backend block at all). You run that once, by hand, before
touching the main config:
```
cd terraform/backend-bootstrap
terraform init
terraform apply -auto-approve
```
Its outputs (`bucket_name`, `dynamodb_table_name`) are then copied into
`terraform/backend.tf` by hand, and only *then* does `terraform init` in
`terraform/` have a real, already-existing backend to configure against. The
bootstrap config's own local `terraform.tfstate` is small, touched rarely (only if
you ever need to recreate the backend itself), and is intentionally kept out of the
loop it enables — which is exactly the point: the thing that stores state can't also
depend on the state it's storing.
