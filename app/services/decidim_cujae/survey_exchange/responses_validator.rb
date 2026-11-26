# frozen_string_literal: true

module DecidimCujae
  module SurveyExchange
    # Structural validation of a parsed `decidim.survey.responses` document
    # (spec 4.2 schema with additionalProperties: false, R12, P3, SEC4, SEC5,
    # SEC9, SEC12). Rules that depend on the target questionnaire (R1-R11,
    # P1, P2, P4, P5) are checked by ImportResponses.
    #
    # Any error rejects the whole file (spec 4.5 step 2).
    class ResponsesValidator
      TOP_KEYS = %w(format version exported_at target options submissions integrity).freeze
      OPTIONS_KEYS = %w(on_existing validation enforce_display_conditions publish_events).freeze
      SUBMISSION_KEYS = %w(uuid external_id respondent submitted_at locale ip answers).freeze
      SELECTION_KEYS = %w(option free_text).freeze
      FILE_KEYS = %w(filename content_type title base64).freeze
      ANSWER_KEYS = {
        "short_response" => %w(body),
        "long_response" => %w(body),
        "single_option" => %w(selection),
        "multiple_option" => %w(selections),
        "sorting" => %w(ranking),
        "matrix_single" => %w(rows),
        "matrix_multiple" => %w(rows),
        "files" => %w(files)
      }.freeze
      RESPONDENT_KEYS = {
        "existing" => %w(kind respondent_uuid),
        "anonymous" => %w(kind),
        "user" => %w(kind email nickname)
      }.freeze

      attr_reader :errors

      def initialize(data)
        @data = data
        @errors = []
      end

      def call
        validate_top
        raise Error.new(:invalid_file, errors) if errors.any?

        @data
      end

      private

      def validate_top
        return error("$", "must be a JSON object") unless @data.is_a?(Hash)

        allowed_keys!("$", @data, TOP_KEYS)
        error("format", "must be \"#{RESPONSES_FORMAT}\"") unless @data["format"] == RESPONSES_FORMAT
        error("version", "must be #{VERSION}") unless @data["version"] == VERSION
        string!("exported_at", @data["exported_at"]) if @data.has_key?("exported_at")

        if hash!("target", @data["target"])
          allowed_keys!("target", @data["target"], %w(survey_uuid))
          uuid!("target.survey_uuid", @data["target"]["survey_uuid"])
        end

        validate_options(@data["options"]) if @data.has_key?("options") && hash!("options", @data["options"])

        submissions = @data["submissions"]
        return error("submissions", "must be an array") unless submissions.is_a?(Array)
        return error("submissions", "has more than #{RESPONSE_LIMITS[:submissions]} elements") if submissions.size > RESPONSE_LIMITS[:submissions]

        external_ids = {}
        submissions.each_with_index do |submission, i|
          path = "submissions[#{i}]"
          next unless hash!(path, submission)

          validate_submission(path, submission)
          external_id = submission["external_id"]
          next unless external_id.is_a?(String)

          # P3: external_id unique in the file.
          error("#{path}.external_id", "is repeated (also in submissions[#{external_ids[external_id]}])") if external_ids.has_key?(external_id)
          external_ids[external_id] ||= i
        end
      end

      def validate_options(options)
        allowed_keys!("options", options, OPTIONS_KEYS)
        enum!("options.on_existing", options["on_existing"], %w(skip replace error)) if options.has_key?("on_existing")
        enum!("options.validation", options["validation"], %w(strict lenient)) if options.has_key?("validation")
        %w(enforce_display_conditions publish_events).each do |k|
          boolean!("options.#{k}", options[k]) if options.has_key?(k)
        end
      end

      def validate_submission(path, submission)
        allowed_keys!(path, submission, SUBMISSION_KEYS)
        uuid!("#{path}.uuid", submission["uuid"]) if submission.has_key?("uuid")
        if submission.has_key?("external_id")
          external_id = submission["external_id"]
          if !external_id.is_a?(String) || external_id.empty? || external_id.length > RESPONSE_LIMITS[:external_id_chars]
            error("#{path}.external_id", "must be a non-empty string of at most #{RESPONSE_LIMITS[:external_id_chars]} characters")
          end
        end
        error("#{path}.submitted_at", "must be an ISO 8601 date-time") if submission.has_key?("submitted_at") && parse_time(submission["submitted_at"]).nil?
        string!("#{path}.locale", submission["locale"]) if submission.has_key?("locale")
        if submission.has_key?("ip")
          begin
            IPAddr.new(submission["ip"].to_s) if string!("#{path}.ip", submission["ip"])
          rescue IPAddr::Error
            error("#{path}.ip", "must be an IPv4 or IPv6 address")
          end
        end

        validate_respondent("#{path}.respondent", submission["respondent"], submission)
        validate_answers("#{path}.answers", submission["answers"])
      end

      def validate_respondent(path, respondent, submission)
        return unless hash!(path, respondent)

        kind = respondent["kind"]
        return error("#{path}.kind", "must be \"existing\", \"anonymous\" or \"user\"") unless RESPONDENT_KEYS.has_key?(kind)

        allowed_keys!(path, respondent, RESPONDENT_KEYS[kind])
        case kind
        when "existing"
          uuid!("#{path}.respondent_uuid", respondent["respondent_uuid"])
        when "anonymous"
          # P3: the session token of an anonymous respondent comes from external_id.
          error(path.sub(/\.respondent\z/, ".external_id"), "is required for anonymous respondents") unless submission["external_id"].is_a?(String)
        when "user"
          error(path, "needs an email or a nickname") unless respondent["email"].is_a?(String) || respondent["nickname"].is_a?(String)
          %w(email nickname).each { |k| string!("#{path}.#{k}", respondent[k]) if respondent.has_key?(k) }
        end
      end

      def validate_answers(path, answers)
        return error(path, "must be an array") unless answers.is_a?(Array)
        return error(path, "has more than #{LIMITS[:questions]} elements") if answers.size > LIMITS[:questions]

        seen = {}
        answers.each_with_index do |answer, i|
          answer_path = "#{path}[#{i}]"
          next unless hash!(answer_path, answer)

          validate_answer(answer_path, answer)
          question = answer["question"]
          next unless question.is_a?(String)

          # R12: at most one answer per question.
          error("#{answer_path}.question", "is repeated (also in #{path}[#{seen[question]}])") if seen.has_key?(question)
          seen[question] ||= i
        end
      end

      def validate_answer(path, answer)
        type = answer["type"]
        uuid!("#{path}.question", answer["question"])
        return error("#{path}.type", "must be one of #{ANSWER_KEYS.keys.join(", ")} (separator and title_and_description are not sent)") unless ANSWER_KEYS.has_key?(type)

        allowed_keys!(path, answer, %w(question type) + ANSWER_KEYS[type])
        case type
        when "short_response", "long_response"
          text!("#{path}.body", answer["body"])
        when "single_option"
          selection!("#{path}.selection", answer["selection"])
        when "multiple_option"
          selections!("#{path}.selections", answer["selections"])
        when "sorting"
          ranking = answer["ranking"]
          if !ranking.is_a?(Array) || ranking.size > LIMITS[:options_per_question]
            error("#{path}.ranking", "must be an array of at most #{LIMITS[:options_per_question]} UUIDs")
          else
            ranking.each_with_index { |uuid, j| uuid!("#{path}.ranking[#{j}]", uuid) }
          end
        when "matrix_single", "matrix_multiple"
          rows!("#{path}.rows", answer["rows"], type)
        when "files"
          files!("#{path}.files", answer["files"])
        end
      end

      def rows!(path, rows, type)
        return error(path, "must be an array of at most #{LIMITS[:matrix_rows_per_question]} rows") if !rows.is_a?(Array) || rows.size > LIMITS[:matrix_rows_per_question]

        rows.each_with_index do |row, j|
          row_path = "#{path}[#{j}]"
          next unless hash!(row_path, row)

          if type == "matrix_single"
            allowed_keys!(row_path, row, %w(row selection))
            selection!("#{row_path}.selection", row["selection"])
          else
            allowed_keys!(row_path, row, %w(row selections))
            selections!("#{row_path}.selections", row["selections"])
          end
          uuid!("#{row_path}.row", row["row"])
        end
      end

      def selections!(path, selections)
        return error(path, "must be an array of at most #{LIMITS[:options_per_question]} selections") if !selections.is_a?(Array) || selections.size > LIMITS[:options_per_question]

        selections.each_with_index { |selection, j| selection!("#{path}[#{j}]", selection) }
      end

      def selection!(path, selection)
        return unless hash!(path, selection)

        allowed_keys!(path, selection, SELECTION_KEYS)
        uuid!("#{path}.option", selection["option"])
        text!("#{path}.free_text", selection["free_text"]) if selection.has_key?("free_text")
      end

      # SEC12: embedded base64 only, never URLs.
      def files!(path, files)
        return error(path, "must be an array of at most #{RESPONSE_LIMITS[:files_per_answer]} files") if !files.is_a?(Array) || files.size > RESPONSE_LIMITS[:files_per_answer]

        files.each_with_index do |file, j|
          file_path = "#{path}[#{j}]"
          next unless hash!(file_path, file)

          allowed_keys!(file_path, file, FILE_KEYS)
          %w(filename content_type base64).each do |k|
            error("#{file_path}.#{k}", "must be a non-empty string") unless file[k].is_a?(String) && file[k].present?
          end
          text!("#{file_path}.title", file["title"]) if file.has_key?("title")
          error("#{file_path}.filename", "must not contain a path") if file["filename"].is_a?(String) && file["filename"].match?(%r{[/\\]})
        end
      end

      def text!(path, value)
        return error(path, "must be a string") unless value.is_a?(String)

        error(path, "is longer than #{RESPONSE_LIMITS[:answer_chars]} characters") if value.length > RESPONSE_LIMITS[:answer_chars]
      end

      def enum!(path, value, allowed)
        error(path, "must be one of #{allowed.map { |v| "\"#{v}\"" }.join(", ")}") unless allowed.include?(value)
      end

      def allowed_keys!(path, hash, allowed)
        (hash.keys - allowed).each do |key|
          error(path == "$" ? key : "#{path}.#{key}", "is not allowed here (unknown field; numeric ids, session tokens and ip hashes are never accepted)")
        end
      end

      def uuid!(path, value)
        error(path, "must be a UUID taken from an export") unless value.is_a?(String) && UUID_PATTERN.match?(value)
      end

      def hash!(path, value)
        return true if value.is_a?(Hash)

        error(path, "must be an object")
        false
      end

      def string!(path, value)
        return true if value.is_a?(String)

        error(path, "must be a string")
        false
      end

      def boolean!(path, value)
        error(path, "must be true or false") unless [true, false].include?(value)
      end

      def parse_time(value)
        return nil unless value.is_a?(String)

        Time.zone.iso8601(value)
      rescue ArgumentError
        nil
      end

      def error(path, message)
        errors << "#{path}: #{message}"
        nil
      end
    end
  end
end
