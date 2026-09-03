# frozen_string_literal: true

source "https://rubygems.org"
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

ruby file: ".ruby-version"

# Bundle edge Rails instead: gem 'rails', github: 'rails/rails'
gem "rails", "~> 8.1.0"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft", "~> 1.3"
# Use postgresql as the database for Active Record
gem "pg"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]

gem "acts_as_tenant", "~> 1.0"
gem "devise", "~> 5.0.3"
# OAuth 2.0 + PKCE provider — backs the MCP server's bearer-token auth.
# Doorkeeper is OAuth 2.0; we configure it with `force_pkce`, no refresh
# tokens, and authorization_code-only grants to meet the MCP spec's
# OAuth-2.1-aligned posture without needing a 2.1-native gem. See
# config/initializers/doorkeeper.rb.
gem "doorkeeper", "~> 5.9"

# Throttles abuse-prone endpoints (specifically MCP Dynamic Client
# Registration at POST /oauth/register, which is public and DB-writing).
# See config/initializers/rack_attack.rb.
gem "rack-attack", "~> 6.7"

gem "omniauth-google-oauth2", "~> 1.2"
gem "omniauth-rails_csrf_protection", "~> 2.0"
gem "invisible_captcha", "~> 2.0"
gem "local_time", "~> 3.0"
gem "noticed", "~> 3.0"
gem "pagy", "~> 43.6"
gem "pundit", "~> 2.4"
gem "typeid", "~> 0.2"
gem "tailwindcss-rails", "~> 4.6"

# Phlex - Object-oriented views for semantic components
gem "phlex", "~> 2.4.1"
gem "phlex-rails", "~> 2.4.0"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[windows jruby]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 2.0"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[mri windows], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  # Factory Bot for dynamic testing fixtures
  gem "factory_bot_rails"

  gem "erb_lint", require: false
  gem "mailbin", "~> 1.2"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"

  # Process manager for Procfile.dev (runs Rails server + Tailwind CSS watcher)
  gem "overmind", require: false
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"

  # Minitest (mock extracted in minitest 6.0)
  gem "minitest-mock"

  # Shoulda
  gem "shoulda-context", "~> 3.0.0.rc1"
  gem "shoulda-matchers", "~> 8.0.1"
  gem "shoulda-callback-matchers", "~> 1.1.4"
end

# Use Redis adapter to run Action Cable in production
# gem "redis", "~> 5.1"

# ActionText editor
gem "lexxy", "~> 0.9.31"

# Model attribute translations stored in JSONB columns
gem "json_translate"

# Type-safe structured objects in JSONB columns
gem "store_model", "~> 4.6"

# Event sourcing for Framework and Person Development aggregates.
# `rails_event_store/all` is required instead of the umbrella's default entrypoint
# because the latter loads the deprecated `rails_event_store_active_record` gem.
gem "rails_event_store", "~> 3.1", require: "rails_event_store/all"
gem "ruby_event_store-active_record", "~> 3.0"

# HTTP client for HRIS and external API integrations
gem "faraday", "~> 2.0"

# Character/grapheme-level diff for inline suggestion display
gem "diff-lcs", "~> 2.0"

# We recommend using strong migrations when your app is in production
# gem "strong_migrations"
