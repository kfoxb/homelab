ARG BASE_IMAGE
FROM ${BASE_IMAGE}

USER root

# Install Claude Code; if npm isn't available, install Node.js 20 first then retry.
RUN npm install -g @anthropic-ai/claude-code 2>/dev/null || \
    (curl -fsSL https://nodejs.org/dist/v20.x/node-v20.x-linux-x64.tar.gz | \
     tar -xz -C /usr/local --strip-components=1 && \
     npm install -g @anthropic-ai/claude-code)

# Install required tools if not present. The || true makes this layer succeed
# even on non-apt base images where these tools may already be installed.
RUN apt-get update && apt-get install -y tmux jq curl git \
    && rm -rf /var/lib/apt/lists/* 2>/dev/null || true

# Install dotfiles for root
RUN git clone https://github.com/kfoxb/dotfiles /tmp/dotfiles \
    && cd /tmp/dotfiles && bash install.sh \
    && rm -rf /tmp/dotfiles

# Copy claude worker scripts and hooks
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY status-monitor.sh /usr/local/bin/status-monitor.sh
COPY hooks/ /root/.claude/hooks/

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/status-monitor.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
