# frozen_string_literal: true

require "test_helper"

# A note seals under the plan's key while a sealed end state keeps its own
# key, so forgetting the person and deleting the plan each remove only what
# they own.
class TeamPlanning::ChangeNoteTest < ActiveSupport::TestCase
  class CapacitySet < TeamPlanning::Events::Change
    extend Shreddable
    extend TeamPlanning::Events::SealedChange

    shreddable :fte, by: :person, person: :subject_id

    def self.facet = "capacity"
  end

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @ada = create(:person, tenant: @tenant)
    editor = create(:person, tenant: @tenant)
    user = create(:user)
    actor = AuthorizationContext.new(user:, tenant_user: create(:tenant_user, tenant: @tenant, user:, person: editor, role: :admin), person: editor)
    @plan_id = SecureRandom.uuid_v7
    handler = TeamPlanning::CommandHandler.new(actor:)
    handler.create_plan(@plan_id, name: "Next year", base_on: "2026-11-14")
    handler.set_change(@plan_id, TeamPlanning::Events::LevelSet, scenario_id: @plan_id, subject_id: @ada.id,
                                                                 end_state: { level: "4" }, note: "Ready since the platform launch")
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def level_set = Rails.configuration.event_store.read.stream(EventStreamNaming.plan_stream(@plan_id)).of_type(TeamPlanning::Events::LevelSet).to_a.sole

  should "read back both the level and the note" do
    assert_equal [ "4", "Ready since the platform launch" ], level_set.data.values_at(:level, :note).map(&:reveal)
  end

  should "remove the level and keep the note once the person is forgotten" do
    PlanKeyStore.new.destroy_person(@ada.id)

    assert level_set.data[:level].removed?
    assert_equal "Ready since the platform launch", level_set.data[:note].reveal
  end

  should "remove the note once the plan's key is destroyed" do
    PlanKeyStore.new.destroy_plan(@plan_id)

    assert level_set.data[:note].removed?
  end

  should "keep the note out of the end state a sealed change compares" do
    end_state = level_set.data.except(*TeamPlanning::Events::Change::FIELDS)

    assert_equal [ :level ], end_state.keys
    assert TeamPlanning::Events::LevelSet.same_end_state?(end_state, { level: Shreddable::Value.wrap("4") })
  end

  should "give a new sealed kind the note with nothing declared" do
    assert_equal({ note: :plan, fte: :person }, CapacitySet.shreddable_fields.transform_values { it[:by] })
    assert CapacitySet.seals_end_state?
    assert_not TeamPlanning::Events::DepartureSet.seals_end_state?
  end
end
