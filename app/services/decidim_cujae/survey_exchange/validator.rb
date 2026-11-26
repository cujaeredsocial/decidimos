# frozen_string_literal: true

module DecidimCujae
  module SurveyExchange
    # Structural validation of a parsed `decidim.survey` document
    # (spec 3.1 schema with additionalProperties: false, S2, S5-S7, S12, S14,
    # SEC4, SEC9, SEC10). Content rules that depend on the organization or on
    # the database (S1, S3, S8-S11) are checked by the importer with
    # Decidim's own admin forms.
    #
    # Returns a normalized copy: Translated values without
    # machine_translations nor locales unknown to the organization.
    class Validator
      TOP_KEYS = %w(format version decidim_version exported_at source mode survey integrity).freeze
      SURVEY_KEYS = %w(uuid settings questionnaire).freeze
      SETTINGS_KEYS = %w(starts_at ends_at allow_responses allow_unregistered allow_editing_responses clean_after_publish announcement).freeze
      QUESTIONNAIRE_KEYS = %w(title description tos questions).freeze
      QUESTION_BASE_KEYS = %w(key uuid deleted question_type mandatory max_characters display_conditions).freeze
      OPTION_KEYS = %w(key uuid deleted body free_text).freeze
      ROW_KEYS = %w(key uuid deleted body).freeze
      CONDITION_KEYS = %w(uuid deleted condition_question condition_type mandatory response_option condition_value).freeze
      CONDITION_TYPES = %w(responded not_responded equal not_equal match).freeze

      # Maps the locales of a Translated value onto the organization's
      # locales. A file locale that the organization does not have is applied
      # by its language (the part before "-"): "es" fills "es-MX", "es-AR"
      # fills "es" (or "es-MX" when there is no plain "es"). A value given for
      # the exact locale always wins over a mapped one.
      #
      # Returns { result: { org_locale => text }, used: [file locales applied] }.
      def self.map_locales(texts, locales)
        result = {}
        used = []
        # 1. Exact (case-insensitive) matches.
        texts.each do |locale, text|
          target = locales.find { |l| l.casecmp?(locale) }
          next unless target

          result[target] = text
          used << locale
        end
        # 2. Same language, only for locales not set in step 1.
        texts.each do |locale, text| # rubocop:disable Style/CombinableLoops
          next if used.include?(locale)

          base = locale.split("-").first.downcase
          same_language = locales.select { |l| l.split("-").first.casecmp?(base) }
          plain = same_language.find { |l| l.casecmp?(base) }
          targets = (plain ? [plain] : same_language).reject { |l| result.has_key?(l) }
          next if targets.empty?

          targets.each { |l| result[l] = text }
          used << locale
          yield locale, targets if block_given?
        end
        { result:, used: }
      end

      attr_reader :errors, :warnings

      def initialize(data, locales:)
        @data = data
        @locales = locales.map(&:to_s)
        @errors = []
        @warnings = []
        @mapped_locales = {}
      end

      def call
        normalized = validate_top(@data)
        raise Error.new(:invalid_file, errors) if errors.any?

        @mapped_locales.each { |from, to| warnings << "locale \"#{from}\" applied as #{to.join(", ")}" }

        normalized
      end

      def merge_mode?
        @data.is_a?(Hash) && @data["mode"] == "merge"
      end

      private

      def validate_top(data)
        return error("$", "must be a JSON object") && nil unless data.is_a?(Hash)

        allowed_keys!("$", data, TOP_KEYS)
        error("format", "must be \"#{FORMAT}\"") unless data["format"] == FORMAT
        error("version", "must be #{VERSION}") unless data["version"] == VERSION
        %w(decidim_version exported_at).each { |k| string!(k, data[k]) if data.has_key?(k) }
        if data.has_key?("source") && hash!("source", data["source"])
          allowed_keys!("source", data["source"], %w(host))
          string!("source.host", data["source"]["host"]) if data["source"].has_key?("host")
        end
        error("mode", "must be \"replace\" or \"merge\"") if data.has_key?("mode") && %w(replace merge).exclude?(data["mode"])
        # integrity is checked by Signature.verify!

        return data.merge("survey" => nil) unless hash!("survey", data["survey"])

        data.merge("survey" => validate_survey(data["survey"]))
      end

      def validate_survey(survey)
        allowed_keys!("survey", survey, SURVEY_KEYS)
        uuid!("survey.uuid", survey["uuid"]) if survey.has_key?("uuid")
        out = survey.slice("uuid")
        out["settings"] = validate_settings(survey["settings"]) if survey.has_key?("settings") && hash!("survey.settings", survey["settings"])
        out["questionnaire"] = validate_questionnaire(survey["questionnaire"]) if hash!("survey.questionnaire", survey["questionnaire"])
        out
      end

      def validate_settings(settings)
        path = "survey.settings"
        allowed_keys!(path, settings, SETTINGS_KEYS)
        out = {}
        %w(starts_at ends_at).each do |k|
          next unless settings.has_key?(k)

          value = settings[k]
          if value.nil?
            out[k] = nil
          elsif value.is_a?(String) && (time = parse_time(value))
            out[k] = time
          else
            error("#{path}.#{k}", "must be an ISO 8601 date-time or null")
          end
        end
        %w(allow_responses allow_unregistered allow_editing_responses clean_after_publish).each do |k|
          next unless settings.has_key?(k)

          boolean!("#{path}.#{k}", settings[k])
          out[k] = settings[k]
        end
        out["announcement"] = translated("#{path}.announcement", settings["announcement"], html: true) if settings.has_key?("announcement")
        out
      end

      def validate_questionnaire(questionnaire)
        path = "survey.questionnaire"
        allowed_keys!(path, questionnaire, QUESTIONNAIRE_KEYS)
        out = {
          "title" => translated("#{path}.title", questionnaire["title"], required: true),
          "description" => questionnaire.has_key?("description") ? translated("#{path}.description", questionnaire["description"], html: true) : nil,
          "tos" => translated("#{path}.tos", questionnaire["tos"], required: true, html: true)
        }
        questions = questionnaire["questions"]
        unless questions.is_a?(Array)
          error("#{path}.questions", "must be an array")
          return out.merge("questions" => [])
        end
        error("#{path}.questions", "has more than #{LIMITS[:questions]} items") if questions.size > LIMITS[:questions]

        keys = {}
        out["questions"] = questions.each_with_index.map do |question, i|
          qpath = "#{path}.questions[#{i}]"
          next error(qpath, "must be an object") && nil unless question.is_a?(Hash)

          validated = validate_question(qpath, question)
          if (key = validated["key"])
            error("#{qpath}.key", "duplicated key \"#{key}\"") if keys.has_key?(key)
            keys[key] = true
          end
          validated
        end.compact
        out
      end

      def validate_question(path, question)
        type = question["question_type"]
        unless Decidim::Forms::Question::TYPES.include?(type)
          error("#{path}.question_type", "must be one of #{Decidim::Forms::Question::TYPES.join(", ")}")
          return {}
        end

        allowed = QUESTION_BASE_KEYS.dup
        allowed += %w(body description) unless type == "separator"
        allowed << "response_options" if CHOICE_TYPES.include?(type)
        allowed << "max_choices" if MAX_CHOICES_TYPES.include?(type)
        allowed << "matrix_rows" if MATRIX_TYPES.include?(type)
        allowed_keys!(path, question, allowed)

        out = common_element(path, question)
        out["question_type"] = type
        out["mandatory"] = question.has_key?("mandatory") ? boolean!("#{path}.mandatory", question["mandatory"]) : false
        if question.has_key?("max_characters")
          value = question["max_characters"]
          error("#{path}.max_characters", "must be an integer >= 0") unless value.is_a?(Integer) && value >= 0
          out["max_characters"] = value
        else
          out["max_characters"] = 0
        end

        unless type == "separator"
          out["body"] = translated("#{path}.body", question["body"], required: !out["deleted"])
          out["description"] = translated("#{path}.description", question["description"]) if question.has_key?("description")
        end

        if CHOICE_TYPES.include?(type)
          out["response_options"] = children(path, question, "response_options", OPTION_KEYS, LIMITS[:options_per_question]) do |cpath, child, cout|
            cout["body"] = translated("#{cpath}.body", child["body"], required: !cout["deleted"])
            cout["free_text"] = child.has_key?("free_text") ? boolean!("#{cpath}.free_text", child["free_text"]) : false
          end
          live_options = out["response_options"].count { |o| !o["deleted"] }
          error("#{path}.response_options", "must have at least one item") if live_options.zero? && !out["deleted"]
        end

        if MATRIX_TYPES.include?(type)
          out["matrix_rows"] = children(path, question, "matrix_rows", ROW_KEYS, LIMITS[:matrix_rows_per_question]) do |cpath, child, cout|
            cout["body"] = translated("#{cpath}.body", child["body"], required: !cout["deleted"])
          end
          error("#{path}.matrix_rows", "must have at least one item") if out["matrix_rows"].none? { |r| !r["deleted"] } && !out["deleted"]
        end

        if MAX_CHOICES_TYPES.include?(type) && !question["max_choices"].nil?
          value = question["max_choices"]
          options = out["response_options"].count { |o| !o["deleted"] }
          error("#{path}.max_choices", "must be an integer > 1 and <= #{options} (number of response options)") unless value.is_a?(Integer) && value > 1 && value <= options
          out["max_choices"] = value
        end

        out["display_conditions"] = validate_conditions(path, question["display_conditions"]) if question.has_key?("display_conditions")
        out["display_conditions"] ||= []
        out
      end

      def children(path, question, name, keys, limit)
        list = question[name]
        unless list.is_a?(Array)
          error("#{path}.#{name}", "must be an array")
          return []
        end
        error("#{path}.#{name}", "has more than #{limit} items") if list.size > limit

        seen = {}
        list.each_with_index.map do |child, j|
          cpath = "#{path}.#{name}[#{j}]"
          next error(cpath, "must be an object") && nil unless child.is_a?(Hash)

          allowed_keys!(cpath, child, keys)
          cout = common_element(cpath, child)
          if (key = cout["key"])
            error("#{cpath}.key", "duplicated key \"#{key}\" in this question") if seen.has_key?(key)
            seen[key] = true
          end
          yield cpath, child, cout
          cout
        end.compact
      end

      def validate_conditions(path, list)
        unless list.is_a?(Array)
          error("#{path}.display_conditions", "must be an array")
          return []
        end
        error("#{path}.display_conditions", "has more than #{LIMITS[:conditions_per_question]} items") if list.size > LIMITS[:conditions_per_question]

        list.each_with_index.map do |condition, j|
          cpath = "#{path}.display_conditions[#{j}]"
          next error(cpath, "must be an object") && nil unless condition.is_a?(Hash)

          allowed_keys!(cpath, condition, CONDITION_KEYS)
          out = {}
          uuid!("#{cpath}.uuid", condition["uuid"]) if condition.has_key?("uuid")
          out["uuid"] = condition["uuid"]
          out["deleted"] = deleted!(cpath, condition)
          type = condition["condition_type"]
          error("#{cpath}.condition_type", "must be one of #{CONDITION_TYPES.join(", ")}") unless CONDITION_TYPES.include?(type)
          out["condition_type"] = type
          out["condition_question"] = ref!("#{cpath}.condition_question", condition["condition_question"])
          out["mandatory"] = condition.has_key?("mandatory") ? boolean!("#{cpath}.mandatory", condition["mandatory"]) : false

          if %w(equal not_equal).include?(type)
            out["response_option"] = ref!("#{cpath}.response_option", condition["response_option"])
          elsif condition.has_key?("response_option")
            error("#{cpath}.response_option", "is only allowed with condition_type equal / not_equal")
          end

          if type == "match"
            out["condition_value"] = translated("#{cpath}.condition_value", condition["condition_value"], required: !out["deleted"], regex: true)
          elsif condition.has_key?("condition_value")
            error("#{cpath}.condition_value", "is only allowed with condition_type match")
          end
          out
        end.compact
      end

      def common_element(path, element)
        out = {}
        key = element["key"]
        if key.is_a?(String) && KEY_PATTERN.match?(key)
          out["key"] = key
        else
          error("#{path}.key", "is required and must match /^[a-z0-9_]{1,64}$/")
        end
        if element.has_key?("uuid")
          uuid!("#{path}.uuid", element["uuid"])
          out["uuid"] = element["uuid"]
        end
        out["deleted"] = deleted!(path, element)
        out
      end

      def deleted!(path, element)
        return false unless element.has_key?("deleted")

        value = boolean!("#{path}.deleted", element["deleted"])
        if value
          error("#{path}.deleted", "is only allowed with mode \"merge\"") unless merge_mode?
          error("#{path}.uuid", "is required to delete an element") unless element["uuid"]
        end
        value
      end

      def ref!(path, value)
        if value.is_a?(String) && (KEY_PATTERN.match?(value) || UUID_PATTERN.match?(value))
          value
        else
          error(path, "must be a key (/^[a-z0-9_]{1,64}$/) or a UUID")
          nil
        end
      end

      # Translated / TranslatedHtml. Unknown locales are dropped with a warning.
      def translated(path, value, required: false, html: false, regex: false)
        if value.nil?
          error(path, "is required") if required
          return nil
        end
        return error(path, "must be an object { locale: text }") && nil unless value.is_a?(Hash)

        limit = html ? LIMITS[:html_chars] : LIMITS[:text_chars]
        texts = value.each_with_object({}) do |(locale, text), memo|
          if locale == "machine_translations"
            hash!("#{path}.machine_translations", text)
            next
          end
          unless text.is_a?(String)
            error("#{path}.#{locale}", "must be a string")
            next
          end
          error("#{path}.#{locale}", "is longer than #{limit} characters") if text.length > limit
          regex!("#{path}.#{locale}", text) if regex && text != ""
          memo[locale] = text
        end

        mapped = self.class.map_locales(texts, @locales) do |from, to|
          @mapped_locales[from] = (@mapped_locales[from] || []) | to
        end
        (texts.keys - mapped[:used]).each do |locale|
          base = locale.split("-").first
          warnings << if @locales.any? { |l| l.split("-").first.casecmp?(base) }
                        "#{path}.#{locale}: ignored, the file already gives the exact locale"
                      else
                        "#{path}.#{locale}: locale not available in this organization, ignored"
                      end
        end
        mapped[:result]
      end

      # SEC10: bounded length and must compile.
      def regex!(path, text)
        if text.length > LIMITS[:regex_chars]
          error(path, "regular expression longer than #{LIMITS[:regex_chars]} characters")
        else
          Regexp.new(text, Regexp::IGNORECASE)
        end
      rescue RegexpError => e
        error(path, "invalid regular expression (#{e.message})")
      end

      def allowed_keys!(path, hash, allowed)
        (hash.keys - allowed).each do |key|
          error(path == "$" ? key : "#{path}.#{key}", "is not allowed here (unknown field; numeric ids are never accepted)")
        end
      end

      def uuid!(path, value)
        error(path, "must be a UUID generated by an export") unless value.is_a?(String) && UUID_PATTERN.match?(value)
      end

      def hash!(path, value)
        return true if value.is_a?(Hash)

        error(path, "must be an object")
        false
      end

      def string!(path, value)
        error(path, "must be a string") unless value.is_a?(String)
      end

      def boolean!(path, value)
        error(path, "must be true or false") unless [true, false].include?(value)
        value == true
      end

      def parse_time(value)
        Time.zone.iso8601(value)
      rescue ArgumentError
        nil
      end

      def error(path, message)
        errors << "#{path}: #{message}"
        true
      end
    end
  end
end
