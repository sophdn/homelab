# Custom toolkit-server image: ubuntu base + Node 22 + claude CLI.
#
# Why custom: portal-write-api's chat-relay surface (POST /portal/chat/message)
# spawns `claude -p ...` per turn. The bare ubuntu:24.04 image has no Node
# runtime and no claude CLI; spawn fails with `not found` and the SSE
# response is an `error` event. This image bakes Node 22 + the
# `@anthropic-ai/claude-code` package so the spawn finds claude on PATH.
#
# Auth: claude inherits its OAuth from `~/.claude/.credentials.json`,
# which is mounted RO from the host at runtime via docker-compose.yml's
# `volumes` block. The image itself never carries credentials.
#
# Non-root: runs as uid 1000 / gid 1000 to match the host's `youruser`
# user, so volume mounts and file permissions stay sane (the host's
# `~/.claude/` belongs to `youruser:youruser`, uid 1000).
#
# Image rebuild discipline: any time the toolkit-server binary in
# `bin/toolkit-server` is replaced (new mcp-servers commit), no
# rebuild is needed — the binary is bind-mounted RO from the host.
# Rebuild ONLY on Node-version bumps or claude CLI updates (the
# layer that runs `npm install -g @anthropic-ai/claude-code`).

FROM ubuntu:24.04

# Avoid prompts during apt install.
ENV DEBIAN_FRONTEND=noninteractive

# Install Node 22 + git (claude calls git internally for some flows)
# + ca-certificates (for HTTPS to api.anthropic.com).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
 && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Install claude CLI globally. `--unsafe-perm` lets npm postinstall
# scripts run as root during the install layer; the running container
# drops to uid 1000 below.
RUN npm install -g --unsafe-perm @anthropic-ai/claude-code

# Create a non-root user matching the host's `youruser` (uid 1000).
# The container runs as this user; the credentials volume mount
# at `/home/youruser/.claude/` resolves with matching ownership.
#
# ubuntu:24.04 ships a default `ubuntu` user already at uid/gid 1000, so
# creating a user at 1000 collides ("GID '1000' already exists") unless we
# free the id first. Remove the distro default, then claim 1000 for youruser.
ARG UID=1000
ARG GID=1000
RUN userdel -r ubuntu 2>/dev/null || true; \
    groupdel ubuntu 2>/dev/null || true; \
    groupadd -g ${GID} youruser \
 && useradd -m -u ${UID} -g ${GID} -s /bin/bash youruser

USER youruser
WORKDIR /home/youruser

# Default command — overridden by docker-compose.yml's `command`
# block. Kept here so a bare `docker run <image>` produces a
# legible error rather than dropping to a shell.
CMD ["/usr/local/bin/toolkit-server", "--help"]
