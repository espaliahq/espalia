# frozen_string_literal: true

# Applies plan events, sending every kind of change to the plan's one change
# handler, so a new kind needs no `on` in {TeamPlanning::PlanAggregate}.
class TeamPlanning::ChangeAwareApplyStrategy < AggregateRoot::DefaultApplyStrategy
  # @param aggregate [TeamPlanning::PlanAggregate]
  # @param event [RubyEventStore::Event]
  # @return [void]
  def call(aggregate, event)
    return aggregate.send(:record_change, event) if event.is_a?(TeamPlanning::Events::Change)

    super
  end
end
