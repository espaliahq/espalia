# frozen_string_literal: true

require "test_helper"

class FeedbackExchangeConfigTest < ActiveSupport::TestCase
  context "defaults" do
    subject { FeedbackExchangeConfig.new }

    should "be off, sending and importing every type" do
      assert_equal "exchange", subject.provider
      assert_not subject.enabled?
      assert_equal %w[all], subject.import_kinds
      assert_equal %w[all], subject.export_kinds
    end
  end

  should "load a config stored with the switch it used to carry, and ignore it" do
    config = FeedbackExchangeConfig.to_type.cast_value({ "peer_name" => "chip", "suggestions_enabled" => true })

    assert_equal "chip", config.peer_name
    assert_not_respond_to config, :suggestions_enabled?
    assert config.valid?
  end

  context "base_url" do
    should "accept https" do
      config = FeedbackExchangeConfig.new(base_url: "https://chip.example.com/api/feedback-exchange")
      assert config.valid?
    end

    should "refuse http outside development" do
      config = FeedbackExchangeConfig.new(base_url: "http://chip.example.com")
      assert_not config.valid?
      assert_includes config.errors[:base_url], "must start with https://"
    end

    should "accept http in development" do
      Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("development")) do
        assert FeedbackExchangeConfig.new(base_url: "http://rails-app:4000/api").valid?
      end
    end

    should "refuse other schemes and junk" do
      assert_not FeedbackExchangeConfig.new(base_url: "ftp://chip.example.com").valid?
      assert_not FeedbackExchangeConfig.new(base_url: "https://").valid?
      assert_not FeedbackExchangeConfig.new(base_url: "not a url").valid?
    end

    should "refuse a login, query or fragment in the address" do
      %w[https://u:p@chip.example.com/x https://chip.example.com/x?env=prod https://chip.example.com/x#frag].each do |url|
        assert_not FeedbackExchangeConfig.new(base_url: url).valid?, "expected #{url} to be refused"
      end
    end

    should "refuse a private network address" do
      %w[https://localhost/x https://127.0.0.1/x https://10.0.0.5/x https://192.168.1.2/x https://169.254.169.254/x
         https://[::1]/x https://printer.local/x https://db.internal/x].each do |url|
        config = FeedbackExchangeConfig.new(base_url: url)
        assert_not config.valid?, "expected #{url} to be refused"
        assert_includes config.errors[:base_url], "must not be a private network address"
      end
    end

    should "refuse non-canonical IPv4 forms and IPv4 wrapped in IPv6" do
      %w[https://127.1/x https://2130706433/x https://0x7f000001/x https://0177.0.0.1/x https://[::ffff:127.0.0.1]/x
         https://[::127.0.0.1]/x https://100.64.0.1/x].each do |url|
        assert_not FeedbackExchangeConfig.new(base_url: url).valid?, "expected #{url} to be refused"
      end
    end

    should "allow a private address in development" do
      Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("development")) do
        assert FeedbackExchangeConfig.new(base_url: "https://127.0.0.1:4000/api").valid?
      end
    end

    should "be optional while the exchange is off" do
      assert FeedbackExchangeConfig.new(base_url: "").valid?
    end

    should "be required once enabled" do
      config = FeedbackExchangeConfig.new(enabled: true, peer_name: "chip")
      assert_not config.valid?
      assert_not_empty config.errors[:base_url]
    end
  end

  context "kinds" do
    should "accept evidence types" do
      assert FeedbackExchangeConfig.new(import_kinds: %w[peer_feedback impact], export_kinds: EvidenceItem::EVIDENCE_TYPES).valid?
    end

    should "accept the generic feedback kind as an import filter only" do
      assert FeedbackExchangeConfig.new(import_kinds: %w[feedback]).valid?

      config = FeedbackExchangeConfig.new(export_kinds: %w[feedback impact])
      assert_not config.valid?
      assert_includes config.errors[:export_kinds].first, "feedback"
    end

    should "refuse anything else in either list" do
      %i[import_kinds export_kinds].each do |list|
        config = FeedbackExchangeConfig.new(list => %w[impact gossip])
        assert_not config.valid?
        assert_includes config.errors[list].first, "gossip"
      end
    end

    should "accept all in either list" do
      assert FeedbackExchangeConfig.new.valid?
      assert FeedbackExchangeConfig.new(import_kinds: %w[all], export_kinds: %w[all]).valid?
    end
  end

  context "resolving the types" do
    should "store all as all, and resolve it to every evidence type only when read" do
      tenant = create(:tenant, feedback_exchange_config: FeedbackExchangeConfig.new(export_kinds: %w[all]))
      stored = tenant.reload.read_attribute_before_type_cast(:feedback_exchange_config)

      assert_equal %w[all], JSON.parse(stored)["export_kinds"]
      assert tenant.feedback_exchange_config.exports_all_kinds?
      assert_equal EvidenceItem::EVIDENCE_TYPES, tenant.feedback_exchange_config.exported_kinds
    end

    should "send exactly the listed types, and none for an empty list" do
      assert_not FeedbackExchangeConfig.new(export_kinds: %w[impact]).exports_all_kinds?
      assert_equal %w[impact], FeedbackExchangeConfig.new(export_kinds: %w[impact]).exported_kinds
      assert_empty FeedbackExchangeConfig.new(export_kinds: []).exported_kinds
    end

    should "keep only all when types are listed beside it, however it is written" do
      config = FeedbackExchangeConfig.new(export_kinds: %w[impact all], import_kinds: [ "impact", :all ])
      loaded = FeedbackExchangeConfig.to_type.cast_value({ "export_kinds" => %w[all observation] })
      tenant = create(:tenant)
      tenant.update_feedback_exchange!(settings: { import_kinds: %w[peer_feedback all] })

      assert_equal [ %w[all] ] * 2, [ config.export_kinds, config.import_kinds ]
      assert_equal %w[all], loaded.export_kinds
      assert_equal %w[all], tenant.reload.feedback_exchange_config.import_kinds
      assert config.imports_kind?("observation")
    end

    should "import any kind when all, even one Espalia does not know" do
      config = FeedbackExchangeConfig.new(import_kinds: %w[all])

      assert config.imports_kind?("feedback")
      assert config.imports_kind?("shout_out")
    end

    should "import exactly the listed kinds, and nothing for an empty list" do
      config = FeedbackExchangeConfig.new(import_kinds: %w[peer_feedback])

      assert config.imports_kind?("peer_feedback")
      assert config.imports_kind?(:peer_feedback)
      assert_not config.imports_kind?("feedback")
      assert_not FeedbackExchangeConfig.new(import_kinds: []).imports_kind?("peer_feedback")
    end
  end

  context "peer_name" do
    should "accept a slug" do
      assert FeedbackExchangeConfig.new(peer_name: "chip").valid?
      assert FeedbackExchangeConfig.new(peer_name: "acme-feedback-2").valid?
    end

    should "refuse anything else" do
      %w[Chip chip_x chip.io -chip chip-].each do |name|
        assert_not FeedbackExchangeConfig.new(peer_name: name).valid?, "expected #{name} to be refused"
      end
    end
  end

  context "#normalized_base_url" do
    should "drop a trailing slash and whitespace" do
      assert_equal "https://a.example/x", FeedbackExchangeConfig.new(base_url: " https://a.example/x/ ").normalized_base_url
    end
  end

  context "#configured?" do
    setup do
      @tenant = create(:tenant)
      @config = FeedbackExchangeConfig.new(enabled: true, peer_name: "chip", base_url: "https://chip.example.com")
    end

    should "need both secrets" do
      assert_not @config.configured?(@tenant)
      @tenant.update_feedback_exchange!(outbound_secret: "a" * 32, inbound_secret: "b" * 32)
      assert @config.configured?(@tenant)
    end

    should "be false while disabled" do
      @tenant.update_feedback_exchange!(outbound_secret: "a" * 32, inbound_secret: "b" * 32)
      @config.enabled = false
      assert_not @config.configured?(@tenant)
    end
  end
end
