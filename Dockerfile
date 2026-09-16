# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t omarchy_plugin_registry .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name omarchy_plugin_registry omarchy_plugin_registry

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.4.7
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl git libjemalloc2 libvips sqlite3 && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libssl-dev libvips libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile




# Dedicated processors contain no Rails app, credentials, databases or witness.
# Docker's default seccomp/capability policy remains enabled; no nested sandbox.
FROM base AS processor-base
WORKDIR /processor
RUN rmdir /rails && \
    groupadd --system --gid 1000 processor && \
    useradd --system --uid 1001 --gid 1000 processor && \
    mkdir -p /run/processor && chown 1001:1000 /run/processor
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY Gemfile Gemfile.lock ./
COPY lib/registry/processor_protocol.rb lib/registry/processor_client.rb lib/registry/processor_server.rb lib/registry/untrusted_process.rb ./lib/registry/
COPY script/processor_server ./script/
USER 1001:1000
ENTRYPOINT ["/processor/script/processor_server"]

FROM processor-base AS processor-ai
COPY lib/registry/ai_reviewer.rb lib/registry/ai_gateway.rb lib/registry/prompt_injection.rb ./lib/registry/
COPY script/ai_review_adapter ./script/
ENV REGISTRY_PROCESSOR_ROLE="ai"

FROM processor-base AS processor-media
COPY lib/registry/preview_processor.rb lib/registry/og_card_processor.rb ./lib/registry/
COPY script/preview_processor script/og_card_processor ./script/
COPY vendor/fonts/*.ttf ./vendor/fonts/
ENV REGISTRY_PROCESSOR_ROLE="media"

FROM processor-base AS provider-gateway
COPY lib/registry/provider_gateway.rb ./lib/registry/
COPY script/provider_gateway ./script/
ENTRYPOINT ["/processor/script/provider_gateway"]

# Final/default stage remains the Rails app image.
FROM base AS app

# Run and own only the runtime files as a non-root user for security.
# /witness pre-exists rails-owned so a named volume mounted there (the
# kill-list rollback witness, REGISTRY_WITNESS_PATH) inherits writable
# ownership on first creation.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir /witness && chown rails:rails /witness
USER 1000:1000

# Dependencies and code stay root-owned; only runtime directories are writable.
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails
USER root
RUN chown -R rails:rails /rails/storage /rails/tmp /rails/log /witness
USER 1000:1000

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
