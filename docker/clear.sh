#!/bin/sh
# Re-initialize all gateways: restart the container so every stdio child starts fresh.
# Use when a company is wedged. Company list is read from the container (SLUGS).
echo "[clear] restarting qbo-mcp ..."
sudo docker restart qbo-mcp >/dev/null
SLUGS=$(sudo docker exec qbo-mcp printenv SLUGS 2>/dev/null)
n=$(printf "%s\n" $SLUGS | grep -c .)
for i in $(seq 1 30); do
  ok=0
  for s in $SLUGS; do
    sudo docker exec qbo-mcp node -e "require('http').get('http://localhost:8200/$s/healthz',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))" 2>/dev/null && ok=$((ok+1))
  done
  if [ "$ok" -eq "$n" ]; then echo "[clear] all $n gateways healthy"; exit 0; fi
  sleep 1
done
echo "[clear] WARNING: only $ok/$n healthy after wait" >&2; exit 1
