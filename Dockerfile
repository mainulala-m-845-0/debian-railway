FROM debian:bookworm-slim

# Set default environment variables
ENV PORT=7681 \
    USERNAME=root \
    PASSWORD=ttyd \
    DEBIAN_FRONTEND=noninteractive

# Install dependencies with optimized layer caching
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    wget \
    curl \
    git \
    python3 \
    python3-pip \
    neofetch \
    ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Download and setup ttyd with version pinning and error handling
RUN set -e && \
    TTYD_VERSION="1.7.3" && \
    TTYD_URL="https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" && \
    wget -qO /bin/ttyd "$TTYD_URL" && \
    chmod +x /bin/ttyd && \
    /bin/ttyd --version

# Configure shell environment
RUN mkdir -p /root && \
    cat > /root/.bashrc << 'EOF'
if [ -f /etc/bash.bashrc ]; then . /etc/bash.bashrc; fi

export HISTFILESIZE=10000
export HISTSIZE=10000
export PS1='\[\033[01;31m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

# Auto-run neofetch on login
neofetch
cd /root
EOF

# Create startup script with sshx integration and auto-redirect
RUN cat > /usr/local/bin/start-session.sh << 'EOF'
#!/bin/bash
set -e

SSHX_URL=""
REDIRECT_PORT=8080

# Function to create redirect server
create_redirect_server() {
    python3 << 'PYTHON_EOF'
import http.server
import socketserver
import os
import sys
from urllib.parse import quote

sshx_url = os.environ.get('SSHX_URL', '')
port = int(os.environ.get('REDIRECT_PORT', 8080))

class RedirectHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if sshx_url:
            self.send_response(301)
            self.send_header('Location', sshx_url)
            self.end_headers()
        else:
            self.send_response(503)
            self.send_header('Content-type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'sshx session not ready')
    
    def log_message(self, format, *args):
        pass

with socketserver.TCPServer(("", port), RedirectHandler) as httpd:
    sys.stdout.flush()
    httpd.serve_forever()
PYTHON_EOF
}

# Start redirect server in background
export REDIRECT_PORT=$REDIRECT_PORT
create_redirect_server &
REDIRECT_PID=$!

# Start sshx and capture URL
echo "Starting sshx session..."
SSHX_OUTPUT=$(sshx run 2>&1 || true)
if [[ $SSHX_OUTPUT =~ Link:\ ([^ ]+) ]]; then
    SSHX_URL="${BASH_REMATCH[1]}"
    export SSHX_URL
    echo "✓ sshx session available at: $SSHX_URL"
fi

# Start ttyd
exec /bin/ttyd -p ${PORT} -c ${USERNAME}:${PASSWORD} /bin/bash
EOF

chmod +x /usr/local/bin/start-session.sh

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD /bin/ttyd --version || exit 1

EXPOSE ${PORT} 8080

CMD ["/usr/local/bin/start-session.sh"]
