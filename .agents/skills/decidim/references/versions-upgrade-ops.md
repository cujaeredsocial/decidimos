# Decidim ops reference: versions, upgrades, operations (verified 2026-11-15)

Sources: `S31` = `~/.cache/decidim-src/v0.31.5`, `S32` = `~/.cache/decidim-src/v0.32.2` (paths are relative to the tag root).
`GH:vX` = GitHub release body (`gh api repos/decidim/decidim/releases/tags/vX --jq .body`). The full upgrade notes are only in GH releases.
The `RELEASE_NOTES.md` in both trees is an empty template, apart from the "Verification code security hardening" section in S32.
`CL31.8` = `https://raw.githubusercontent.com/decidim/decidim/v0.31.8/CHANGELOG.md`.

## 1. Version matrix

| | 0.31.5 (current app) | 0.32.2 (latest) | Source |
|---|---|---|---|
| Ruby (gemspec) | `~> 3.3.0` (.ruby-version 3.3.4) | `~> 3.4.0` (.ruby-version 3.4.7) | `decidim.gemspec`, `decidim-core/decidim-core.gemspec`, `.ruby-version` |
| Node | `>=22.14.0`, npm `>=9.6.7` (.node-version 22.14.0) | same | `package.json` "engines", `.node-version` |
| Rails | `~> 7.2.0, >= 7.2.2.2` (lock 7.2.2.2) | `~> 8.1.0` (lock 8.1.3) | `decidim-core/decidim-core.gemspec`, `Gemfile.lock` |
| pg gem | `~> 1.5.0` | `>= 1.5, < 1.7` | core gemspec |
| Shakapacker | 8.3.0 | 9.7.0 | `Gemfile.lock` |
| Image processing | ImageMagick (mini_magick 4.13) | **libvips** (+ImageMagick listed) | `docs/modules/install/pages/manual.adoc` |
| PostgreSQL (docs) | "17.4+" (dev guide) | "17.4+" | `docs/modules/install/pages/manual.adoc` l.6 |

Official matrix (`docs/modules/install/partials/version_matrix.adoc`, S32): `develop` = Ruby 3.4.7 / Node 22.14.x;
`v0.31` = 3.3.4 / 22.14.x ("Bug fixes and security updates"); `v0.30` = 3.3.4 / 18.17.x; `v0.29` = 3.2.2 / 18.17.x ("Not maintained").
Note: S32 `manual.adoc` still says "Ruby 3.3.4", which is stale. The gemspec `~> 3.4.0` is authoritative.

Releases (RubyGems API): 0.31.5 2026-05-12 · 0.31.6 07-06 · 0.31.7 07-30 · 0.31.8 10-22 · 0.32.0 07-02 · 0.32.1 07-30 · 0.32.2 10-22.
**Docker images** (`decidim/decidim` on Docker Hub and ghcr.io, checked 2026-11-15): tags exist up to **0.31.6** only. There are NO 0.31.7, 0.31.8 or 0.32.x images.

## 2a. Patch upgrade 0.31.5 → 0.31.8

The steps are the same for every patch (GH:v0.31.6, v0.31.7, v0.31.8). Do them one release at a time ("make sure your installation is on v0.31.N-1"):
```console
# Gemfile: gem "decidim", "0.31.8"; gem "decidim-dev", "0.31.8"
bundle update decidim
bin/rails decidim:upgrade
bin/rails db:migrate
bin/rails data:migrate
```
None of them has one-time tasks, scheduled-task changes or API changes ("Nothing" in each section).
- **0.31.6**: bug fixes. Authorization revocation now runs in the background (#16806). System org form fix for short name / single locale (#17144). No security section.
- **0.31.7**: bug fixes. **Fixes the env var for the inactive-user deletion period (#17276)**. In 0.31.5, `decidim-core/lib/decidim/core.rb:298` reads `DELETE_INACTIVE_USERS_AFTER_DAYS`. The fix makes it read `DECIDIM_DELETE_INACTIVE_USERS_AFTER_DAYS`, the documented name, which is what S32 reads. Also: pins rack-proxy for shakapacker (#17375), ensures the JWT secret for devise-jwt (#17346), and removes nicknames from notification emails (#17225). No security section.
- **0.31.8**: **security release**. It fixes GHSA-q43x-7468-g2qq, GHSA-mv8c-4cp9-p6xx, GHSA-rvf7-fphg-fc2f, GHSA-2pjf-v779-h293 and GHSA-mgfc-r9h4-2r3q. The same five are fixed in 0.32.2. Details are embargoed; the notes say "February 22th 2026", which looks like a typo for 2027. Related hardening in CL31.8:
  - Verification lock-in moved to the DB (#17685), with new env vars `DECIDIM_VERIFICATION_MAX_FAILED_ATTEMPTS`=5, `DECIDIM_VERIFICATION_UNLOCK_IN`=30 (minutes) and `DECIDIM_VERIFICATION_CODE_EXPIRY_MINUTES`=10. Rack::Attack limits verification confirmation to 10 requests/min/IP. Custom authorization handlers that use session-based attempt tracking must be reviewed.
  - "Harden access to resources in API" (#17916), commentable-type validation in GraphQL (#17677), action-log sanitization (#17680), magic-bytes validation for image uploads (#17878).
  - `enqueue_after_transaction_commit` in ActiveJob (#17875).
  - Adds pagination on Members pages and renames "Steps" to "Phases" in processes (#17533).
- 0.31.5 itself already contains the fixes for CVE-2026-45330, -45376, -45377, -45415, -45378, -45572, -45573, -45086 and -45414 (GH:v0.32.0 §0).

## 2b. Minor upgrade 0.31.x → 0.32.2 (GH:v0.32.0, then v0.32.1 and v0.32.2)

Prerequisite: at least v0.31.0 with all of its steps applied (GH:v0.32.0). Docs say to go one minor version at a time (`docs/modules/install/pages/update.adoc`).
**Rails 7.2 → 8.1. Back up `SECRET_KEY_BASE` and `tmp/local_secret.txt`.**
Exact command block from GH:v0.32.0 §1.3 (Ruby 3.4.7 first, via rbenv or "changing the decidim docker image to use ruby:3.4.7"):
```console
sudo apt install libvips libvips-tools
bundle update decidim                       # Gemfile: "0.32.0" (then 0.32.1, 0.32.2)
bin/rails decidim:upgrade
sed -i "s/config\.load_defaults [0-9]\+\.[0-9]\+/config.load_defaults 8.1/g" config/application.rb
wget https://raw.githubusercontent.com/decidim/decidim/refs/heads/release/0.32-stable/decidim-core/lib/decidim/shakapacker/shakapacker.yml -O config/shakapacker.yml
bin/rails db:migrate
bin/rails decidim:upgrade:encryption                    # SHA1 -> SHA256 re-encrypt (authorizations, initiative votes)
echo "/public/sw.js*" >> .gitignore
bin/rails decidim:upgrade:remove_deleted_users_left_data
bin/rails decidim:upgrade:fix_deleted_members_follows
sed -i 's/Env.new("SMTP_STARTTLS_AUTO").to_boolean_string/Env.new("SMTP_STARTTLS_AUTO", true).present?/' config/environments/production.rb
bin/rails data:migrate                                   # includes organization short_name data migration (#15729)
```
Breaking changes and notes (GH:v0.32.0 §2–5, CHANGELOG `S32/CHANGELOG.md` 0.32.0.rc1 "Removed" l.708+):

| Change | Impact |
|---|---|
| Rails 8.1, `load_defaults 8.1` | Custom code and tests may break. **Azure ActiveStorage removed** (the `azure` block is commented out in generator `storage.yml`; use the azure-blob gem) |
| Locale always in the URL (`/en/processes/...`) (#14432) | Old URLs redirect. Hard-coded paths in tests/custom code must use route helpers |
| Shakapacker 9.7.0 | Replace `config/shakapacker.yml`. Key `webpack_loader` becomes `javascript_transpiler` + `assets_bundler: "webpack"`. `dev_server.https` removed (webpack-dev-server 5.2.2, #15534) |
| ImageMagick → **libvips** (#15670) | Install libvips in the image. **`.ico` favicons no longer supported** |
| `decidim-sortitions` removed (#15563) | Drop the gem. `decidim:choose_target_plugins` no longer lists `decidim_sortitions` (`decidim-core/lib/tasks/decidim_tasks.rake` diff) |
| Collaborative drafts removed (#16184) | Use proposal co-authorship. Meeting polls deprecated (removal date TBD) |
| User Group DB fields/tables dropped (#16022) | `decidim_user_group_id` columns and `decidim_user_group_memberships` are gone (groups were deprecated in 0.31) |
| Also removed | `ParticipatoryProcessType`/`AssembliesType` models (#16448, #16476), `enable_participatory_space_filters`, legacy banner images |
| `ActiveSupport::Configurable` dropped (#16366) | Custom `Decidim::X.configure` blocks: use `Decidim.force_ssl = true` style / `mattr_accessor` |
| Filter params (rack 3, #16103) | `with_any_taxonomies[4]` becomes `with_any_taxonomies => {"4" => [""]}` |
| SMTP_STARTTLS_AUTO bug (#16491) | Fixed with the sed above. **The decidimos app already has the fixed line** (`config/environments/production.rb:72`) |
| Rake rename | 0.31.5 has `decidim:upgrade:fix_deleted_private_follows`; 0.32.2 has `decidim:upgrade:fix_deleted_members_follows`. New: `decidim:upgrade:encryption`, `decidim_initiatives:upgrade:encryption`. Removed: `decidim:upgrade:active_storage_migrations:migrate_inline_images_to_active_storage` |
| Env vars | New `DECIDIM_VERIFICATION_*` (3). `API_SCHEMA_MAX_ALIASES` dropped from the env doc (`docs/modules/configure/pages/environment_variables.adoc` diff) |
| Scheduled tasks | "Nothing" changed in 0.32 |

`decidim-ai`, `decidim-collaborative_texts`, `decidim-elections` and `decidim-demographics` **already exist in 0.31.5** (dirs in S31); they are not new in 0.32.
0.32.1: no special steps. 0.32.2: the same security fixes and verification hardening as 0.31.8 (GH:v0.32.2).

What `bin/rails decidim:upgrade` runs (`decidim-core/lib/tasks/decidim_tasks.rake`): `choose_target_plugins` (sets `FROM`) → `decidim:upgrade_app` (deletes `public/favicon.ico`) → `decidim:upgrade:shakapacker_npm` (npm reinstalls shakapacker) → `railties:install:migrations` → `decidim:upgrade:migrations` → `decidim:upgrade:shakapacker` (removes `bin/yarn`, copies `config/webpack/*`, runs npm install of `@decidim/*`) → `decidim_api:generate_docs`.
So it **writes app files and needs node/npm and the network**. Run it in a dev checkout and commit the result, not in the prod container. It does NOT overwrite an existing `config/shakapacker.yml`, which is why the notes use `wget`.
`decidim:update` is an alias. Prior 0.31.0 one-time tasks are in `~/.cache/decidim-src/dl/RN-v0.31.0.md` §1.3.

## 3. Operations

### Scheduled tasks (crontab from `docs/modules/install/pages/index.adoc` "Scheduled tasks"; identical in 0.31.5 and 0.32.2)
| Cron | Task |
|---|---|
| `0 0 * * *` | `decidim:delete_download_your_data_files` (honours `DECIDIM_DOWNLOAD_YOUR_DATA_EXPIRY_TIME`, default 7 days) |
| `2 0 * * *` | `decidim:open_data:export` (enqueues `OpenDataJob` per org) |
| `3 0 * * *` | `decidim_meetings:clean_registration_forms` |
| `4 0 * * *` | `decidim:reminders:all` |
| `5 0 * * *` | `decidim:mailers:notifications_digest_daily` |
| `5 0 * * 6` | `decidim:mailers:notifications_digest_weekly` |
| `*/15 * * * *` | `decidim_participatory_processes:change_active_step` |
| `0 0 * * *` | `decidim:participants:delete_inactive_participants` (optional `[days]` arg, must be ≥ `DECIDIM_MINIMUM_INACTIVITY_PERIOD_IN_DAYS`=30) |
| initiatives | `30 7` `decidim_initiatives:check_published` · `0 7` `decidim_initiatives:check_validating` · `0 8` `decidim_initiatives:notify_progress` |
Doc form: `cd /app && RAILS_ENV=production bundle exec rake <task>`.
**These task names do NOT exist:** `decidim:metrics:all` (Metrics were removed in 0.31.0, #14387) and `decidim:delete_data_portability_files` (the current name is `delete_download_your_data_files`). There is no `decidim:upgrade` cron.
Inactive-user env vars (S32 `decidim-core/lib/decidim/core.rb:291-300`): `DECIDIM_DELETE_INACTIVE_USERS_AFTER_DAYS`=365, `..._FIRST_WARNING_DAYS_BEFORE`=30, `..._LAST_WARNING_DAYS_BEFORE`=7. In 0.31.5–0.31.6 the first one is read as `DELETE_INACTIVE_USERS_AFTER_DAYS`.

### ActiveJob / Sidekiq
- Decidim is backend-agnostic (`docs/modules/services/pages/activejob.adoc`). The generator's `--queue sidekiq` writes `config/sidekiq.yml` and sets `config.active_job.queue_adapter = ENV['QUEUE_ADAPTER'] if ENV['QUEUE_ADAPTER'].present?` in production. It also mounts `/sidekiq` for admins (`decidim-generators/lib/decidim/generators/app_generator.rb:228-272`). Sidekiq needs Redis: `REDIS_URL`, default localhost:6379.
- **Set `QUEUE_ADAPTER=sidekiq` in prod and run a separate `bundle exec sidekiq` process**; otherwise jobs (emails!) use the Rails default adapter.
- Queues (`app_templates/sidekiq.yml.erb`, the same in both versions and the same as the app's `config/sidekiq.yml`): mailers 4, vote_reminder, reminders, default, delete_inactive_participants, newsletter, newsletters_opt_in, conference_diplomas, events, translations, user_report, block_user (2 each), exports, close_meeting_reminder, spam_analysis (1 each). `queue_as` usage in S32 also covers all of these (newsletters_opt_in is no longer used by any job in 0.32.2).

### System admin and organizations
- `bin/rails decidim_system:create_admin` prompts for email, password and confirmation via `$stdin.noecho`, so it **needs a TTY** (`decidim-system/lib/tasks/decidim_system.rake`).
- Then log in at `/system`, create the organization, and set its host to the bare domain (no protocol or port). The org admin receives an invitation email, so SMTP must work (`docs/modules/install/pages/index.adoc` "Deploy", `empty-database.adoc`).
- Seeds don't run in production unless `SEED=true`.

### Storage / SMTP / logs (env-driven, `docs/modules/configure/pages/environment_variables.adoc`)
- `STORAGE_PROVIDER` = `local` | `s3` | `gcs` (`azure` only via a third-party gem in 0.32). `local` uses Disk `Rails.root/storage` (`app_templates/storage.yml`).
- S3 vars: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_BUCKET`, `AWS_REGION`, `AWS_ENDPOINT`, `AWS_PUBLIC`. A non-local provider requires CSP and CORS changes (`docs/modules/services/pages/activestorage.adoc`).
- SMTP: `SMTP_ADDRESS`, `SMTP_PORT`(587), `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_DOMAIN`, `SMTP_AUTHENTICATION`(plain), `SMTP_STARTTLS_AUTO`(true). It can also be overridden per organization in `/system` (`docs/modules/services/pages/smtp.adoc`).
- Logs: `RAILS_LOG_TO_STDOUT` (any value) sends logs to stdout, which is what you want in Docker/CapRover. `RAILS_LOG_LEVEL` (debug|info|warn|error|fatal). `RAILS_SERVE_STATIC_FILES` for Docker without nginx.
- Other env vars: `SECRET_KEY_BASE`, `DECIDIM_FORCE_SSL` (auto|true|false; use false behind a TLS-terminating proxy), `VAPID_PUBLIC_KEY`/`VAPID_PRIVATE_KEY` (generate with `bin/rails decidim:pwa:generate_vapid_keys`), and `MAPS_*`.

### Production checklist (`docs/modules/install/pages/checklist.adoc`, the same in both)
- Domain, languages, time zone (changing it later shifts dates), SSL (Let's Encrypt, HTTP→HTTPS, CAA, TLS 1.2/1.3), SMTP, geolocation, backups of DB + uploads.
- Authorizations, publish your AGPL code, review env vars and the initializer, ActiveJob backend, ActiveStorage, social providers.
- No default users or passwords. Scheduled tasks, a staging environment (disable SMTP and anonymise data), exception tracking (Sentry etc.).
- Content: ToS page slug must be `terms-of-service`.

### Useful rake tasks (from `*/lib/tasks/**/*.rake`, verified in 0.32.2; the 0.31.5 differences are noted in §2b)
| Task | Purpose |
|---|---|
| `decidim:locales:sync_all` / `decidim:locales:rebuild_search` | Sync org locales with the initializer / rebuild the search index |
| `decidim:upgrade:clean:invalid_records` (+ `:searchable_resources`, `:notifications`, `:follows`, `:action_logs`) | Clean orphaned data |
| `decidim:upgrade:attachments_cleanup` | Clean orphaned blobs |
| `decidim:right_to_be_forgotten` | Delete users by ID from a CSV |
| `decidim:verifications:revoke:<handler>` | Revoke all authorizations of a handler (dynamic per engine) |
| `decidim:taxonomies:{make_plan,import_plan,import_all_plans,reset_counters}` | Taxonomies import |
| `decidim:robots:replace`, `decidim:common_passwords:update`, `decidim:check_users_newsletter_opt_in` | Misc |
| `decidim:ai:spam:{create_reporting_user,train_application_database,load_application_dataset,reset}` | decidim-ai spam model |
| `decidim_api:generate_docs`, `decidim:shakapacker:install`, `decidim:webpacker:npm_install`, `decidim:procfile:install` | Build/dev |
| `decidim_proposals:upgrade:*`, `decidim_surveys:upgrade:fix_survey_permissions`, `decidim_initiatives:upgrade:fix_broken_pages`, `decidim_comments:upgrade:participatory_process_in_comments` | Module data fixes |

## 4. Docker-only workflow (no Ruby on host)

Docs: `docs/modules/develop/pages/docker.adoc` points to github.com/decidim/docker. The official image only has core modules ("cannot use modules with this image", `install/pages/index.adoc` §B). The generator template is `FROM decidim/decidim:<version>` (`app_templates/Dockerfile.erb`), and the compose template runs `bundle exec puma` with `.:/app` bind-mounted (`app_templates/docker-compose.yml.erb`).
```console
docker compose exec app bin/rails db:migrate                    # also data:migrate
docker compose exec -it app bin/rails decidim_system:create_admin   # needs a TTY
docker compose exec app bin/rails c
docker compose exec app bin/rails assets:precompile           # RAILS_ENV=production in prod
docker compose exec app bundle exec rake decidim:reminders:all # cron: call from host crontab or a scheduler container
docker compose run --rm app bundle update decidim             # in a dev checkout, then commit Gemfile.lock/package*.json
docker compose logs -f app
```
The decidimos app's `bin/docker-entrypoint` runs `./bin/rails db:prepare` automatically when the CMD is `./bin/rails server`. It does NOT run `data:migrate` or the one-time `decidim:upgrade:*` tasks.

## 5. Debugging
- Error pages: Decidim sets `config.exceptions_app = Decidim::Core::Engine.routes` (`decidim-core/lib/decidim/core/engine.rb:335`). `/404` maps to `errors#not_found` and `/500` to `errors#internal_server_error` (`decidim-core/config/routes.rb:206-207`), and the generator deletes `public/404.html` and `public/500.html`. There is **no** `develop/pages/*error*.adoc` doc in either version.
- letter_opener_web: mounted at `/letter_opener` **only in development**, with `delivery_method = :letter_opener_web` (`decidim-generators/lib/decidim/generators/install_generator.rb:114-127`; `install/pages/empty-database.adoc`).
- Sidekiq UI: `/sidekiq` (admins only). Turn up logging with `RAILS_LOG_LEVEL=debug` + `RAILS_LOG_TO_STDOUT=1`.
- Dev perf: `RAILS_BOOST_PERFORMANCE=true` (generator `dev_performance_config`). Profiling and Grafana docs: `docs/modules/develop/pages/profiling.adoc`, `grafana.adoc`.

