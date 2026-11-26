# frozen_string_literal: true

module DecidimCujae
  module SurveyExchange
    # Builds a signed `decidim.survey` document from a survey (spec 3.1, 3.7).
    # No numeric ids are exported: elements carry content UUIDs and keys
    # generated from their position (q<i>, q<i>_o<j>, q<i>_r<j>).
    class Exporter
      def initialize(survey, host: nil)
        @survey = survey
        @questionnaire = survey.questionnaire
        @host = host
      end

      def call
        ids = Identifiers.new(@questionnaire)
        @ids = ids
        @keys = {}
        ids.questions.each_with_index { |q, i| @keys[q.id] = "q#{i}" }

        data = {
          "format" => FORMAT,
          "version" => VERSION,
          "decidim_version" => Decidim.version,
          "exported_at" => Time.current.utc.iso8601,
          "mode" => "replace",
          "survey" => {
            "uuid" => ids.fingerprint,
            "settings" => settings,
            "questionnaire" => {
              "title" => translated(@questionnaire.title) || {},
              "description" => translated(@questionnaire.description),
              "tos" => translated(@questionnaire.tos) || {},
              "questions" => ids.questions.each_with_index.map { |q, i| question(q, i) }
            }.compact
          }
        }
        data["source"] = { "host" => @host } if @host.present?
        data["integrity"] = Signature.sign(data)
        data
      end

      def filename
        title = @questionnaire.title.is_a?(Hash) ? @questionnaire.title.values.find { |v| v.is_a?(String) && v.present? } : nil
        slug = title.to_s.parameterize.presence || "survey"
        "#{slug.first(60)}-#{Time.current.strftime("%Y%m%d-%H%M")}.survey.json"
      end

      private

      def settings
        data = {
          "starts_at" => @survey.starts_at&.iso8601,
          "ends_at" => @survey.ends_at&.iso8601,
          "allow_responses" => @survey.allow_responses ? true : false,
          "allow_unregistered" => @survey.allow_unregistered ? true : false,
          "allow_editing_responses" => @survey.allow_editing_responses ? true : false,
          "clean_after_publish" => @survey.clean_after_publish ? true : false
        }
        announcement = translated(@survey.announcement)
        data["announcement"] = announcement if announcement
        data
      end

      def question(question, index)
        key = "q#{index}"
        type = question.question_type
        data = {
          "key" => key,
          "uuid" => @ids.uuid_for(question),
          "question_type" => type,
          "mandatory" => question.mandatory ? true : false
        }
        unless type == "separator"
          data["body"] = translated(question.body) || {}
          description = translated(question.description)
          data["description"] = description if description
        end
        data["max_characters"] = question.max_characters || 0
        data["max_choices"] = question.max_choices if MAX_CHOICES_TYPES.include?(type) && question.max_choices.present?

        if CHOICE_TYPES.include?(type)
          data["response_options"] = @ids.response_options_of(question).each_with_index.map do |option, j|
            {
              "key" => "#{key}_o#{j}",
              "uuid" => @ids.uuid_for(option),
              "body" => translated(option.body) || {},
              "free_text" => option.free_text ? true : false
            }
          end
        end

        if MATRIX_TYPES.include?(type)
          data["matrix_rows"] = question.matrix_rows.each_with_index.map do |row, j|
            { "key" => "#{key}_r#{j}", "uuid" => @ids.uuid_for(row), "body" => translated(row.body) || {} }
          end
        end

        conditions = @ids.display_conditions_of(question)
        data["display_conditions"] = conditions.map { |c| condition(c) } if conditions.any?
        data
      end

      def condition(condition)
        data = {
          "uuid" => @ids.uuid_for(condition),
          "condition_question" => @keys[condition.decidim_condition_question_id],
          "condition_type" => condition.condition_type,
          "mandatory" => condition.mandatory ? true : false
        }
        if %w(equal not_equal).include?(condition.condition_type) && condition.response_option
          option_question = condition.response_option.decidim_question_id
          index = @ids.questions.find { |q| q.id == option_question }&.then { |q| @ids.response_options_of(q).index(condition.response_option) }
          data["response_option"] = "#{@keys[option_question]}_o#{index}" if index
        end
        data["condition_value"] = translated(condition.condition_value) || {} if condition.condition_type == "match"
        data
      end

      # Keeps locales with text and machine_translations (informative).
      def translated(value)
        return nil unless value.is_a?(Hash)

        clean = value.each_with_object({}) do |(locale, text), memo|
          if locale.to_s == "machine_translations"
            machine = text.is_a?(Hash) ? text.compact_blank.transform_keys(&:to_s) : {}
            memo["machine_translations"] = machine if machine.any?
          elsif text.is_a?(String) && text != ""
            memo[locale.to_s] = text
          end
        end
        clean.empty? ? nil : clean
      end
    end
  end
end
