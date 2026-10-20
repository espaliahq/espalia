# frozen_string_literal: true

require "test_helper"

class ExternalReferenceTest < ActiveSupport::TestCase
  context "validations" do
    should "allow nil system" do
      ref = ExternalReference.new(system: nil, url: "https://example.com")
      assert ref.valid?
    end

    should "allow known systems" do
      ExternalReference::KNOWN_SYSTEMS.each do |sys|
        ref = ExternalReference.new(system: sys)
        assert ref.valid?, "expected #{sys.inspect} to be valid"
      end
    end

    should "allow any slug, so a new peer needs no code change" do
      %w[chip some-peer some_peer peer2].each do |sys|
        assert ExternalReference.new(system: sys).valid?, "expected #{sys.inspect} to be valid"
      end
    end

    should "reject a system that is not a slug" do
      [ "Chip", "chip peer", "-chip", "chip_", "chip!" ].each do |sys|
        ref = ExternalReference.new(system: sys)
        assert_not ref.valid?, "expected #{sys.inspect} to be invalid"
        assert ref.errors[:system].any?
      end
    end

    should "reject javascript: URLs to prevent XSS when rendered as href" do
      ref = ExternalReference.new(system: "github", url: "javascript:alert(1)")
      assert_not ref.valid?
      assert ref.errors[:url].any?
    end

    should "reject data: URLs" do
      ref = ExternalReference.new(system: "github", url: "data:text/html,<script>alert(1)</script>")
      assert_not ref.valid?
    end

    should "accept http and https URLs" do
      assert ExternalReference.new(system: "github", url: "https://x.test/path").valid?
      assert ExternalReference.new(system: "github", url: "http://x.test/path").valid?
    end
  end

  context "#safe_url" do
    should "return the URL when scheme is http(s)" do
      assert_equal "https://x.test", ExternalReference.new(url: "https://x.test").safe_url
      assert_equal "http://x.test", ExternalReference.new(url: "http://x.test").safe_url
    end

    should "return nil for javascript: and other interactive schemes" do
      %w[javascript:alert(1) data:text/html,x vbscript:msgbox file:///etc/passwd].each do |bad|
        assert_nil ExternalReference.new(url: bad).safe_url, "expected #{bad.inspect} to be unsafe"
      end
    end

    should "return nil when url is blank" do
      assert_nil ExternalReference.new(url: nil).safe_url
      assert_nil ExternalReference.new.safe_url
    end

    should "return nil when url is malformed and unparseable" do
      assert_nil ExternalReference.new(url: "https://[bad").safe_url
    end
  end

  context "#present?" do
    should "be false when all fields blank" do
      assert_not ExternalReference.new.present?
    end

    should "be true with just a url" do
      assert ExternalReference.new(url: "https://example.com").present?
    end

    should "be true with just a system" do
      assert ExternalReference.new(system: "github").present?
    end

    should "be true when metadata has entries" do
      assert ExternalReference.new(metadata: { "pr_number" => "42" }).present?
    end

    should "be false when metadata is empty hash" do
      assert_not ExternalReference.new(metadata: {}).present?
    end
  end

  context "normalisation" do
    should "convert empty strings to nil for system, url, and external_id" do
      ref = ExternalReference.new(system: "", url: "  ", external_id: "")
      assert_nil ref.system
      assert_nil ref.url
      assert_nil ref.external_id
    end

    should "preserve non-blank values verbatim (apart from trim)" do
      ref = ExternalReference.new(system: "github", url: " https://x ", external_id: "42")
      assert_equal "github", ref.system
      assert_equal "https://x", ref.url
      assert_equal "42", ref.external_id
    end

    should "round-trip an all-empty form submission as a blank reference" do
      ref = ExternalReference.new(system: "", url: "", external_id: "")
      assert ref.valid?
      assert_not ref.present?
    end
  end

  context "#blank?" do
    should "be the inverse of #present?" do
      [
        ExternalReference.new,
        ExternalReference.new(metadata: {}),
        ExternalReference.new(system: "github"),
        ExternalReference.new(url: "https://example.com"),
        ExternalReference.new(metadata: { "pr_number" => "42" })
      ].each do |ref|
        assert_equal !ref.present?, ref.blank?, "blank? mismatched present? for #{ref.inspect}"
      end
    end
  end

  context ".validation_error_for" do
    should "return nil for a blank or nil payload" do
      assert_nil ExternalReference.validation_error_for(nil)
      assert_nil ExternalReference.validation_error_for({})
    end

    should "return nil for an accepted shape (string or symbol keys)" do
      assert_nil ExternalReference.validation_error_for({ "system" => "github", "url" => "https://x.test/1" })
      assert_nil ExternalReference.validation_error_for({ system: "slack", url: "https://x.test/2", external_id: "9" })
      assert_nil ExternalReference.validation_error_for({ "metadata" => { "pr" => "42" } })
    end

    # The reported bug: an unknown key (e.g. `title`) made `new(payload)` raise
    # ActiveModel::UnknownAttributeError, which surfaced to MCP clients as an
    # opaque -32603. It must now be a clear, non-raising validation reason.
    should "name unknown keys instead of raising (string or symbol)" do
      %w[title].each do |_|
        msg = ExternalReference.validation_error_for({ "url" => "https://x.test", "title" => "My link" })
        assert_match(/unknown field/, msg)
        assert_match(/title/, msg)
        assert_match(/allowed: system, url, external_id, metadata/, msg)
      end
      assert_match(/title/, ExternalReference.validation_error_for({ url: "https://x.test", title: "x" }))
    end

    should "report an invalid system or unsafe url without raising" do
      assert_match(/system/i, ExternalReference.validation_error_for({ "system" => "My Space" }))
      assert_match(/url/i, ExternalReference.validation_error_for({ "url" => "javascript:alert(1)" }))
    end
  end

  context ".json_schema" do
    should "publish the accepted keys, the slug pattern and the known systems as examples" do
      schema = ExternalReference.json_schema
      assert_equal "object", schema[:type]
      assert_equal %w[system url external_id metadata], schema[:properties].keys.map(&:to_s)
      assert_nil schema[:properties][:system][:enum]
      assert_equal ExternalReference::KNOWN_SYSTEMS, schema[:properties][:system][:examples]
      assert_match Regexp.new(schema[:properties][:system][:pattern]), "google_doc"
      assert_no_match Regexp.new(schema[:properties][:system][:pattern]), "Google Doc"
      assert_equal false, schema[:additionalProperties]
    end
  end
end
