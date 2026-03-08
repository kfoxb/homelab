FROM mcr.microsoft.com/devcontainers/base:bullseye

# Install system dependencies
RUN apt-get update && apt-get install -y \
    tmux \
    git \
    jq \
    curl \
    unzip \
    sudo \
    ca-certificates \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20 via NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Create non-root user 'claude' with sudo access
RUN useradd -m -s /bin/bash claude \
    && echo "claude ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/claude \
    && chmod 0440 /etc/sudoers.d/claude

# Clone and run dotfiles install as the claude user
RUN git clone https://github.com/kfoxb/dotfiles /home/claude/dotfiles \
    && chown -R claude:claude /home/claude/dotfiles \
    && cd /home/claude/dotfiles \
    && sudo -u claude bash install.sh

USER claude
WORKDIR /home/claude

# Copy entrypoint and status monitor
COPY --chown=claude:claude entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chown=claude:claude status-monitor.sh /usr/local/bin/status-monitor.sh
RUN sudo chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/status-monitor.sh

# Copy hooks and configure Claude Code settings.json to register the Stop hook
COPY --chown=claude:claude hooks/ /home/claude/.claude/hooks/
RUN chmod +x /home/claude/.claude/hooks/on-stop.sh \
    && mkdir -p /home/claude/.claude \
    && echo '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/home/claude/.claude/hooks/on-stop.sh"}]}]}}' \
       > /home/claude/.claude/settings.json

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
