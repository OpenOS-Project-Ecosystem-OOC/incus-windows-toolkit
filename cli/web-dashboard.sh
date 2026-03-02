#!/usr/bin/env bash
# Lightweight web dashboard for IWT VM monitoring.
#
# Serves a single-page HTML dashboard with live VM status.
# Uses socat or ncat as the HTTP server (no Node.js/Python needed).
#
# Usage:
#   web-dashboard.sh [options]
#
# Options:
#   --port PORT     Listen port (default: 8420)
#   --bind ADDR     Bind address (default: 127.0.0.1)
#   --help          Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

PORT=8420
BIND="127.0.0.1"

# --- Argument parsing ---

# Internal dispatch flags are handled at the bottom of the file.
# Only parse user-facing flags here.
PARSED_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)  PORT="$2"; shift 2 ;;
        --bind)  BIND="$2"; shift 2 ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        --handle-request|--api-json|--html)
            PARSED_ARGS+=("$1"); shift ;;
        *)       die "Unknown option: $1" ;;
    esac
done

# --- JSON API ---

api_vms_json() {
    local vm_list
    vm_list=$(incus list --format csv -c n,s,t 2>/dev/null | grep ",virtual-machine" || true)

    echo '{"vms":['
    local first=true
    if [[ -n "$vm_list" ]]; then
        while IFS=',' read -r name status _type; do
            [[ -n "$name" ]] || continue
            local cpu mem disk ip template

            cpu=$(incus config get "$name" limits.cpu 2>/dev/null || echo "?")
            mem=$(incus config get "$name" limits.memory 2>/dev/null || echo "?")
            disk=$(incus config device get "$name" root size 2>/dev/null || echo "?")
            template=$(incus config get "$name" user.iwt.template 2>/dev/null || echo "")
            ip="-"

            if [[ "$status" == "RUNNING" ]]; then
                ip=$(incus list "$name" --format csv -c 4 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "-")
            fi

            if [[ "$first" == true ]]; then
                first=false
            else
                echo ','
            fi

            cat <<VMJSON
{"name":"$name","status":"$status","cpu":"$cpu","memory":"$mem","disk":"$disk","ip":"$ip","template":"$template"}
VMJSON
        done <<< "$vm_list"
    fi
    echo '],'

    # System info
    local total running
    total=$(echo "$vm_list" | grep -c "virtual-machine" 2>/dev/null || echo "0")
    running=$(echo "$vm_list" | grep -c "RUNNING" 2>/dev/null || echo "0")

    local host_mem host_disk
    host_mem=$(free -h 2>/dev/null | grep "^Mem:" | awk '{printf "%s / %s", $3, $2}' || echo "?")
    host_disk=$(df -h / 2>/dev/null | tail -1 | awk '{printf "%s / %s (%s)", $3, $2, $5}' || echo "?")

    local version
    version=$(grep '^VERSION=' "$IWT_ROOT/cli/iwt.sh" | cut -d'"' -f2)

    cat <<SYSJSON
"system":{"total_vms":$total,"running_vms":$running,"host_memory":"$host_mem","host_disk":"$host_disk","version":"$version"}}
SYSJSON
}

# --- HTML page ---

html_page() {
    cat <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>IWT Dashboard</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace;
         background: #0d1117; color: #c9d1d9; padding: 20px; }
  h1 { color: #58a6ff; margin-bottom: 5px; font-size: 1.4em; }
  .subtitle { color: #8b949e; margin-bottom: 20px; font-size: 0.9em; }
  .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
           gap: 12px; margin-bottom: 20px; }
  .card { background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 16px; }
  .card h3 { color: #58a6ff; font-size: 0.85em; margin-bottom: 8px; text-transform: uppercase; }
  .card .value { font-size: 1.6em; font-weight: bold; }
  table { width: 100%; border-collapse: collapse; background: #161b22;
          border: 1px solid #30363d; border-radius: 6px; overflow: hidden; }
  th { background: #21262d; color: #8b949e; text-align: left; padding: 10px 14px;
       font-size: 0.8em; text-transform: uppercase; }
  td { padding: 10px 14px; border-top: 1px solid #21262d; font-size: 0.9em; }
  tr:hover { background: #1c2128; }
  .status-running { color: #3fb950; }
  .status-stopped { color: #8b949e; }
  .refresh { color: #8b949e; font-size: 0.8em; margin-top: 15px; }
  .actions { margin-top: 15px; }
  .actions button { background: #21262d; color: #c9d1d9; border: 1px solid #30363d;
                    padding: 6px 14px; border-radius: 4px; cursor: pointer; margin-right: 6px;
                    font-size: 0.85em; }
  .actions button:hover { background: #30363d; }
</style>
</head>
<body>
<h1>IWT Dashboard</h1>
<p class="subtitle">Incus Windows Toolkit — VM Monitor</p>

<div class="cards" id="system-cards"></div>

<table>
  <thead>
    <tr><th>Name</th><th>Status</th><th>Template</th><th>CPU</th><th>Memory</th><th>Disk</th><th>IP</th></tr>
  </thead>
  <tbody id="vm-table"></tbody>
</table>

<div class="actions">
  <button onclick="refresh()">Refresh</button>
</div>
<p class="refresh" id="last-refresh"></p>

<script>
async function refresh() {
  try {
    const res = await fetch('/api/vms');
    const data = await res.json();

    // System cards
    const cards = document.getElementById('system-cards');
    cards.innerHTML = `
      <div class="card"><h3>Running</h3><div class="value">${data.system.running_vms} / ${data.system.total_vms}</div></div>
      <div class="card"><h3>Host Memory</h3><div class="value" style="font-size:1em">${data.system.host_memory}</div></div>
      <div class="card"><h3>Host Disk</h3><div class="value" style="font-size:1em">${data.system.host_disk}</div></div>
      <div class="card"><h3>IWT Version</h3><div class="value" style="font-size:1em">v${data.system.version}</div></div>
    `;

    // VM table
    const tbody = document.getElementById('vm-table');
    if (data.vms.length === 0) {
      tbody.innerHTML = '<tr><td colspan="7" style="text-align:center;color:#8b949e">No VMs found</td></tr>';
    } else {
      tbody.innerHTML = data.vms.map(vm => `
        <tr>
          <td><strong>${vm.name}</strong></td>
          <td class="status-${vm.status.toLowerCase()}">${vm.status}</td>
          <td>${vm.template || '-'}</td>
          <td>${vm.cpu}</td>
          <td>${vm.memory}</td>
          <td>${vm.disk}</td>
          <td>${vm.ip}</td>
        </tr>
      `).join('');
    }

    document.getElementById('last-refresh').textContent = 'Last refresh: ' + new Date().toLocaleTimeString();
  } catch (e) {
    console.error('Refresh failed:', e);
  }
}

refresh();
setInterval(refresh, 5000);
</script>
</body>
</html>
HTMLEOF
}

# --- HTTP handler ---

handle_request() {
    local request_line=""
    read -r request_line || true

    # Parse path from request line
    local path
    path=$(echo "$request_line" | awk '{print $2}')

    # Consume remaining headers
    while IFS= read -r header; do
        [[ -z "$header" || "$header" == $'\r' ]] && break
    done

    # Route
    case "$path" in
        /api/vms)
            local json
            json=$(api_vms_json)
            local len=${#json}
            printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\n\r\n%s" "$len" "$json"
            ;;
        /|/index.html)
            local html
            html=$(html_page)
            local len=${#html}
            printf "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\n\r\n%s" "$len" "$html"
            ;;
        *)
            printf "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found"
            ;;
    esac
}

# --- Server ---

start_server() {
    bold "IWT Web Dashboard"
    info "Listening on http://${BIND}:${PORT}"
    info "Press Ctrl+C to stop"
    echo ""

    if command -v socat &>/dev/null; then
        socat "TCP-LISTEN:${PORT},bind=${BIND},reuseaddr,fork" \
            EXEC:"$0 --handle-request",nofork
    elif command -v ncat &>/dev/null; then
        ncat -l "$BIND" "$PORT" --keep-open --sh-exec "$0 --handle-request"
    elif command -v python3 &>/dev/null; then
        # Fallback: use Python's http.server with a custom handler
        info "Using Python HTTP server fallback"
        python3 -c "
import http.server, subprocess, json

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/api/vms':
            result = subprocess.run(['$0', '--api-json'], capture_output=True, text=True)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(result.stdout.encode())
        elif self.path in ('/', '/index.html'):
            result = subprocess.run(['$0', '--html'], capture_output=True, text=True)
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(result.stdout.encode())
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, format, *args): pass

http.server.HTTPServer(('$BIND', $PORT), Handler).serve_forever()
"
    else
        die "Need socat, ncat, or python3 to run the web server"
    fi
}

# --- Main ---

case "${PARSED_ARGS[0]:-}" in
    --handle-request) handle_request ;;
    --api-json)       api_vms_json ;;
    --html)           html_page ;;
    *)                start_server ;;
esac
