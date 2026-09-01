#!/usr/bin/env bash
# Read chunk JSONL on stdin, return vector JSONL on stdout.
#
# This is the ENTIRE remote-provider integration. Cloudflare Workers AI and a local
# 2x4090 box differ only by the environment variables below — nothing in the Swift
# binary knows either of them exists.
#
#   Cloudflare Workers AI:
#     EMBED_URL='https://api.cloudflare.com/client/v4/accounts/<ACCT>/ai/run/@cf/baai/bge-m3'
#     EMBED_TOKEN=<token>   EMBED_DIM=1024
#
#   Local box (vLLM / text-embeddings-inference on the 4090s):
#     EMBED_URL='http://gpu.local:8080/embed'   EMBED_DIM=1024   # no token needed
#
# Usage:
#   session-viewer embed --dump --db .data/sessions.db \
#     | EMBED_URL=... EMBED_TOKEN=... scripts/embed-http.sh \
#     | session-viewer embed --load --model bge-m3/1024 --db .data/sessions.db
#
# The token lives in this script's ENVIRONMENT, never on argv — `ps` shows command
# lines to every user on the machine.
set -euo pipefail

: "${EMBED_URL:?set EMBED_URL}"
: "${EMBED_DIM:?set EMBED_DIM — must match what the model actually returns}"
BATCH="${EMBED_BATCH:-32}"

auth=()
[ -n "${EMBED_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${EMBED_TOKEN}")

# Batch, because one HTTP round trip per chunk is the difference between minutes and hours.
jq -c -s "_nwise(${BATCH})" \
| while read -r batch; do
    texts=$(jq -c '[.[].text]' <<<"$batch")
    # Ollama (/api/embed) wants {"model":…,"input":[…]}; Cloudflare wants {"text":[…]}.
    # EMBED_MODEL set → Ollama shape. Response parsing below already handles both.
    if [ -n "${EMBED_MODEL:-}" ]; then
      body=$(jq -nc --arg m "$EMBED_MODEL" --argjson t "$texts" '{model: $m, input: $t}')
    else
      body="{\"text\": ${texts}}"
    fi
    # Retry transient failures rather than dropping chunks: a dropped chunk becomes a
    # permanent hole, because the event then has SOME rows and looks done to --dump.
    # `-f` makes HTTP 4xx/5xx a curl FAILURE (without it a 500 body "succeeds" on attempt
    # 1); after 3 failed attempts we abort the whole pipe rather than emit a short batch —
    # a loud dead run is recoverable (re-run resumes via the dump anti-join), a silent
    # partial event is not.
    for attempt in 1 2 3; do
      resp=$(curl -sSf --max-time 120 "${auth[@]}" \
                  -H 'Content-Type: application/json' \
                  -d "$body" "$EMBED_URL") && break
      resp=""
      sleep $((attempt * 5))
    done
    if [ -z "$resp" ]; then
      echo "embed-http: no response after 3 attempts (${EMBED_URL}) — aborting before any partial batch" >&2
      exit 1
    fi
    # Accept either {result:{data:[[...]]}} (Cloudflare) or {embeddings:[[...]]} / [[...]].
    vecs=$(jq -c '(.result.data // .embeddings // .data // .) | if type=="array" then . else [] end' <<<"$resp")
    n_in=$(jq 'length' <<<"$batch"); n_out=$(jq 'length' <<<"$vecs")
    if [ "$n_in" != "$n_out" ]; then
      echo "embed-http: sent $n_in texts, got $n_out vectors — misaligned response, aborting" >&2
      exit 1
    fi
    paste -d'\t' <(jq -c '.[]' <<<"$batch") <(jq -c '.[]' <<<"$vecs") \
    | while IFS=$'\t' read -r row vec; do
        jq -c --argjson v "$vec" --argjson d "$EMBED_DIM" \
           '{session_id, seq, chunk_index, dim: $d, vector: $v, text}' <<<"$row"
      done
  done
