# Project progress – Tasks 3 & 4

**Overall: 21 / 29 done (72%)**
`[█████████████████████░░░░░░░░]`

⚠️ **Exam on Nov 1.** Plan: Oct 29 Task 3 + Jenkins install ✅ · Oct 30 CI + CD pipelines · Oct 31 webhook, demos, Task 4 docs · Nov 1 review only.

---

## Task 3 – Kubernetes ✅
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
- [x] NetworkPolicies, plus proof that they block traffic (15/15 tests, before/after in `evidence/task3/`)
- [x] Trivy image scan: 18 CRITICAL → 1 (accepted, documented), frontend fully clean
- [ ] S3 upload + SNS email working *(⛔ BLOCKED: AWS account closed. Code + Terraform ready; documented in README §8)*
- [x] Evidence collected with one script (`./scripts/collect-evidence.sh`)
- [x] README + security chapter + architecture diagram
- [x] Pushed to GitHub, **Task 3 ready to submit** 🎯

## Task 4 – Jenkins CI/CD
**Oct 29 · Jenkins installed as code**
- [x] Unit tests (8) + linter (ruff, incl. security rules) added to the app
- [x] `jenkins` namespace + RBAC (controller / CI agent / deployer), 4 RBAC checks pass
- [x] Jenkins installed as code (Helm 5.10.2 + JCasC + 88 pinned plugins + PVC), clean reinstall verified
- [x] Both jobs created from code (Job DSL)
- [x] Install / configure / create-jobs / verify / uninstall scripts
- [ ] Container registry (GHCR) token → `secrets/ghcr.env` *(your step)*

**Oct 30 · Pipelines**
- [ ] `Jenkinsfile-ci` working (test → build → scan → push)
- [ ] `Jenkinsfile-cd` working (deploy → rollout → smoke test)
- [ ] GitHub webhook triggers CI

**Oct 31 · Finish Task 4**
- [ ] Failure demo + rollback demo
- [ ] Task 4 evidence collected
- [ ] README + 2 diagrams, **Task 4 ready to submit** 🎯

---

### Blockers
- AWS account closed (unpaid $20). Waiver requested. Only S3/SNS depend on it – documented as blocked.
