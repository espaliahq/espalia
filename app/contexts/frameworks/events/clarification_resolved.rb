# frozen_string_literal: true

# Event emitted when someone with expectation-tier authority declares a
# clarification question settled — with a note explaining the outcome
# ("reworded L4", "added two illustrations", "wording is fine; here's the
# reading"), optionally linking the concrete suggestion the discussion spawned.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :suggestion_id UUID of the clarification
#   @option data [String] :resolver_id UUID of the resolving person
#   @option data [String] :note what settled the question
#   @option data [String, nil] :resulting_suggestion_id UUID of a concrete
#     change suggestion this clarification led to, when there is one
#
class Frameworks::Events::ClarificationResolved < RubyEventStore::Event
end
