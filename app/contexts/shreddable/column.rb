# frozen_string_literal: true

# Lets a read model hold a shreddable value. The column keeps the sealed form
# the event store keeps, so destroying the key makes every copy unreadable at
# once, and a rebuild copies the sealed value with no key at all.
# See docs/team-planning/shreddable-fields-design.md.
#
# The column reads as a {Shreddable::Value}. It opens as removed once its key
# is destroyed, or when the identifier it holds isn't the row's own.
#
# Ordering, filtering, grouping and plucking the column raise: its order and
# its matches would say something about the value.
#
# @example
#   class TeamPlanningPlan < ApplicationRecord
#     include Shreddable::Column
#     shreddable_column :name, by: :plan, plan: :id
#   end
module Shreddable::Column
  extend ActiveSupport::Concern

  # Raised on a query that would order, match or read the column in clear.
  class Refused < StandardError; end

  # What the column holds at rest: ciphertext, or the mark of a removed value.
  STORED_KEYS = [ %w[cipher ciphertext identifier iv], %w[removed] ].freeze
  REMOVED = { "removed" => true }.freeze

  # A jsonb type that only ever serialises the stored form, so a value in
  # clear can't reach the column through `update_all`, `upsert_all` or `where`.
  class Type < ActiveRecord::Type::Json
    def serialize(value)
      return super if value.nil?
      raise Refused, "A shreddable column only takes a sealed value" unless Shreddable::Column.stored?(value)

      super
    end
  end

  # Refuses queries that order, match or read a shreddable column.
  module Guard
    %i[order reorder group pluck pick in_order_of].each do |name|
      define_method(name) do |*args, **kwargs, &block|
        Shreddable::Column.refuse!(model, args + kwargs.keys, name)
        super(*args, **kwargs, &block)
      end
    end

    # Only the condition is checked: the values bound into it are data.
    def where(*args, **kwargs)
      condition = args.first.is_a?(Hash) ? args.first.keys : args.first(1)
      Shreddable::Column.refuse!(model, condition + kwargs.keys, :where)
      super
    end
  end

  included do
    [ ActiveRecord::Relation, ActiveRecord::AssociationRelation, ActiveRecord::Associations::CollectionProxy ].each do
      relation_delegate_class(it).prepend(Guard)
    end
    # On create, after ApplicationRecord assigns the id, which `plan: :id` needs.
    before_create :seal_shreddable_columns
    before_update :seal_shreddable_columns
    # A clear value stays until the write commits, so a rollback, which
    # also rolls back a key just minted, leaves it to seal again.
    after_commit { @shreddable_pending = {} }
  end

  class_methods do
    # @param field [Symbol] a jsonb column
    # @param by [Symbol] :plan for the plan's own key, :person for one person's key
    # @param plan [Symbol] the column that holds the plan's id
    # @param person [Symbol] the column that holds the person's id
    # @raise [ArgumentError] for an unknown key
    def shreddable_column(field, by:, plan: :plan_id, person: :person_id)
      raise ArgumentError, "by: must be one of #{Shreddable::KEYS.join(', ')}" unless Shreddable::KEYS.include?(by)

      shreddable_columns[field.to_sym] = { by:, plan:, person: }
      attribute field, Shreddable::Column::Type.new

      define_method(field) { shreddable_value(field) }
      define_method(:"#{field}=") { |value| assign_shreddable(field, value) }
    end

    # @return [Hash{Symbol => Hash}]
    def shreddable_columns
      @shreddable_columns ||= {}
    end

    # The stored form of a value, for writes that skip the model, such as
    # `update_all`. A sealed value is copied as it is; a value in clear is
    # encrypted under the row's key, so it must run in a transaction.
    #
    # @param field [Symbol]
    # @param value [Shreddable::Value, Object, nil]
    # @param row [Hash{Symbol => String}] the row's tenant_id and the columns
    #   that name its plan and person
    # @return [Hash, nil]
    # @raise [PlanKeyStore::Destroyed] for a value in clear whose key is gone
    def seal_column(field, value, **row)
      Shreddable::Column.seal(value, -> { shreddable_identifier(field, row) })
    end

    # @param field [Symbol]
    # @param row [#[]]
    # @return [String] the identifier of the key that should seal the field
    def shreddable_identifier(field, row)
      rule = shreddable_columns.fetch(field)
      plan_id = row[rule[:plan]]
      return PlanKeyStore.plan_identifier(row[:tenant_id], plan_id) if rule[:by] == :plan

      PlanKeyStore.person_identifier(row[:tenant_id], plan_id, row[rule[:person]])
    end
  end

  # @param value [Object]
  # @return [Boolean] whether the value is in the stored form
  def self.stored?(value) = value.is_a?(Hash) && STORED_KEYS.include?(value.keys.map(&:to_s).sort)

  # @param value [Shreddable::Value, Object, nil]
  # @param identifier [#call] gives the identifier of the row's key
  # @return [Hash, nil]
  def self.seal(value, identifier)
    return if value.nil?
    return value if stored?(value)
    return value.envelope || REMOVED if value.is_a?(Shreddable::Value::Sealed)
    return REMOVED if value.is_a?(Shreddable::Value) && value.removed?

    raise ArgumentError, "Seal a shreddable value inside a transaction" unless PlanEncryptionKey.connection.transaction_open?

    id = identifier.call
    key = PlanKeyStore.new.create(id)
    iv = key.random_iv
    clear = value.is_a?(Shreddable::Value) ? value.reveal : Shreddable::Value.new(value).reveal
    { "cipher" => key.cipher, "ciphertext" => Base64.strict_encode64(key.encrypt(JSON.generate(clear), iv)),
      "identifier" => id, "iv" => Base64.strict_encode64(iv) }
  end

  # @raise [Refused] if any argument names a shreddable column
  def self.refuse!(model, args, method)
    fields = model.shreddable_columns.keys.map(&:to_s)
    return if fields.empty?

    named = args.flat_map { names_in(it) }.compact.map(&:to_s)
    hit = fields.find { |field| named.any? { it == field || it.match?(/(?<![\w.])(?:\w+\.)?#{field}\b/) } }
    raise Refused, "#{model.name}##{hit} is shreddable, so it can't be used in #{method}" if hit
  end

  def self.names_in(arg)
    case arg
    when Symbol, String then [ arg ]
    when Hash then arg.keys
    when Array then arg.flat_map { names_in(it) }
    when Arel::Nodes::Node, Arel::Attributes::Attribute then [ arg.to_sql ] if arg.respond_to?(:to_sql)
    end
  rescue StandardError
    [ arg.to_s ]
  end
  private_class_method :names_in

  # @return [self]
  def reload(*)
    @shreddable_pending = {}
    super
  end

  private

  def initialize_dup(other)
    super
    @shreddable_pending = @shreddable_pending&.dup
  end

  def assign_shreddable(field, value)
    @shreddable_pending ||= {}
    if value.nil? || Shreddable::Column.stored?(value) || value.is_a?(Shreddable::Value::Sealed) ||
       (value.is_a?(Shreddable::Value) && value.removed?)
      @shreddable_pending.delete(field)
      write_attribute(field, Shreddable::Column.seal(value, nil))
    else
      @shreddable_pending[field] = Shreddable::Value.wrap(value)
      attribute_will_change!(field.to_s)
    end
  end

  def shreddable_value(field)
    pending = @shreddable_pending&.[](field)
    return pending if pending

    stored = read_attribute(field)
    return if stored.nil?
    return Shreddable::Value.removed unless stored["ciphertext"]

    own = self.class.shreddable_identifier(field, attributes.symbolize_keys)
    Shreddable::Value::Sealed.new(
      ciphertext: stored["ciphertext"], iv: stored["iv"], identifier: stored["identifier"], cipher: stored["cipher"],
      key_of: ->(identifier, cipher) { PlanKeyStore.new.key_of(identifier, cipher:) if identifier == own }
    )
  end

  def seal_shreddable_columns
    (@shreddable_pending || {}).each do |field, value|
      write_attribute(field, Shreddable::Column.seal(value, -> { self.class.shreddable_identifier(field, attributes.symbolize_keys) }))
    end
  end
end
