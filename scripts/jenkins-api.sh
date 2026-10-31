#!/usr/bin/env bash
# Shared helper: call the Jenkins HTTP API as admin (sourced by other scripts).
# The password is read from the Kubernetes Secret the chart created - never stored in a file.

JENKINS_URL="${JENKINS_URL:-http://jenkins.localhost:8080}"

jenkins_password() {
  kubectl get secret jenkins -n jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d
}

# jenkins_api <METHOD> <path> [extra curl args...]
# Uses a cookie jar so the CSRF crumb and the request share a session.
jenkins_api() {
  local method="$1" path="$2"; shift 2
  local pass jar crumb
  pass="$(jenkins_password)"
  jar="$(mktemp)"
  # Git Bash: curl.exe is a Windows program and can't open "/tmp/..." when
  # MSYS_NO_PATHCONV is set, so hand it the Windows form of the path.
  command -v cygpath >/dev/null 2>&1 && jar="$(cygpath -m "$jar")"
  crumb="$(curl -sf -c "$jar" -u "admin:$pass" "$JENKINS_URL/crumbIssuer/api/json" \
           | sed -E 's/.*"crumbRequestField":"([^"]+)","crumb":"([^"]+)".*/\1:\2/; s/.*"crumb":"([^"]+)".*"crumbRequestField":"([^"]+)".*/\2:\1/')"
  # -g: don't treat [ ] in Jenkins API paths (e.g. tree=jobs[name]) as curl URL patterns
  curl -sfg -b "$jar" -u "admin:$pass" -H "$crumb" -X "$method" "$JENKINS_URL$path" "$@"
  local rc=$?
  rm -f "$jar"
  return $rc
}
