# frozen_string_literal: true

# A tenant whose HRIS titles have drifted from its role mappings — the shape
# behind #436: one person on a renamed title still holds the assignment an
# earlier title gave them, another holds a title nobody has mapped.
module HrisMappingFixtures
  private

  def build_hris_mapping_tenant
    @tenant = create(:tenant, :with_hibob_config)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tenant_user = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tenant_user = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework = create(:framework_state, tenant: @tenant)
      @e_role = create(:framework_role, tenant: @tenant, code: "E", name: "Software Engineer")
      @em_role = create(:framework_role, tenant: @tenant, code: "EM", name: "Engineering Manager", track: "management")
      @ae_role = create(:framework_role, tenant: @tenant, code: "AE", name: "Analytics Engineer")
      @e3 = create(:framework_level, tenant: @tenant, role_id: @e_role.role_id, ordinal: 3, code: "E3", title: "Senior SWE")
      @em3 = create(:framework_level, tenant: @tenant, role_id: @em_role.role_id, ordinal: 3, code: "EM3", title: "EM")
      create(:framework_level, tenant: @tenant, role_id: @em_role.role_id, ordinal: 4, code: "EM4", title: "Senior EM")
      @ae2 = create(:framework_level, tenant: @tenant, role_id: @ae_role.role_id, ordinal: 2, code: "AE2", title: "AE")
      create(:framework_level, tenant: @tenant, role_id: @ae_role.role_id, ordinal: 3, code: "AE3", title: "Senior AE")

      @renamed = hris_person("Vera Renamed", "Engineering Manager (EM3)", assigned_to: [ @e_role, @e3 ])
      @unmapped = hris_person("Kit Unmapped", "Analytics Lead", assigned_to: [ @ae_role, @ae2 ])
      @settled = hris_person("Sam Settled", "Software Engineer", assigned_to: [ @e_role, @e3 ])
    end
  end

  def hris_person(name, title, assigned_to:)
    person = create(:person, tenant: @tenant, name: name, email: "#{name.parameterize}@example.com",
                    job_title: title, hris_source: "hibob", status: "active", hris_level_ordinal: 3)
    role, level = assigned_to
    create(:person_framework_assignment, tenant: @tenant, person_id: person.id,
           framework_id: @framework.framework_id, role_id: role.role_id, level_id: level.level_id)
    person
  end

  def hris_context(tenant_user)
    AuthorizationContext.new(user: tenant_user.user, tenant_user: tenant_user, person: nil)
  end
end
