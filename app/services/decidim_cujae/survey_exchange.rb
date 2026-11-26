# frozen_string_literal: true

module DecidimCujae
  # Import/export of survey definitions (`decidim.survey`) and import of
  # responses (`decidim.survey.responses`) in JSON.
  # Specification: docs/survey-exchange-formats.md (sections 3, 4 and 5).
  module SurveyExchange
    FORMAT = "decidim.survey"
    VERSION = 1

    KEY_PATTERN = /\A[a-z0-9_]{1,64}\z/
    UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

    CHOICE_TYPES = %w(single_option multiple_option sorting matrix_single matrix_multiple).freeze
    MATRIX_TYPES = %w(matrix_single matrix_multiple).freeze
    MAX_CHOICES_TYPES = %w(multiple_option matrix_multiple).freeze
    # Questions that cannot be the condition_question of a display condition
    # (DisplayConditionForm#questions_for_select disables sorting and skips separators).
    NON_CONDITIONABLE_TYPES = %w(sorting separator title_and_description).freeze

    # SEC9 / D8 limits.
    LIMITS = {
      file_bytes: 2 * 1024 * 1024,
      questions: 300,
      options_per_question: 200,
      matrix_rows_per_question: 200,
      conditions_per_question: 50,
      text_chars: 5_000,
      html_chars: 100_000,
      regex_chars: 500
    }.freeze

    # `decidim.survey.responses` (spec section 4).
    RESPONSES_FORMAT = "decidim.survey.responses"
    RESPONSE_LIMITS = {
      file_bytes: 20 * 1024 * 1024, # files are embedded as base64 (SEC12)
      submissions: 5_000,
      answer_chars: 50_000,
      external_id_chars: 200,
      files_per_answer: 10
    }.freeze

    # A failure that aborts the whole import. `code` is one of the codes of
    # the specification (stale_reference, invalid_file, ...).
    class Error < StandardError
      attr_reader :code, :details

      def initialize(code, details = [])
        @code = code
        @details = Array(details)
        super("#{code}: #{@details.join("; ")}")
      end
    end
  end
end
