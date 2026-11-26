# frozen_string_literal: true

require "digest"

module DecidimCujae
  module SurveyExchange
    # Imports a `decidim.survey` document into an existing survey
    # (spec 3.3, 3.5, 3.6). The target survey comes from the request, never
    # from the file (SEC2); every reference is resolved against the UUIDs
    # computed for that survey only (SEC3).
    #
    # Saving reuses Decidim's admin commands so the rules are the same as in
    # the admin UI:
    #   - Decidim::Surveys::Admin::UpdateSurvey          (title, description, tos)
    #   - Decidim::Surveys::Admin::UpdateSurveySettings  (settings)
    #   - Decidim::Forms::Admin::UpdateQuestions         (pass 1: questions, options, rows;
    #                                                     pass 2: display conditions, which need real ids)
    #
    # Broadcasts :ok with a report Hash, or :invalid with an Error.
    class ImportSurvey < Decidim::Command
      Report = Struct.new(:created, :updated, :deleted, :recreated_options, :warnings, :signature, :fingerprint, :questions_changed, keyword_init: true)

      # Plan entries (in memory only).
      QuestionPlan = Struct.new(:record, :file, :position, :attrs, :options, :rows, :conditions, keyword_init: true)
      ChildPlan = Struct.new(:record, :file, :attrs, :old_record, keyword_init: true)
      ConditionPlan = Struct.new(:condition_question, :response_option, :attrs, :path, keyword_init: true)

      # survey   - Decidim::Surveys::Survey (target, from the request).
      # raw      - Hash parsed from the uploaded JSON.
      # user     - the admin performing the import (already authorized, SEC1).
      # as_new   - ignore identifiers: treat every element as new (copy a survey
      #            exported from another survey or installation).
      # file_sha256 - digest of the uploaded bytes for the audit log (SEC11).
      def initialize(survey, raw, user, as_new: false, file_sha256: nil)
        @survey = survey
        @questionnaire = survey.questionnaire
        @raw = raw
        @user = user
        @as_new = as_new
        @file_sha256 = file_sha256
        @organization = survey.component.organization
        @warnings = []
        @counts = Hash.new(0)
      end

      def call
        report = nil
        # U4: one transaction. requires_new gives a savepoint, so a failure
        # also rolls back when the caller already opened a transaction
        # (e.g. creating a new survey from a file).
        ActiveRecord::Base.transaction(requires_new: true) do
          report = import!
          # SEC11: audit entry with the digest of the file and the counts.
          Decidim.traceability.perform_action!("update", @survey, @user, survey_exchange_log(report))
        end
        broadcast(:ok, report)
      rescue Error => e
        broadcast(:invalid, e)
      end

      private

      def import!
        signature = @raw.is_a?(Hash) ? Signature.verify!(@raw) : :absent
        @warnings << "integrity: signed by another installation, treated as unsigned" if signature == :foreign

        validator = Validator.new(@raw, locales: @organization.available_locales)
        data = validator.call
        @warnings.concat(validator.warnings)
        data = strip_identifiers(data) if @as_new
        @mode = data["mode"] || "replace"
        survey_data = data["survey"]
        questionnaire_data = survey_data["questionnaire"]

        @ids = Identifiers.new(@questionnaire)
        if survey_data["uuid"] && survey_data["uuid"] != @ids.fingerprint
          raise Error.new(:stale_reference, ["survey.uuid: the survey changed after this file was exported; export it again"])
        end

        validate_questionnaire_form!(questionnaire_data)

        questions_changed = false
        if @questionnaire.questions_editable?
          plan = build_plan(questionnaire_data["questions"])
          validate_question_forms!(plan)
          update_questionnaire!(questionnaire_data)
          update_settings!(survey_data["settings"]) if survey_data["settings"]
          save_questions!(plan)
          questions_changed = true
        else
          assert_questions_unchanged!(questionnaire_data["questions"])
          update_questionnaire!(questionnaire_data)
          update_settings!(survey_data["settings"]) if survey_data["settings"]
        end

        @questionnaire.reload
        Report.new(
          created: @counts[:created], updated: @counts[:updated], deleted: @counts[:deleted],
          recreated_options: @counts[:recreated_options], warnings: @warnings, signature:,
          fingerprint: Identifiers.new(@questionnaire).fingerprint, questions_changed:
        )
      end

      def survey_exchange_log(report)
        {
          extra: {
            survey_exchange: {
              action: "import_definition", sha256: @file_sha256, as_new: @as_new, signature: report.signature,
              questions_changed: report.questions_changed, created: report.created, updated: report.updated,
              deleted: report.deleted, fingerprint: report.fingerprint
            }
          }
        }
      end

      # ---------------------------------------------------------------- plan

      def strip_identifiers(data)
        questions = data["survey"]["questionnaire"]["questions"].reject { |q| q["deleted"] }.map do |q|
          q = q.except("uuid")
          q["response_options"] = q["response_options"].reject { |o| o["deleted"] }.map { |o| o.except("uuid") } if q["response_options"]
          q["matrix_rows"] = q["matrix_rows"].reject { |r| r["deleted"] }.map { |r| r.except("uuid") } if q["matrix_rows"]
          q["display_conditions"] = q["display_conditions"].reject { |c| c["deleted"] }.map { |c| c.except("uuid") }
          q
        end
        data.merge(
          "mode" => "replace",
          "survey" => data["survey"].except("uuid").merge(
            "questionnaire" => data["survey"]["questionnaire"].merge("questions" => questions)
          )
        )
      end

      def build_plan(file_questions)
        @deleted_questions = []
        used = {}

        resolved = file_questions.each_with_index.map do |fq, i|
          path = "survey.questionnaire.questions[#{i}]"
          record = resolve!(Decidim::Forms::Question, fq["uuid"], path, used)
          [fq, record, path]
        end

        live = resolved.reject { |fq, _r, _p| fq["deleted"] }
        @deleted_questions.concat(resolved.select { |fq, _r, _p| fq["deleted"] }.map { |_fq, r, _p| r })
        referenced = resolved.map { |_fq, r, _p| r }.compact
        omitted = @ids.questions - referenced
        if @mode == "replace"
          @deleted_questions.concat(omitted)
          omitted = []
        end

        entries = live.map do |fq, record, path|
          QuestionPlan.new(record:, file: fq.merge("_path" => path))
        end
        entries += omitted.map { |record| QuestionPlan.new(record:, file: nil) }
        entries.each_with_index { |entry, position| entry.position = position }

        @by_key = entries.select(&:file).index_by { |e| e.file["key"] }
        @by_record = entries.select(&:record).index_by { |e| e.record.id }

        entries.each do |entry|
          entry.attrs = question_attrs(entry)
          entry.options = plan_options(entry)
          entry.rows = plan_rows(entry)
        end
        # Separate pass: conditions may reference options of later questions.
        entries.each { |entry| entry.conditions = plan_conditions(entry) } # rubocop:disable Style/CombinableLoops
        entries
      end

      def question_attrs(entry)
        if entry.file
          fq = entry.file
          {
            body: fq["question_type"] == "separator" ? nil : fq["body"],
            description: fq["description"],
            position: entry.position,
            mandatory: fq["mandatory"],
            question_type: fq["question_type"],
            max_choices: fq["max_choices"],
            max_characters: fq["max_characters"]
          }
        else
          r = entry.record
          { body: r.body, description: r.description, position: entry.position, mandatory: r.mandatory,
            question_type: r.question_type, max_choices: r.max_choices, max_characters: r.max_characters }
        end
      end

      # Response options: U2. They have no position (ordered by id), so if
      # the final order cannot be reached by updating in place, every option
      # of the question is deleted and created again in the new order.
      def plan_options(entry)
        existing = entry.record ? @ids.response_options_of(entry.record) : []
        file_list = entry.file ? Array(entry.file["response_options"]) : nil
        plans, deleted = plan_children(entry, existing, file_list, "response_options", Decidim::Forms::ResponseOption) do |child|
          { body: child["body"], free_text: child["free_text"] }
        end
        entry.define_singleton_method(:deleted_options) { deleted }

        kept_ids = plans.map { |p| p.record&.id }
        first_new = kept_ids.index(nil)
        in_order = kept_ids.compact.each_cons(2).all? { |a, b| a < b } &&
                   (first_new.nil? || kept_ids[first_new..].compact.empty?)
        unless in_order
          @counts[:recreated_options] += 1
          plans.each do |plan|
            next unless plan.record

            deleted << plan.record
            plan.old_record = plan.record
            plan.record = nil
          end
        end
        plans
      end

      def plan_rows(entry)
        existing = entry.record ? entry.record.matrix_rows.to_a : []
        file_list = entry.file ? Array(entry.file["matrix_rows"]) : nil
        plans, deleted = plan_children(entry, existing, file_list, "matrix_rows", Decidim::Forms::QuestionMatrixRow) do |child|
          { body: child["body"] }
        end
        entry.define_singleton_method(:deleted_rows) { deleted }
        plans.each_with_index { |plan, idx| plan.attrs[:position] = idx }
        plans
      end

      # Generic resolution for options and rows of one question (U3, SEC3).
      def plan_children(entry, existing, file_list, name, klass)
        return [existing.map { |r| ChildPlan.new(record: r, attrs: attrs_from_record(r)) }, []] if file_list.nil?

        used = {}
        resolved = file_list.each_with_index.map do |child, j|
          path = "#{entry.file["_path"]}.#{name}[#{j}]"
          record = nil
          if child["uuid"]
            raise Error.new(:stale_reference, ["#{path}.uuid: the question is new, so its elements cannot reference existing ones"]) unless entry.record

            record = resolve!(klass, child["uuid"], path, used)
            parent_id = record.decidim_question_id
            raise Error.new(:stale_reference, ["#{path}.uuid: does not belong to this question"]) unless parent_id == entry.record.id
          end
          [child.merge("_path" => path), record]
        end

        deleted = resolved.select { |c, _r| c["deleted"] }.map(&:last)
        omitted = existing - resolved.map(&:last).compact
        if @mode == "replace"
          deleted += omitted
          omitted = []
        end
        plans = resolved.reject { |c, _r| c["deleted"] }.map { |c, r| ChildPlan.new(record: r, file: c, attrs: yield(c)) }
        plans += omitted.map { |r| ChildPlan.new(record: r, attrs: attrs_from_record(r)) }
        [plans, deleted]
      end

      def attrs_from_record(record)
        if record.is_a?(Decidim::Forms::ResponseOption)
          { body: record.body, free_text: record.free_text }
        else
          { body: record.body }
        end
      end

      # Display conditions are always destroyed and created again in pass 2
      # (their UUID only depends on content, so unchanged conditions keep it).
      def plan_conditions(entry)
        existing = entry.record ? @ids.display_conditions_of(entry.record) : []
        list = []

        if entry.file
          used = {}
          referenced = []
          entry.file["display_conditions"].each_with_index do |fc, j|
            path = "#{entry.file["_path"]}.display_conditions[#{j}]"
            if fc["uuid"]
              raise Error.new(:stale_reference, ["#{path}.uuid: the question is new, so its conditions cannot reference existing ones"]) unless entry.record

              record = resolve!(Decidim::Forms::DisplayCondition, fc["uuid"], path, used)
              raise Error.new(:stale_reference, ["#{path}.uuid: does not belong to this question"]) unless record.decidim_question_id == entry.record.id

              referenced << record
            end
            next if fc["deleted"]

            list << file_condition(entry, fc, path)
          end
          kept = @mode == "merge" ? existing - referenced : []
        else
          kept = existing
        end

        list + kept.filter_map { |record| existing_condition(entry, record) }
      end

      def file_condition(entry, file_cond, path)
        target = resolve_question_ref!(file_cond["condition_question"], "#{path}.condition_question")
        type = file_cond["condition_type"]
        raise Error.new(:invalid_file, ["#{path}.condition_question: a question cannot depend on itself"]) if target.equal?(entry)
        if NON_CONDITIONABLE_TYPES.include?(target.attrs[:question_type])
          raise Error.new(:invalid_file, ["#{path}.condition_question: questions of type #{target.attrs[:question_type]} cannot be used in conditions"])
        end
        raise Error.new(:invalid_file, ["#{path}: the first question (position 0) cannot have display conditions"]) if entry.position.zero?

        option = (resolve_option_ref!(target, file_cond["response_option"], "#{path}.response_option") if %w(equal not_equal).include?(type))
        ConditionPlan.new(
          condition_question: target, response_option: option, path:,
          attrs: { condition_type: type, condition_value: type == "match" ? file_cond["condition_value"] : nil, mandatory: file_cond["mandatory"] }
        )
      end

      # merge mode: an existing condition omitted from the file is kept.
      def existing_condition(entry, record)
        target = @by_record[record.decidim_condition_question_id]
        if target.nil?
          @warnings << "display condition of question at position #{entry.position} removed: its condition question was deleted"
          return nil
        end
        option = nil
        if %w(equal not_equal).include?(record.condition_type)
          option = target.options.find { |o| (o.record || o.old_record)&.id == record.decidim_response_option_id }
          if option.nil?
            @warnings << "display condition of question at position #{entry.position} removed: its response option was deleted"
            return nil
          end
        end
        return nil if entry.position.zero?

        ConditionPlan.new(condition_question: target, response_option: option, path: "question at position #{entry.position}",
                          attrs: { condition_type: record.condition_type, condition_value: record.condition_value, mandatory: record.mandatory })
      end

      def resolve_question_ref!(ref, path)
        return @by_key[ref] || raise(Error.new(:invalid_file, ["#{path}: no question with key \"#{ref}\" in this file"])) unless UUID_PATTERN.match?(ref)

        record = @ids.find(Decidim::Forms::Question, ref)
        entry = record && @by_record[record.id]
        raise Error.new(:stale_reference, ["#{path}: no current question matches this UUID (changed or deleted)"]) unless entry

        entry
      end

      def resolve_option_ref!(target, ref, path)
        if UUID_PATTERN.match?(ref)
          record = @ids.find(Decidim::Forms::ResponseOption, ref)
          option = record && target.options.find { |o| (o.record || o.old_record)&.id == record.id }
          raise Error.new(:stale_reference, ["#{path}: no response option of the condition question matches this UUID"]) unless option
        else
          option = target.options.find { |o| o.file && o.file["key"] == ref }
          raise Error.new(:invalid_file, ["#{path}: the condition question has no response option with key \"#{ref}\""]) unless option
        end
        option
      end

      # U3: a UUID must match a current element of the same kind of this
      # questionnaire; the same element cannot be claimed twice.
      def resolve!(klass, uuid, path, used)
        return nil if uuid.nil?

        record = @ids.find(klass, uuid)
        raise Error.new(:stale_reference, ["#{path}.uuid: no current element matches this UUID (it changed or was deleted); export the survey again"]) unless record
        raise Error.new(:invalid_file, ["#{path}.uuid: used more than once"]) if used[uuid]

        used[uuid] = true
        record
      end

      # ----------------------------------------------------- U1 (not editable)

      def assert_questions_unchanged!(file_questions)
        current = @ids.questions
        changed = file_questions.size != current.size
        changed ||= file_questions.each_with_index.any? { |fq, i| question_changed?(fq, current[i], file_questions) }
        return unless changed

        raise Error.new(:questions_not_editable, [
                          "the survey already has responses and its component is published, so its questions cannot be modified; " \
                          "only title, description, terms of service and settings can be imported"
                        ])
      end

      def question_changed?(file_question, record, file_questions)
        return true if file_question["deleted"] || file_question["uuid"] != @ids.uuid_for(record)

        key = @ids.key
        projection = Identifiers.question_projection(
          position: record.position, question_type: file_question["question_type"], mandatory: file_question["mandatory"],
          body: file_question["body"], description: file_question["description"], max_choices: file_question["max_choices"], max_characters: file_question["max_characters"]
        )
        return true if Identifiers.content_uuid(key, projection) != file_question["uuid"]

        options = @ids.response_options_of(record)
        file_options = Array(file_question["response_options"])
        return true if file_options.size != options.size
        return true if file_options.each_with_index.any? do |fo, j|
          fo["deleted"] || fo["uuid"] != @ids.uuid_for(options[j]) ||
          Identifiers.content_uuid(key,
                                   Identifiers.response_option_projection(question_position: record.position, index: j, body: fo["body"], free_text: fo["free_text"])) != fo["uuid"]
        end

        rows = record.matrix_rows.to_a
        file_rows = Array(file_question["matrix_rows"])
        return true if file_rows.size != rows.size
        return true if file_rows.each_with_index.any? do |fr, j|
          fr["deleted"] || fr["uuid"] != @ids.uuid_for(rows[j]) ||
          Identifiers.content_uuid(key, Identifiers.matrix_row_projection(question_position: record.position, position: rows[j].position, body: fr["body"])) != fr["uuid"]
        end

        conditions = @ids.display_conditions_of(record)
        file_conditions = file_question["display_conditions"]
        return true if file_conditions.size != conditions.size

        file_conditions.each_with_index.any? do |fc, j|
          next true if fc["deleted"] || fc["uuid"] != @ids.uuid_for(conditions[j])

          target_index = if UUID_PATTERN.match?(fc["condition_question"])
                           @ids.questions.index { |q| @ids.uuid_for(q) == fc["condition_question"] }
                         else
                           file_questions.index { |q| q["key"] == fc["condition_question"] }
                         end
          next true if target_index.nil?

          target = @ids.questions[target_index]
          option_index = nil
          if fc["response_option"]
            target_options = @ids.response_options_of(target)
            option_index = if UUID_PATTERN.match?(fc["response_option"])
                             target_options.index { |o| @ids.uuid_for(o) == fc["response_option"] }
                           else
                             Array(file_questions[target_index]["response_options"]).index { |o| o["key"] == fc["response_option"] }
                           end
          end
          projection = Identifiers.display_condition_projection(
            question_position: record.position, condition_question_position: target.position,
            condition_type: fc["condition_type"], response_option_index: option_index,
            condition_value: fc["condition_value"], mandatory: fc["mandatory"]
          )
          Identifiers.content_uuid(key, projection) != fc["uuid"]
        end
      end

      # ------------------------------------------------- validation by forms

      def form_context
        { current_organization: @organization, current_user: @user, current_component: @survey.component }
      end

      def validate_questionnaire_form!(questionnaire_data)
        form = Decidim::Surveys::Admin::SurveyForm.from_params(
          title: questionnaire_data["title"], description: questionnaire_data["description"], tos: questionnaire_data["tos"]
        ).with_context(form_context)
        return if form.valid?

        raise Error.new(:invalid_file, form.errors.full_messages.uniq.map { |m| "survey.questionnaire: #{m}" })
      end

      def validate_question_forms!(plan)
        errors = []
        plan.each do |entry|
          form = question_form(entry, conditions: false)
          next if form.valid?

          path = entry.file ? entry.file["_path"] : "question at position #{entry.position}"
          errors.concat(form.errors.full_messages.map { |m| "#{path}: #{m}" })
          form.response_options.each_with_index do |option_form, j|
            errors.concat(option_form.errors.full_messages.map { |m| "#{path}.response_options[#{j}]: #{m}" }) if option_form.invalid?
          end
          form.matrix_rows.each_with_index do |row_form, j|
            errors.concat(row_form.errors.full_messages.map { |m| "#{path}.matrix_rows[#{j}]: #{m}" }) if row_form.invalid?
          end
        end
        raise Error.new(:invalid_file, errors.uniq) if errors.any?
      end

      # QuestionForm for pass 1 (no display conditions). Deleted children go
      # first so that new options are created after the deletions.
      def question_form(entry, conditions:)
        options = []
        rows = []
        if entry.respond_to?(:deleted_options)
          options += entry.deleted_options.map { |r| { id: r.id, deleted: true, body: r.body, free_text: r.free_text } }
          rows += entry.deleted_rows.map { |r| { id: r.id, deleted: true, body: r.body, position: r.position } }
        end
        options += entry.options.map { |o| o.attrs.merge(id: o.record&.id) }
        rows += entry.rows.map { |r| r.attrs.merge(id: r.record&.id) }

        Decidim::Forms::Admin::QuestionForm.from_params(
          entry.attrs.merge(
            id: entry.record&.id,
            response_options: options,
            matrix_rows: rows,
            display_conditions: conditions ? condition_params(entry) : []
          )
        ).with_context(form_context)
      end

      def condition_params(entry)
        entry.conditions.map do |condition|
          {
            id: nil,
            decidim_question_id: entry.record.id,
            decidim_condition_question_id: condition.condition_question.record.id,
            decidim_response_option_id: condition.response_option&.record&.id,
            condition_type: condition.attrs[:condition_type],
            condition_value: condition.attrs[:condition_value],
            mandatory: condition.attrs[:mandatory]
          }
        end
      end

      # ------------------------------------------------------------- saving

      def update_questionnaire!(questionnaire_data)
        form = Decidim::Surveys::Admin::SurveyForm.from_params(
          title: questionnaire_data["title"], description: questionnaire_data["description"], tos: questionnaire_data["tos"]
        ).with_context(form_context)
        result = Decidim::Surveys::Admin::UpdateSurvey.call(form, @survey, @user)
        raise Error.new(:invalid_file, form.errors.full_messages.map { |m| "survey.questionnaire: #{m}" }) unless result.has_key?(:ok)
      end

      def update_settings!(settings)
        current = {
          allow_responses: @survey.allow_responses, allow_unregistered: @survey.allow_unregistered,
          allow_editing_responses: @survey.allow_editing_responses, clean_after_publish: @survey.clean_after_publish,
          starts_at: @survey.starts_at, ends_at: @survey.ends_at, announcement: @survey.announcement
        }
        attrs = current.merge(settings.symbolize_keys)
        form = Decidim::Surveys::Admin::SurveySettingsForm.from_params(attrs).with_context(form_context)
        # UpdateSurveySettings does not validate the form; SurveySettingsForm
        # inherits title/tos presence from QuestionnaireForm, which is not
        # what is being updated here, so only the settings are applied.
        result = Decidim::Surveys::Admin::UpdateSurveySettings.call(form, @survey, @user)
        raise Error.new(:invalid_file, ["survey.settings: could not be saved"]) unless result.has_key?(:ok)

        @survey.reload
        raise Error.new(:invalid_file, ["survey.settings: could not be saved"]) unless settings.all? { |k, v| same_setting?(@survey.public_send(k), v) }
      end

      def same_setting?(stored, value)
        return stored.to_i == value.to_i if stored.is_a?(Time) || value.is_a?(Time)
        return Canonical.translated(stored) == Canonical.translated(value) if value.is_a?(Hash) || stored.is_a?(Hash)

        stored == value
      end

      def save_questions!(plan)
        # 0. Display conditions are recreated in pass 2.
        Decidim::Forms::DisplayCondition.where(decidim_question_id: @ids.questions.map(&:id)).destroy_all

        # 1. Questions, response options and matrix rows.
        forms = plan.map { |entry| question_form(entry, conditions: false) }
        # Deleted questions: from_model keeps their rows/options so the form
        # validations (matrix presence, max_choices) pass; their conditions
        # were already destroyed in step 0.
        forms += (@deleted_questions.uniq.map do |record|
          Decidim::Forms::Admin::QuestionForm.from_model(record).tap do |form|
            form.deleted = true
            form.display_conditions = []
          end.with_context(form_context)
        end)
        run_update_questions!(forms, "questions")

        @counts[:created] = plan.count { |e| e.record.nil? }
        @counts[:updated] = plan.count(&:record)
        @counts[:deleted] = @deleted_questions.uniq.size

        # Map plan entries to the records created in pass 1.
        questions = @questionnaire.questions.reload.includes(:response_options, :matrix_rows).to_a
        raise Error.new(:invalid_file, ["questions: unexpected count after saving"]) unless questions.size == plan.size

        plan.each_with_index do |entry, i|
          entry.record = questions[i]
          options = questions[i].response_options.sort_by(&:id)
          entry.options.each_with_index { |option, j| option.record = options[j] }
          entry.rows.each_with_index { |row, j| row.record = questions[i].matrix_rows[j] }
        end

        # 2. Display conditions (they need the ids of pass 1).
        return if plan.all? { |entry| entry.conditions.empty? }

        forms = plan.map do |entry|
          Decidim::Forms::Admin::QuestionForm.from_model(entry.record).tap do |form|
            form.display_conditions = condition_params(entry).map do |params|
              Decidim::Forms::Admin::DisplayConditionForm.from_params(params).with_context(form_context)
            end
          end.with_context(form_context)
        end
        run_update_questions!(forms, "display_conditions", plan)
      end

      def run_update_questions!(question_forms, step, plan = nil)
        form = Decidim::Forms::Admin::QuestionsForm.new(questions: question_forms).with_context(form_context)
        result = Decidim::Forms::Admin::UpdateQuestions.call(form, @questionnaire)
        return if result.has_key?(:ok)

        errors = []
        question_forms.each_with_index do |qf, i|
          errors.concat(qf.errors.full_messages.map { |m| "#{step} (question at position #{qf.position || i}): #{m}" })
          qf.display_conditions.each_with_index do |cf, j|
            next if cf.errors.empty?

            path = plan ? plan[i].conditions[j].path : "question #{i}"
            errors.concat(cf.errors.full_messages.map { |m| "#{path}: #{m}" })
          end
        end
        raise Error.new(:invalid_file, errors.presence || ["#{step}: could not be saved"])
      end
    end
  end
end
