FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PORT=7681 \
    USERNAME=root \
    PASSWORD=ttyd \
    REDIRECT_PORT=8000

# Install packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash \
        curl \
        wget \
        git \
        python3 \
        python3-pip \
        neofetch \
        ca-certificates \
        procps && \
    rm -rf /var/lib/apt/lists/*

# Install ttyd
RUN set -eux; \
    TTYD_VERSION="1.7.7"; \
    wget -O /usr/local/bin/ttyd \
      "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64"; \
    chmod +x /usr/local/bin/ttyd; \
    ttyd --version

# Shell config
RUN mkdir -p /root && \
    cat > /root/.bashrc <<'EOF'
if [ -f /etc/bash.bashrc ]; then
    . /etc/bash.bashrc
fi

export HISTFILESIZE=10000
export HISTSIZE=10000

export PS1='\[\e[1;31m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '

clear
neofetch
cd /root
EOF

# Startup script
RUN cat > /usr/local/bin/start-session.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SSHX_URL_FILE="/tmp/sshx_url.txt"

cleanup() {
    pkill -f ttyd || true
    pkill -f sshx || true
    pkill -f redirect_server.py || true
}

trap cleanup EXIT

# Create redirect server
cat > /tmp/redirect_server.py <<'PY'
import http.server
import socketserver
import os

PORT = int(os.environ.get("REDIRECT_PORT", "8000"))
URL_FILE = os.environ.get("SSHX_URL_FILE", "/tmp/sshx_url.txt")

class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        target = None

        if os.path.exists(URL_FILE):
            try:
                with open(URL_FILE) as f:
                    target = f.read().strip()
            except:
                pass

        if not target:
            host = self.headers.get("Host", "localhost").split(":")[0]
            ttyd_port = os.environ.get("PORT", "7681")
            target = f"http://{host}:{ttyd_port}"

        self.send_response(302)
        self.send_header("Location", target)
        self.end_headers()

    def log_message(self, *args):
        pass

with ReusableTCPServer(("0.0.0.0", PORT), Handler) as httpd:
    httpd.serve_forever()
PY

# Start redirect server
python3 /tmp/redirect_server.py &
echo "✓ Redirect server running on ${REDIRECT_PORT}"

# Install sshx
if ! command -v sshx >/dev/null 2>&1; then
    echo "Installing sshx..."
    curl -fsSL https://sshx.io/get | sh || true
fi

# Start sshx in background
if command -v sshx >/dev/null 2>&1; then
(
    sshx 2>&1 | tee /tmp/sshx_output.txt
) &

    echo "Waiting for sshx URL..."

    for i in $(seq 1 20); do
        sleep 1

        URL=$(grep -Eo 'https://[^ ]+' /tmp/sshx_output.txt | head -n1 || true)

        if [ -n "${URL}" ]; then
            echo "${URL}" > "${SSHX_URL_FILE}"
            echo "✓ sshx ready: ${URL}"
            break
        fi
    done
else
    echo "⚠ sshx install failed"
fi

echo "✓ Starting ttyd on port ${PORT}"

exec ttyd \
    -i 0.0.0.0 \
    -p "${PORT}" \
    -c "${USERNAME}:${PASSWORD}" \
    bash
EOF

RUN chmod +x /usr/local/bin/start-session.sh

# Better healthcheck
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fs http://127.0.0.1:${PORT} >/dev/null || exit 1

EXPOSE 7681 8000

CMD ["/usr/local/bin/start-session.sh"]
