#!/usr/bin/env zsh
# start-agents-local.sh
# Fetches all agents for a company and starts each in its own tmux window.
# Run `pnpm dev` manually first, then run this script.
#
# Usage:
#   ./scripts/start-agents-local.sh
#   ./scripts/start-agents-local.sh --company-id <uuid>
#
# Requirements: tmux, node >=25, python3

set -euo pipefail

SESSION="paperclip"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API_BASE="http://localhost:3100"
COMPANY_ID="${PAPERCLIP_COMPANY_ID:-}"
WITH_SERVER=false

# ── Argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --company-id)   COMPANY_ID="$2"; shift 2 ;;
    --with-server)  WITH_SERVER=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Check tmux ───────────────────────────────────────────────────────────────

if ! command -v tmux &>/dev/null; then
  echo "ERROR: tmux not found. Install with: brew install tmux"
  exit 1
fi

# ── Start server in tmux (if requested) ──────────────────────────────────────

if [[ "$WITH_SERVER" == "true" ]]; then
  if curl -sf "$API_BASE/api/health" &>/dev/null; then
    echo "Server already running at $API_BASE — skipping restart."
  else
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    tmux new-session -d -s "$SESSION" -n "server" -c "$REPO_ROOT"
    tmux send-keys -t "$SESSION:server" "pnpm dev" Enter

    echo -n "Waiting for server at $API_BASE/api/health"
    until curl -sf "$API_BASE/api/health" &>/dev/null; do
      echo -n "."
      sleep 1
    done
    echo " ready."
  fi
fi

# ── Resolve company ID ────────────────────────────────────────────────────────

if [[ -z "$COMPANY_ID" ]]; then
  echo "Fetching companies from $API_BASE..."
  COMPANIES_JSON=$(curl -sf "$API_BASE/api/companies" || true)
  if [[ -z "$COMPANIES_JSON" ]]; then
    echo "ERROR: Could not reach $API_BASE/api/companies — is pnpm dev running?"
    exit 1
  fi

  COMPANY_COUNT=$(echo "$COMPANIES_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

  if [[ "$COMPANY_COUNT" -eq 1 ]]; then
    COMPANY_ID=$(echo "$COMPANIES_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
    COMPANY_NAME=$(echo "$COMPANIES_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['name'])")
    echo "Company: $COMPANY_NAME ($COMPANY_ID)"
  else
    echo ""
    echo "Multiple companies found. Choose one:"
    echo "$COMPANIES_JSON" | python3 -c "
import sys, json
companies = json.load(sys.stdin)
for i, c in enumerate(companies):
    print(f'  [{i}] {c[\"name\"]} — {c[\"id\"]}')
"
    echo ""
    printf "Enter number: "
    read -r CHOICE
    COMPANY_ID=$(echo "$COMPANIES_JSON" | python3 -c "import sys,json; companies=json.load(sys.stdin); print(companies[$CHOICE]['id'])")
    COMPANY_NAME=$(echo "$COMPANIES_JSON" | python3 -c "import sys,json; companies=json.load(sys.stdin); print(companies[$CHOICE]['name'])")
    echo "Selected: $COMPANY_NAME ($COMPANY_ID)"
  fi
fi

# ── Fetch all agents for the company ─────────────────────────────────────────

echo "Fetching agents for company $COMPANY_ID..."
AGENTS_JSON=$(curl -sf "$API_BASE/api/companies/$COMPANY_ID/agents" || true)
if [[ -z "$AGENTS_JSON" ]]; then
  echo "ERROR: Could not fetch agents — check company ID and server status."
  exit 1
fi

# Extract urlKey (shortname) list — filter out agents without one
AGENT_KEYS=($(echo "$AGENTS_JSON" | python3 -c "
import sys, json
agents = json.loads(sys.stdin.read(), strict=False)
for a in agents:
    key = a.get('urlKey') or ''
    if key:
        print(key)
"))

if [[ ${#AGENT_KEYS[@]} -eq 0 ]]; then
  echo "ERROR: No agents with a shortname found for this company."
  exit 1
fi

echo "Found ${#AGENT_KEYS[@]} agent(s): ${AGENT_KEYS[*]}"
echo ""

# ── Start tmux session ────────────────────────────────────────────────────────

if [[ "$WITH_SERVER" == "false" ]]; then
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  tmux new-session -d -s "$SESSION" -n "${AGENT_KEYS[1]}" -c "$REPO_ROOT"
fi

FIRST=$([[ "$WITH_SERVER" == "true" ]] && echo false || echo true)
for agent in "${AGENT_KEYS[@]}"; do
  echo "  → $agent"
  if [[ "$FIRST" == "true" ]]; then
    tmux rename-window -t "$SESSION:0" "$agent"
    FIRST=false
  else
    tmux new-window -t "$SESSION" -n "$agent" -c "$REPO_ROOT"
  fi

  CMD="source ~/.nvm/nvm.sh && nvm use 25.9 --silent && eval \$(npx paperclipai agent local-cli '$agent' --company-id '$COMPANY_ID' --json | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d['exports'])\") && claude"
  tmux send-keys -t "$SESSION:$agent" "$CMD" Enter
done

echo ""
echo "All agent windows ready. Attaching to tmux session '$SESSION'..."
echo "  Ctrl+b n / p  — next / prev window"
echo "  Ctrl+b d      — detach (agents keep running)"
echo ""

tmux select-window -t "$SESSION:0"
tmux attach-session -t "$SESSION"
