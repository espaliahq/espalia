# frozen_string_literal: true

# {Hris::BaseAdapter#read_field}'s values, each beside the row the next sync
# writes it to, found by HRIS id. A provider whose sync adopts rows by email
# overrides it, so a value lands on the row it adopts. Read inside the tenant.
module Hris::FieldRows
  # @return [Array<(String, Hris::FieldValue)>] the row's id, or nil for a
  #   person the sync has yet to create, beside their value
  def read_field_rows(field_id, kind:, alongside: nil)
    by_external_id = read_field(field_id, kind:, alongside:)
    rows = Person.where(external_id: by_external_id.keys).pluck(:external_id, :id).to_h
    by_external_id.map { |external_id, value| [ rows[external_id], value ] }
  end
end
