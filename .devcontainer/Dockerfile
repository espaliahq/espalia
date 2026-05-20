# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.1
FROM ghcr.io/rails/devcontainer/images/ruby:$RUBY_VERSION

# Ensure binding is always 0.0.0.0
# Binds the server to all IP addresses of the container, so it can be accessed from outside the container.
ENV BINDING="0.0.0.0"

# Install CodeRabbit CLI so the Claude plugin (`/coderabbit` review) works inside the devcontainer.
# Installer drops the binary in /home/vscode/.local/bin, which isn't on PATH during the build shell,
# so put it on PATH before verifying — this also makes `coderabbit` usable in the running container.
ENV PATH="/home/vscode/.local/bin:${PATH}"
RUN curl -fsSL https://cli.coderabbit.ai/install.sh | sh \
    && coderabbit --version

# Render CLI for managing deploys, logs, and the projection-rebuild predeploy gate.
# xdg-utils is required so `render login` can advertise a launch URL (the actual
# browser still has to be opened on the host — the CLI just prints the URL).
ARG RENDER_CLI_VERSION=2.17.0
RUN sudo apt-get update \
    && sudo apt-get install -y --no-install-recommends xdg-utils unzip \
    && sudo rm -rf /var/lib/apt/lists/* \
    && ARCH="$(dpkg --print-architecture)" \
    && curl -fsSL -o /tmp/render-cli.zip \
       "https://github.com/render-oss/cli/releases/download/v${RENDER_CLI_VERSION}/cli_${RENDER_CLI_VERSION}_linux_${ARCH}.zip" \
    && unzip -p /tmp/render-cli.zip "cli_v${RENDER_CLI_VERSION}" | sudo tee /usr/local/bin/render > /dev/null \
    && sudo chmod 755 /usr/local/bin/render \
    && rm -f /tmp/render-cli.zip \
    && render --version
