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

  # Refuses the query methods that would order, match or read a shreddable
  # column. Raw SQL, through `find_by_sql` or `select`, isn't checked.
  module Guard
    %i[order reorder group regroup pluck pick in_order_of].each do |name|
      define_method(name) do |*args, **kwargs, &block|
        Shreddable::Column.refuse!(model, args + [ kwargs ], name)
        super(*args, **kwargs, &block)
      end
    end

    # Only the condition is checked: the values bound into it are data.
    %i[where rewhere having exists?].each do |name|
      define_method(name) do |*args, **kwargs, &block|
        Shreddable::Column.refuse!(model, Shreddable::Column.condition(args, kwargs), name)
        super(*args, **kwargs, &block)
      end
    end
  end

  # Guards `where.not`, which builds its condition apart from `where`.
  module WhereChainGuard
    def not(*args, **kwargs)
      model = @scope.model
      Shreddable::Column.refuse!(model, Shreddable::Column.condition(args, kwargs), :where) if model.respond_to?(:shreddable_columns)
      super
    end
  end
  ActiveRecord::QueryMethods::WhereChain.prepend(WhereChainGuard)

  included do
    guard_shreddable_relations
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
    # @param person [Symbol, #call] the column that holds the person's id, or
    #   a callable that takes the row and gives the id, or nil for the plan's key
    # @raise [ArgumentError] for an unknown key
    def shreddable_column(field, by:, plan: :plan_id, person: :person_id)
      Shreddable.check_key!(by)

      own_shreddable_columns[field.to_sym] = { by:, plan:, person:, named_in: /(?<![\w.])(?:\w+\.)?#{field}\b/ }
      attribute field, Shreddable::Column::Type.new

      define_method(field) { shreddable_value(field) }
      define_method(:"#{field}=") { |value| assign_shreddable(field, value) }
    end

    # @return [Hash{Symbol => Hash}] each column this class or a parent declares
    def shreddable_columns
      inherited = superclass.respond_to?(:shreddable_columns) ? superclass.shreddable_columns : {}
      inherited.merge(own_shreddable_columns)
    end

    # @return [Hash{Symbol => Hash}]
    def own_shreddable_columns
      @own_shreddable_columns ||= {}
    end

    # A subclass gets relation classes of its own, so it needs the guard too.
    def inherited(subclass)
      super
      subclass.guard_shreddable_relations
    end

    # @api private
    def guard_shreddable_relations
      [ ActiveRecord::Relation, ActiveRecord::AssociationRelation, ActiveRecord::Associations::CollectionProxy ].each do
        relation_delegate_class(it).prepend(Guard)
      end
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
    # @raise [PlanKeyStore::Destroyed] for a value in clear whose key is gone,
    #   outside a rebuild
    def seal_column(field, value, **row)
      Shreddable::Column.seal(value, -> { shreddable_identifier(field, row) })
    end

    # @param field [Symbol]
    # @param row [#[]]
    # @return [String] the identifier of the key that should seal the field
    def shreddable_identifier(field, row)
      rule = shreddable_columns.fetch(field)
      Shreddable.identifier(rule, row[:tenant_id], row[rule[:plan]], Shreddable.person_of(rule, row) { row[it] })
    end
  end

  # @param value [Object]
  # @return [Boolean] whether the value is in the stored form
  def self.stored?(value) = value.is_a?(Hash) && STORED_KEYS.include?(value.keys.map(&:to_s).sort)

  # A value the mapper just encrypted under the row's key keeps the mapper's
  # stored form, so a live write and a rebuild store the same bytes. A value
  # in clear whose key is destroyed seals as removed.
  #
  # @param value [Shreddable::Value, Object, nil]
  # @param identifier [#call] gives the identifier of the row's key
  # @return [Hash, nil]
  # @raise [PlanKeyStore::Destroyed] for a value in clear whose key is gone,
  #   outside a rebuild
  def self.seal(value, identifier)
    return if value.nil?
    return value if stored?(value)
    return value.envelope || REMOVED if value.is_a?(Shreddable::Value::Sealed)
    return REMOVED if value.is_a?(Shreddable::Value) && value.removed?

    raise ArgumentError, "Seal a shreddable value inside a transaction" unless PlanEncryptionKey.connection.transaction_open?

    id = identifier.call
    key = PlanKeyStore.new.create(id) # rubocop:disable Espalia/WritesMustBeDeclared -- the key store, plan_encryption_keys' declared writer
    sealed, sealed_by = value.sealed if value.is_a?(Shreddable::Value)
    # A publish that rolled back took its key with it.
    return sealed if sealed && sealed["identifier"] == id && sealed_by&.key == key.key

    Shreddable.encrypt(Shreddable::Value.wrap(value).reveal, id, key)
  rescue PlanKeyStore::Destroyed
    # A rebuild meets a value stored in clear before its field was declared
    # shreddable, for a plan since deleted. A live write still raises.
    raise unless Projections::Replayer.replay_mode?

    REMOVED
  end

  # The condition of a `where`, without the values bound into it, in either
  # `where("sql ?", x)` or `where([ "sql ?", x ])`.
  #
  # @param args [Array]
  # @param kwargs [Hash]
  # @return [Array]
  def self.condition(args, kwargs)
    first = args.first
    (first.is_a?(Array) && first.first.is_a?(String) ? first.first(1) : args.first(1)) + [ kwargs ]
  end

  # @raise [Refused] if any argument names a shreddable column
  def self.refuse!(model, args, method)
    columns = model.shreddable_columns
    return if columns.empty?

    named = args.flat_map { names_in(it) }.compact.map(&:to_s)
    hit, = columns.find { |field, rule| named.any? { it == field.to_s || it.match?(rule[:named_in]) } }
    raise Refused, "#{model.name}##{hit} is shreddable, so it can't be used in #{method}" if hit
  end

  def self.names_in(arg)
    case arg
    when Symbol, String then [ arg ]
    # A table's name can nest its columns: `where(notes: { note: x })`.
    when Hash then arg.flat_map { |key, value| [ key ] + (value.is_a?(Hash) ? names_in(value) : []) }
    when Array then arg.flat_map { names_in(it) }
    when Arel::Attributes::Attribute then [ arg.name ]
    when Arel::Nodes::Node then [ arg.to_sql ]
    end
  rescue StandardError
    [ arg.to_s ]
  end
  private_class_method :names_in

  # @return [self]
  def reload(*)
    @shreddable_pending = {}
    @shreddable_read = nil
    super
  end

  private

  def initialize_dup(other)
    super
    @shreddable_pending = @shreddable_pending&.dup
    @shreddable_read = nil
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

    # One sealed value per stored value and row key, so reading it twice
    # looks up its key once.
    own = self.class.shreddable_identifier(field, self)
    read = (@shreddable_read ||= {})[field]
    return read.last if read&.first.equal?(stored) && read[1] == own

    sealed = Shreddable::Value::Sealed.new(
      ciphertext: stored["ciphertext"], iv: stored["iv"], identifier: stored["identifier"], cipher: stored["cipher"],
      key_of: ->(identifier, cipher) { PlanKeyStore.new.key_of(identifier, cipher:) if identifier == own }
    )
    @shreddable_read[field] = [ stored, own, sealed ]
    sealed
  end

  def seal_shreddable_columns
    (@shreddable_pending || {}).each do |field, value|
      write_attribute(field, Shreddable::Column.seal(value, -> { self.class.shreddable_identifier(field, self) }))
    end
  end
end
