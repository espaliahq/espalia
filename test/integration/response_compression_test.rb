# frozen_string_literal: true

require "test_helper"

# The app compresses its own HTML/JSON responses (#383).
#
# growthos.work is behind Cloudflare, which already compresses at the edge; this
# covers the deployments that have no such edge (self-hosting is a supported
# model) and the origin-to-edge hop, which carries the explorer's ~1 MB matrix
# frame. See the Rack::Deflater comment in config/application.rb.
class ResponseCompressionTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @user) }
    post user_session_path, params: { user: { email: @user.email, password: "password123" } }
    follow_redirect!
  end

  context "a sizeable HTML response" do
    should "come back gzipped, and decode to the same page" do
      get root_path, headers: { "HTTP_ACCEPT_ENCODING" => "gzip" }
      assert_response :success
      assert_equal "gzip", response.headers["Content-Encoding"]
      assert_includes response.headers["Vary"].to_s, "Accept-Encoding"

      plain = Zlib::GzipReader.new(StringIO.new(response.body)).read
      assert_includes plain, "<html"
      assert_operator response.body.bytesize, :<, plain.bytesize
    end

    should "stay uncompressed for a client that does not ask" do
      get root_path, headers: { "HTTP_ACCEPT_ENCODING" => "identity" }
      assert_response :success
      assert_nil response.headers["Content-Encoding"]
      assert_includes response.body, "<html"
    end
  end

  context "the compressibility rule" do
    # Exercised directly: the allowlist decides on every response in the app,
    # and an integration test can only reach the handful of types it happens to
    # render. A type wrongly added here is CPU burnt re-compressing JPEGs.
    should "cover the text types we author and nothing already compressed" do
      compressible = [
        "text/html; charset=utf-8",
        "text/plain",
        "text/vnd.turbo-stream.html",
        "application/json",
        "application/javascript",
        "application/vnd.api+json"
      ]
      incompressible = [ "image/png", "image/jpeg", "font/woff2", "application/pdf", "application/zip" ]

      compressible.each do |type|
        assert compressible?(type), "#{type} should be compressed"
      end

      incompressible.each do |type|
        assert_not compressible?(type), "#{type} should not be compressed"
      end
    end

    should "skip a response that already declares a small length" do
      assert_not compressible?("text/html", length: 200)
      assert compressible?("text/html", length: GrowthOs::Application::COMPRESSION_MIN_BYTES)
    end

    should "compress a body whose length is unknown" do
      # Rails leaves Content-Length to the server, so this is the common case —
      # and it is where the large payloads are. Never skip for want of a number.
      assert compressible?("text/html", length: nil)
    end

    should "never re-frame a response the app already encoded" do
      assert_not GrowthOs::Application::COMPRESSIBLE.call(
        {}, 200, { "content-type" => "text/html", "content-encoding" => "gzip" }, [ "<html>" ]
      )
    end

    should "leave a streamed, callable-only body alone" do
      # Rack 3 allows a body that only responds to `call`; Rack::Deflater's
      # wrapper enumerates with `each`, so compressing one raises NoMethodError
      # when the response is consumed. Nothing streams here today — this is what
      # keeps a future SSE endpoint from finding out the hard way.
      streamed = Class.new { def call(stream) = stream.close }.new

      assert_not streamed.respond_to?(:each), "the fixture must be callable-only"
      assert_not GrowthOs::Application::COMPRESSIBLE.call(
        {}, 200, { "content-type" => "text/event-stream" }, streamed
      )
    end
  end

  private

  # An enumerable body, like every buffered Rails response — the callable-only
  # case has its own test above.
  def compressible?(content_type, length: 100_000)
    headers = { "content-type" => content_type }
    headers["content-length"] = length.to_s if length
    GrowthOs::Application::COMPRESSIBLE.call({}, 200, headers, [ "body" ])
  end
end
