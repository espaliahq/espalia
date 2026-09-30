# frozen_string_literal: true

require "test_helper"

# Declared explorations (ADR-22): an intent fact about another role or level,
# one open per target role, never the role and level already held, and no
# open cycle required.
class PersonDevelopment::AggregateExplorationTest < ActiveSupport::TestCase
  setup do
    @aggregate = PersonDevelopment::Aggregate.new
    @home_role = SecureRandom.uuid_v7
    @home_level = SecureRandom.uuid_v7
    @pm_role = SecureRandom.uuid_v7
    @pm_level = SecureRandom.uuid_v7
    @actor = SecureRandom.uuid_v7
    @aggregate.assign_to_framework(SecureRandom.uuid_v7, SecureRandom.uuid_v7, @home_role, @home_level)
  end

  def explore(role_id = @pm_role, level_id = @pm_level, id: SecureRandom.uuid_v7, ordinal: 3, note: nil)
    @aggregate.start_exploration(id, target_role_id: role_id, target_level_id: level_id,
                                 target_level_ordinal: ordinal, started_by_id: @actor, note: note)
    id
  end

  def events_of(klass)
    @aggregate.unpublished_events.to_a.grep(klass)
  end

  context "starting" do
    should "record the target, the declarer and the note without an open cycle" do
      id = explore(note: "Loves discovery work")

      event = events_of(PersonDevelopment::Events::ExplorationStarted).last
      assert_equal id, event.data[:exploration_id]
      assert_equal @pm_role, event.data[:target_role_id]
      assert_equal @pm_level, event.data[:target_level_id]
      assert_equal 3, event.data[:target_level_ordinal]
      assert_equal @actor, event.data[:started_by_id]
      assert_equal "Loves discovery work", event.data[:note]
    end

    should "store a blank note as nil" do
      explore(note: "")

      assert_nil events_of(PersonDevelopment::Events::ExplorationStarted).last.data[:note]
    end

    should "refuse a second open exploration of the same role" do
      explore
      error = assert_raises(PersonDevelopment::Aggregate::CommandError) { explore(@pm_role, SecureRandom.uuid_v7) }
      assert_match(/already open/, error.message)
    end

    should "allow explorations of two different roles at once" do
      explore
      assert_nothing_raised { explore(SecureRandom.uuid_v7, SecureRandom.uuid_v7) }
    end

    should "refuse the role and level already held" do
      error = assert_raises(PersonDevelopment::Aggregate::CommandError) { explore(@home_role, @home_level) }
      assert_match(/already held/, error.message)
    end

    should "allow the next level of the role already held" do
      assert_nothing_raised { explore(@home_role, SecureRandom.uuid_v7, ordinal: 4) }
    end

    should "refuse a reused id" do
      id = explore
      assert_raises(PersonDevelopment::Aggregate::CommandError) { explore(SecureRandom.uuid_v7, SecureRandom.uuid_v7, id: id) }
    end

    should "refuse before the person is assigned" do
      aggregate = PersonDevelopment::Aggregate.new
      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        aggregate.start_exploration(SecureRandom.uuid_v7, target_role_id: @pm_role, target_level_id: @pm_level,
                                    target_level_ordinal: 3, started_by_id: @actor)
      end
    end

    should "allow a role explored before to be explored again once closed" do
      id = explore
      @aggregate.close_exploration(id, closed_by_id: @actor, outcome: "not_now")

      assert_nothing_raised { explore }
    end
  end

  context "closing" do
    should "record the outcome, the closer and the note" do
      id = explore
      @aggregate.close_exploration(id, closed_by_id: @actor, outcome: "pursue", note: "Next cycle")

      event = events_of(PersonDevelopment::Events::ExplorationClosed).last
      assert_equal id, event.data[:exploration_id]
      assert_equal "pursue", event.data[:outcome]
      assert_equal @actor, event.data[:closed_by_id]
      assert_equal "Next cycle", event.data[:note]
    end

    should "refuse to close twice" do
      id = explore
      @aggregate.close_exploration(id, closed_by_id: @actor, outcome: "moved")

      error = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.close_exploration(id, closed_by_id: @actor, outcome: "moved")
      end
      assert_match(/already closed/, error.message)
    end

    should "refuse an unknown exploration and an unknown outcome" do
      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.close_exploration(SecureRandom.uuid_v7, closed_by_id: @actor, outcome: "pursue")
      end
      id = explore
      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.close_exploration(id, closed_by_id: @actor, outcome: "abandoned")
      end
    end
  end

  context "moving into the target" do
    should "close it as moved when the role and level change to it" do
      id = explore
      @aggregate.change_role(@pm_role, @pm_level, changed_by: @actor)

      event = events_of(PersonDevelopment::Events::ExplorationClosed).sole
      assert_equal [ id, "moved", @actor ], event.data.values_at(:exploration_id, :outcome, :closed_by_id)
      assert_nothing_raised { explore(@pm_role, SecureRandom.uuid_v7) }
    end

    should "close a vertical exploration on the promotion to it" do
      e4 = SecureRandom.uuid_v7
      explore(@home_role, e4, ordinal: 4)
      @aggregate.change_level(e4)

      assert_equal "moved", events_of(PersonDevelopment::Events::ExplorationClosed).sole.data[:outcome]
    end

    should "leave it open on a move to another level of the role" do
      explore
      @aggregate.change_role(@pm_role, SecureRandom.uuid_v7)

      assert_empty events_of(PersonDevelopment::Events::ExplorationClosed)
    end
  end

  context "through the repository" do
    setup do
      @tenant = create(:tenant)
      @person_id = SecureRandom.uuid_v7
      @framework_id = SecureRandom.uuid_v7
      @handler = PersonDevelopment::CommandHandler.new
    end

    should "keep the one-open-per-role guard across reloads" do
      ActsAsTenant.with_tenant(@tenant) do
        Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
          @handler.assign_to_framework(@person_id, @framework_id, @home_role, @home_level)
          @handler.start_exploration(@person_id, @framework_id, SecureRandom.uuid_v7,
                                     target_role_id: @pm_role, target_level_id: @pm_level,
                                     target_level_ordinal: 3, started_by_id: @actor)

          assert_raises(PersonDevelopment::Aggregate::CommandError) do
            @handler.start_exploration(@person_id, @framework_id, SecureRandom.uuid_v7,
                                       target_role_id: @pm_role, target_level_id: @pm_level,
                                       target_level_ordinal: 3, started_by_id: @actor)
          end
        end
      end
    end
  end
end
