# frozen_string_literal: true

require "openssl"

module DecidimCujae
  module SurveyExchange
    # Content-derived UUIDs (spec 5.3). Nothing is stored: every UUID is
    # recomputed from the current database state with a per-questionnaire
    # HMAC key derived from secret_key_base.
    class Identifiers
      KEY_SALT = "decidim-survey-exchange/uuid/v1"
      SCOPE_PREFIX = "decidim-survey-exchange/v1|"

      class << self
        # K_app (32 bytes), derived from secret_key_base.
        def app_key
          Rails.application.key_generator.generate_key(KEY_SALT, 32)
        end

        # K_q = HMAC-SHA256(K_app, "decidim-survey-exchange/v1|" + scope)
        def questionnaire_key(questionnaire, app_key: self.app_key)
          scope = questionnaire.salt.present? ? "salt:#{questionnaire.salt}" : "id:#{questionnaire.id}"
          OpenSSL::HMAC.digest("SHA256", app_key, SCOPE_PREFIX + scope)
        end

        # UUID v8 from HMAC-SHA256(K_q, JCS(projection)).
        def content_uuid(key, projection)
          canonical = Canonical.jcs(Canonical.json_roundtrip(projection))
          bytes = OpenSSL::HMAC.digest("SHA256", key, canonical.encode("UTF-8")).byteslice(0, 16).bytes
          bytes[6] = (bytes[6] & 0x0f) | 0x80
          bytes[8] = (bytes[8] & 0x3f) | 0x80
          hex = bytes.pack("C*").unpack1("H*")
          "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
        end

        def question_projection(position:, question_type:, mandatory:, body:, description:, max_choices:, max_characters:)
          {
            kind: "question",
            position:,
            question_type: question_type.to_s,
            mandatory: mandatory ? true : false,
            body: Canonical.translated(body),
            description: Canonical.translated(description),
            max_choices: max_choices.presence,
            max_characters: max_characters || 0
          }
        end

        def response_option_projection(question_position:, index:, body:, free_text:)
          {
            kind: "response_option",
            question_position:,
            index:,
            body: Canonical.translated(body),
            free_text: free_text ? true : false
          }
        end

        def matrix_row_projection(question_position:, position:, body:)
          { kind: "matrix_row", question_position:, position:, body: Canonical.translated(body) }
        end

        def display_condition_projection(question_position:, condition_question_position:, condition_type:,
                                         response_option_index:, condition_value:, mandatory:)
          {
            kind: "display_condition",
            question_position:,
            condition_question_position:,
            condition_type: condition_type.to_s,
            response_option_index:,
            condition_value: Canonical.translated(condition_value),
            mandatory: mandatory ? true : false
          }
        end
      end

      attr_reader :questionnaire, :key, :questions

      def initialize(questionnaire)
        @questionnaire = questionnaire
        @key = self.class.questionnaire_key(questionnaire)
        @questions = questionnaire.questions
                                  .includes(:response_options, :matrix_rows, display_conditions: :response_option)
                                  .to_a
        # Do not preload display_conditions.condition_question: Decidim's
        # Question#display_conditions_for_other_questions declares
        # `inverse_of: :question`, so that preload overwrites the in-memory
        # decidim_question_id of each condition with the condition question.
        @questions_by_id = @questions.index_by(&:id)
        compute!
      end

      def uuid_for(record)
        @uuids[[record.class.name, record.id]]
      end

      # Current record of `klass` with this UUID, or nil.
      def find(klass, uuid)
        @index[[klass.name, uuid]]
      end

      def response_options_of(question)
        @options_by_question[question.id]
      end

      def display_conditions_of(question)
        @conditions_by_question[question.id]
      end

      # Survey fingerprint (survey.uuid / target.survey_uuid).
      def fingerprint
        @fingerprint ||= self.class.content_uuid(key, {
                                                   kind: "survey",
                                                   questions: questions.map do |q|
                                                     {
                                                       uuid: uuid_for(q),
                                                       options: response_options_of(q).map { |o| uuid_for(o) },
                                                       matrix_rows: q.matrix_rows.map { |r| uuid_for(r) },
                                                       display_conditions: display_conditions_of(q).map { |c| uuid_for(c) }
                                                     }
                                                   end
                                                 })
      end

      private

      def compute!
        @uuids = {}
        @index = {}
        @options_by_question = {}
        @conditions_by_question = {}

        questions.each do |question|
          store(question, self.class.question_projection(
                            position: question.position,
                            question_type: question.question_type,
                            mandatory: question.mandatory,
                            body: question.body,
                            description: question.description,
                            max_choices: question.max_choices,
                            max_characters: question.max_characters
                          ))

          # ResponseOption has no position: default_scope orders by id.
          options = question.response_options.sort_by(&:id)
          @options_by_question[question.id] = options
          options.each_with_index do |option, index|
            store(option, self.class.response_option_projection(
                            question_position: question.position, index:, body: option.body, free_text: option.free_text
                          ))
          end

          question.matrix_rows.each do |row|
            store(row, self.class.matrix_row_projection(question_position: question.position, position: row.position, body: row.body))
          end

          conditions = question.display_conditions.sort_by(&:id)
          @conditions_by_question[question.id] = conditions
          conditions.each do |condition|
            store(condition, condition_projection(question, condition))
          end
        end
      end

      def condition_projection(question, condition)
        option_index = if condition.response_option
                         (@options_by_question[condition.response_option.decidim_question_id] ||
                           condition.response_option.question.response_options.sort_by(&:id)).index { |o| o.id == condition.response_option.id }
                       end
        self.class.display_condition_projection(
          question_position: question.position,
          condition_question_position: @questions_by_id[condition.decidim_condition_question_id]&.position,
          condition_type: condition.condition_type,
          response_option_index: option_index,
          condition_value: condition.condition_value,
          mandatory: condition.mandatory
        )
      end

      def store(record, projection)
        uuid = self.class.content_uuid(key, projection)
        @uuids[[record.class.name, record.id]] = uuid
        @index[[record.class.name, uuid]] = record
      end
    end
  end
end
