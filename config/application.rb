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

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
