# frozen_string_literal: true

# The keys that encrypt a plan's shreddable fields, behind RailsEventStore's
# key repository interface (`key_of`, `create`, `forget`), so the encryption
# mapper can use it unchanged.
#
# A plan has one key for what it says in general, and one key per person for
# what it holds about them. Identifiers carry the tenant:
#
#   tenant-<tenant_id>/plan-<plan_id>
#   tenant-<tenant_id>/plan-<plan_id>/person-<person_id>
#
# Key material is encrypted at rest with Active Record encryption. Without
# its keys, reading or minting a key raises {Unavailable}; destroying keys
# needs no key material, so forgetting still works.
#
# {#destroy_plan} and {#destroy_person} write in the caller's transaction and
# do nothing later, so the event that records the deletion and the destroyed
# keys commit or roll back together.
#
# @example
#   store = PlanKeyStore.new
#   id = PlanKeyStore.person_identifier(tenant.id, plan_id, person.id)
#   store.create(id)
#   store.key_of(id)             # => RubyEventStore::Mappers::EncryptionKey
#   store.destroy_person(person.id)
#   store.key_of(id)             # => nil, so the field reads as forgotten
class PlanKeyStore
  DEFAULT_CIPHER = "aes-256-gcm"
  IDENTIFIER = %r{\Atenant-(?<tenant_id>[0-9a-f-]{36})/plan-(?<plan_id>[0-9a-f-]{36})(?:/person-(?<person_id>[0-9a-f-]{36}))?\z}

  # The identifier isn't one this store hands out.
  class InvalidIdentifier < ArgumentError; end

  # The identifier names a tenant other than the current one.
  class ForeignTenant < StandardError; end

  # The key was destroyed, or its plan deleted or its person forgotten, so no
  # new key may take its place.
  class Destroyed < StandardError; end

  # Active Record encryption has no keys, so key material can't be read or
  # written. Nothing outside plans needs this store.
  class Unavailable < StandardError
    def initialize(msg = "Plans can't hold private fields yet: set the active_record_encryption " \
                         "primary_key and key_derivation_salt credentials")
      super
    end
  end

  # @param tenant_id [String]
  # @param plan_id [String]
  # @return [String]
  def self.plan_identifier(tenant_id, plan_id) = "tenant-#{tenant_id}/plan-#{plan_id}".downcase

  # @param tenant_id [String]
  # @param plan_id [String]
  # @param person_id [String]
  # @return [String]
  def self.person_identifier(tenant_id, plan_id, person_id) = "#{plan_identifier(tenant_id, plan_id)}/person-#{person_id.to_s.downcase}"

  # @return [Boolean] whether Active Record encryption has the keys it needs
  def self.available?
    config = ActiveRecord::Encryption.config
    config.has_primary_key? && config.has_key_derivation_salt?
  end

  # @param identifier [String]
  # @param cipher [String]
  # @return [RubyEventStore::Mappers::EncryptionKey, nil] nil once destroyed,
  #   or before {#create}
  # @raise [Unavailable, ForeignTenant, InvalidIdentifier]
  def key_of(identifier, cipher: DEFAULT_CIPHER)
    row = scope_for(parse(identifier)).live.find_by(cipher: cipher)
    row && encryption_key(row)
  end

  # Mints the key, or returns the live one already there.
  #
  # @param identifier [String]
  # @param cipher [String]
  # @return [RubyEventStore::Mappers::EncryptionKey]
  # @raise [Destroyed] for a deleted plan or a forgotten person
  # @raise [Unavailable, ForeignTenant, InvalidIdentifier]
  def create(identifier, cipher: DEFAULT_CIPHER)
    parts = parse(identifier)
    existing = live_key(parts, cipher)
    return existing if existing

    PlanEncryptionKey.transaction do
      lock(:plan, parts[:tenant_id], parts[:plan_id])
      lock(:person, parts[:tenant_id], parts[:person_id]) if parts[:person_id]
      existing = live_key(parts, cipher)
      return existing if existing

      refuse_destroyed!(parts)
      encryption_key(insert_key(parts, cipher))
    end
  end

  # Destroys one key.
  #
  # @param identifier [String]
  # @return [Integer] keys destroyed
  def forget(identifier)
    parts = parse(identifier, needs_encryption: false)
    tombstone(scope_for(parts), "forgotten")
  end

  # Destroys every key a deleted plan holds, and leaves a tombstone so the
  # plan can't mint another.
  #
  # @param plan_id [String]
  # @return [Integer] keys destroyed
  def destroy_plan(plan_id)
    tenant = current_tenant!
    PlanEncryptionKey.transaction do
      lock(:plan, tenant.id, plan_id)
      destroyed = tombstone(PlanEncryptionKey.where(tenant: tenant, plan_id: plan_id), "plan_deleted")
      PlanEncryptionKey.upsert_all(
        [ { id: SecureRandom.uuid_v7, tenant_id: tenant.id, plan_id: plan_id, person_id: nil, cipher: DEFAULT_CIPHER,
            destroyed_at: Time.current, destroyed_reason: "plan_deleted" } ],
        unique_by: :index_plan_keys_one_per_plan, update_only: %i[destroyed_reason]
      )
      destroyed
    end
  end

  # Destroys a forgotten person's key in every plan of the current tenant.
  # Plans that held no key for them refuse one later, as the person is
  # forgotten.
  #
  # @param person_id [String]
  # @return [Integer] keys destroyed
  def destroy_person(person_id)
    tenant = current_tenant!
    PlanEncryptionKey.transaction do
      lock(:person, tenant.id, person_id)
      tombstone(PlanEncryptionKey.where(tenant: tenant, person_id: person_id), "person_forgotten")
    end
  end

  private

  def parse(identifier, needs_encryption: true)
    match = IDENTIFIER.match(identifier.to_s.downcase) or raise InvalidIdentifier, "Not a plan key identifier"
    current = ActsAsTenant.current_tenant
    raise ForeignTenant, "The key belongs to another tenant" if current && current.id != match[:tenant_id]
    raise Unavailable if needs_encryption && !self.class.available?

    { tenant_id: match[:tenant_id], plan_id: match[:plan_id], person_id: match[:person_id] }
  end

  # Mappers read events before a handler sets the tenant, so the identifier's
  # tenant scopes the lookup.
  def scope_for(parts)
    ActsAsTenant.without_tenant { PlanEncryptionKey.where(**parts) }
  end

  # A create and a destroy for the same plan or person take turns, so a key
  # can't be minted between a destroy's check and its commit. The lock lasts
  # until the caller's transaction ends.
  def lock(kind, tenant_id, id)
    PlanEncryptionKey.connection.execute(
      PlanEncryptionKey.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))",
                                             lock_name(kind, tenant_id, id) ])
    )
  end

  # Every spelling of a uuid names the same lock.
  def lock_name(kind, tenant_id, id)
    [ "plan-keys", kind, *[ tenant_id, id ].map { it.to_s.delete("{}-").downcase } ].join("/")
  end

  def live_key(parts, cipher)
    row = scope_for(parts).live.first or return
    raise ArgumentError, "This identifier already has a #{row.cipher} key" unless row.cipher == cipher

    encryption_key(row)
  end

  def insert_key(parts, cipher)
    PlanEncryptionKey.transaction(requires_new: true) do
      PlanEncryptionKey.create!(**parts, cipher: cipher, key_material: Base64.strict_encode64(random_key(cipher)))
    end
  end

  def refuse_destroyed!(parts)
    raise Destroyed, "This key was destroyed" if scope_for(parts).tombstones.exists?

    plan_key = scope_for(parts.merge(person_id: nil))
    raise Destroyed, "The plan was deleted" if plan_key.tombstones.exists?(destroyed_reason: "plan_deleted")
    return unless parts[:person_id]

    person_destroyed = ActsAsTenant.without_tenant do
      PlanEncryptionKey.tombstones.exists?(tenant_id: parts[:tenant_id], person_id: parts[:person_id],
                                          destroyed_reason: "person_forgotten") ||
        Person.unscoped.where(tenant_id: parts[:tenant_id], id: parts[:person_id]).where.not(forgotten_at: nil).exists?
    end
    raise Destroyed, "The person was forgotten" if person_destroyed
  end

  def tombstone(scope, reason)
    ActsAsTenant.without_tenant do
      scope.live.update_all(key_material: nil, destroyed_at: Time.current, destroyed_reason: reason,
                            updated_at: Time.current)
    end
  end

  def current_tenant!
    ActsAsTenant.current_tenant or raise ArgumentError, "Destroying plan keys needs a current tenant"
  end

  def random_key(cipher)
    crypto = OpenSSL::Cipher.new(cipher)
    crypto.encrypt
    crypto.random_key
  end

  def encryption_key(row)
    RubyEventStore::Mappers::EncryptionKey.new(cipher: row.cipher, key: row.raw_key)
  rescue ActiveRecord::Encryption::Errors::Configuration
    raise Unavailable
  end
end
