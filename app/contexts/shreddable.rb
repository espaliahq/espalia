# frozen_string_literal: true

# Lets an event declare fields shreddable. Each is written encrypted under a
# key in {PlanKeyStore}; once the key is destroyed it reads back as removed.
# See docs/team-planning/shreddable-fields-design.md.
#
# A declared field always holds a {Shreddable::Value}, in a new event and in
# one read back, so nothing reads it in clear by accident.
#
# @example
#   class TeamPlanning::Events::NoteWritten < RubyEventStore::Event
#     extend Shreddable
#     shreddable :note, by: :plan
#     shreddable :pay, by: :person
#   end
module Shreddable
  KEYS = %i[plan person].freeze

  # Wraps declared fields as they enter an event.
  module Wrapping
    def initialize(event_id: SecureRandom.uuid, metadata: nil, data: {})
      super(event_id:, metadata:, data: Shreddable.wrap(self.class, data))
    end
  end

  def self.extended(event_class)
    event_class.prepend(Wrapping)
  end

  # @param fields [Array<Symbol>]
  # @param by [Symbol] :plan for the plan's own key, :person for one person's
  #   key in the plan
  # @param person [Symbol] the data key that holds that person's id
  # @raise [ArgumentError] for an unknown key
  def shreddable(*fields, by:, person: :person_id)
    raise ArgumentError, "by: must be one of #{KEYS.join(', ')}" unless KEYS.include?(by)

    fields.each { shreddable_fields[it.to_sym] = { by:, person: } }
  end

  # @return [Hash{Symbol => Hash}] each declared field, with its key
  def shreddable_fields
    @shreddable_fields ||= {}
  end

  # @param tenant_id [String]
  # @param data [Hash]
  # @param field [Symbol]
  # @return [String] the identifier of the key that encrypts the field
  def shreddable_identifier(tenant_id, data, field)
    rule = shreddable_fields.fetch(field)
    plan_id = data.fetch(:plan_id)
    return PlanKeyStore.plan_identifier(tenant_id, plan_id) if rule[:by] == :plan

    PlanKeyStore.person_identifier(tenant_id, plan_id, data.fetch(rule[:person]))
  end

  # @param event_class [Class]
  # @param data [Hash]
  # @return [Hash] data with each declared field wrapped
  def self.wrap(event_class, data)
    fields = present_fields(event_class, data)
    return data if fields.empty?

    data.merge(fields.to_h { [ it, Value.wrap(data[it]) ] })
  end

  # @param event [RubyEventStore::Event]
  # @return [RubyEventStore::Event] the event itself if it declares nothing,
  #   or a copy with every shreddable field removed
  def self.redact(event)
    fields = present_fields(event.class, event.data)
    return event if fields.empty?

    event.class.new(event_id: event.event_id, metadata: event.metadata.to_h,
                    data: event.data.merge(fields.to_h { [ it, Value.removed ] }))
  end

  # @return [Array<Symbol>] the declared fields the data holds a value for
  def self.present_fields(event_class, data)
    return [] unless event_class.respond_to?(:shreddable_fields) && data.is_a?(Hash)

    event_class.shreddable_fields.keys.reject { data[it].nil? }
  end
end
