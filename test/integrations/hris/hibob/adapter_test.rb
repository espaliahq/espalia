# frozen_string_literal: true

require "test_helper"

class Hris::Hibob::AdapterTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant, :with_hibob_config)
    ActsAsTenant.current_tenant = @tenant
    @tenant.claim_hris_facts!

    @fixture = JSON.parse(
      File.read(Rails.root.join("test/fixtures/files/hibob/people_search_response.json"))
    )
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  context "a person already forgotten" do
    setup do
      @employees = @fixture["employees"]
    end

    should "stay skipped while HiBob shows them as gone" do
      forgotten = forget_row("bob-003")

      result = build_adapter(@employees).sync_people

      assert_equal 1, result[:forgotten_skipped]
      assert_equal 2, result[:created]
      assert_nil Person.find_by(external_id: "bob-003")
      assert_equal OrgGraph::Forgetting.digest(@tenant, "hibob", "bob-003"), forgotten.reload.forgotten_external_id_digest
    end

    should "stay skipped while a rehire is yet to start" do
      forget_row("bob-001")
      @employees.find { it["id"] == "bob-001" }["work"]["startDate"] = (Date.current + 30).iso8601

      result = build_adapter(@employees).sync_people

      assert_equal 1, result[:forgotten_skipped]
      assert_nil Person.find_by(external_id: "bob-001")
    end

    should "stay skipped while HiBob holds no start date for them" do
      forget_row("bob-001")
      @employees.find { it["id"] == "bob-001" }["work"].delete("startDate")

      result = build_adapter(@employees).sync_people

      assert_equal 1, result[:forgotten_skipped]
      assert_nil Person.find_by(external_id: "bob-001")
    end

    should "not be adopted by a new hire whose email HiBob leaves blank" do
      forgotten = forget_row("bob-003")
      @employees.find { it["id"] == "bob-001" }["email"] = nil

      build_adapter(@employees).sync_people

      assert_nil forgotten.reload.external_id
      assert_nil forgotten.email
    end

    should "come back as a new person, unlinked from the forgotten one, once back at work" do
      forgotten = forget_row("bob-001")

      result = build_adapter(@employees).sync_people

      assert_equal 0, result[:forgotten_skipped]
      rehired = Person.find_by(external_id: "bob-001")
      assert_not_equal forgotten.id, rehired.id
      assert_nil forgotten.reload.forgotten_external_id_digest
      assert forgotten.forgotten?
    end

    should "not write a forgotten manager back into their reports' payloads" do
      forget_row("bob-002")
      manager = @employees.find { it["id"] == "bob-002" }
      manager["isActive"] = false
      manager["internal"] = { "terminationDate" => "2026-10-31" }

      build_adapter(@employees).sync_people

      report = Person.find_by(external_id: "bob-001")
      assert_nil report.hris_raw_data.dig("work", "reportsTo")
      assert_equal "bob-002", @employees.first.dig("work", "reportsTo", "id")
    end

    should "refuse to sync, creating nobody, without the forgetting key" do
      forget_row("bob-003")

      OrgGraph::Forgetting.stub(:key, nil) do
        assert_raises(OrgGraph::Forgetting::KeyMissing) { build_adapter(@employees).sync_people }
      end
      assert_equal 1, Person.count
    end
  end

  context "#active_external_ids" do
    should "hold everyone HiBob doesn't mark inactive, a hire yet to start included" do
      ids = @fixture["employees"].map { it["id"].to_s }
      inactive = @fixture["employees"].select { it["isActive"] == false }.map { it["id"].to_s }

      assert_equal ids - inactive, build_adapter(@fixture["employees"]).active_external_ids
      assert_not_empty inactive
    end

    should "refuse an empty response, which would spare nobody" do
      assert_raises(Hris::Hibob::Errors::UnexpectedResponseError) { build_adapter([]).active_external_ids }
    end
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

    should "not merge a row into a person who holds another HRIS id, and report it" do
      old = ActsAsTenant.with_tenant(@tenant) do
        create(:person, tenant: @tenant, external_id: "bob-old", hris_source: "hibob", status: "inactive",
               email: "alice@example.com", name: "Alice Before")
      end

      result = build_adapter(@fixture["employees"]).sync_people

      assert_equal [ [ "bob-001", "Email belongs to a person with another HRIS id (bob-old); not merged" ] ],
        result[:errors].map { it.values_at(:external_id, :error) }
      old.reload
      assert_equal [ "bob-old", "inactive", "Alice Before" ], [ old.external_id, old.status, old.name ]
      assert_empty Rails.configuration.event_store.read.stream(stream_of(old)).to_a
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

    should "keep a role mapping an admin changed while the sync ran" do
      adapter = build_adapter(@fixture["employees"])

      # Another request edits the mappings after the adapter read the config.
      elsewhere = Tenant.find(@tenant.id)
      elsewhere.hris_config.map_title("Analytics Lead", framework_role_code: "AE", level_ordinal: 3)
      elsewhere.save!

      adapter.sync_people

      assert_equal "AE", @tenant.reload.hris_config.mapping_for("Analytics Lead")&.framework_role_code
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
      # Charlie: isActive false — skipped before title mapping (Pass 3b owns him)
      assert_equal 2, result[:assigned]
      assert_equal 1, result[:skipped_inactive]
      assert_empty result[:unmapped_titles]

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

    should "track unmapped titles for active people" do
      # Charlie carries the unmapped title but is inactive in the fixture —
      # activate him so his title reaches the mapping step.
      employees = @fixture["employees"].map do |e|
        e["id"] == "bob-003" ? e.merge("isActive" => true) : e
      end
      adapter = build_adapter(employees)
      result = adapter.sync_people

      assert_includes result[:unmapped_titles], "Junior Designer"
    end

    should "track missing roles when mapping code does not exist in framework" do
      ActsAsTenant.with_tenant(@tenant) do
        @tenant.hris_config = HrisConfig.new(
          provider: "hibob",
          sync_enabled: true,
          level_field_id: "work.customColumns.column_test_id",
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

  context "#sync_people offboarding + reactivation (Pass 3b)" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @framework = create(:framework_state)
        @e_role = create(:framework_role, code: "E", name: "Software Engineer")
        @e_level_5 = create(:framework_level, role_id: @e_role.role_id, ordinal: 5, code: "E5", title: "Senior SWE")

        @cycle_id = SecureRandom.uuid_v7
        AssessmentCycles::CommandHandler.new.define_cycle(
          @cycle_id, @framework.framework_id, "Q1", "regular", 1
        )
      end
      @alice = @fixture["employees"].find { |e| e["id"] == "bob-001" }
      @without_alice = @fixture["employees"].select { |e| e["id"] == "bob-002" }

      # Initial sync: alice is created, assigned via her mapped title, and
      # auto-enrolled into the open cycle by AutoEnrollNewAssignments.
      build_adapter([ @alice ]).sync_people
      ActsAsTenant.with_tenant(@tenant) do
        @alice_person = Person.find_by!(external_id: "bob-001")
        assert PersonFrameworkAssignment.find_by(person_id: @alice_person.id)
        assert_equal "enrolled",
          AssessmentCycleEnrollment.find_by!(cycle_id: @cycle_id, person_id: @alice_person.id).status
      end
    end

    should "offboard a person who disappears from the HRIS response" do
      result = build_adapter(@without_alice).sync_people

      assert_equal 1, result[:deactivated]
      assert_equal 1, result[:offboarded]
      assert_empty result[:errors]

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "inactive", @alice_person.reload.status

        enrollment = AssessmentCycleEnrollment.find_by!(cycle_id: @cycle_id, person_id: @alice_person.id)
        assert_equal "withdrawn", enrollment.status
        assert_equal "left_company", enrollment.withdrawal_reason

        assert_nil PersonFrameworkAssignment.find_by(person_id: @alice_person.id)
        refute_includes AssessmentCycle.find_by!(cycle_id: @cycle_id).eligible_people, @alice_person
      end
    end

    should "offboard a person present in the response with isActive false" do
      result = build_adapter([ @alice.merge("isActive" => false) ]).sync_people

      assert_equal 1, result[:offboarded]
      assert_equal 1, result[:skipped_inactive]

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "inactive", @alice_person.reload.status
        enrollment = AssessmentCycleEnrollment.find_by!(cycle_id: @cycle_id, person_id: @alice_person.id)
        assert_equal "withdrawn", enrollment.status
        assert_nil PersonFrameworkAssignment.find_by(person_id: @alice_person.id)
      end
    end

    should "be idempotent — a second sync after offboarding does nothing" do
      build_adapter(@without_alice).sync_people
      result = build_adapter(@without_alice).sync_people

      assert_equal 0, result[:deactivated]
      assert_equal 0, result[:offboarded]
      assert_empty result[:errors]
    end

    should "keep everyone when HiBob returns nobody, as a failed sync" do
      result = build_adapter([]).sync_people

      assert_equal [ 0, 0 ], [ result[:deactivated], result[:offboarded] ]
      assert_equal [ "hibob returned nobody, so no one was marked as left" ], result[:errors].map { it[:error] }
      ActsAsTenant.with_tenant(@tenant) { assert_equal "active", @alice_person.reload.status }
    end

    should "reactivate a returnee like a new hire — re-assigned and re-enrolled" do
      build_adapter(@without_alice).sync_people
      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "inactive", @alice_person.reload.status
      end

      result = build_adapter([ @alice ]).sync_people

      assert_equal 1, result[:assigned]
      assert_equal 0, result[:offboarded]

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "active", @alice_person.reload.status

        assignment = PersonFrameworkAssignment.find_by(person_id: @alice_person.id)
        assert_not_nil assignment, "returnee must be re-assigned via the new-hire path"
        assert_equal @e_role.role_id, assignment.role_id

        enrollment = AssessmentCycleEnrollment.find_by!(cycle_id: @cycle_id, person_id: @alice_person.id)
        assert_equal "enrolled", enrollment.status, "returnee must be auto-enrolled into the open cycle"
        assert_nil enrollment.withdrawn_at

        stream = EventStreamNaming.person_development_stream(@alice_person.id, @framework.framework_id)
        events = Rails.configuration.event_store.read.stream(stream).to_a
        assert_equal 2, events.count { |e| e.is_a?(PersonDevelopment::Events::PersonAssignedToFramework) },
          "the return is a second assignment on the same self-contained stream"
      end
    end
  end

  context "#read_field" do
    should "ask HiBob for the field beside each current person's id, and read each record" do
      adapter = Hris::Hibob::Adapter.new(@tenant)
      client = Minitest::Mock.new
      employees = [
        { "id" => "3141", "work" => { "customColumns" => { "column_team" => "7" } },
          "humanReadable" => { "work" => { "customColumns" => { "column_team" => "Payments" } } } },
        { "id" => "2718" },
        { "work" => { "customColumns" => { "column_team" => "9" } } }
      ]
      client.expect(:search_people, employees, fields: %w[root.id work.customColumns.column_team], show_inactive: false)
      adapter.instance_variable_set(:@client, client)

      values = adapter.read_field("column_team", kind: :list)

      assert_equal({ "3141" => Hris::FieldValue.new(state: :value, id: "7", label: "Payments"),
                     "2718" => Hris::FieldValue.withheld }, values)
      client.verify
    end

    should "withhold a fact from anyone whose record withholds the fact it travels with" do
      adapter = Hris::Hibob::Adapter.new(@tenant)
      client = Minitest::Mock.new
      employees = [
        { "id" => "3141", "work" => { "site" => "Sydney", "customColumns" => { "column_country" => "Australia" } } },
        { "id" => "2718", "work" => { "customColumns" => { "column_country" => "Australia" } } }
      ]
      client.expect(:search_people, employees, fields: %w[root.id work.customColumns.column_country work.site],
        show_inactive: false)
      adapter.instance_variable_set(:@client, client)

      values = adapter.read_field("column_country", kind: :text, alongside: "site")

      assert_equal({ "3141" => Hris::FieldValue.new(state: :value, label: "Australia"),
                     "2718" => Hris::FieldValue.withheld }, values)
      client.verify
    end
  end

  context "#fetch_field_catalogue" do
    setup do
      @fields = hibob_fixture("people_fields_response.json")
      @named_lists = hibob_fixture("named_lists_response.json")
    end

    should "give each field its path, name and kind" do
      catalogue = catalogue_adapter.fetch_field_catalogue.index_by(&:id)

      assert_equal "Employee ID", catalogue["root.id"].name
      assert_predicate catalogue["root.id"], :text?
      assert_predicate catalogue["work.department"], :list?
      assert_predicate catalogue["work.customColumns.column_1700000000002"], :text?
      assert_equal "Squad", catalogue["work.customColumns.column_1700000000001"].name
    end

    should "read a field that is neither list nor text as text, since its values have no ids" do
      catalogue = catalogue_adapter.fetch_field_catalogue.index_by(&:id)

      assert_predicate catalogue["work.reportsTo"], :text?
      assert_empty catalogue["work.reportsTo"].values
    end

    should "attach each list field's values from its named list, leaving out archived ones" do
      department = catalogue_adapter.fetch_field_catalogue.find { it.id == "work.department" }

      assert_equal [ Hris::Field::Value.new(id: "201", name: "Engineering") ], department.values
    end

    should "flatten a hierarchy list, dropping an archived value with its children" do
      squad = catalogue_adapter.fetch_field_catalogue.find { it.name == "Squad" }

      assert_equal %w[Payments Checkout Refunds], squad.values.map(&:name)
      assert_equal %w[301 302 303], squad.values.map(&:id)
    end

    should "keep a list field whose named list HiBob did not return, with no values" do
      site = catalogue_adapter.fetch_field_catalogue.find { it.id == "work.site" }

      assert_predicate site, :list?
      assert_empty site.values
    end

    should "leave out an entry with no path" do
      names = catalogue_adapter.fetch_field_catalogue.map(&:name)

      assert_not_includes names, "Field with no path"
      assert_equal 7, names.size
    end

    should "read named lists served as an object keyed by list id, whatever each list calls itself" do
      keyed = @named_lists.to_h { |list| [ list["name"], { "name" => list["name"].titleize, "items" => list["items"] } ] }

      title = catalogue_adapter(named_lists: keyed).fetch_field_catalogue.find { it.id == "work.title" }

      assert_equal [ "Software Engineer", "Engineering Manager" ], title.values.map(&:name)
    end

    should "read a list's entries from values when it has no items" do
      keyed = { "title" => { "values" => [ { "id" => 101, "name" => "Software Engineer" } ] } }

      title = catalogue_adapter(named_lists: keyed).fetch_field_catalogue.find { it.id == "work.title" }

      assert_equal [ Hris::Field::Value.new(id: "101", name: "Software Engineer") ], title.values
    end

    should "keep a list HiBob returned with no entries as a list with no values" do
      @named_lists.first["items"] = []

      title = catalogue_adapter.fetch_field_catalogue.find { it.id == "work.title" }

      assert_empty title.values
    end

    should "leave out a list value with no id, since nothing could refer to it" do
      @named_lists.first["items"] << { "value" => "No id", "name" => "No id", "archived" => false }

      title = catalogue_adapter.fetch_field_catalogue.find { it.id == "work.title" }

      assert_not_includes title.values.map(&:name), "No id"
    end

    should "not ask for named lists when no field is a list" do
      text_only = @fields.reject { Hris::Hibob::Adapter::LIST_TYPES.include?(it["type"]) }
      adapter = Hris::Hibob::Adapter.new(@tenant)
      client = Minitest::Mock.new
      client.expect(:get_fields, text_only)
      adapter.instance_variable_set(:@client, client)

      assert adapter.fetch_field_catalogue.all?(&:text?)
      client.verify
    end

    should "raise when HiBob fails, rather than return no fields" do
      failing = Object.new
      failing.define_singleton_method(:get_fields) { raise Hris::Hibob::Errors::ApiError.new(status: 503, body: "down") }
      adapter = Hris::Hibob::Adapter.new(@tenant)
      adapter.instance_variable_set(:@client, failing)

      assert_raises(Hris::Hibob::Errors::ApiError) { adapter.fetch_field_catalogue }
    end

    should "raise when the fields response is not a list" do
      error = assert_raises(Hris::Hibob::Errors::UnexpectedResponseError) do
        catalogue_adapter(fields: { "error" => "unexpected" }).fetch_field_catalogue
      end
      assert_match "fields", error.message
    end

    should "raise on a named lists body of the wrong shape" do
      [
        "oops",
        [ "department" ],
        { "department" => [ { "id" => 1 } ] },
        { "error" => { "message" => "unavailable" } },
        [ { "name" => "title" } ],
        [ { "name" => "title", "items" => nil } ],
        [ { "name" => "title", "items" => "Software Engineer" } ],
        [ { "name" => "title", "items" => [ "Software Engineer" ] } ]
      ].each do |named_lists|
        assert_raises(Hris::Hibob::Errors::UnexpectedResponseError, named_lists.inspect) do
          catalogue_adapter(named_lists:).fetch_field_catalogue
        end
      end
    end

    should "raise on a fields body holding something other than objects" do
      assert_raises(Hris::Hibob::Errors::UnexpectedResponseError) do
        catalogue_adapter(fields: [ "work.title" ]).fetch_field_catalogue
      end
    end

    should "read a list field whose typeData is not an object as a list with no values" do
      @fields << { "jsonPath" => "work.odd", "name" => "Odd", "type" => "list", "typeData" => "department" }

      odd = catalogue_adapter.fetch_field_catalogue.find { it.id == "work.odd" }

      assert_predicate odd, :list?
      assert_empty odd.values
    end
  end

  context "#sync_people when Espalia holds a fact the sync supplies" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).set_fact_provider("title", "espalia", effective_on: Date.current)
      end
      @result = build_adapter(@fixture["employees"]).sync_people
    end

    should "report each refused person and finish the rest of the run" do
      people = ActsAsTenant.with_tenant(@tenant) { Person.all.to_a }
      refused = @result[:errors].select { it[:error] == "espalia supplies title; change it there" }

      assert_equal people.map(&:id).sort, refused.pluck(:person_id).sort
      assert_equal @fixture["employees"].size, @result[:created]
      assert_empty org_graph_events
    end
  end

  context "#sync_people Org Graph differences (Pass 2b)" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        create(:framework_state)
        e_role = create(:framework_role, code: "E", name: "Software Engineer")
        em_role = create(:framework_role, code: "EM", name: "Engineering Manager", track: "management")
        create(:framework_level, role_id: e_role.role_id, ordinal: 5, code: "E5", title: "Senior SWE")
        create(:framework_level, role_id: em_role.role_id, ordinal: 6, code: "EM6", title: "Eng Manager")
      end
      build_adapter(@fixture["employees"]).sync_people
      @people = ActsAsTenant.with_tenant(@tenant) { Person.all.index_by(&:external_id) }
    end

    should "start every person's stream with PersonRecorded on the first sync" do
      @people.each_value do |person|
        events = Rails.configuration.event_store.read.stream(stream_of(person)).to_a
        assert_kind_of OrgGraph::Events::PersonRecorded, events.first, person.external_id
        assert_equal 1, events.size, person.external_id
      end
    end

    should "record the facts as they stood, from HiBob, today" do
      alice = recorded(@people["bob-001"])

      assert_equal "employed", alice[:employment_status]
      assert_equal "Software Engineer", alice[:title]
      assert_equal "5", alice[:level]
      assert_equal @people["bob-002"].id, alice[:manager_id]
      assert_equal "hibob", alice[:provider]
      assert_equal Date.current.iso8601, alice[:effective_on]
    end

    should "mark every Org Graph event as the HRIS sync's, sharing one correlation id" do
      metadata = org_graph_events.map(&:metadata)

      assert(metadata.all? { it[:acting_via] == "hris" })
      assert_equal 1, metadata.map { it[:correlation_id] }.uniq.compact.size
    end

    should "record site, FTE, employment type and start date with the person" do
      alice = recorded(@people["bob-001"])

      assert_equal [ "Melbourne", nil, 1.0, "Permanent", "2023-01-15" ],
        alice.values_at(:site, :country, :fte, :employment_type, :started_on)
    end

    should "record a leaver's termination date" do
      assert_equal "2026-10-31", recorded(@people["bob-003"])[:left_on]
    end

    should "keep a hire HiBob shows active before their start date pending, then join them on it" do
      start = Date.current + 10
      newcomer = @fixture["employees"].first.deep_dup.merge("id" => "bob-005", "email" => "eve@example.com", "displayName" => "Eve Ito")
      newcomer["work"] = newcomer["work"].merge("startDate" => start.iso8601, "reportsTo" => nil)
      employees = @fixture["employees"] + [ newcomer ]

      build_adapter(employees).sync_people
      eve = ActsAsTenant.with_tenant(@tenant) { Person.find_by(external_id: "bob-005") }
      assert_equal "pending", recorded(eve)[:employment_status]

      travel_to(start + 1) { build_adapter(employees).sync_people }
      joined = Rails.configuration.event_store.read.stream(stream_of(eve)).to_a.last
      assert_equal [ OrgGraph::Events::PersonJoined, start.iso8601 ], [ joined.class, joined.data[:effective_on] ]
    end

    should "record a person HiBob shows as inactive as having left" do
      assert_equal "left", recorded(@people["bob-003"])[:employment_status]
    end

    should "record a person who first appears in a later sync" do
      newcomer = @fixture["employees"].first.deep_dup.merge("id" => "bob-004", "email" => "dana@example.com", "displayName" => "Dana Ng")

      result = build_adapter(@fixture["employees"] + [ newcomer ]).sync_people

      assert_equal 1, result[:org_graph_events]
      assert_kind_of OrgGraph::Events::PersonRecorded, org_graph_events.last
    end

    context "for people the Org Graph has recorded" do
      setup do
        @recorded = org_graph_events.size
      end

      should "write no events when nothing changed" do
        result = build_adapter(@fixture["employees"]).sync_people

        assert_empty result[:errors]
        assert_equal 0, result[:org_graph_events]
        assert_equal @recorded, org_graph_events.size
      end

      should "write exactly a TitleChanged from HiBob for a new title" do
        employees = with_employee("bob-001") { |e| e["work"]["title"] = e["humanReadable"]["work"]["title"] = "Staff Engineer" }

        result = build_adapter(employees).sync_people

        event = org_graph_events.last
        assert_equal 1, result[:org_graph_events]
        assert_kind_of OrgGraph::Events::TitleChanged, event
        assert_equal @people["bob-001"].id, event.data[:person_id]
        assert_equal "Staff Engineer", event.data[:title]
        assert_equal "hibob", event.data[:provider]
        assert_equal Date.current.iso8601, event.data[:effective_on]
      end

      should "write a LevelChanged with HiBob's own level label" do
        employees = with_employee("bob-002") { |e| e["humanReadable"]["work"]["customColumns"]["column_test_id"] = "7" }

        build_adapter(employees).sync_people

        assert_equal [ [ OrgGraph::Events::LevelChanged, "7" ] ], new_events.map { |e| [ e.class, e.data[:level] ] }
      end

      should "record a manager the HRIS no longer names, which Pass 2 keeps" do
        employees = with_employee("bob-001") { |e| e["work"].delete("reportsTo") }

        build_adapter(employees).sync_people

        assert_equal [ [ OrgGraph::Events::ManagerChanged, nil ] ], new_events.map { |e| [ e.class, e.data[:manager_id] ] }
      end

      should "leave the manager uncompared when HiBob names someone Espalia does not know" do
        employees = with_employee("bob-001") { |e| e["work"]["reportsTo"] = { "id" => "bob-999" } }

        build_adapter(employees).sync_people

        assert_empty new_events
      end

      should "leave a fact HiBob omits unchanged, never cleared" do
        employees = with_employee("bob-001") do |e|
          e["work"].delete("title")
          e["humanReadable"]["work"].delete("title")
          e["humanReadable"]["work"]["customColumns"].delete("column_test_id")
        end

        result = build_adapter(employees).sync_people

        assert_empty result[:errors]
        assert_empty new_events
      end

      should "write a self-managed person's other facts and leave the manager uncompared" do
        employees = with_employee("bob-002") do |e|
          e["work"]["reportsTo"] = { "id" => "bob-002" }
          e["work"]["title"] = e["humanReadable"]["work"]["title"] = "Director"
        end

        result = build_adapter(employees).sync_people

        assert_empty result[:errors]
        assert_equal [ OrgGraph::Events::TitleChanged ], new_events.map(&:class)
      end

      should "leave an inactive person's facts uncompared" do
        employees = with_employee("bob-003") { |e| e["work"]["title"] = e["humanReadable"]["work"]["title"] = "Designer" }

        build_adapter(employees).sync_people

        assert_empty new_events
      end

      should "write a PersonLeft once when HiBob shows someone inactive" do
        employees = with_employee("bob-001") { |e| e["isActive"] = false }

        build_adapter(employees).sync_people
        build_adapter(employees).sync_people

        assert_equal [ [ OrgGraph::Events::PersonLeft, @people["bob-001"].id ] ],
          new_events.map { |e| [ e.class, e.data[:person_id] ] }
      end

      should "write a PersonReturned when a leaver is active again" do
        employees = with_employee("bob-003") { |e| e["isActive"] = true }

        result = build_adapter(employees).sync_people

        assert_empty result[:errors]
        assert_equal OrgGraph::Events::PersonReturned, new_events.first&.class
        assert_equal @people["bob-003"].id, new_events.first.data[:person_id]
      end

      should "write a SiteChanged with no country for a new site, and an absent one for a blank site" do
        moved = with_employee("bob-001") { |e| e["work"]["site"] = "Sydney" }
        build_adapter(moved).sync_people
        blank = with_employee("bob-001") { |e| e["work"]["site"] = "" }
        build_adapter(blank).sync_people

        assert_equal [ [ OrgGraph::Events::SiteChanged, "Sydney", nil ], [ OrgGraph::Events::SiteChanged, nil, nil ] ],
          new_events.map { |e| [ e.class, *e.data.values_at(:site, :country) ] }
      end

      should "read cost centre and country from the fields the tenant's mapping names" do
        handler = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        handler.set_fact_provider("cost_centre", "hibob", fields: { cost_centre: "work.customColumns.column_cc" },
                                                          effective_on: Date.current)
        handler.set_fact_provider("site", "hibob", fields: { country: "address.country" }, effective_on: Date.current)
        @recorded = org_graph_events.size
        employees = with_employee("bob-001") do |e|
          e["work"]["customColumns"] = { "column_cc" => "cc-17" }
          e["address"] = { "country" => "AU" }
          e["humanReadable"]["work"]["customColumns"] = { "column_cc" => "Platform" }
          e["humanReadable"]["address"] = { "country" => "Australia" }
        end

        build_adapter(employees).sync_people

        assert_equal [ [ OrgGraph::Events::CostCentreChanged, "Platform" ], [ OrgGraph::Events::SiteChanged, "Australia" ] ],
          new_events.map { |e| [ e.class, e.data[:cost_centre] || e.data[:country] ] }
      end

      should "write no cost centre for a value it cannot read, as for one HiBob withholds" do
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).set_fact_provider("cost_centre", "hibob",
          fields: { cost_centre: "work.customColumns.column_cc" }, effective_on: Date.current)
        @recorded = org_graph_events.size
        employees = with_employee("bob-001") do |e|
          e["work"]["customColumns"] = { "column_cc" => %w[17 18] }
          e["humanReadable"]["work"]["customColumns"] = { "column_cc" => "Platform, Payments" }
        end

        result = build_adapter(employees).sync_people

        assert_empty result[:errors]
        assert_not new_events.any?(OrgGraph::Events::CostCentreChanged)
      end

      should "request the mapped fields from HiBob" do
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).set_fact_provider("cost_centre", "hibob",
          fields: { cost_centre: "work.customColumns.column_cc" }, effective_on: Date.current)

        assert_includes Hris::Hibob::Adapter.new(@tenant).send(:client).default_fields, "work.customColumns.column_cc"
      end

      should "write an EmploymentChanged for a new FTE, keeping HiBob's own type label" do
        employees = with_employee("bob-001") do |e|
          e["payroll"]["employment"]["fte"] = 60
          e["humanReadable"]["payroll"]["employment"]["type"] = "Part-time permanent"
        end

        build_adapter(employees).sync_people

        assert_equal [ [ OrgGraph::Events::EmploymentChanged, 0.6, "Part-time permanent" ] ],
          new_events.map { |e| [ e.class, *e.data.values_at(:fte, :employment_type) ] }
      end

      should "leave FTE and type uncompared when HiBob withholds them" do
        employees = with_employee("bob-001") do |e|
          e.delete("payroll")
          e["humanReadable"].delete("payroll")
        end

        result = build_adapter(employees).sync_people

        assert_empty result[:errors]
        assert_empty new_events
      end

      should "write a StartDateChanged when HiBob's start date differs" do
        employees = with_employee("bob-001") { |e| e["work"]["startDate"] = "2023-02-01" }

        build_adapter(employees).sync_people

        assert_equal [ [ OrgGraph::Events::StartDateChanged, "2023-02-01" ] ],
          new_events.map { |e| [ e.class, e.data[:started_on] ] }
      end

      should "date a leaving by HiBob's termination date" do
        employees = with_employee("bob-001") do |e|
          e["isActive"] = false
          e["internal"] = { "terminationDate" => "2026-11-05" }
        end

        build_adapter(employees).sync_people

        assert_equal [ [ OrgGraph::Events::PersonLeft, "2026-11-05" ] ],
          new_events.map { |e| [ e.class, e.data[:effective_on] ] }
      end

      should "keep writing Person Development as before" do
        pd_before = person_development_event_count
        employees = with_employee("bob-001") do |e|
          e["work"]["title"] = e["humanReadable"]["work"]["title"] = "Engineering Manager"
          e["humanReadable"]["work"]["customColumns"]["column_test_id"] = "6"
        end

        result = build_adapter(employees).sync_people

        assert_equal 1, result[:role_changed]
        assert_operator person_development_event_count, :>, pd_before
      end

      context "when HiBob no longer returns someone" do
        setup do
          @without_bob = @fixture["employees"].reject { it["id"] == "bob-001" }
        end

        should "write a PersonLeft dated by the first sync to miss them, and none on later days" do
          first = build_adapter(@without_bob).sync_people
          second = travel(1.day) { build_adapter(@without_bob).sync_people }

          assert_empty first[:errors]
          assert_equal [ 1, 0 ], [ first[:org_graph_events], second[:org_graph_events] ]
          assert_equal [ [ OrgGraph::Events::PersonLeft, @people["bob-001"].id, Date.current.iso8601, "hibob" ] ],
            new_events.map { |e| [ e.class, *e.data.values_at(:person_id, :effective_on, :provider) ] }
        end

        should "share one correlation id between the leaving and the sync's other changes" do
          employees = with_employee("bob-002") { |e| e["work"]["title"] = e["humanReadable"]["work"]["title"] = "Staff Engineer" }
          build_adapter(employees.reject { it["id"] == "bob-001" }).sync_people

          assert_equal [ OrgGraph::Events::PersonLeft, OrgGraph::Events::TitleChanged ].to_set, new_events.to_set(&:class)
          assert_equal 1, new_events.map { it.metadata[:correlation_id] }.uniq.size
        end

        should "deactivate at once and write the PersonLeft on the next sync when the first write fails" do
          handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
          handler.define_singleton_method(:record_absence) { |*, **| raise "event store down" }
          failed = OrgGraph::CommandHandler.stub(:new, handler) { build_adapter(@without_bob).sync_people }
          retried = travel(1.day) { build_adapter(@without_bob).sync_people }

          assert_equal [ "event store down" ], failed[:errors].map { it[:error] }
          assert_equal "inactive", @people["bob-001"].reload.status
          assert_empty retried[:errors]
          assert_equal [ [ OrgGraph::Events::PersonLeft, Date.tomorrow.iso8601 ] ],
            new_events.map { |e| [ e.class, e.data[:effective_on] ] }
        end

        should "write nothing for a leaver HiBob already showed as inactive" do
          result = travel(1.day) { build_adapter(@fixture["employees"].reject { it["id"] == "bob-003" }).sync_people }

          assert_empty result[:errors]
          assert_empty new_events
        end

        should "write nothing for anyone when HiBob returns nobody" do
          result = build_adapter([]).sync_people

          assert_equal 0, result[:org_graph_events]
          assert_equal 1, result[:errors].size
          assert_empty new_events
        end

        should "write nothing for anyone when the fetch fails" do
          adapter = Hris::Hibob::Adapter.new(@tenant)
          failing = Object.new
          failing.define_singleton_method(:search_people) { |**| raise Hris::Hibob::Errors::ApiError.new(status: 503, body: "down") }
          adapter.instance_variable_set(:@client, failing)

          assert_raises(Hris::Hibob::Errors::ApiError) { adapter.sync_people }
          assert_empty new_events
        end

        should "write a PersonReturned on the same stream when they come back" do
          build_adapter(@without_bob).sync_people
          result = build_adapter(@fixture["employees"]).sync_people

          assert_empty result[:errors]
          assert_equal [ OrgGraph::Events::PersonLeft, OrgGraph::Events::PersonReturned ],
            Rails.configuration.event_store.read.stream(stream_of(@people["bob-001"])).to_a.drop(1).map(&:class)
          assert_equal @people["bob-001"].id, ActsAsTenant.with_tenant(@tenant) { Person.find_by(external_id: "bob-001").id }
        end
      end
    end

    context "once the tenant is cut over to the Org Graph" do
      setup do
        assert OrgGraph::PeopleCutover.new(@tenant).run(apply: true).applied
        @alice = @people["bob-001"]
      end

      should "leave the title, manager and status to the streams, writing none of them itself" do
        @alice.update_columns(job_title: "Stale", manager_id: nil, status: "inactive")

        result = build_adapter(@fixture["employees"]).sync_people

        assert_empty result[:errors]
        assert_equal [ "Stale", nil, "inactive" ], @alice.reload.slice(:job_title, :manager_id, :status).values
      end

      should "write a new title through its event" do
        employees = with_employee("bob-001") { |e| e["work"]["title"] = e["humanReadable"]["work"]["title"] = "Staff Engineer" }

        build_adapter(employees).sync_people

        assert_equal "Staff Engineer", @alice.reload.job_title
      end

      should "record a leaving for someone HiBob stops returning, which marks them inactive" do
        result = build_adapter(@fixture["employees"].reject { it["id"] == "bob-001" }).sync_people

        assert_equal 1, result[:deactivated]
        assert_kind_of OrgGraph::Events::PersonLeft, Rails.configuration.event_store.read.stream(stream_of(@alice)).last
        assert_equal "inactive", @alice.reload.status
      end

      should "record a leaving even when Espalia holds the title and manager" do
        handler = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        %w[title manager].each { handler.set_fact_provider(it, "espalia", effective_on: Date.current) }

        result = build_adapter(@fixture["employees"].reject { it["id"] == "bob-001" }).sync_people

        assert_equal 1, result[:deactivated]
        assert_kind_of OrgGraph::Events::PersonLeft, Rails.configuration.event_store.read.stream(stream_of(@alice)).last
        assert_equal "inactive", @alice.reload.status
      end

      should "leave a leaver active and report it when the absence write fails, and offboard them on the next sync" do
        without_alice = @fixture["employees"].reject { it["id"] == "bob-001" }
        handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        handler.define_singleton_method(:record_absence) { |*, **| raise "event store down" }

        failed = OrgGraph::CommandHandler.stub(:new, handler) { build_adapter(without_alice).sync_people }

        assert_equal [ "event store down" ], failed[:errors].map { it[:error] }
        assert_equal 0, failed[:deactivated]
        assert_equal "active", @alice.reload.status

        retried = travel(1.day) { build_adapter(without_alice).sync_people }

        assert_empty retried[:errors]
        assert_equal 1, retried[:deactivated]
        assert_equal "inactive", @alice.reload.status
      end

      should "record a leaving HiBob reports while Espalia holds the title and manager" do
        handler = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        %w[title manager].each { handler.set_fact_provider(it, "espalia", effective_on: Date.current) }

        result = build_adapter(with_employee("bob-001") { |e| e["isActive"] = false }).sync_people

        assert_not_includes result[:errors].pluck(:person_id), @alice.id
        assert_kind_of OrgGraph::Events::PersonLeft, Rails.configuration.event_store.read.stream(stream_of(@alice)).last
        assert_equal "inactive", @alice.reload.status
      end

      should "create a newcomer HiBob shows as inactive as inactive, even if recording them fails" do
        leaver = @fixture["employees"].first.deep_dup.merge("id" => "bob-004", "email" => "dana@example.com", "isActive" => false)
        failing = Object.new
        def failing.sync_person(*, **) = raise("recording failed")

        result = OrgGraph::CommandHandler.stub(:new, failing) { build_adapter(@fixture["employees"] + [ leaver ]).sync_people }

        assert_includes result[:errors].map { it[:error] }, "recording failed"
        assert_equal "inactive", Person.find_by!(external_id: "bob-004").status
      end

      should "record someone with no stream as having left when HiBob stops returning them" do
        stray = create(:person, tenant: @tenant, external_id: "bob-009", hris_source: "hibob", job_title: "Analyst")

        result = build_adapter(@fixture["employees"]).sync_people

        assert_empty result[:errors]
        assert_equal [ "left", "Analyst" ], recorded(stray).values_at(:employment_status, :title)
        assert_equal "inactive", stray.reload.status
      end

      should "date a leaver with no stream by the termination date their stored HiBob record holds" do
        stray = create(:person, tenant: @tenant, external_id: "bob-009", hris_source: "hibob", job_title: "Analyst",
                                hris_raw_data: { "id" => "bob-009", "internal" => { "terminationDate" => "2019-03-15" } })

        build_adapter(@fixture["employees"]).sync_people

        assert_equal [ "left", "2019-03-15", "hris_termination_date" ],
                     recorded(stray).values_at(:employment_status, :left_on, :left_on_source)
        assert_equal Date.new(2019, 3, 15), ActsAsTenant.with_tenant(@tenant) { OrgLeaver.find_by(person_id: stray.id).left_on }
      end

      should "date a leaver with no stream and no termination date by the sync, whenever their row last changed" do
        stray = create(:person, tenant: @tenant, external_id: "bob-009", hris_source: "hibob", job_title: "Analyst")
        stray.update_columns(updated_at: Time.zone.parse("2025-06-30 10:00"))

        build_adapter(@fixture["employees"]).sync_people

        assert_equal [ Date.current.iso8601, "first_recorded" ], recorded(stray).values_at(:left_on, :left_on_source)
      end

      should "pass over a termination date still to come for a leaver with no stream" do
        stray = create(:person, tenant: @tenant, external_id: "bob-009", hris_source: "hibob",
                                hris_raw_data: { "internal" => { "terminationDate" => (Date.current + 30).iso8601 } })

        build_adapter(@fixture["employees"]).sync_people

        assert_equal [ Date.current.iso8601, "first_recorded" ], recorded(stray).values_at(:left_on, :left_on_source)
      end

      should "record someone with no stream as having left when Espalia holds their title and manager" do
        handler = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        %w[title manager].each { handler.set_fact_provider(it, "espalia", effective_on: Date.current) }
        stray = create(:person, tenant: @tenant, external_id: "bob-009", hris_source: "hibob", job_title: "Analyst", manager: @alice)

        result = build_adapter(@fixture["employees"]).sync_people

        assert_not_includes result[:errors].pluck(:person_id), stray.id
        assert_equal 1, result[:deactivated]
        assert_equal 3, Rails.configuration.event_store.read.stream(stream_of(stray)).count
        assert_operator result[:org_graph_events], :>=, 3
        assert_equal [ "inactive", "Analyst", @alice.id ], stray.reload.values_at(:status, :job_title, :manager_id)
      end

      should "record nothing for a stray leaver when keeping their manager fails, and record them on the next sync" do
        handler = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        %w[title manager].each { handler.set_fact_provider(it, "espalia", effective_on: Date.current) }
        stray = create(:person, tenant: @tenant, external_id: "bob-009", hris_source: "hibob", job_title: "Analyst", manager: @alice)
        real_new = OrgGraph::CommandHandler.method(:new)
        failing_new = lambda do |**kwargs|
          real_new.call(**kwargs).tap { |h| h.define_singleton_method(:change_manager) { |*, **| raise "manager write failed" } }
        end

        result = OrgGraph::CommandHandler.stub(:new, failing_new) { build_adapter(@fixture["employees"]).sync_people }

        assert_includes result[:errors], { person_id: stray.id, error: "manager write failed" }
        assert_equal 0, Rails.configuration.event_store.read.stream(stream_of(stray)).count
        assert_equal [ "active", "Analyst", @alice.id ], stray.reload.values_at(:status, :job_title, :manager_id)

        build_adapter(@fixture["employees"]).sync_people

        assert_equal [ "inactive", "Analyst", @alice.id ], stray.reload.values_at(:status, :job_title, :manager_id)
      end

      should "hand the columns back to the sync once reverted" do
        @alice.update_columns(job_title: "Stale")
        OrgGraph::PeopleCutover.new(@tenant).revert!

        build_adapter(@fixture["employees"]).sync_people

        assert_equal "Software Engineer", @alice.reload.job_title
      end
    end

    should "see a cut-over that commits after the job loaded its tenant" do
      adapter = build_adapter(@fixture["employees"])
      assert OrgGraph::PeopleCutover.new(Tenant.find(@tenant.id)).run(apply: true).applied
      alice = @people["bob-001"]
      alice.update_columns(job_title: "Stale")

      adapter.sync_people

      assert_equal "Stale", alice.reload.job_title
    end
  end

  context "#sync_people absence brake" do
    setup do
      @staff = synthetic_employees(10)
      build_adapter(@staff).sync_people
      @recorded = org_graph_events.size
    end

    should "mark nobody as left when more than 10% and more than 5 people vanish at once" do
      result = build_adapter(@staff.first(4)).sync_people

      assert_equal 0, result[:deactivated]
      assert_empty new_events
      assert_equal [ "6 of 10 employed people are missing from hibob, more than 10% and 5 people, so no one was marked as left" ],
        result[:errors].map { it[:error] }
      ActsAsTenant.with_tenant(@tenant) { assert_equal 10, Person.where(status: "active").count }
    end

    should "mark them left when no more than 5 vanish" do
      result = build_adapter(@staff.first(5)).sync_people

      assert_empty result[:errors]
      assert_equal 5, result[:deactivated]
      assert_equal [ OrgGraph::Events::PersonLeft ] * 5, new_events.map(&:class)
    end

    should "decide afresh on the next sync" do
      build_adapter(@staff.first(4)).sync_people
      result = build_adapter(@staff.first(9)).sync_people

      assert_empty result[:errors]
      assert_equal 1, result[:deactivated]
      assert_equal [ [ OrgGraph::Events::PersonLeft, "syn-9" ] ],
        new_events.map { |e| [ e.class, ActsAsTenant.with_tenant(@tenant) { Person.find(e.data[:person_id]).external_id } ] }
    end

    should "mark them left when they are no more than 10% of everyone employed" do
      staff = synthetic_employees(60)
      build_adapter(staff).sync_people
      result = build_adapter(staff.drop(6)).sync_people

      assert_empty result[:errors]
      assert_equal 6, result[:deactivated]
    end
  end

  context "mirroring a structure level" do
    setup do
      @team_level = SecureRandom.uuid_v7
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      structure.define_taxonomy([ { level_id: @team_level, name: "Team" } ], effective_on: "2026-01-01")
      structure.set_level_provider(@team_level, "hibob", field: "work.department", effective_on: "2026-01-01")
    end

    should "place each person in the unit their record names" do
      adapter = build_adapter(@fixture["employees"])
      adapter.define_singleton_method(:fetch_field_catalogue) { [ Hris::Field.new(id: "work.department", name: "Department", kind: :text) ] }

      adapter.sync_people

      engineering = OrgUnit.live.find_by!(level_id: @team_level, external_ref: "work.department/Engineering")
      alice = Person.find_by!(external_id: "bob-001")
      assert OrgMembership.exists?(person_id: alice.id, unit_id: engineering.id, provider: "hibob")
    end

    should "mirror nothing when HiBob's field lists can't be read" do
      adapter = build_adapter(@fixture["employees"])
      adapter.define_singleton_method(:fetch_field_catalogue) { raise Hris::Hibob::Errors::ApiError.new(status: 503, body: "timeout") }

      result = adapter.sync_people

      assert_not OrgUnit.exists?(level_id: @team_level)
      assert(result[:errors].any? { it[:error].include?("no structure level was mirrored") })
    end

    should "forget a unit's first parent reading when HiBob's field lists can't be read" do
      unit = SecureRandom.uuid_v7
      OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                       .create_unit(unit, "Engineering", level_id: @team_level, provider: "hibob",
                                                                         external_ref: "work.department/Engineering", effective_on: "2026-01-01")
      HrisUnitParentProposal.create!(unit_id: unit, parent_id: SecureRandom.uuid_v7, first_seen_on: Date.new(2026, 11, 12))
      adapter = build_adapter(@fixture["employees"])
      adapter.define_singleton_method(:fetch_field_catalogue) { raise Hris::Hibob::Errors::ApiError.new(status: 503, body: "timeout") }

      adapter.sync_people

      assert_not HrisUnitParentProposal.exists?
    end
  end

  private

  def org_graph_events
    settings = [ OrgGraph::Events::FactProviderSet, OrgGraph::Events::LevelProviderSet ]
    Rails.configuration.event_store.read.of_type(OrgGraph::Events.constants.map { OrgGraph::Events.const_get(it) } - settings).to_a
  end

  def new_events
    org_graph_events.drop(@recorded)
  end

  def person_development_event_count
    Rails.configuration.event_store.read.to_a.count { it.class.name.start_with?("PersonDevelopment::") }
  end

  def stream_of(person)
    ActsAsTenant.with_tenant(@tenant) { EventStreamNaming.person_stream(person.id) }
  end

  # @return [Hash] the data of the person's PersonRecorded
  def recorded(person)
    Rails.configuration.event_store.read.stream(stream_of(person)).first.data
  end

  # @param count [Integer]
  # @return [Array<Hash>] active employees with no manager, cloned from bob-002
  def synthetic_employees(count)
    template = @fixture["employees"].find { it["id"] == "bob-002" }
    Array.new(count) { |i| template.deep_dup.merge("id" => "syn-#{i}", "email" => "syn#{i}@example.com") }
  end

  # @param external_id [String]
  # @yieldparam employee [Hash] a copy of that fixture employee, to change
  # @return [Array<Hash>] the fixture employees with the change applied
  def with_employee(external_id)
    @fixture["employees"].deep_dup.each { yield it if it["id"] == external_id }
  end

  # Builds an adapter with a stubbed client that returns the given employees.
  #
  # @param employees [Array<Hash>]
  # @return [Hris::Hibob::Adapter]
  def forget_row(external_id)
    person = create(:person, tenant: @tenant, hris_source: "hibob")
    person.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current, status: "inactive",
                          forgotten_external_id_digest: OrgGraph::Forgetting.digest(@tenant, "hibob", external_id))
    person
  end

  def build_adapter(employees)
    adapter = Hris::Hibob::Adapter.new(@tenant)
    mock_client = Minitest::Mock.new
    mock_client.expect(:search_people, employees, show_inactive: true)
    adapter.instance_variable_set(:@client, mock_client)
    adapter
  end

  # @param fields [Object] what the stubbed client's get_fields returns
  # @param named_lists [Object] what its get_named_lists returns
  # @return [Hris::Hibob::Adapter]
  def catalogue_adapter(fields: @fields, named_lists: @named_lists)
    adapter = Hris::Hibob::Adapter.new(@tenant)
    client = Minitest::Mock.new
    client.expect(:get_fields, fields)
    client.expect(:get_named_lists, named_lists)
    adapter.instance_variable_set(:@client, client)
    adapter
  end

  # @param name [String] a file under test/fixtures/files/hibob/
  # @return [Object] the parsed JSON
  def hibob_fixture(name)
    JSON.parse(File.read(Rails.root.join("test/fixtures/files/hibob", name)))
  end
end
