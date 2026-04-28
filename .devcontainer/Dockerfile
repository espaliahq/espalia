# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.1
FROM ghcr.io/rails/devcontainer/images/ruby:$RUBY_VERSION

# Ensure binding is always 0.0.0.0
# Binds the server to all IP addresses of the container, so it can be accessed from outside the container.
ENV BINDING="0.0.0.0"

# Install CodeRabbit CLI so the Claude plugin (`/coderabbit` review) works inside the devcontainer.
RUN curl -fsSL https://cli.coderabbit.ai/install.sh | sh \
    && coderabbit --version
