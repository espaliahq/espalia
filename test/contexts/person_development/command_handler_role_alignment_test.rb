# frozen_string_literal: true

require "test_helper"

# The command handler supplies what the stream can't know: which role is
# home, and which cells a role reads.
class PersonDevelopment::CommandHandlerRoleAlignmentTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = PersonDevelopment::CommandHandler.new
    @framework_id = SecureRandom.uuid_v7
    create(:framework_state, framework_id: @framework_id)
    family = create(:framework_role_family, framework_id: @framework_id)
    @engineer = create(:framework_role, role_family_id: family.role_family_id, code: "E")
    @pm = create(:framework_role, role_family_id: family.role_family_id, code: "PM")
    level = create(:framework_level, role_id: @engineer.role_id, ordinal: 3)
    category = create(:framework_capability_category, framework_id: @framework_id)
    @shared = bound_capability(category, [ @engineer, @pm ])
    @pm_only = bound_capability(category, [ @pm ])

    @manager = create(:person, tenant: @tenant)
    @person = create(:person, tenant: @tenant, manager: @manager)
    @handler.assign_to_framework(@person.id, @framework_id, @engineer.role_id, level.level_id)
    @cycle_id = SecureRandom.uuid_v7
    cycles = AssessmentCycles::CommandHandler.new
    cycles.define_cycle(@cycle_id, @framework_id, "Q3", "regular", 1)
    cycles.enroll(@cycle_id, @person.id)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def bound_capability(category, roles)
    capability = create(:framework_capability, category_id: category.category_id)
    roles.each { |role| create(:framework_capability_role_binding, capability_id: capability.capability_id, role_id: role.role_id) }
    create(:framework_behavioural_expectation, capability_id: capability.capability_id, level_ordinal: 3)
    capability
  end

  def last_event(klass)
    stream = EventStreamNaming.person_development_stream(@person.id, @framework_id)
    Rails.configuration.event_store.read.stream(stream).to_a.grep(klass).last
  end

  should "start against the home role with its cells when no role is named" do
    @handler.start_alignment(@person.id, @framework_id, @cycle_id, started_by_id: @manager.id)

    event = last_event(PersonDevelopment::Events::AlignmentStarted)
    assert_equal @engineer.role_id, event.data[:role_id]
    assert_equal [ [ @shared.stable_id, 3 ] ], event.data[:cell_keys]
  end

  should "start against a named role with that role's cells" do
    @handler.start_alignment(@person.id, @framework_id, @cycle_id, started_by_id: @manager.id,
                             role_id: @pm.role_id, level_ordinal: 3)

    event = last_event(PersonDevelopment::Events::AlignmentStarted)
    assert_equal @pm.role_id, event.data[:role_id]
    assert_equal 3, event.data[:level_ordinal]
    assert_equal [ [ @pm_only.stable_id, 3 ], [ @shared.stable_id, 3 ] ].sort, event.data[:cell_keys].sort
  end

  should "complete and re-open the named role" do
    @handler.start_alignment(@person.id, @framework_id, @cycle_id, started_by_id: @manager.id, role_id: @pm.role_id)
    @handler.complete_alignment(@person.id, @framework_id, @cycle_id, completed_by_id: @manager.id,
                                role_id: @pm.role_id)
    assert_equal @pm.role_id, last_event(PersonDevelopment::Events::FullAlignmentCompleted).data[:role_id]

    @handler.reopen_alignment(@person.id, @framework_id, @cycle_id, reopened_by_id: @manager.id, role_id: @pm.role_id)
    assert_equal @pm.role_id, last_event(PersonDevelopment::Events::AlignmentReopened).data[:role_id]
  end
end
