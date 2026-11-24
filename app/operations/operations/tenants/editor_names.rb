# frozen_string_literal: true

# Names who last changed a tenant setting, such as a pay band or a rule default.
module Operations::Tenants::EditorNames
  private

  # Each editor's name in this tenant. Anyone forgotten, or gone, reads as a
  # former member. A row the previous release changed during a deploy names
  # its account until reconcile records it, so that account's person stands
  # in until then.
  #
  # @param records [Array<#updated_by_person_id, #updated_by_id>]
  # @return [Hash{String => String}] by {#editor_id}
  def editor_names(records)
    people_of = account_people(records)
    ids = records.filter_map { editor_id(it) }.uniq
    people = Person.remembered.where(id: ids.map { people_of.fetch(it, it) }).pluck(:id, :name).to_h
    ids.to_h { [ it, people.fetch(people_of.fetch(it, it), Person::FORMER_MEMBER) ] }
  end

  # An account with no person left, or no membership, keeps its own id,
  # which reads as a former member.
  #
  # @return [Hash{String => String, nil}] each account's person, by account id
  def account_people(records)
    accounts = records.filter_map(&:updated_by_id).uniq
    return {} if accounts.empty?

    TenantUser.where(tenant_id: records.map(&:tenant_id).uniq, user_id: accounts).pluck(:user_id, :person_id).to_h
  end

  # The key {#editor_names} names this row's editor by.
  #
  # @return [String, nil]
  def editor_id(record) = record.updated_by_id || record.updated_by_person_id
end
