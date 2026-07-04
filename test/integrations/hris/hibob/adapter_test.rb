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
      assert_equal "Software Engineer", person.job_title
    end

    should "adopt pre-existing Person records matched by email" do
      ActsAsTenant.with_tenant(@tenant) do
        create(:person, tenant: @tenant, external_id: nil, hris_source: nil,
               email: "alice@example.com", name: "Old Alice")
      end

      adapter = build_adapter(@fixture["employees"])
      result = adapter.sync_people

      assert_equal 2, result[:created]
      assert_equal 1, result[:updated]

      ActsAsTenant.with_tenant(@tenant) do
        person = Person.find_by(email: "alice@example.com")
        assert_equal "Alice Smith", person.name
        assert_equal "bob-001", person.external_id
        assert_equal "hibob", person.hris_source
        assert_equal 1, Person.where(email: "alice@example.com").count
      end
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

    should "pseudonymise names end to end when the dev whimsifier is enabled" do
      Hris::DevNameWhimsifier.stub(:enabled?, true) do
        adapter = build_adapter(@fixture["employees"])
        adapter.sync_people
      end

      ActsAsTenant.with_tenant(@tenant) do
        alice = Person.find_by(external_id: "bob-001")
        bob = Person.find_by(external_id: "bob-002")

        assert_equal Hris::DevNameWhimsifier.whimsical_name("bob-001"), alice.name
        assert_equal Hris::DevNameWhimsifier.whimsical_name("bob-002"), bob.name
        refute_equal "Alice Smith", alice.name
        assert_equal bob.name.split(" ").last, alice.hris_raw_data.dig("work", "reportsTo", "surname")
        assert_equal "alice@example.com", alice.email
        assert_equal bob, alice.manager
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

  context "#sync_people framework assignment (Pass 5)" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @framework = create(:framework_state)
        @e_role = create(:framework_role, code: "E", name: "Software Engineer")
        @em_role = create(:framework_role, code: "EM", name: "Engineering Manager", track: "management")
        @e_level_5 = create(:framework_level, role_id: @e_role.role_id, ordinal: 5, code: "E5", title: "Senior SWE")
        @e_level_7 = create(:framework_level, role_id: @e_role.role_id, ordinal: 7, code: "E7", title: "Staff SWE")
        @em_level_6 = create(:framework_level, role_id: @em_role.role_id, ordinal: 6, code: "EM6", title: "Eng Manager")
      end
    end

    should "assign touched Person records to framework via Mode 2 (ordinal from custom column)" do
      adapter = build_adapter(@fixture["employees"])
      result = adapter.sync_people

      # Alice: "Software Engineer", level ordinal 5 (from fixture humanReadable)
      # Bob: "Engineering Manager", level ordinal 6
      # Charlie: "Junior Designer" (no mapping)
      assert_equal 2, result[:assigned]
      assert_includes result[:unmapped_titles], "Junior Designer"

      ActsAsTenant.with_tenant(@tenant) do
        alice = Person.find_by(external_id: "bob-001")
        alice_assignment = PersonFrameworkAssignment.find_by(person_id: alice.id)
        assert_equal @e_role.role_id, alice_assignment.role_id
        assert_equal @e_level_5.level_id, alice_assignment.level_id

        bob = Person.find_by(external_id: "bob-002")
        bob_assignment = PersonFrameworkAssignment.find_by(person_id: bob.id)
        assert_equal @em_role.role_id, bob_assignment.role_id
        assert_equal @em_level_6.level_id, bob_assignment.level_id
      end
    end

    should "support Mode 1 (level ordinal in the mapping)" do
      ActsAsTenant.with_tenant(@tenant) do
        @tenant.hris_config = HrisConfig.new(
          provider: "hibob",
          sync_enabled: true,
          # Intentionally no level_field_id — mode 1 only
          role_mappings: [
            HrisRoleMapping.new(hris_titles: [ "Software Engineer" ], framework_role_code: "E", level_ordinal: 7)
          ]
        )
        @tenant.save!
      end

      adapter = build_adapter(@fixture["employees"])
      result = adapter.sync_people

      assert_equal 1, result[:assigned]

      ActsAsTenant.with_tenant(@tenant) do
        alice = Person.find_by(external_id: "bob-001")
        assignment = PersonFrameworkAssignment.find_by(person_id: alice.id)
        # Mode 1 forces level_ordinal=7 regardless of what the column says
        assert_equal @e_level_7.level_id, assignment.level_id
      end
    end

    should "mark unchanged assignments as unchanged" do
      adapter1 = build_adapter(@fixture["employees"])
      adapter1.sync_people

      adapter2 = build_adapter(@fixture["employees"])
      result = adapter2.sync_people

      assert_equal 0, result[:assigned]
      assert_equal 2, result[:unchanged]
    end

    should "emit role change when person moves to a different role" do
      adapter = build_adapter(@fixture["employees"])
      adapter.sync_people

      # Change Alice's title to Engineering Manager + ordinal 6 in the next sync
      updated_employees = @fixture["employees"].map do |e|
        next e unless e["id"] == "bob-001"
        e = e.deep_dup
        e["work"]["title"] = "Engineering Manager"
        e["humanReadable"]["work"]["title"] = "Engineering Manager"
        e["humanReadable"]["work"]["customColumns"]["column_test_id"] = "6"
        e
      end

      adapter2 = build_adapter(updated_employees)
      result = adapter2.sync_people

      assert_equal 1, result[:role_changed]

      ActsAsTenant.with_tenant(@tenant) do
        alice = Person.find_by(external_id: "bob-001")
        assignment = PersonFrameworkAssignment.find_by(person_id: alice.id)
        assert_equal @em_role.role_id, assignment.role_id
        assert_equal @em_level_6.level_id, assignment.level_id
      end
    end

    should "emit level change when only the level changes within the same role" do
      adapter = build_adapter(@fixture["employees"])
      adapter.sync_people

      # Bump Alice's level ordinal from 5 to 7
      updated_employees = @fixture["employees"].map do |e|
        next e unless e["id"] == "bob-001"
        e = e.deep_dup
        e["humanReadable"]["work"]["customColumns"]["column_test_id"] = "7"
        e
      end

      adapter2 = build_adapter(updated_employees)
      result = adapter2.sync_people

      assert_equal 1, result[:level_changed]

      ActsAsTenant.with_tenant(@tenant) do
        alice = Person.find_by(external_id: "bob-001")
        assignment = PersonFrameworkAssignment.find_by(person_id: alice.id)
        assert_equal @e_role.role_id, assignment.role_id
        assert_equal @e_level_7.level_id, assignment.level_id
      end
    end

    should "track unmapped titles" do
      adapter = build_adapter(@fixture["employees"])
      result = adapter.sync_people

      assert_includes result[:unmapped_titles], "Junior Designer"
    end

    should "track missing roles when mapping code does not exist in framework" do
      ActsAsTenant.with_tenant(@tenant) do
        @tenant.hris_config = HrisConfig.new(
          provider: "hibob",
          sync_enabled: true,
          level_field_id: "column_test_id",
          role_mappings: [
            HrisRoleMapping.new(hris_titles: [ "Software Engineer" ], framework_role_code: "ZZZ")
          ]
        )
        @tenant.save!
      end

      adapter = build_adapter(@fixture["employees"])
      result = adapter.sync_people

      assert_equal 0, result[:assigned]
      assert_includes result[:missing_roles], "ZZZ"
    end

    should "track missing ordinals when neither mapping nor column provide one" do
      ActsAsTenant.with_tenant(@tenant) do
        @tenant.hris_config = HrisConfig.new(
          provider: "hibob",
          sync_enabled: true,
          # No level_field_id, and mapping has no level_ordinal
          role_mappings: [
            HrisRoleMapping.new(hris_titles: [ "Software Engineer" ], framework_role_code: "E")
          ]
        )
        @tenant.save!
      end

      adapter = build_adapter(@fixture["employees"])
      result = adapter.sync_people

      assert_equal 0, result[:assigned]
      assert result[:missing_ordinals].any? { |e| e[:title] == "Software Engineer" }
    end

    should "track missing levels when ordinal does not exist for role" do
      ActsAsTenant.with_tenant(@tenant) do
        @tenant.hris_config = HrisConfig.new(
          provider: "hibob",
          sync_enabled: true,
          role_mappings: [
            HrisRoleMapping.new(hris_titles: [ "Software Engineer" ], framework_role_code: "E", level_ordinal: 99)
          ]
        )
        @tenant.save!
      end

      adapter = build_adapter(@fixture["employees"])
      result = adapter.sync_people

      assert_equal 0, result[:assigned]
      assert_includes result[:missing_levels], { code: "E", ordinal: 99 }
    end

    should "skip when role_mappings is empty" do
      ActsAsTenant.with_tenant(@tenant) do
        @tenant.hris_config = HrisConfig.new(provider: "hibob", sync_enabled: true, role_mappings: [])
        @tenant.save!
      end

      adapter = build_adapter(@fixture["employees"])
      result = adapter.sync_people

      assert_equal 0, result[:assigned]
      assert_equal 3, result[:created]
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
