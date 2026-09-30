# frozen_string_literal: true

require "test_helper"

class HrisSyncJobTest < ActiveSupport::TestCase
  context "#perform" do
    should "skip tenants without configured HRIS" do
      tenant = create(:tenant)

      # Should not raise — just returns early
      assert_nothing_raised do
        HrisSyncJob.new.perform(tenant)
      end
    end

    should "call sync_people on the HiBob adapter for configured tenants" do
      tenant = create(:tenant, :with_hibob_config)

      mock_adapter = Minitest::Mock.new
      mock_adapter.expect(:sync_people, { created: 0, updated: 0, deactivated: 0, errors: [] })

      Hris::Hibob::Adapter.stub(:new, mock_adapter) do
        HrisSyncJob.new.perform(tenant)
      end

      assert mock_adapter.verify
    end

    should "log the titles and levels the sync could not assign" do
      tenant = create(:tenant, :with_hibob_config)
      result = { created: 0, updated: 0, deactivated: 0, errors: [],
                 unmapped_titles: Set["Analytics Lead"], missing_levels: Set[{ code: "EM", ordinal: 9 }] }
      log = StringIO.new

      Hris::Hibob::Adapter.stub(:new, Struct.new(:sync_people).new(result)) do
        with_logger(Logger.new(log)) { HrisSyncJob.new.perform(tenant) }
      end

      assert_match(/Assignments skipped for tenant #{tenant.id}: unmapped_titles=\["Analytics Lead"\] missing_levels=/, log.string)
      assert_no_match(/missing_roles/, log.string)
    end
  end

  private

  def with_logger(logger)
    original = Rails.logger
    Rails.logger = logger
    yield
  ensure
    Rails.logger = original
  end
end
