# frozen_string_literal: true

# Names who last changed a tenant setting, such as a pay band or a rule default.
module Operations::Tenants::EditorNames
  private

  # Each editor's name in this tenant. Anyone forgotten, or gone, reads as a
  # former member.
  #
  # @param records [Array<#updated_by_person_id>]
  # @return [Hash{String => String}] by {#editor_id}
  def editor_names(records)
    ids = records.filter_map { editor_id(it) }.uniq
    people = Person.remembered.where(id: ids).pluck(:id, :name).to_h
    ids.index_with { people.fetch(it, Person::FORMER_MEMBER) }
  end

  # The key {#editor_names} names this row's editor by.
  #
  # @return [String, nil]
  def editor_id(record) = record.updated_by_person_id
end
