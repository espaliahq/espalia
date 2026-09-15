# frozen_string_literal: true

require "test_helper"

# The review page's rows and the publish gate read the same answer from here.
class Frameworks::RetiringCapabilitiesQueryTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @framework_id = SecureRandom.uuid_v7
      @gone_id = SecureRandom.uuid_v7
      @retiring_id = SecureRandom.uuid_v7
      @gone_stable = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      cat_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Eng")
      handler.add_capability_category(@framework_id, cat_id, "Thinking")
      handler.add_capability(@framework_id, @gone_id, @gone_stable, cat_id, "Gone In V2")
      handler.add_capability(@framework_id, @retiring_id, SecureRandom.uuid_v7, cat_id, "Retiring In V3")
      handler.add_capability(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, cat_id, "Survivor")
      handler.publish_version(@framework_id, "seed")                    # v1
      handler.archive_capability(@framework_id, @gone_id, reason: "x")  # auto-opens v2
      handler.define_migration_mapping(@framework_id, SecureRandom.uuid_v7, @gone_stable, nil, "archived")
      handler.publish_version(@framework_id, "seed")                    # v2: archive is live
      handler.archive_capability(@framework_id, @retiring_id, reason: "x") # auto-opens v3
    end
  end

  def query
    ActsAsTenant.with_tenant(@tenant) do
      Frameworks::RetiringCapabilitiesQuery.new(FrameworkState::Framework.find_by!(framework_id: @framework_id))
    end
  end

  should "list only the capabilities retired in the open draft" do
    ActsAsTenant.with_tenant(@tenant) do
      assert_equal [ "Retiring In V3" ], query.call.map { |e| e[:capability].name }
      assert_equal [ "Retiring In V3" ], query.unmapped_names
    end
  end

  should "offer neither the retiring nor the previously archived capabilities as survivors" do
    ActsAsTenant.with_tenant(@tenant) do
      assert_equal [ "Survivor" ], query.survivors.map { |s| s[:name] }
    end
  end
end
