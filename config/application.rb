# frozen_string_literal: true

require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module GrowthOs
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    #
    # `rubocop` holds custom cops (lib/rubocop/cop/**) that subclass
    # RuboCop::Cop::Base — a constant only present when the rubocop gem is
    # loaded (development/test). They are loaded explicitly by RuboCop via the
    # `require:` directive in .rubocop.yml, never by the app. Eager-loading
    # them in production raises NameError and crashes boot, so exclude them.
    config.autoload_lib(ignore: %w[assets tasks rubocop])

    # Stable OAuth issuer for the MCP server's discovery doc (RFC 8414
    # requires exact-match validation by clients). Behind a proxy or LB
    # the `request.base_url` Rails sees varies with X-Forwarded-* headers,
    # which would silently break token validation; set OAUTH_ISSUER to the
    # canonical public URL in production. In dev/test we fall back to
    # `request.base_url` so contributors don't have to configure anything.
    config.x.oauth_issuer = ENV.fetch("OAUTH_ISSUER", nil)

    # Throttling for abuse-prone endpoints — currently only OAuth Dynamic
    # Client Registration. Disabled in test/dev via the initializer.
    config.middleware.use Rack::Attack

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
