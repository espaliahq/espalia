# frozen_string_literal: true

# A shreddable value as read from the event store, still encrypted. It opens
# on the first {#reveal} or {#removed?}, so a read that never asks for the
# value never looks up a key: an aggregate load, or a replayer passing over
# another tenant's events.
#
# A damaged field opens as removed. Looking up the key raises as
# {PlanKeyStore#key_of} does, so revealing another tenant's value, or a value
# where Active Record encryption has no keys, fails at the line that asked.
class Shreddable::Value::Sealed < Shreddable::Value
  # @param ciphertext [String] Base64
  # @param iv [String] Base64
  # @param identifier [String]
  # @param cipher [String]
  # @param key_of [#call] takes the identifier and cipher, and returns the key or nil
  def initialize(ciphertext:, iv:, identifier:, cipher:, key_of:) # rubocop:disable Lint/MissingSuper
    @ciphertext = ciphertext
    @iv = iv
    @identifier = identifier
    @cipher = cipher
    @key_of = key_of
  end

  # @return [Object, nil] the value, or nil once removed
  # @raise [PlanKeyStore::ForeignTenant, PlanKeyStore::Unavailable]
  def reveal = opened.reveal

  # @return [Boolean]
  def removed? = opened.removed?

  # Printing never opens the value.
  #
  # @return [String]
  def to_s = @opened ? @opened.to_s : "[shreddable]"

  # A value that opened as removed loads back as removed, without its ciphertext.
  #
  # @return [void]
  def marshal_load(_)
    @opened = Shreddable::Value.removed
    freeze
  end

  # @return [Integer]
  def hash = opened.hash

  # What a shreddable column stores, still encrypted. Copying it needs no key.
  #
  # @return [Hash{String => String}, nil] nil for a value loaded from Marshal,
  #   which keeps no ciphertext
  def envelope
    return unless @ciphertext

    { "cipher" => @cipher, "ciphertext" => @ciphertext, "identifier" => @identifier, "iv" => @iv }
  end

  private

  def opened
    @opened ||= open
  end

  def open
    ciphertext, iv = decode(@ciphertext), decode(@iv)
    return Shreddable::Value.removed unless ciphertext && iv

    key = @key_of.call(@identifier, @cipher) or return Shreddable::Value.removed
    Shreddable::Value.new(JSON.parse(key.decrypt(ciphertext, iv)))
  rescue OpenSSL::Cipher::CipherError, JSON::ParserError
    Shreddable::Value.removed
  end

  def decode(text)
    Base64.strict_decode64(text)
  rescue ArgumentError, TypeError
    nil
  end
end
