# frozen_string_literal: true

module DecidimCujae
  module SurveyExchange
    # Decidim's own command for responding a questionnaire, used by
    # ImportResponses (spec 4.6, option A). The only change: the
    # "decidim.forms.response_questionnaire" notifications (and with them the
    # confirmation email of decidim-surveys) are published only when the
    # import asks for it (`options.publish_events`).
    class SaveSubmission < Decidim::Forms::ResponseQuestionnaire
      def initialize(form, questionnaire, publish_events: false)
        super(form, questionnaire)
        @publish_events = publish_events
      end

      def with_events(**, &)
        return super if @publish_events

        yield
      end
    end
  end
end
