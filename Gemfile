source "https://rubygems.org"
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

ruby file: ".ruby-version"

# Bundle edge Rails instead: gem 'rails', github: 'rails/rails'
gem "rails", "~> 8.1.0"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft", "~> 1.0"
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
gem "invisible_captcha", "~> 2.0"
gem "local_time", "~> 3.0"
gem "noticed", "~> 3.0"
gem "pagy", "~> 43.4"
gem "prefixed_ids", "~> 1.2"
gem "pundit", "~> 2.4"
gem "tailwindcss-rails", "~> 4.0"

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
gem "image_processing", "~> 1.2"

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
  gem "mailbin", "~> 1.0"
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
  gem "shoulda-matchers", "~> 7.0.1"
  gem "shoulda-callback-matchers", "~> 1.1.4"
end

# Use Redis adapter to run Action Cable in production
# gem "redis", "~> 5.1"

# ActionText editor
gem "lexxy", "~> 0.9.0.beta"

# Model attribute translations stored in JSONB columns
gem "json_translate"

# Type-safe structured objects in JSONB columns
gem "store_model", "~> 4.5"

# Event sourcing for Framework and Person Development aggregates
gem "rails_event_store", "~> 2.16"

# HTTP client for HRIS and external API integrations
gem "faraday", "~> 2.0"

# We recommend using strong migrations when your app is in production
# gem "strong_migrations"
