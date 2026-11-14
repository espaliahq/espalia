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

  # Wraps declared fields as each event of the class is built.
  #
  # @param event_class [Class]
  def self.extended(event_class)
    event_class.prepend(Wrapping)
  end

  # @param fields [Array<Symbol>]
  # @param by [Symbol] :plan for the plan's own key, :person for one person's
  #   key in the plan
  # @param person [Symbol] the data key that holds that person's id
  # @raise [ArgumentError] for an unknown key
  def shreddable(*fields, by:, person: :person_id)
    Shreddable.check_key!(by)

    fields.each { own_shreddable_fields[it.to_sym] = { by:, person: } }
  end

  # @return [Hash{Symbol => Hash}] each field this class or a parent declares,
  #   with its key
  def shreddable_fields
    inherited = superclass.respond_to?(:shreddable_fields) ? superclass.shreddable_fields : {}
    inherited.merge(own_shreddable_fields)
  end

  # @return [Hash{Symbol => Hash}]
  def own_shreddable_fields
    @own_shreddable_fields ||= {}
  end

  # @param tenant_id [String]
  # @param data [Hash]
  # @param field [Symbol]
  # @return [String] the identifier of the key that encrypts the field
  def shreddable_identifier(tenant_id, data, field)
    rule = shreddable_fields.fetch(field)
    Shreddable.identifier(rule, tenant_id, data.fetch(:plan_id), rule[:by] == :person ? data.fetch(rule[:person]) : nil)
  end

  # Each value the mapper encrypted, with its stored form, so a sync
  # projection copies the bytes a rebuild will copy. Keyed by identity: two
  # equal values are sealed apart.
  SEALED = ObjectSpace::WeakMap.new

  # @param clear [Object] a JSON value
  # @param identifier [String]
  # @param key [RubyEventStore::Mappers::EncryptionKey]
  # @return [Hash{String => String}] the stored form: the cipher, the
  #   identifier, and the ciphertext and IV in Base64
  def self.encrypt(clear, identifier, key)
    iv = key.random_iv
    { "cipher" => key.cipher, "ciphertext" => Base64.strict_encode64(key.encrypt(JSON.generate(clear), iv)),
      "identifier" => identifier, "iv" => Base64.strict_encode64(iv) }
  end

  # @param rule [Hash] the declaration, with :by
  # @param tenant_id [String]
  # @param plan_id [String]
  # @param person_id [String, nil] for a person's key
  # @return [String] the identifier of the key the rule names
  def self.identifier(rule, tenant_id, plan_id, person_id = nil)
    return PlanKeyStore.plan_identifier(tenant_id, plan_id) if rule[:by] == :plan

    PlanKeyStore.person_identifier(tenant_id, plan_id, person_id)
  end

  # @param by [Symbol]
  # @raise [ArgumentError] for an unknown key
  def self.check_key!(by)
    raise ArgumentError, "by: must be one of #{KEYS.join(', ')}" unless KEYS.include?(by)
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
  # @raise [ArgumentError] for a declared field under a string key, which
  #   would otherwise be stored in clear
  def self.present_fields(event_class, data)
    return [] unless event_class.respond_to?(:shreddable_fields) && data.is_a?(Hash)

    declared = event_class.shreddable_fields.keys
    if (clear = declared.map(&:to_s) & data.keys).any?
      raise ArgumentError, "Shreddable fields need symbol keys: #{clear.join(', ')}"
    end

    declared.reject { data[it].nil? }
  end
end
