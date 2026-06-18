# frozen_string_literal: true

# Derives a projection read-model's primary key deterministically from its
# stable natural key, so a projection rebuild (`reset!` + replay) reproduces
# the SAME id for the same logical row.
#
# Projection read models are materialised by deleting every row (`reset!`) and
# re-creating them from the event stream. A row created via
# `find_or_initialize_by(natural_key)` with no explicit `id` otherwise gets a
# fresh random `uuid_v7` on every rebuild (see {ApplicationRecord}). Any
# external reference that captured the old id — a REST URL, a bookmark, an MCP
# resource URI — then breaks the moment the projection is rebuilt (404).
# Deriving the id from the natural key removes that class of inconsistency
# entirely: the id is a pure function of event-sourced data.
#
# Use ONLY for read models whose identity is externally addressable AND whose
# natural key is stable and singular (exactly one row per key). Read models
# that already set their PK to an event-carried id (`EvidenceItem#evidence_id`,
# `PersonDevelopmentComment#comment_id`) are already rebuild-stable and do not
# need this.
#
# @example
#   class PersonFrameworkAssignment < ApplicationRecord
#     include DeterministicId
#     deterministic_id_from :person_id, :framework_id
#   end
#
# The derivation (namespace, attribute set, ordering, formatting) is FROZEN
# once any row exists in production: historical rows' ids depend on it, so
# changing it reissues their ids on the next rebuild — the very bug this
# prevents. Treat it like an immutable event shape.
module DeterministicId
  extend ActiveSupport::Concern

  # Fixed, app-specific UUIDv5 namespace. Arbitrary but immutable — never
  # change it, or every deterministically-keyed row's id changes on rebuild.
  NAMESPACE = "d398e20b-ab21-4916-89fc-f0756602f73b"

  class_methods do
    # Declares the natural-key attributes whose values derive the primary key.
    #
    # @param attributes [Array<Symbol>] columns forming the stable natural key
    def deterministic_id_from(*attributes)
      @deterministic_id_attributes = attributes.freeze
    end

    # @return [Array<Symbol>, nil]
    def deterministic_id_attributes
      @deterministic_id_attributes
    end
  end

  included do
    # before_validation (not before_create) so the id is set before
    # ApplicationRecord's `assign_uuid_v7_id` before_create runs — that hook
    # bails when `id` is already present, leaving our deterministic id intact.
    before_validation :assign_deterministic_id, on: :create
  end

  private

  # Assigns the deterministic primary key from the declared natural key.
  # No-op when an id is already set, no natural key is declared, or any
  # natural-key value is blank (the row can't be stably identified yet).
  def assign_deterministic_id
    return if id.present?

    attributes = self.class.deterministic_id_attributes
    return unless attributes

    values = attributes.map { |attr| public_send(attr) }
    return if values.any?(&:blank?)

    # Namespacing by class name keeps two models that share a natural key
    # (e.g. both keyed on person_id/framework_id) from colliding.
    name = "#{self.class.name}:#{values.join('/')}"
    self.id = Digest::UUID.uuid_v5(NAMESPACE, name)
  end
end
