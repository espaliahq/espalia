# frozen_string_literal: true

require "test_helper"

class Frameworks::AggregateCollaboratorTest < ActiveSupport::TestCase
  setup do
    @aggregate = Frameworks::Aggregate.new
    @framework_id = SecureRandom.uuid_v7
    @person_id = SecureRandom.uuid_v7
    @added_by = SecureRandom.uuid_v7
    @aggregate.create(@framework_id, "Engineering Growth")
  end

  # ── Add collaborator ──

  context "#add_collaborator" do
    should "apply CollaboratorAdded event" do
      @aggregate.add_collaborator(@framework_id, @person_id, "editor", added_by: @added_by)

      events = @aggregate.unpublished_events.to_a
      event = events.last
      assert_kind_of Frameworks::Events::CollaboratorAdded, event
      assert_equal @framework_id, event.data[:framework_id]
      assert_equal @person_id, event.data[:person_id]
      assert_equal "editor", event.data[:collaborator_role]
      assert_nil event.data[:scope_type]
    end

    should "apply CollaboratorAdded with scope" do
      scope_id = SecureRandom.uuid_v7
      @aggregate.add_collaborator(@framework_id, @person_id, "role_lead",
                                  scope_type: "role", scope_id: scope_id, added_by: @added_by)

      event = @aggregate.unpublished_events.to_a.last
      assert_equal "role", event.data[:scope_type]
      assert_equal scope_id, event.data[:scope_id]
    end

    should "raise if collaborator already has this role" do
      @aggregate.add_collaborator(@framework_id, @person_id, "editor", added_by: @added_by)

      err = assert_raises(RuntimeError) do
        @aggregate.add_collaborator(@framework_id, @person_id, "editor", added_by: @added_by)
      end
      assert_match /already has this role/, err.message
    end

    should "allow same person with different roles" do
      @aggregate.add_collaborator(@framework_id, @person_id, "editor", added_by: @added_by)
      @aggregate.add_collaborator(@framework_id, @person_id, "role_lead",
                                  scope_type: "role", scope_id: SecureRandom.uuid_v7, added_by: @added_by)

      collab_events = @aggregate.unpublished_events.to_a.select { |e|
        e.is_a?(Frameworks::Events::CollaboratorAdded)
      }
      assert_equal 2, collab_events.size
    end

    should "raise if framework not created" do
      aggregate = Frameworks::Aggregate.new

      err = assert_raises(RuntimeError) do
        aggregate.add_collaborator(SecureRandom.uuid_v7, @person_id, "editor", added_by: @added_by)
      end
      assert_match /not yet created/, err.message
    end
  end

  # ── Change collaborator role ──

  context "#change_collaborator_role" do
    should "apply CollaboratorRoleChanged event" do
      @aggregate.add_collaborator(@framework_id, @person_id, "editor", added_by: @added_by)
      @aggregate.change_collaborator_role(@framework_id, @person_id, "editor", "owner", changed_by: @added_by)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::CollaboratorRoleChanged, event
      assert_equal "editor", event.data[:old_role]
      assert_equal "owner", event.data[:new_role]
    end

    should "raise if collaborator does not have old role" do
      err = assert_raises(RuntimeError) do
        @aggregate.change_collaborator_role(@framework_id, @person_id, "editor", "owner", changed_by: @added_by)
      end
      assert_match /does not have this role/, err.message
    end
  end

  # ── Remove collaborator ──

  context "#remove_collaborator" do
    should "apply CollaboratorRemoved event" do
      @aggregate.add_collaborator(@framework_id, @person_id, "editor", added_by: @added_by)
      @aggregate.remove_collaborator(@framework_id, @person_id, "editor", removed_by: @added_by)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::CollaboratorRemoved, event
      assert_equal @person_id, event.data[:person_id]
      assert_equal "editor", event.data[:collaborator_role]
    end

    should "raise if collaborator does not have this role" do
      err = assert_raises(RuntimeError) do
        @aggregate.remove_collaborator(@framework_id, @person_id, "editor", removed_by: @added_by)
      end
      assert_match /does not have this role/, err.message
    end
  end

  # ── can_approve? ──

  context "#can_approve?" do
    should "return true when no collaborators exist (bootstrapping)" do
      assert @aggregate.can_approve?(@person_id)
    end

    should "return true for owner on any tier" do
      @aggregate.add_collaborator(@framework_id, @person_id, "owner", added_by: @added_by)

      assert @aggregate.can_approve?(@person_id, target_entity_type: "RoleIllustration")
      assert @aggregate.can_approve?(@person_id, target_entity_type: "Capability")
      assert @aggregate.can_approve?(@person_id, target_entity_type: "BehaviouralExpectation")
    end

    should "return true for editor on any tier" do
      @aggregate.add_collaborator(@framework_id, @person_id, "editor", added_by: @added_by)

      assert @aggregate.can_approve?(@person_id, target_entity_type: "RoleIllustration")
      assert @aggregate.can_approve?(@person_id, target_entity_type: "BehaviouralExpectation")
    end

    should "return true for role_lead on tier 1 only" do
      @aggregate.add_collaborator(@framework_id, @person_id, "role_lead",
                                  scope_type: "role", scope_id: SecureRandom.uuid_v7, added_by: @added_by)

      assert @aggregate.can_approve?(@person_id, target_entity_type: "RoleIllustration")
      assert_not @aggregate.can_approve?(@person_id, target_entity_type: "Capability")
    end

    should "return false for collaborator role" do
      @aggregate.add_collaborator(@framework_id, @person_id, "collaborator", added_by: @added_by)

      assert_not @aggregate.can_approve?(@person_id, target_entity_type: "RoleIllustration")
    end

    should "return false for viewer role" do
      @aggregate.add_collaborator(@framework_id, @person_id, "viewer", added_by: @added_by)

      assert_not @aggregate.can_approve?(@person_id, target_entity_type: "RoleIllustration")
    end

    should "return false for unknown person when collaborators exist" do
      @aggregate.add_collaborator(@framework_id, @person_id, "owner", added_by: @added_by)

      assert_not @aggregate.can_approve?(SecureRandom.uuid_v7)
    end
  end
end
