# frozen_string_literal: true

# Event emitted when the author edits an existing evidence item's
# content fields.
#
# Only the user-correctable fields are mutable through update — capability
# and level are owned by {EvidenceRelinked}, and `source`/`author_id`/
# `recorded_at` are identity invariants that cannot change. The event
# carries the full post-edit value of every mutable field (a snapshot,
# not a delta) so the projection can apply it without ambiguity and so
# readers never need to compute "did the title change?".
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :evidence_id UUID of the evidence being edited
#   @option data [String, nil] :title optional one-line summary (post-edit)
#   @option data [String] :content body of the evidence (post-edit, required)
#   @option data [String] :evidence_type one of EvidenceItem::EVIDENCE_TYPES
#   @option data [String, nil] :custom_type_label free text, only when
#     evidence_type == "other"
#   @option data [Hash, nil] :external_reference { system:, url:, external_id:, metadata: }
#   @option data [String] :edited_by_id UUID of the Person performing the edit
#     (always the original author — enforced by {EvidencePolicy#update?})
#
class PersonDevelopment::Events::EvidenceUpdated < RubyEventStore::Event
end
