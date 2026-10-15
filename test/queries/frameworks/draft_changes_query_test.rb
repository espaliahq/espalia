# frozen_string_literal: true

require "test_helper"

# What the publish-review page tells the person confirming a version (#497).
class Frameworks::DraftChangesQueryTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @handler = Frameworks::CommandHandler.new
    @framework_id = SecureRandom.uuid_v7
    @cat_id = SecureRandom.uuid_v7
    @ae = SecureRandom.uuid_v7
    @de = SecureRandom.uuid_v7
    @design_id = SecureRandom.uuid_v7
    @sql_id = SecureRandom.uuid_v7
    @design_ae = SecureRandom.uuid_v7
    @sql_ae = SecureRandom.uuid_v7

    within_tenant do
      family = SecureRandom.uuid_v7
      @handler.create_framework(@framework_id, "Data")
      @handler.add_role_family(@framework_id, family, "Data")
      @handler.add_role(@framework_id, @ae, family, "Analytics Engineer", "AE", "ic")
      @handler.add_role(@framework_id, @de, family, "Data Engineer", "DE", "ic")
      @ae1 = SecureRandom.uuid_v7
      @handler.add_level(@framework_id, @ae1, @ae, 1, "Analytics Engineer I", "AE1", is_entry: true)
      @handler.add_level(@framework_id, SecureRandom.uuid_v7, @de, 1, "Data Engineer I", "DE1", is_entry: true)
      @handler.add_capability_category(@framework_id, @cat_id, "Engineering")
      @handler.add_capability(@framework_id, @design_id, SecureRandom.uuid_v7, @cat_id, "System Design")
      @handler.add_capability(@framework_id, @sql_id, SecureRandom.uuid_v7, @cat_id, "SQL")
      @handler.create_capability_role_binding(@framework_id, @design_ae, @design_id, @ae)
      @handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @design_id, @de)
      @handler.create_capability_role_binding(@framework_id, @sql_ae, @sql_id, @ae)
      @handler.publish_version(@framework_id, "seed") # v1

      cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id)
      2.times { create(:assessment_cycle_enrollment, tenant: @tenant, cycle: cycle, role_id: @ae) }
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: cycle, role_id: @de)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: cycle, role_id: @ae, status: "withdrawn")
      # Enrolled before the role snapshot existed: counted by their assignment.
      unsnapshotted = create(:person, tenant: @tenant)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: cycle, person_id: unsnapshotted.id, role_id: nil)
      create(:person_framework_assignment, tenant: @tenant, person_id: unsnapshotted.id,
             framework_id: @framework_id, role_id: @ae, level_id: @ae1)
    end
  end

  def changes
    within_tenant do
      Frameworks::DraftChangesQuery.new(FrameworkState::Framework.find_by!(framework_id: @framework_id))
    end
  end

  def within_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  should "name the capability and role a binding came off, and the open-cycle people it reaches" do
    within_tenant { @handler.remove_capability_role_binding(@framework_id, @design_ae) } # opens v2

    assert_equal [ { capability: "System Design", role: "Analytics Engineer", open_cycle_people: 3 } ],
                 within_tenant { changes.call[:roles_removed] }
  end

  should "list nothing for a binding removed and added back" do
    within_tenant do
      @handler.remove_capability_role_binding(@framework_id, @sql_ae)
      @handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @sql_id, @ae)
    end

    result = within_tenant { changes }
    assert result.empty?, "expected no changes, got #{result.call.reject { |_, v| v.empty? }}"
  end

  should "list an archive once, not once per role it drops" do
    within_tenant { @handler.archive_capability(@framework_id, @design_id, reason: "x") }

    result = within_tenant { changes.call }
    assert_equal [ { capability: "System Design", open_cycle_people: 4 } ], result[:capabilities_archived]
    assert_empty result[:roles_removed]
  end

  should "count an archive over the roles it is published with, even one removed earlier in the draft" do
    within_tenant do
      @handler.remove_capability_role_binding(@framework_id, @design_ae)
      @handler.archive_capability(@framework_id, @design_id, reason: "x")
    end

    assert_equal [ { capability: "System Design", open_cycle_people: 4 } ],
                 within_tenant { changes.call[:capabilities_archived] }
  end

  should "list nothing more for a capability being archived than the archive" do
    within_tenant do
      family = FrameworkState::Role.find_by!(role_id: @ae).role_family_id
      ml = SecureRandom.uuid_v7
      @handler.add_role(@framework_id, ml, family, "ML Engineer", "ML", "ic")
      @handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @design_id, ml)
      @handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @design_id, 1, "X")
      @handler.archive_capability(@framework_id, @design_id, reason: "x")
    end

    result = within_tenant { changes.call }
    assert_equal [ "System Design" ], result[:capabilities_archived].map { |c| c[:capability] }
    assert_empty result[:roles_added]
    assert_empty result[:expectations_added]
  end

  should "not list a capability added and archived in the same draft" do
    within_tenant do
      new_id = SecureRandom.uuid_v7
      @handler.add_capability(@framework_id, new_id, SecureRandom.uuid_v7, @cat_id, "Short-lived")
      @handler.archive_capability(@framework_id, new_id, reason: "x")
    end

    result = within_tenant { changes }
    assert result.empty?, "expected no changes, got #{result.call.reject { |_, v| v.empty? }}"
  end

  should "list a level moved to another ordinal" do
    within_tenant do
      @handler.start_draft(@framework_id, 2, "tester")
      @handler.change_level_ordinal(@framework_id, @ae1, 3, reason: "x")
    end

    assert_equal [ { role: "AE · Analytics Engineer", level: "AE1", title: "Analytics Engineer I", from: 1, to: 3 } ],
                 within_tenant { changes.call[:levels_moved] }
  end

  should "list added capabilities with their roles, and roles added to existing ones" do
    within_tenant do
      new_id = SecureRandom.uuid_v7
      @handler.add_capability(@framework_id, new_id, SecureRandom.uuid_v7, @cat_id, "dbt Modelling")
      @handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, new_id, @ae)
      @handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @sql_id, @de)
    end

    result = within_tenant { changes.call }
    assert_equal [ { capability: "dbt Modelling", category: "Engineering", roles: [ "Analytics Engineer" ] } ],
                 result[:capabilities_added]
    assert_equal [ { capability: "SQL", role: "Data Engineer" } ], result[:roles_added]
  end

  should "list added levels and expectations" do
    within_tenant do
      @handler.add_level(@framework_id, SecureRandom.uuid_v7, @ae, 2, "Analytics Engineer II", "AE2")
      @handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @sql_id, 2, "Writes it")
    end

    result = within_tenant { changes.call }
    assert_equal [ { role: "AE · Analytics Engineer", level: "AE2", title: "Analytics Engineer II" } ], result[:levels_added]
    assert_equal [ { capability: "SQL", level_ordinal: 2 } ], result[:expectations_added]
  end

  should "list an archived category" do
    within_tenant do
      empty_cat = SecureRandom.uuid_v7
      @handler.add_capability_category(@framework_id, empty_cat, "Old Stuff")
      @handler.start_draft(@framework_id, 2, "tester")
      @handler.archive_capability_category(@framework_id, empty_cat, reason: "x")
    end

    assert_equal [ { category: "Old Stuff" } ], within_tenant { changes.call[:categories_archived] }
  end
end
