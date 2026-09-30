# frozen_string_literal: true

# "Keep exploring this" / "Share with Alex" — declaring the lens role and
# level as an exploration (ADR-22). Looking through a lens tells nobody;
# declaring is the act the other party sees, so the dialog says who is told
# and what is (and isn't) shared. Mounted with the page's other embedded
# modals.
class Views::Assessments::StartExplorationModal < Views::Base
  include Views::Assessments::ExplorationModalForm

  ID = "start-exploration-modal"

  # @param lens [Assessments::Lens] the role and level to explore
  # @param assessment_id [String]
  # @param assessee_name [String, nil] nil when the assessee declares it
  def initialize(lens:, assessment_id:, assessee_name: nil)
    @lens = lens
    @assessment_id = assessment_id
    @first_name = assessee_name.to_s.split.first.presence
  end

  def view_template
    render Components::Kit::Modal.new(id: ID, title: title, standalone: false) do |modal|
      modal.body do
        exploration_form(action: assessment_explorations_path(@assessment_id), submit: submit_label,
                         submitting: "Saving…") { bullets(*points) }
      end
    end
  end

  private

  def title
    @first_name ? "Share #{@lens.label} with #{@first_name}?" : "Keep exploring #{@lens.label}?"
  end

  def submit_label
    @first_name ? "Share with #{@first_name}" : "Keep exploring"
  end

  def points
    if @first_name
      [ "#{@first_name} is told, and sees #{@lens.code} on their assessments list.",
        "None of your ratings are shared — those stay private until you start alignment against #{@lens.code}.",
        "Either of you can stop exploring whenever you like." ]
    else
      [ "Your manager is told, and sees #{@lens.code} on their team list.",
        "Your #{@lens.home_code} assessment doesn't change.",
        "Either of you can stop exploring whenever you like." ]
    end
  end
end
