# frozen_string_literal: true

require "test_helper"

class FrameworkPublicationTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @framework_id = SecureRandom.uuid_v7
  end

  should "allow only one queued or running publication per framework" do
    ActsAsTenant.with_tenant(@tenant) do
      create(:framework_publication, tenant: @tenant, framework_id: @framework_id, status: :queued)

      assert_raises(ActiveRecord::RecordNotUnique) do
        create(:framework_publication, tenant: @tenant, framework_id: @framework_id, status: :running)
      end
    end
  end

  should "allow a new request once the previous one has finished" do
    ActsAsTenant.with_tenant(@tenant) do
      create(:framework_publication, tenant: @tenant, framework_id: @framework_id, status: :failed)
      create(:framework_publication, tenant: @tenant, framework_id: @framework_id, status: :succeeded)

      assert_nothing_raised do
        create(:framework_publication, tenant: @tenant, framework_id: @framework_id, status: :queued)
      end
      assert FrameworkPublication.in_flight_for?(@framework_id)
    end
  end

  should "report the newest request for a draft" do
    ActsAsTenant.with_tenant(@tenant) do
      older = create(:framework_publication, tenant: @tenant, framework_id: @framework_id,
        draft_version: 2, status: :failed, created_at: 2.hours.ago)
      newer = create(:framework_publication, tenant: @tenant, framework_id: @framework_id,
        draft_version: 2, status: :failed, created_at: 1.hour.ago)
      create(:framework_publication, tenant: @tenant, framework_id: @framework_id, draft_version: 3, status: :queued)

      assert_equal newer, FrameworkPublication.latest_for(@framework_id, 2)
      assert_not_equal older, FrameworkPublication.latest_for(@framework_id, 2)
      assert_not FrameworkPublication.in_flight_for?(SecureRandom.uuid_v7)
    end
  end
end
