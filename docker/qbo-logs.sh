#!/bin/sh
# Inspect the QBO MCP gateway. Company list is read from the running container (SLUGS).
#   qbo-logs.sh                 -> live container log (all companies, timestamped)
#   qbo-logs.sh <slug>          -> tail that company's persistent log (-f)
#   qbo-logs.sh <slug> 200      -> last 200 lines of that company's log (no follow)
#   qbo-logs.sh crashes         -> child exits / restarts / upstream errors
#   qbo-logs.sh status          -> container status + a health check per company
C=/app/companies
SLUGS=$(sudo docker exec qbo-mcp printenv SLUGS 2>/dev/null)
case "${1:-tail}" in
  status)
    sudo docker ps --filter name=qbo-mcp --format "{{.Names}}: {{.Status}}"
    for s in $SLUGS; do
      printf "%-24s " "$s:"; sudo docker exec qbo-mcp node -e "require('http').get('http://localhost:8200/$s/healthz',r=>{let b='';r.on('data',d=>b+=d);r.on('end',()=>console.log(b))})" 2>/dev/null || echo DOWN
    done ;;
  crashes)
    sudo docker exec qbo-mcp sh -c "grep -hiE 'child.*exit|respawn|initialized|child-stderr.*[Ee]rror|AuthorizationFailure' $C/*/logs/gateway.log 2>/dev/null | tail -40" ;;
  tail|"")
    sudo docker logs -f --tail 60 qbo-mcp ;;
  *)
    slug="$1"; n="${2:-}"
    if [ -n "$n" ]; then sudo docker exec qbo-mcp sh -c "tail -n $n $C/$slug/logs/gateway.log";
    else sudo docker exec qbo-mcp sh -c "tail -f $C/$slug/logs/gateway.log"; fi ;;
esac
