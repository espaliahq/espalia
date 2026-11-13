# frozen_string_literal: true

require "test_helper"

class Hris::BaseAdapterTest < ActiveSupport::TestCase
  class CountingAdapter < Hris::BaseAdapter
    attr_reader :fetches
    attr_accessor :failure

    def provider_name = "counting"

    def fetch_field_catalogue
      @fetches = fetches.to_i + 1
      raise failure if failure

      [ Hris::Field.new(id: "work.title", name: "Job title", kind: :text) ]
    end
  end

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
  end

  context "#field_catalogue" do
    should "fetch once and serve the cached catalogue after" do
      adapter = CountingAdapter.new(@tenant)

      2.times { assert_equal [ "Job title" ], adapter.field_catalogue.map(&:name) }
      assert_equal 1, adapter.fetches
    end

    should "fetch again once the catalogue expires" do
      adapter = CountingAdapter.new(@tenant)
      adapter.field_catalogue

      travel(Hris::BaseAdapter::FIELD_CATALOGUE_TTL + 1.minute) { adapter.field_catalogue }

      assert_equal 2, adapter.fetches
    end

    should "keep each tenant's catalogue apart" do
      CountingAdapter.new(@tenant).field_catalogue
      other = CountingAdapter.new(create(:tenant, :with_hibob_config))

      other.field_catalogue

      assert_equal 1, other.fetches
    end

    should "fetch afresh after the tenant connects another HRIS account" do
      CountingAdapter.new(@tenant).field_catalogue
      @tenant.update!(hris_credentials: { "service_user_id" => "another-account", "api_token" => "t" })

      adapter = CountingAdapter.new(@tenant.reload)
      adapter.field_catalogue

      assert_equal 1, adapter.fetches
    end

    should "raise an HRIS error and cache nothing, so the next call tries again" do
      adapter = CountingAdapter.new(@tenant)
      adapter.failure = Hris::Hibob::Errors::ApiError.new(status: 503, body: "down")

      assert_raises(Hris::Hibob::Errors::ApiError) { adapter.field_catalogue }
      adapter.failure = nil

      assert_equal [ "Job title" ], adapter.field_catalogue.map(&:name)
      assert_equal 2, adapter.fetches
    end
  end

  should "require a provider to implement fetch_field_catalogue" do
    assert_raises(NotImplementedError) { Hris::BaseAdapter.new(@tenant).fetch_field_catalogue }
  end
end
