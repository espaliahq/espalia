# frozen_string_literal: true

# The one spelling of "name this person id" for calibration views — every
# surface reads the same preloaded `@people` map, and a missing row (a
# deleted person, a reference from another tenant's log) says "Unknown"
# instead of raising.
module Views::CalibrationSessions::PeopleNames
  def person_name(person_id)
    @people[person_id]&.name || "Unknown"
  end
end
