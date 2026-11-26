# frozen_string_literal: true

require "base64"

module DecidimCujae
  module SurveyExchange
    # Imports a `decidim.survey.responses` document into an existing survey
    # (spec 4.1-4.6). The target survey comes from the request, never from
    # the file (SEC2); `target.survey_uuid` is only compared with its current
    # fingerprint, and every reference is resolved against the UUIDs computed
    # for that questionnaire only (SEC3).
    #
    # Each submission is saved in its own transaction with Decidim's
    # ResponseQuestionnaire command (through SaveSubmission), so validations
    # (mandatory, max_choices, max_characters, matrix rows, sorting, files)
    # and attachment handling are the same as in the public form.
    #
    # Broadcasts :ok with a Report, or :invalid with an Error when the whole
    # file is rejected (format, schema, signature, stale target).
    class ImportResponses < Decidim::Command
      Report = Struct.new(:imported, :skipped, :errors, :assigned, :warnings, :discarded, :signature, keyword_init: true) do
        def to_h
          super.except(:warnings, :discarded, :signature)
        end
      end

      # One answer of a submission, resolved against the questionnaire.
      Resolved = Struct.new(:question, :body, :choices, :files, keyword_init: true) do
        def answered?
          body.present? || choices.present? || files.present?
        end
      end

      # A failure of one submission (not of the whole file).
      class SubmissionError < StandardError
        attr_reader :entries

        def initialize(entries)
          @entries = entries
          super(entries.map { |e| e[:message] }.join("; "))
        end
      end

      # survey   - Decidim::Surveys::Survey (target, from the request).
      # raw      - Hash parsed from the uploaded JSON.
      # user     - the admin performing the import (already authorized, SEC1).
      # allow_identified_respondents - accept respondent.kind "user" (SEC7).
      #            Only honoured when `user` is an organization admin.
      # file_sha256 - digest of the uploaded bytes for the audit log (SEC11).
      def initialize(survey, raw, user, allow_identified_respondents: false, file_sha256: nil)
        @survey = survey
        @questionnaire = survey.questionnaire
        @raw = raw
        @user = user
        @organization = survey.component.organization
        @allow_identified = allow_identified_respondents && user&.admin? ? true : false
        @file_sha256 = file_sha256
      end

      def call
        report = import!
        # SEC11: audit entry with the digest of the file and the counts.
        Decidim.traceability.perform_action!("update", @survey, @user, audit_log(report))
        broadcast(:ok, report)
      rescue Error => e
        broadcast(:invalid, e)
      end

      private

      def import!
        signature = @raw.is_a?(Hash) ? Signature.verify!(@raw) : :absent
        data = ResponsesValidator.new(@raw).call

        @ids = Identifiers.new(@questionnaire)
        raise Error.new(:invalid_file, ["the target survey has no questions"]) if @ids.questions.empty?
        if data["target"]["survey_uuid"] != @ids.fingerprint
          raise Error.new(:stale_reference, ["target.survey_uuid: the questions of the survey changed after the definition was exported; export it again"])
        end

        options = data["options"] || {}
        @on_existing = options["on_existing"] || "skip"
        @lenient = options["validation"] == "lenient"
        @enforce_conditions = options.fetch("enforce_display_conditions", true)
        @publish_events = options.fetch("publish_events", false)

        @report = Report.new(imported: 0, skipped: [], errors: [], assigned: {}, warnings: [], discarded: 0, signature:)
        @report.warnings << "integrity: signed by another installation, treated as unsigned" if signature == :foreign

        data["submissions"].each_with_index do |submission, index|
          import_submission(submission, index)
        end
        @report
      end

      # ------------------------------------------------------- submission

      def import_submission(submission, index)
        ref = submission["external_id"] || submission.dig("respondent", "respondent_uuid") || "submissions[#{index}]"
        @blobs = []

        user, session_token = resolve_respondent!(submission)
        if @questionnaire.responded_by?(user || session_token)
          case @on_existing
          when "skip"
            return @report.skipped << { ref:, reason: "already_responded" }
          when "error"
            raise SubmissionError, [{ code: "already_responded", message: "the respondent already responded to this survey" }]
          end
          replace = true
        end

        locale = submission_locale!(submission)
        resolved, errors = resolve_answers(submission["answers"], locale)
        raise SubmissionError, errors if errors.any? && !@lenient

        add_errors(ref, errors)
        ip_hash = submission["ip"] ? tokenize(submission["ip"]) : existing_ip_hash(session_token)
        submitted_at = submission["submitted_at"] ? Time.zone.iso8601(submission["submitted_at"]) : Time.current

        dropped = save_submission!(resolved, user:, session_token:, ip_hash:, submitted_at:, replace:)
        add_errors(ref, dropped)
        purge_blobs # files of answers dropped in "lenient" mode

        @report.imported += 1
        if submission["external_id"]
          @report.assigned[submission["external_id"]] = {
            submission_uuid: @ids.submission_uuid(session_token),
            respondent_uuid: @ids.respondent_uuid(session_token)
          }
        end
      rescue SubmissionError => e
        purge_blobs
        add_errors(ref, e.entries)
      end

      def add_errors(ref, entries)
        entries.each { |entry| @report.errors << { ref: }.merge(entry) }
      end

      # P1-P3. Returns [user or nil, session_token].
      def resolve_respondent!(submission)
        respondent = submission["respondent"]
        case respondent["kind"]
        when "existing"
          token = @ids.respondents[respondent["respondent_uuid"]]
          raise SubmissionError, [{ code: "stale_reference", message: "respondent.respondent_uuid does not match any participant of this survey" }] unless token

          user_id = Decidim::Forms::Response.where(questionnaire: @questionnaire, session_token: token).where.not(decidim_user_id: nil).pick(:decidim_user_id)
          [user_id && Decidim::User.find_by(id: user_id), token]
        when "anonymous"
          [nil, tokenize("import:#{submission["external_id"]}")]
        when "user"
          user = find_user!(respondent)
          [user, tokenize(user.id)]
        end
      end

      # P2 / SEC7.
      def find_user!(respondent)
        unless @allow_identified
          raise SubmissionError, [{ code: "identified_respondents_disabled",
                                    message: "respondent.kind \"user\" needs the \"allow identified respondents\" option, available to organization admins only" }]
        end

        scope = Decidim::User.where(organization: @organization)
        by_email = scope.find_by("LOWER(email) = ?", respondent["email"].downcase) if respondent["email"]
        by_nickname = scope.find_by(nickname: respondent["nickname"]) if respondent["nickname"]
        user = by_email || by_nickname
        if user.nil? || (by_email && by_nickname && by_email != by_nickname) || (respondent["email"] && !by_email) || (respondent["nickname"] && !by_nickname)
          raise SubmissionError, [{ code: "unknown_user", message: "respondent: no single user of this organization matches the given email/nickname" }]
        end
        raise SubmissionError, [{ code: "unknown_user", message: "respondent: the user is deleted or blocked" }] if user.deleted? || user.blocked?

        user
      end

      # Locales are per organization in Decidim (spaces, components and
      # surveys have none). A locale of the file is accepted when the
      # organization has that language: "es", "es-ES" or "es_MX" all resolve
      # to "es-MX" in an organization with ["en", "es-MX"].
      def submission_locale!(submission)
        return @organization.default_locale.to_s unless submission.has_key?("locale")

        given = submission["locale"]
        locale = Validator.resolve_locale(given, @organization.available_locales, default: @organization.default_locale)
        unless locale
          raise SubmissionError, [{ code: "invalid_locale",
                                    message: "locale \"#{given}\": this organization has no locale of that language (#{@organization.available_locales.join(", ")})" }]
        end

        if locale != given && !(@mapped_locales ||= {}).has_key?(given)
          @mapped_locales[given] = locale
          @report.warnings << "locale \"#{given}\" applied as #{locale}"
        end
        locale
      end

      def existing_ip_hash(session_token)
        Decidim::Forms::Response.where(questionnaire: @questionnaire, session_token:).where.not(ip_hash: nil).pick(:ip_hash)
      end

      # Same token as Decidim::Forms::Concerns::HasQuestionnaire#tokenize.
      def tokenize(value)
        Decidim::Tokenizer.new(salt: @questionnaire.salt || @questionnaire.id, length: 10).int_digest(value).to_s
      end

      # ---------------------------------------------------------- answers

      # R1-R3, R7, R11 (+ duplicates). Returns [{question_id => Resolved}, errors].
      def resolve_answers(answers, locale)
        resolved = {}
        errors = []
        answers.each do |answer|
          question = @ids.find(Decidim::Forms::Question, answer["question"])
          unless question
            errors << { question: answer["question"], code: "stale_reference", message: "question does not match any question of this survey" }
            next
          end
          unless question.question_type == answer["type"]
            errors << { question: answer["question"], code: "type_mismatch", message: "type is \"#{answer["type"]}\" but the question is \"#{question.question_type}\"" }
            next
          end

          resolved[question.id] = resolve_answer(question, answer, locale)
        rescue SubmissionError => e
          errors.concat(e.entries.map { |entry| { question: answer["question"] }.merge(entry) })
        end
        [resolved, errors]
      end

      def resolve_answer(question, answer, locale)
        case answer["type"]
        when "short_response", "long_response"
          Resolved.new(question:, body: answer["body"], choices: [], files: [])
        when "single_option"
          Resolved.new(question:, choices: [choice(question, answer["selection"], locale)], files: [])
        when "multiple_option"
          Resolved.new(question:, choices: unique_choices(question, answer["selections"], locale), files: [])
        when "sorting"
          Resolved.new(question:, choices: ranking(question, answer["ranking"], locale), files: [])
        when "matrix_single", "matrix_multiple"
          Resolved.new(question:, choices: matrix(question, answer, locale), files: [])
        when "files"
          Resolved.new(question:, choices: [], files: answer["files"].map { |file| upload(file) })
        end
      end

      # R2, R3. `body` is a copy of the option text, as the public form does.
      def choice(question, selection, locale, row: nil, position: nil)
        option = option!(question, selection.is_a?(Hash) ? selection["option"] : selection)
        free_text = selection.is_a?(Hash) ? selection["free_text"] : nil
        raise SubmissionError, [{ code: "free_text_not_allowed", message: "option #{@ids.uuid_for(option)} does not accept free text" }] if free_text && !option.free_text

        { response_option_id: option.id, body: option_text(option, locale), custom_body: free_text, matrix_row_id: row&.id, position: }
      end

      def unique_choices(question, selections, locale, row: nil)
        options = selections.map { |s| s["option"] }
        raise SubmissionError, [{ code: "duplicate_option", message: "the same option is selected more than once" }] if options.uniq.size != options.size

        selections.map { |s| choice(question, s, locale, row:) }
      end

      # R7: every option once; the index is the position.
      def ranking(question, uuids, locale)
        options = @ids.response_options_of(question)
        if uuids.uniq.size != uuids.size || uuids.size != options.size
          raise SubmissionError, [{ code: "invalid_ranking", message: "ranking must contain each of the #{options.size} options exactly once" }]
        end

        uuids.each_with_index.map { |uuid, index| choice(question, uuid, locale, position: index) }
      end

      def matrix(question, answer, locale)
        rows = answer["rows"].map { |entry| row!(question, entry["row"]) }
        raise SubmissionError, [{ code: "duplicate_row", message: "the same matrix row is answered more than once" }] if rows.uniq.size != rows.size

        answer["rows"].zip(rows).flat_map do |entry, row|
          if answer["type"] == "matrix_single"
            [choice(question, entry["selection"], locale, row:)]
          else
            unique_choices(question, entry["selections"], locale, row:)
          end
        end
      end

      def option!(question, uuid)
        option = @ids.find(Decidim::Forms::ResponseOption, uuid)
        return option if option && option.decidim_question_id == question.id

        raise SubmissionError, [{ code: "stale_reference", message: "option #{uuid} is not an option of this question" }]
      end

      def row!(question, uuid)
        row = @ids.find(Decidim::Forms::QuestionMatrixRow, uuid)
        return row if row && row.decidim_question_id == question.id

        raise SubmissionError, [{ code: "stale_reference", message: "row #{uuid} is not a row of this question" }]
      end

      # Copy of the option text in the submission locale (choice.body). Falls
      # back to another variant of the same language ("es" for "es-MX"),
      # then to a machine translation, then to the default locale and
      # finally to any text, so the copy is never blank (a blank body would
      # make Decidim treat the choice as not selected).
      def option_text(option, locale)
        body = option.body.is_a?(Hash) ? option.body : {}
        texts = body.except("machine_translations").select { |_, v| v.is_a?(String) && v.present? }
        machine = body["machine_translations"].is_a?(Hash) ? body["machine_translations"] : {}
        same_language = ->(l) { texts.find { |k, _| k.split("-").first.casecmp?(l.split("-").first) }&.last }

        texts[locale] || same_language.call(locale) || machine[locale].presence ||
          texts[@organization.default_locale.to_s] || texts.values.first || "-"
      end

      # SEC12: embedded content only. Size and type are validated by
      # Decidim::Attachment (organization upload settings) when saving.
      def upload(file)
        content = Base64.strict_decode64(file["base64"])
        blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(content), filename: file["filename"], content_type: file["content_type"])
        @blobs << blob
        { file: blob.signed_id, title: file["title"].presence || file["filename"] }
      rescue ArgumentError
        raise SubmissionError, [{ code: "invalid_file", message: "#{file["filename"]}: base64 is not valid" }]
      end

      def purge_blobs
        @blobs&.each { |blob| blob.purge if blob.attachments.reload.empty? }
        @blobs = []
      end

      # ------------------------------------------------ display conditions

      # P5, same semantics as Decidim::Forms::ResponseForm#display_conditions_fulfilled?
      # but on the answers of this submission.
      def visible?(question, resolved)
        conditions = @ids.display_conditions_of(question)
        mandatory, optional = conditions.partition(&:mandatory)
        return mandatory.all? { |c| fulfilled?(c, resolved) } if mandatory.any?
        return true if optional.empty?

        optional.any? { |c| fulfilled?(c, resolved) }
      end

      def fulfilled?(condition, resolved)
        answer = resolved[condition.decidim_condition_question_id]
        answered = answer&.answered? || false
        case condition.condition_type
        when "responded" then answered
        when "not_responded" then !answered
        when "equal" then answered && answer.choices.any? { |c| c[:response_option_id] == condition.decidim_response_option_id }
        when "not_equal" then answered && answer.choices.none? { |c| c[:response_option_id] == condition.decidim_response_option_id }
        when "match" then answered && matches?(condition, answer)
        else false
        end
      end

      # SEC10: Regexp.timeout is set globally (config/initializers/survey_exchange.rb).
      def matches?(condition, answer)
        patterns = (condition.condition_value || {}).except("machine_translations").values.select { |v| v.is_a?(String) && v.present? }
        texts = [answer.body] + answer.choices.flat_map { |c| [c[:body], c[:custom_body]] }
        patterns.any? do |pattern|
          regexp = Regexp.new(pattern, Regexp::IGNORECASE)
          texts.compact.any? { |text| text.match?(regexp) }
        rescue RegexpError # includes Regexp::TimeoutError
          false
        end
      end

      # ------------------------------------------------------------ saving

      # Returns the errors of the answers dropped in "lenient" mode.
      def save_submission!(resolved, user:, session_token:, ip_hash:, submitted_at:, replace:)
        dropped = []
        2.times do |attempt|
          form, discarded = build_form(resolved, user:, session_token:, ip_hash:)
          if persist(form, user:, session_token:, submitted_at:, replace:)
            @report.discarded += discarded
            return dropped
          end

          errors = form_errors(form)
          # "lenient": drop the answers Decidim rejected and try once more.
          invalid_ids = form.responses.select { |r| r.errors.any? }.map { |r| r.question.id } & resolved.keys
          raise SubmissionError, dropped + errors if !@lenient || attempt.positive? || invalid_ids.empty?

          dropped.concat(errors)
          resolved = resolved.except(*invalid_ids)
        end
      end

      def persist(form, user:, session_token:, submitted_at:, replace:)
        result = nil
        ActiveRecord::Base.transaction(requires_new: true) do
          # P4 "replace": remove the previous responses of the participant
          # (attachments go with them, Decidim::HasAttachments).
          clear_responses!(user, session_token) if replace
          SaveSubmission.call(form, @questionnaire, publish_events: @publish_events) do
            on(:ok) { result = :ok }
            on(:invalid) { result = :invalid }
          end
          raise ActiveRecord::Rollback unless result == :ok

          # The command cannot set created_at (spec 4.6).
          Decidim::Forms::Response.where(questionnaire: @questionnaire, session_token:).update_all(created_at: submitted_at, updated_at: submitted_at) # rubocop:disable Rails/SkipsModelValidations
        end
        result == :ok
      end

      def clear_responses!(user, session_token)
        scope = Decidim::Forms::Response.where(questionnaire: @questionnaire)
        rows = scope.where(session_token:)
        rows = rows.or(scope.where(user:)) if user
        rows.destroy_all
      end

      # Same params as the public form (decidim/forms/questionnaires/_response):
      # one ResponseForm per question, in position order, with the option
      # text copied in choices[].body.
      # Returns [form, number of answers discarded by display conditions].
      def build_form(resolved, user:, session_token:, ip_hash:)
        visibility = {}
        responses = @ids.questions.map do |question|
          answer = resolved[question.id]
          visibility[question.id] = visible?(question, resolved) || (!@enforce_conditions && answer&.answered?)
          {
            question_id: question.id.to_s,
            body: answer ? answer.body : filler_body(question),
            choices: answer ? answer.choices : []
          }
        end

        form = Decidim::Forms::QuestionnaireForm.from_params(responses:, tos_agreement: true)
                                                .with_context(session_token:, ip_hash:, current_user: user, current_organization: @organization)
        form.responses.each do |response_form|
          question = @ids.questions.find { |q| q.id == response_form.question_id.to_i }
          response_form.question = question
          shown = visibility[question.id]
          response_form.define_singleton_method(:display_conditions_fulfilled?) { shown }
          files = resolved[question.id]&.files
          response_form.add_documents = files.map(&:with_indifferent_access) if files.present?
        end
        [form, resolved.count { |id, answer| !visibility[id] && answer.answered? }]
      end

      # The public form sends these fixed bodies (responses/_separator and
      # responses/_title_and_description). Separators are then dropped by
      # QuestionnaireForm#responses_by_step, as in the web.
      def filler_body(question)
        case question.question_type
        when "separator" then "separator"
        when "title_and_description" then "title-and-description"
        end
      end

      def form_errors(form)
        # The :responses error only says that a nested form is invalid; the
        # detail comes from each ResponseForm below.
        entries = form.errors.reject { |e| e.attribute == :responses }.map { |e| { code: "invalid_submission", message: e.full_message } }
        form.responses.each do |response_form|
          next if response_form.errors.empty?

          uuid = @ids.uuid_for(response_form.question)
          # :needs_to_be_reattached is a hint for the web form only.
          response_form.errors.reject { |e| e.type == :needs_to_be_reattached }.each do |e|
            entries << { question: uuid, code: "invalid_answer", message: e.full_message }
          end
        end
        entries = [{ code: "invalid_submission", message: "Decidim rejected the submission" }] if entries.empty?
        entries
      end

      def audit_log(report)
        {
          extra: {
            survey_exchange: {
              action: "import_responses", sha256: @file_sha256, signature: report.signature,
              identified_respondents: @allow_identified, imported: report.imported,
              skipped: report.skipped.size, errors: report.errors.size
            }
          }
        }
      end
    end
  end
end
