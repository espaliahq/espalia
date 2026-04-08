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
  end
end
