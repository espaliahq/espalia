# frozen_string_literal: true

require "test_helper"

# The list's exploration entries (ADR-22): open ones only, with the person's
# vetted self ratings at the target level counted against its capabilities.
class Assessments::OpenExplorationsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @fx = build_role_lens_framework(tenant: @tenant)
    @person = create(:person, tenant: @tenant)
    @assignment, @cycle_id = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant)
    @handler = PersonDevelopment::CommandHandler.new
    @exploration_id = SecureRandom.uuid_v7
    @handler.start_exploration(@person.id, @fx.framework_id, @exploration_id, target_role_id: @fx.pm.role_id,
                               target_level_id: @fx.pm_levels.fetch(3).level_id, target_level_ordinal: 3,
                               started_by_id: @person.id)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def entry
    Assessments::OpenExplorations.for([ @assignment ], progress_for: [ @assignment ]).fetch(@assignment.id).sole
  end

  def rate(capability, source:)
    create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle_id, person_id: @person.id,
           framework_id: @fx.framework_id, capability_stable_id: capability.stable_id, level_ordinal: 3,
           self_rated_frequency: "some", self_rating_source: source)
  end

  should "count the vetted self ratings at the target level, not the carried ones" do
    rate(@fx.pm_only, source: "human")
    rate(@fx.shared, source: "seeded")

    assert_equal [ 1, 2 ], [ entry.rated, entry.total ]
    assert_equal "PM3", entry.code
  end

  should "leave the count out between cycles" do
    AssessmentCycles::CommandHandler.new.close_cycle(@cycle_id)

    assert_equal [ nil, 2 ], [ entry.rated, entry.total ]
  end

  should "drop a closed exploration" do
    @handler.close_exploration(@person.id, @fx.framework_id, @exploration_id, closed_by_id: @person.id,
                               outcome: "not_now")

    assert_empty Assessments::OpenExplorations.for([ @assignment ])
  end
end
