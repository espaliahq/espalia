# frozen_string_literal: true

# A shreddable field's value. {#reveal} is the one way to read it. It prints
# as a placeholder, and refuses to serialise, so it can't reach a log, a
# cache or a clear field of another event.
class Shreddable::Value
  # Raised when something tries to serialise a value in clear.
  class Unserialisable < StandardError
    def initialize(msg = "A shreddable value can only be written into a field declared shreddable")
      super
    end
  end

  # @param value [Object, nil]
  # @return [Shreddable::Value, nil] nil stays nil, and a value isn't wrapped twice
  def self.wrap(value) = value.nil? || value.is_a?(self) ? value : new(value)

  # @return [Shreddable::Value] what a field holds once its key is destroyed,
  #   and what an aggregate always sees
  def self.removed = REMOVED

  # @param value [Object] a JSON value: a string, number, boolean, array or hash
  def initialize(value, removed: false)
    @value = value
    @removed = removed
    freeze
  end

  # @return [Object, nil] the value, or nil once removed
  def reveal = @value

  # @return [Boolean]
  def removed? = @removed

  # @return [String]
  def to_s = removed? ? "[removed]" : "[shreddable]"

  # @return [String]
  def inspect = "#<#{self.class.name} #{self}>"

  # @raise [Unserialisable]
  def to_json(*) = raise(Unserialisable)

  # @raise [Unserialisable]
  def as_json(*) = raise(Unserialisable)

  # @raise [Unserialisable]
  def encode_with(*) = raise(Unserialisable)

  # A removed value can be cached; a value in clear can't.
  # @raise [Unserialisable]
  def marshal_dump = removed? ? :removed : raise(Unserialisable)

  def marshal_load(_)
    @value = nil
    @removed = true
    freeze
  end

  def ==(other) = other.is_a?(self.class) && other.removed? == removed? && other.reveal == reveal
  alias eql? ==

  def hash = [ self.class, @removed, @value ].hash

  REMOVED = new(nil, removed: true)
end
