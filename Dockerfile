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

REDIRECT_PORT=8000
SSHX_URL_FILE="/tmp/sshx_url.txt"

# Function to create dynamic redirect server
create_redirect_server() {
    python3 << 'PYTHON_EOF'
import http.server
import socketserver
import os
import sys
import time

port = int(os.environ.get('REDIRECT_PORT', 8000))
url_file = os.environ.get('SSHX_URL_FILE', '/tmp/sshx_url.txt')

class RedirectHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        try:
            if os.path.exists(url_file):
                with open(url_file, 'r') as f:
                    sshx_url = f.read().strip()
                if sshx_url and sshx_url.startswith('http'):
                    self.send_response(301)
                    self.send_header('Location', sshx_url)
                    self.end_headers()
                    return
        except:
            pass
        
        # Fallback to ttyd on port 7681
        self.send_response(301)
        self.send_header('Location', 'http://localhost:7681')
        self.end_headers()
    
    def log_message(self, format, *args):
        pass

with socketserver.TCPServer(("", port), RedirectHandler) as httpd:
    sys.stdout.flush()
    httpd.serve_forever()
PYTHON_EOF
}

# Initialize sshx in background
initialize_sshx() {
    rm -f "$SSHX_URL_FILE"
    
    # Install sshx if not present
    if ! command -v sshx &> /dev/null; then
        echo "Installing sshx..."
        curl -sSf https://sshx.io/get | sh 2>&1 | grep -E "Done|Error" || true
    fi
    
    # Run sshx with stdin from /dev/null to avoid blocking
    # Wait a bit for sshx server to initialize
    sleep 2
    echo "Initializing sshx session..."
    echo | timeout 10 sshx run 2>&1 | tee /tmp/sshx_output.txt &
    
    # Extract URL asynchronously
    for i in {1..20}; do
        sleep 1
        if grep -q "Link:" /tmp/sshx_output.txt 2>/dev/null; then
            SSHX_URL=$(grep "Link:" /tmp/sshx_output.txt | head -1 | grep -oP 'https://[^\s]+' || true)
            if [ -n "$SSHX_URL" ]; then
                echo "$SSHX_URL" > "$SSHX_URL_FILE"
                echo "✓ sshx session available: $SSHX_URL"
                return 0
            fi
        fi
    done
    
    echo "⚠ sshx session not available, ttyd fallback active on port 7681"
    return 1
}

# Clean up old files
rm -f "$SSHX_URL_FILE" /tmp/sshx_output.txt

# Start redirect server in background
export REDIRECT_PORT=$REDIRECT_PORT
export SSHX_URL_FILE=$SSHX_URL_FILE
create_redirect_server &
REDIRECT_PID=$!
echo "✓ Redirect server started on port $REDIRECT_PORT"

# Initialize sshx in background (non-blocking)
initialize_sshx &
SSHX_PID=$!

# Start ttyd immediately
echo "Starting ttyd on port ${PORT}..."
exec /bin/ttyd -p ${PORT} -c ${USERNAME}:${PASSWORD} /bin/bash
EOF

RUN chmod +x /usr/local/bin/start-session.sh

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD /bin/ttyd --version || exit 1

EXPOSE ${PORT} 8000

CMD ["/usr/local/bin/start-session.sh"]
