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

  def reveal = opened.reveal

  def removed? = opened.removed?

  # Printing never opens the value.
  def to_s = @opened ? @opened.to_s : "[shreddable]"

  def hash = opened.hash

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
