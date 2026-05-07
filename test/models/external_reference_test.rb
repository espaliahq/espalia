# frozen_string_literal: true

require "test_helper"

class ExternalReferenceTest < ActiveSupport::TestCase
  context "validations" do
    should "allow nil system" do
      ref = ExternalReference.new(system: nil, url: "https://example.com")
      assert ref.valid?
    end

    should "allow known systems" do
      ExternalReference::SYSTEMS.each do |sys|
        ref = ExternalReference.new(system: sys)
        assert ref.valid?, "expected #{sys.inspect} to be valid"
      end
    end

    should "reject unknown system" do
      ref = ExternalReference.new(system: "unknown_system")
      assert_not ref.valid?
      assert ref.errors[:system].any?
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
end
