# frozen_string_literal: true

require "test_helper"

class HrisSyncIssueTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
  end

  teardown { ActsAsTenant.current_tenant = nil }

  subject { HrisSyncIssue.new(tenant: @tenant, provider: "hibob", kind: "in_structure", unit_id: SecureRandom.uuid_v7, first_seen_on: Date.current, last_seen_on: Date.current) }

  context "validations" do
    should validate_presence_of(:provider)
    should validate_presence_of(:unit_id)
    should validate_inclusion_of(:kind).in_array(HrisSyncIssue::KINDS)
  end

  context ".replace_in_structure" do
    should "leave alone the issues for units the sync didn't read" do
      unread = subject.tap(&:save!)

      HrisSyncIssue.replace_in_structure(provider: "hibob", unit_ids: [ SecureRandom.uuid_v7 ], reported: [], today: Date.current)

      assert HrisSyncIssue.exists?(unread.id)
    end
  end
end
