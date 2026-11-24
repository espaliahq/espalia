# frozen_string_literal: true

# Names who last changed a tenant setting, such as a pay band or a rule default.
module Operations::Tenants::EditorNames
  private

  # Each editor's name in this tenant. Anyone forgotten, or gone, reads as a
  # former member.
  #
  # @param records [Array<#updated_by_person_id, #updated_by_id>]
  # @return [Hash{String => String}] by person id
  def editor_names(records)
    ids = records.filter_map { editor_id(it) }.uniq
    people = Person.remembered.where(id: ids).pluck(:id, :name).to_h
    ids.to_h { [ it, people.fetch(it, Person::FORMER_MEMBER) ] }
  end

  # A row the previous release changed during a deploy names its account
  # until reconcile records it, so its person stands in until then. An
  # account with no person left keeps its own id, which reads as a former
  # member.
  #
  # @return [String, nil] the editor's person id
  def editor_id(record)
    return record.updated_by_person_id unless record.updated_by_id

    TenantUser.where(tenant_id: record.tenant_id, user_id: record.updated_by_id).pick(:person_id) || record.updated_by_id
  end
end
