# frozen_string_literal: true

require "test_helper"

class Frameworks::Projections::PublishedStateTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @projection = Frameworks::Projections::PublishedState.new
  end

  context "FrameworkCreated" do
    should "create a FrameworkState::Framework read model" do
      framework_id = SecureRandom.uuid_v7
      event = Frameworks::Events::FrameworkCreated.new(
        data: { framework_id: framework_id, name: "Design Growth" },
        metadata: { tenant_id: @tenant.id }
      )

      @projection.call(event)

      ActsAsTenant.with_tenant(@tenant) do
        read_model = FrameworkState::Framework.find_by(framework_id: framework_id)
        assert_not_nil read_model
        assert_equal "Design Growth", read_model.name
        assert_equal @tenant.id, read_model.tenant_id
        assert_equal 0, read_model.current_published_version
        assert_equal false, read_model.draft_in_progress
      end
    end
  end
end
