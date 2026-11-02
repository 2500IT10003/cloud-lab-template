#!/usr/bin/env bash
# VLSC Session 05 - proof-of-work audit. Run ONLY inside GitHub Codespaces.
set -uo pipefail
: "${STUDENT_ID:?export STUDENT_ID first}"
: "${RENDER_URL:?export RENDER_URL first}"
OWNER=$(echo "${GITHUB_USER:?GITHUB_USER missing}" | tr '[:upper:]' '[:lower:]')
VERSION="${VERSION:-1.0.0}"; REF="ghcr.io/$OWNER/vlsc-s05-api:$VERSION"
MAX_BYTES=150000000; MIN_SINGLE=1000000000
OUT=audit_report.txt; : > "$OUT"; PASS=0; FAIL=0

log() { echo "$*" | tee -a "$OUT"; }
check() { # usage: check <name> <exit-code> <detail>
  if [ "$2" -eq 0 ]; then PASS=$((PASS+1)); log "[PASS] $1 :: $3"; else FAIL=$((FAIL+1)); log "[FAIL] $1 :: $3"; fi
}

log "=== VLSC SESSION 05 AUDIT ==="
log "utc=$(date -u +%FT%TZ)"
log "student=$STUDENT_ID github_user=$GITHUB_USER codespace=${CODESPACE_NAME:-NONE}"
log "host=$(uname -srm)"
log "image=$REF"
log "render_url=$RENDER_URL"

# ZT-1: must be a cloud Codespace
[ "${CODESPACES:-}" = "true" ]; check "ZT-1 running in Codespaces" $? "CODESPACES=${CODESPACES:-unset}"

# Docker engine reachable
timeout 20 docker info >/dev/null 2>&1; check "Docker engine reachable" $? "docker info"

# Dockerfile structure: multi-stage, named stages, COPY --from
STAGES=$(grep -ciE '^FROM ' Dockerfile 2>/dev/null || echo 0)
[ "$STAGES" -ge 2 ] && grep -qiE 'AS builder' Dockerfile && grep -qiE 'AS runner' Dockerfile && grep -q -- '--from=builder' Dockerfile
check "Multi-stage Dockerfile (builder + runner)" $? "FROM count=$STAGES"

[ -s .dockerignore ] && grep -q 'node_modules' .dockerignore; check ".dockerignore present" $? "node_modules excluded"

# Size gates
SINGLE=$(docker image inspect vlsc-s05:single --format '{{.Size}}' 2>/dev/null || echo 0)
MULTI=$(docker image inspect "$REF" --format '{{.Size}}' 2>/dev/null || echo 999999999999)
[ "$SINGLE" -gt "$MIN_SINGLE" ]; check "Single-stage baseline > 1 GB" $? "bytes=$SINGLE"
[ "$MULTI" -lt "$MAX_BYTES" ]; check "Multi-stage image < 150 MB" $? "bytes=$MULTI"
if [ "$MULTI" -gt 0 ] && [ "$SINGLE" -gt 0 ]; then log "reduction_factor=$(awk -v s=$SINGLE -v m=$MULTI 'BEGIN{printf "%.1f", s/m}')"; fi

# Image hardening and identity
ARCH=$(docker image inspect "$REF" --format '{{.Architecture}}' 2>/dev/null)
[ "$ARCH" = "amd64" ]; check "Architecture linux/amd64" $? "arch=$ARCH"
USR=$(docker image inspect "$REF" --format '{{.Config.User}}' 2>/dev/null)
[ -n "$USR" ] && [ "$USR" != "root" ] && [ "$USR" != "0" ]; check "Non-root user" $? "user=$USR"
HC=$(docker image inspect "$REF" --format '{{json .Config.Healthcheck}}' 2>/dev/null)
[ -n "$HC" ] && [ "$HC" != "null" ]; check "HEALTHCHECK defined" $? "present"
LBL=$(docker image inspect "$REF" --format '{{index .Config.Labels "vlsc.student"}}' 2>/dev/null)
[ "$LBL" = "$STUDENT_ID" ]; check "Student label matches (ZT-4)" $? "label=$LBL"
echo "$VERSION" | grep -Eq '^[0-9]+[.][0-9]+[.][0-9]+$'; check "Semantic version tag, not latest (ZT-5)" $? "tag=$VERSION"

# Registry proof
DIGEST=$(timeout 90 docker buildx imagetools inspect "$REF" 2>/dev/null | awk '/^Digest:/{print $2; exit}')
[ -n "$DIGEST" ]; check "Digest exists in GHCR" $? "digest=${DIGEST:-none}"
ANON=$(mktemp -d)
DOCKER_CONFIG="$ANON" timeout 300 docker pull "$REF" >/dev/null 2>&1; check "Anonymous pull from GHCR" $? "public package"
rm -rf "$ANON"

# PaaS proof
CODE=$(curl -sS --max-time 120 --retry 3 --retry-delay 5 -o /dev/null -w '%{http_code}' "$RENDER_URL/health" 2>/dev/null)
[ "$CODE" = "200" ]; check "PaaS /health returns 200" $? "http=$CODE"
INFO=$(curl -sS --max-time 60 "$RENDER_URL/info" 2>/dev/null)
echo "$INFO" | grep -qF "\"studentId\":\"$STUDENT_ID\"" && echo "$INFO" | grep -qF '"appEnv":"production"'
check "PaaS env injection (studentId, appEnv)" $? "$INFO"

# Secret hygiene (ZT-2): patterns are split so this script does not match itself
P1='gh''p_'; P2='github''_pat_'
grep -rIl --exclude-dir=.git --exclude-dir=node_modules --exclude=audit_report.txt -e "$P1" -e "$P2" . >/dev/null 2>&1; [ $? -ne 0 ]
check "No token strings in workspace (ZT-2)" $? "scan complete"

# Evidence files
OKF=0; for f in evidence/step1.txt evidence/step2.txt evidence/step3.txt evidence/step4.txt evidence/step5.txt; do [ -s "$f" ] || OKF=1; done
check "Evidence files step1-step5 present" $OKF "evidence/"

RESULT=PASS; [ "$FAIL" -eq 0 ] || RESULT=FAIL
log "=== SUMMARY: pass=$PASS fail=$FAIL RESULT=$RESULT ==="
sha256sum "$OUT" > audit_report.sha256
echo "(SHA-256 of the report above is stored in audit_report.sha256 - do not edit the report)"
cat audit_report.sha256
[ "$FAIL" -eq 0 ]
