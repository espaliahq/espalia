# frozen_string_literal: true

require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Espalia
  class Application < Rails::Application
    # Below this a gzip frame costs about as much as it saves. Only consulted
    # when the response DECLARES its length: Rails leaves Content-Length to the
    # server, so most responses reach the deflater without one. An unknown
    # length is compressed — that is where the big payloads are, and the
    # alternative (buffering the body to measure it) is exactly the cost this
    # is trying to avoid.
    COMPRESSION_MIN_BYTES = 1024

    # Types whose payload is text we author. Everything else either arrives
    # compressed already (images, fonts, archives) or is not worth the CPU.
    COMPRESSIBLE_TYPES = %r{\A(?:text/|application/(?:json|xml|javascript|ecmascript)|
                               application/vnd\.[\w.+-]*\+?(?:json|xml))}x

    # Rack 3 downcases response header names; be explicit rather than relying
    # on that, since this runs on every response.
    COMPRESSIBLE = lambda do |_env, _status, headers, body|
      # Rack 3 allows a body that only responds to `call` (a streamed response),
      # and Rack::Deflater's wrapper enumerates with `each` — so compressing one
      # raises NoMethodError when the response is consumed. Nothing streams here
      # today; this keeps that true if something starts to.
      next false unless body.respond_to?(:each)

      # Already encoded by the app (a pre-gzipped asset, a proxied response):
      # re-framing it would corrupt the encoding chain.
      next false if headers["content-encoding"] || headers["Content-Encoding"]

      type = headers["content-type"] || headers["Content-Type"]
      next false unless type&.match?(COMPRESSIBLE_TYPES)

      length = headers["content-length"] || headers["Content-Length"]
      length.nil? || length.to_i >= COMPRESSION_MIN_BYTES
    end

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

    # The product's display name: page titles, the navbar, sign-in, OAuth
    # consent and outbound Slack messages all read it (#660). An instance
    # sets PRODUCT_NAME to run under its own identity; set-but-empty is unset.
    config.x.product_name = ENV["PRODUCT_NAME"].presence || "Espalia"

    # Throttling for abuse-prone endpoints — currently only OAuth Dynamic
    # Client Registration. Disabled in test/dev via the initializer.
    config.middleware.use Rack::Attack

    # Compress our own HTML/JSON/JS responses.
    #
    # The reference deployment sits behind Cloudflare, which already compresses at the
    # edge (measured 2026-09-09: the sign-in page, 16,914 B identity vs 3,496 B
    # gzip). This covers the two paths that edge does not: a self-hosted
    # deployment with no proxy in front of it — an explicitly supported
    # deployment model — and the origin-to-edge hop, which matters when the
    # response is the explorer's ~1 MB matrix frame.
    #
    # Placed between Rack::ConditionalGet and Rack::ETag so ETag digests the
    # UNCOMPRESSED body and this compresses afterwards: one weak validator for
    # both representations, which is exactly what a weak ETag is for.
    #
    # Skips anything already compressed and anything binary — see COMPRESSIBLE:
    # a content-type allowlist so images, fonts and PDFs aren't re-compressed
    # for nothing, plus a floor for responses that declare a small length.
    config.middleware.insert_before Rack::ETag, Rack::Deflater, if: COMPRESSIBLE

    # Nothing in this app attaches images, so Active Storage never needs to
    # process a variant. Say so explicitly: since 8.1.3.1 the engine resolves
    # the variant transformer at boot, and the default (:vips) hard-requires
    # the ruby-vips gem plus the libvips system library. :disabled selects the
    # NullTransformer, so we don't carry a native dependency we never use.
    # Revisit if we ever add an attachment that needs variants.
    config.active_storage.variant_processor = :disabled

    # A role or level an assessment can't be read against is a missing
    # record. Rails maps exception classes by name, not ancestry, so the
    # RecordNotFound subclass needs its own entry to answer 404.
    config.action_dispatch.rescue_responses["Assessments::Lens::NotFound"] = :not_found

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
