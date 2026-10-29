# Project progress – Tasks 3 & 4

**Overall: 14 / 29 done (48%)**
`[██████████████░░░░░░░░░░░░░░░]`

⚠️ Deadline moved up: **exam on Nov 1**. Compressed plan: Oct 29 finish Task 3 · Oct 30 Jenkins + CI · Oct 31 CD + Task 4 docs · Nov 1 review only.

Plan: ~2–2.5 hours a day. Started Mon Oct 26 · Day 6 = Sat Oct 31 · buffer Sun Nov 1

---

## Day 1 – Mon Oct 26 · App running in Kubernetes
- [x] Tools installed (Docker, kubectl, Helm, k3d, Trivy)
- [x] 3-service app built and tested in containers
- [x] Terraform for S3 / SNS / IAM written (apply waits for AWS account)
- [x] Local cluster created (k3d: 1 server + 2 agents)
- [x] Helm chart skeleton
- [x] Backend Deployment + Service
- [x] Frontend + worker Deployments
- [x] ConfigMap + Secrets + `secret.example.yaml`
- [x] PostgreSQL inside the cluster (data survives pod restarts)
- [x] Ingress (only the frontend is exposed)
- [x] **App working at http://localhost:8080** 🎯

## Day 2 – Tue Oct 27 · Security
- [x] NetworkPolicies, plus proof that they block traffic (15/15 tests, before/after in `evidence/task3/`)
- [x] Trivy image scan: 18 CRITICAL → 1 (accepted, documented), frontend fully clean
- [ ] S3 upload + SNS email working *(⛔ BLOCKED since Oct 29: AWS account closed. Code + Terraform ready; document as blocked)*
- [x] Evidence collected with one script (`./scripts/collect-evidence.sh`)

## Day 3 – Wed Oct 28 · Finish Task 3
- [ ] README + security chapter + architecture diagram
- [ ] Pushed to GitHub, **Task 3 ready to submit** 🎯

## Day 4 – Thu Oct 29 · Jenkins
- [ ] Unit tests + linter added to the app
- [ ] Container registry (GHCR) + token
- [ ] `jenkins` namespace + RBAC (controller / CI agent / deployer)
- [ ] Jenkins installed as code (Helm + JCasC + plugins + PVC)
- [ ] Both jobs created from code

## Day 5 – Fri Oct 30 · Pipelines
- [ ] `Jenkinsfile-ci` working (test → build → scan → push)
- [ ] `Jenkinsfile-cd` working (deploy → rollout → smoke test)
- [ ] GitHub webhook triggers CI
- [ ] Failure demo + rollback demo

## Day 6 – Sat Oct 31 · Finish Task 4
- [ ] Install / verify / uninstall scripts
- [ ] Task 4 evidence collected
- [ ] README + 2 diagrams, **Task 4 ready to submit** 🎯

---

### Blockers
- AWS account closed (unpaid $20). Waiver request or payment pending. Only S3/SNS depend on it.
  If not resolved by Day 3: email the instructor and document it.
