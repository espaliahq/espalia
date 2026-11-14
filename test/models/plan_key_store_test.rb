# frozen_string_literal: true

require "test_helper"

class PlanKeyStoreTest < ActiveSupport::TestCase
  class NoteWritten < RubyEventStore::Event
    def self.encryption_schema = { note: ->(data) { data.fetch(:key_identifier) } }
  end

  setup do
    @tenant = create(:tenant)
    @person = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant) }
    @plan_id = SecureRandom.uuid
    @store = PlanKeyStore.new
    @plan_key = PlanKeyStore.plan_identifier(@tenant.id, @plan_id)
    @person_key = PlanKeyStore.person_identifier(@tenant.id, @plan_id, @person.id)
  end

  def in_tenant(tenant = @tenant, &) = ActsAsTenant.with_tenant(tenant, &)

  context "creating and reading" do
    should "mint a key once and read it back" do
      created = in_tenant { @store.create(@plan_key) }

      assert_equal "aes-256-gcm", created.cipher
      assert_equal 32, created.key.bytesize
      assert_equal created.key, in_tenant { @store.key_of(@plan_key) }.key
      assert_equal created.key, in_tenant { @store.create(@plan_key) }.key
      assert_equal 1, PlanEncryptionKey.unscoped.count
    end

    should "keep the plan key apart from each person's key" do
      in_tenant do
        assert_not_equal @store.create(@plan_key).key, @store.create(@person_key).key
      end
    end

    should "store the key encrypted at rest" do
      key = in_tenant { @store.create(@plan_key) }
      stored = PlanEncryptionKey.connection.select_value("SELECT key_material FROM plan_encryption_keys")

      assert_not_includes stored, Base64.strict_encode64(key.key)
      assert_includes PlanEncryptionKey.encrypted_attributes, :key_material
    end

    should "read nothing before a key is minted" do
      assert_nil in_tenant { @store.key_of(@plan_key) }
    end

    should "read a key with no tenant set, as a mapper does before a handler runs" do
      key = in_tenant { @store.create(@plan_key) }

      assert_equal key.key, @store.key_of(@plan_key).key
    end

    should "refuse an identifier it doesn't hand out" do
      assert_raises(PlanKeyStore::InvalidIdentifier) { in_tenant { @store.key_of("plan-#{@plan_id}") } }
    end
  end

  context "tenant isolation" do
    should "refuse another tenant's identifier" do
      other = create(:tenant)
      in_tenant { @store.create(@plan_key) }

      assert_raises(PlanKeyStore::ForeignTenant) { in_tenant(other) { @store.key_of(@plan_key) } }
      assert_raises(PlanKeyStore::ForeignTenant) { in_tenant(other) { @store.create(@plan_key) } }
    end

    should "destroy only the current tenant's keys" do
      other = create(:tenant)
      other_key = PlanKeyStore.person_identifier(other.id, @plan_id, @person.id)
      in_tenant { @store.create(@person_key) }
      in_tenant(other) { @store.create(other_key) }

      in_tenant { @store.destroy_plan(@plan_id) }
      in_tenant { @store.destroy_person(@person.id) }

      assert in_tenant(other) { @store.key_of(other_key) }
    end
  end

  context "destroying by plan" do
    should "destroy every key the plan holds and refuse new ones" do
      other_plan_key = PlanKeyStore.plan_identifier(@tenant.id, SecureRandom.uuid)
      in_tenant do
        @store.create(@plan_key)
        @store.create(@person_key)
        @store.create(other_plan_key)

        assert_equal 2, @store.destroy_plan(@plan_id)
        assert_nil @store.key_of(@plan_key)
        assert_nil @store.key_of(@person_key)
        assert @store.key_of(other_plan_key)
        assert_raises(PlanKeyStore::Destroyed) { @store.create(@plan_key) }
        assert_raises(PlanKeyStore::Destroyed) { @store.create(@person_key) }
      end
    end

    should "leave no key material behind" do
      in_tenant do
        @store.create(@person_key)
        @store.destroy_plan(@plan_id)
      end

      assert_equal [ nil, nil ], PlanEncryptionKey.unscoped.pluck(:key_material)
      assert_equal %w[plan_deleted], PlanEncryptionKey.unscoped.distinct.pluck(:destroyed_reason)
    end

    should "leave the same person's key in another plan alone" do
      other_plan_key = PlanKeyStore.person_identifier(@tenant.id, SecureRandom.uuid, @person.id)
      in_tenant do
        @store.create(@person_key)
        @store.destroy_plan(@plan_id)

        assert @store.create(other_plan_key)
      end
    end

    should "tombstone a plan that never minted a key" do
      in_tenant { @store.destroy_plan(@plan_id) }

      assert_raises(PlanKeyStore::Destroyed) { in_tenant { @store.create(@plan_key) } }
    end

    should "need a current tenant" do
      assert_raises(ArgumentError) { @store.destroy_plan(@plan_id) }
    end
  end

  context "destroying by person" do
    should "destroy the person's key in every plan and leave the rest readable" do
      second_plan = SecureRandom.uuid
      second_key = PlanKeyStore.person_identifier(@tenant.id, second_plan, @person.id)
      someone_else = in_tenant { create(:person, tenant: @tenant) }
      their_key = PlanKeyStore.person_identifier(@tenant.id, @plan_id, someone_else.id)
      in_tenant do
        [ @plan_key, @person_key, second_key, their_key ].each { @store.create(it) }

        assert_equal 2, @store.destroy_person(@person.id)
        assert_nil @store.key_of(@person_key)
        assert_nil @store.key_of(second_key)
        assert @store.key_of(@plan_key)
        assert @store.key_of(their_key)
        assert_raises(PlanKeyStore::Destroyed) { @store.create(@person_key) }
      end
    end

    should "refuse a key for a forgotten person in a plan that held none" do
      @person.update_columns(forgotten_at: Time.current, name: "Former member", email: nil)

      assert_raises(PlanKeyStore::Destroyed) { in_tenant { @store.create(@person_key) } }
    end

    should "roll back with the caller's transaction" do
      in_tenant do
        @store.create(@person_key)
        ActiveRecord::Base.transaction do
          @store.destroy_person(@person.id)
          raise ActiveRecord::Rollback
        end

        assert @store.key_of(@person_key)
      end
    end
  end

  context "forgetting one key" do
    should "destroy that key only" do
      in_tenant do
        @store.create(@plan_key)
        @store.create(@person_key)

        assert_equal 1, @store.forget(@person_key)
        assert_nil @store.key_of(@person_key)
        assert @store.key_of(@plan_key)
        assert_raises(PlanKeyStore::Destroyed) { @store.create(@person_key) }
      end
    end

    should "leave the plan open to new person keys after its own key goes" do
      in_tenant do
        @store.create(@plan_key)
        @store.forget(@plan_key)

        assert @store.create(@person_key)
        assert_raises(PlanKeyStore::Destroyed) { @store.create(@plan_key) }
      end
    end
  end

  context "with the encryption mapper" do
    setup { @mapper = RubyEventStore::Mappers::EncryptionMapper.new(@store) }

    should "read a field back while its key lives and as forgotten once it is gone" do
      record = in_tenant do
        @store.create(@person_key)
        @mapper.event_to_record(NoteWritten.new(data: { key_identifier: @person_key, note: "Ready to lead" }))
      end

      assert_not_includes record.data[:note], "Ready to lead"
      assert_equal "Ready to lead", @mapper.record_to_event(record).data[:note]

      in_tenant { @store.destroy_person(@person.id) }

      assert_equal RubyEventStore::Mappers::ForgottenData.new, @mapper.record_to_event(record).data[:note]
    end
  end

  context "without Active Record encryption keys" do
    should "refuse to mint or read a key, and still destroy one" do
      in_tenant { @store.create(@person_key) }

      ActiveRecord::Encryption.config.stub(:has_primary_key?, false) do
        error = assert_raises(PlanKeyStore::Unavailable) { in_tenant { @store.create(@plan_key) } }
        assert_match "active_record_encryption", error.message
        assert_raises(PlanKeyStore::Unavailable) { in_tenant { @store.key_of(@person_key) } }
        assert_equal 1, in_tenant { @store.destroy_person(@person.id) }
      end
    end
  end

  context "a restore that brings keys back" do
    should "find live keys for people the Org Graph has forgotten" do
      in_tenant { @store.create(@person_key) }
      @person.update_columns(forgotten_at: Time.current, name: "Former member", email: nil)

      assert_equal [ @person.id ], ActsAsTenant.without_tenant { PlanEncryptionKey.outliving_forgotten_people.pluck(:person_id) }
    end
  end
end
