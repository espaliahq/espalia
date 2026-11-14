# frozen_string_literal: true

# Wraps the event store's mapper so shreddable fields are written encrypted
# and read back sealed: each opens on its first reveal, decrypted, or as
# removed once its key is gone.
#
# An event that declares nothing passes to the inner mapper untouched, with no
# query and no key lookup.
#
# At rest a field holds Base64 ciphertext, and the record's metadata holds
# `shreddable: { field => { cipher:, iv:, identifier: } }`, the IV in Base64.
# Old code that reads such a record sees those strings and doesn't raise.
class Shreddable::Mapper
  # What the inner mapper reads from an event, holding ciphertext where the
  # event class would wrap it.
  Encrypted = Data.define(:event_id, :event_type, :metadata, :data)

  # JSONClient builds its default mapper inline, with no way to reach it.
  # Taking it from a client keeps the stored form exactly what it was, which
  # test/contexts/shreddable/mapper_test.rb checks against every context.
  #
  # @return [RubyEventStore::Mappers::BatchMapper]
  def self.json_client_default
    RailsEventStore::JSONClient.new(repository: RubyEventStore::InMemoryRepository.new).instance_variable_get(:@mapper)
  end

  # @param inner [#events_to_records, #records_to_events]
  # @param key_store [PlanKeyStore]
  def initialize(inner, key_store: PlanKeyStore.new)
    @inner = inner
    @key_store = key_store
  end

  # @param events [Array<RubyEventStore::Event>]
  # @return [Array<RubyEventStore::Record>]
  # @raise [ArgumentError] for a removed value, an event without a tenant, or
  #   a shreddable event written outside a transaction
  # @raise [PlanKeyStore::Destroyed] for a deleted plan or a forgotten person
  def events_to_records(events) = @inner.events_to_records(events.map { encrypt(it) })

  # @param records [Array<RubyEventStore::Record>]
  # @return [Array<RubyEventStore::Event>]
  def records_to_events(records)
    # No memo: a value opened after a destroy must read as removed.
    key_of = ->(identifier, cipher) { @key_store.key_of(identifier, cipher:) }
    @inner.records_to_events(records).map { seal(it, key_of) }
  end

  private

  def encrypt(event)
    fields = Shreddable.present_fields(event.class, event.data)
    return event if fields.empty?

    tenant_id = event.metadata[:tenant_id] or raise ArgumentError, "A shreddable event needs a tenant"
    # The key's lock lasts until the transaction commits, and the append runs
    # after this returns, so without one a destroy could land in between.
    raise ArgumentError, "Publish a shreddable event inside a transaction" unless PlanEncryptionKey.connection.transaction_open?

    keys = {}
    data = event.data.dup
    description = fields.to_h do |field|
      identifier = event.class.shreddable_identifier(tenant_id, data, field)
      key = keys[identifier] ||= @key_store.create(identifier)
      iv = key.random_iv
      data[field] = encode(key.encrypt(JSON.generate(reveal(data[field])), iv))
      [ field, { cipher: key.cipher, iv: encode(iv), identifier: identifier } ]
    end
    Encrypted.new(event_id: event.event_id, event_type: event.event_type,
                  metadata: event.metadata.to_h.merge(shreddable: description), data: data)
  end

  def reveal(value)
    raise ArgumentError, "A removed value can't be written again" if value.is_a?(Shreddable::Value) && value.removed?

    value.is_a?(Shreddable::Value) ? value.reveal : value
  end

  def seal(event, key_of)
    description = event.metadata[:shreddable] or return event

    data = event.data.dup
    description.each do |field, meta|
      data[field] = sealed(data[field], meta, key_of) unless data[field].nil?
    end
    event.class.new(event_id: event.event_id, metadata: event.metadata.to_h.except(:shreddable), data: data)
  end

  def sealed(stored, meta, key_of)
    Shreddable::Value::Sealed.new(ciphertext: stored.is_a?(Shreddable::Value) ? stored.reveal : stored,
                                  iv: meta[:iv], identifier: meta.fetch(:identifier),
                                  cipher: meta.fetch(:cipher), key_of: key_of)
  end

  def encode(bytes) = Base64.strict_encode64(bytes)
end
