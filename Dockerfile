FROM debian:bookworm-slim

# Set default environment variables
ENV PORT=7681 \
    USERNAME=root \
    PASSWORD=1 \
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

# Health check
# Bug fix: ttyd --version exits with code 1, use curl to check if port is open instead
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${PORT} || exit 1

EXPOSE ${PORT}

# Bug fix: CMD with variable expansion requires shell form, but shell form is already used.
# However ${PORT}, ${USERNAME}, ${PASSWORD} won't expand from ENV in this context
# because they are evaluated at build time in some edge cases.
# Fix: use exec to properly handle signals and ensure env vars expand at runtime
CMD ["/bin/bash", "-c", "exec /bin/ttyd -p ${PORT} -c ${USERNAME}:${PASSWORD} /bin/bash"]
