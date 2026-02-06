FROM ghcr.io/cachix/devenv/devcontainer:latest

ARG CLAUDE_CODE_VERSION=latest

# Install additional tools
RUN apt-get update && apt-get install -y --no-install-recommends \
  sudo \
  fzf \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Node.js for Claude Code
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
  apt-get install -y nodejs && \
  apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Set devcontainer indicator
ENV DEVCONTAINER=true

# Copy and set up firewall script
COPY init-firewall.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/init-firewall.sh
