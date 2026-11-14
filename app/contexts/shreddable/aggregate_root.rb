# frozen_string_literal: true

# Include in place of AggregateRoot. An aggregate never sees a shreddable
# value: replaying with every key destroyed must give the same state.
Shreddable::AggregateRoot = AggregateRoot.with(strategy: -> { Shreddable::RedactingApplyStrategy.new })
