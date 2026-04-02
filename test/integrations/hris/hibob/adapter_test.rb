# frozen_string_literal: true

require "test_helper"

class Hris::Hibob::AdapterTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant, :with_hibob_config)
    ActsAsTenant.current_tenant = @tenant

    @fixture = JSON.parse(
      File.read(Rails.root.join("test/fixtures/files/hibob/people_search_response.json"))
    )
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  context "#sync_people" do
    should "create new Person records for new employees" do
      adapter = build_adapter(@fixture["employees"])

      result = adapter.sync_people

      assert_equal 3, result[:created]
      assert_equal 0, result[:updated]
      assert_equal 3, Person.count
    end

    should "update existing Person records when attributes change" do
      ActsAsTenant.with_tenant(@tenant) do
        create(:person, tenant: @tenant, external_id: "bob-001", email: "alice@example.com",
               name: "Old Name", hris_source: "hibob")
      end

      adapter = build_adapter(@fixture["employees"])
      result = adapter.sync_people

      assert_equal 2, result[:created]
      assert_equal 1, result[:updated]

      person = ActsAsTenant.with_tenant(@tenant) { Person.find_by(external_id: "bob-001") }
      assert_equal "Alice Smith", person.name
      assert_equal "Senior Engineer", person.job_title
    end

    should "resolve manager relationships" do
      adapter = build_adapter(@fixture["employees"])
      adapter.sync_people

      ActsAsTenant.with_tenant(@tenant) do
        alice = Person.find_by(external_id: "bob-001")
        bob = Person.find_by(external_id: "bob-002")

        assert_equal bob, alice.manager
        assert_nil bob.manager
      end
    end

    should "mark inactive employees from HiBob as inactive" do
      adapter = build_adapter(@fixture["employees"])
      adapter.sync_people

      ActsAsTenant.with_tenant(@tenant) do
        charlie = Person.find_by(external_id: "bob-003")
        assert_equal "inactive", charlie.status
      end
    end

    should "deactivate people no longer in HRIS" do
      ActsAsTenant.with_tenant(@tenant) do
        create(:person, tenant: @tenant, external_id: "bob-gone", email: "gone@example.com",
               name: "Gone User", hris_source: "hibob", status: "active")
      end

      adapter = build_adapter(@fixture["employees"])
      result = adapter.sync_people

      assert_equal 1, result[:deactivated]

      ActsAsTenant.with_tenant(@tenant) do
        gone = Person.find_by(external_id: "bob-gone")
        assert_equal "inactive", gone.status
      end
    end

    should "not deactivate people from other HRIS sources" do
      ActsAsTenant.with_tenant(@tenant) do
        create(:person, tenant: @tenant, external_id: "bamboo-001", email: "bamboo@example.com",
               name: "Bamboo User", hris_source: "bamboohr", status: "active")
      end

      adapter = build_adapter(@fixture["employees"])
      adapter.sync_people

      ActsAsTenant.with_tenant(@tenant) do
        bamboo = Person.find_by(external_id: "bamboo-001")
        assert_equal "active", bamboo.status
      end
    end

    should "be idempotent — running twice produces same result" do
      adapter = build_adapter(@fixture["employees"])
      adapter.sync_people

      adapter2 = build_adapter(@fixture["employees"])
      result2 = adapter2.sync_people

      assert_equal 0, result2[:created]
      assert_equal 0, result2[:updated]
      assert_equal 3, ActsAsTenant.with_tenant(@tenant) { Person.count }
    end

    should "not create User records" do
      user_count = User.count
      adapter = build_adapter(@fixture["employees"])
      adapter.sync_people

      assert_equal user_count, User.count
    end

    should "collect errors for invalid employees without failing the sync" do
      employees = @fixture["employees"] + [
        { "id" => "bob-bad", "email" => "", "firstName" => "", "surname" => "", "isActive" => true }
      ]

      adapter = build_adapter(employees)
      result = adapter.sync_people

      assert_equal 3, result[:created]
      assert result[:errors].any? { |e| e[:external_id] == "bob-bad" }
    end

    should "auto-link TenantUsers to Person records by email" do
      user = create(:user, email: "alice@example.com")
      ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: user, person: nil)
      end

      adapter = build_adapter(@fixture["employees"])
      adapter.sync_people

      ActsAsTenant.with_tenant(@tenant) do
        tu = TenantUser.find_by(user: user)
        assert_not_nil tu.person
        assert_equal "alice@example.com", tu.person.email
      end
    end

    should "update last_synced_at on the config" do
      adapter = build_adapter(@fixture["employees"])

      assert_nil @tenant.hris_config.last_synced_at

      adapter.sync_people
      @tenant.reload

      assert_not_nil @tenant.hris_config.last_synced_at
    end
  end

  private

  # Builds an adapter with a stubbed client that returns the given employees.
  #
  # @param employees [Array<Hash>]
  # @return [Hris::Hibob::Adapter]
  def build_adapter(employees)
    adapter = Hris::Hibob::Adapter.new(@tenant)
    mock_client = Minitest::Mock.new
    mock_client.expect(:search_people, employees, show_inactive: true)
    adapter.instance_variable_set(:@client, mock_client)
    adapter
  end
end
