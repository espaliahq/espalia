# frozen_string_literal: true

ForgottenPersonAudit.exempt "team_planning_units",
                            "returns unit and level ids and unit names, never a person; a planned name is free text, " \
                            "not shredded until #209"
