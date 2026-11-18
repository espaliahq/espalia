# frozen_string_literal: true

# A one-role framework (E1, E2) built through the real commands and published,
# for tests of a later publish that renumbers a level. A factory-built
# framework won't do: a publish rebuilds the levels from the event stream,
# which a factory never wrote.
module RenumberedLevelFixture
  TwoLevelFramework = Struct.new(:tenant, :framework_id, :role_id, :level_id, keyword_init: true)

  # @param tenant [Tenant]
  # @return [RenumberedLevelFixture::TwoLevelFramework] with `level_id` the E2 level, at ordinal 2
  def build_published_two_level_framework(tenant:)
    ActsAsTenant.with_tenant(tenant) do
      framework_id, family_id, role_id, level_id = Array.new(4) { SecureRandom.uuid_v7 }
      frameworks = Frameworks::CommandHandler.new
      frameworks.create_framework(framework_id, "Growth")
      frameworks.add_role_family(framework_id, family_id, "Engineering")
      frameworks.add_role(framework_id, role_id, family_id, "Engineer", "E", "ic")
      frameworks.add_level(framework_id, SecureRandom.uuid_v7, role_id, 1, "Engineer 1", "E1", is_entry: true)
      frameworks.add_level(framework_id, level_id, role_id, 2, "Engineer 2", "E2")
      frameworks.publish_version(framework_id, "seed")
      TwoLevelFramework.new(tenant: tenant, framework_id: framework_id, role_id: role_id, level_id: level_id)
    end
  end

  # Assigns the person to E2 on first call, then enrols them in a new cycle at E2.
  #
  # @return [String] the cycle id
  def enrol_at_e2(person, fx)
    ActsAsTenant.with_tenant(fx.tenant) do
      unless PersonFrameworkAssignment.exists?(person_id: person.id, framework_id: fx.framework_id)
        PersonDevelopment::CommandHandler.new.assign_to_framework(person.id, fx.framework_id, fx.role_id, fx.level_id)
      end
      cycle_id = SecureRandom.uuid_v7
      cycles = AssessmentCycles::CommandHandler.new
      cycles.define_cycle(cycle_id, fx.framework_id, "Cycle", "regular", 1)
      cycles.enroll(cycle_id, person.id, role_id: fx.role_id, level_id: fx.level_id)
      cycle_id
    end
  end

  # Moves E2 to a new ordinal in a new draft, which takes effect only once published.
  def renumber_e2_in_draft(fx, to: 3)
    ActsAsTenant.with_tenant(fx.tenant) do
      version = FrameworkState::Framework.find_by!(framework_id: fx.framework_id).current_published_version
      frameworks = Frameworks::CommandHandler.new
      frameworks.start_draft(fx.framework_id, version + 1, "tester")
      frameworks.change_level_ordinal(fx.framework_id, fx.level_id, to, reason: "Room for a level between")
    end
  end

  def publish_draft(fx)
    ActsAsTenant.with_tenant(fx.tenant) { Frameworks::CommandHandler.new.publish_version(fx.framework_id, "tester") }
  end
end

ActiveSupport::TestCase.include(RenumberedLevelFixture)
