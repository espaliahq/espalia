# frozen_string_literal: true

# Hands each `on` handler a copy of the event with every shreddable field
# removed, so an aggregate decides the same with its keys or without them.
# The aggregate still publishes the real event.
class Shreddable::RedactingApplyStrategy
  # @param inner [#call] the strategy that applies the redacted copy, for an
  #   aggregate with its own
  def initialize(inner = AggregateRoot::DefaultApplyStrategy.new)
    @inner = inner
  end

  # AggregateRoot.with gives the aggregate its `on` DSL only when this is defined.
  # @return [Boolean]
  def uses_on_dsl? = true

  # @param aggregate [Object]
  # @param event [RubyEventStore::Event]
  def call(aggregate, event) = @inner.call(aggregate, Shreddable.redact(event))
end
