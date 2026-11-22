# Decidim "the Decidim way" — developer reference (verified against v0.31.5 and v0.32.2 source)

All paths are relative to the tag root (`~/.cache/decidim-src/v0.31.5` or `v0.32.2`). Paths that are the same in both versions are given once.
Small upstream examples worth copying: **decidim-pages** (smallest: 1 model), **decidim-blogs** (CRUD, trash, events, cells, API), **decidim-debates** (permissions split admin/public, mutations in 0.32).

## 1. Architecture and concepts

| Concept | What it is | Source |
|---|---|---|
| Organization | Tenant (one per host). Everything is scoped to it | `decidim-core/app/models/decidim/organization.rb` |
| Participatory space | Container registered with `Decidim.register_participatory_space` (processes, assemblies, conferences, initiatives) | `decidim-participatory_processes/lib/decidim/participatory_processes/participatory_space.rb` |
| Component | Pluggable feature inside a space (`Decidim::Component` row + manifest) | `decidim-core/lib/decidim/component_manifest.rb` |
| Resource | Model registered via `component.register_resource`, includes `Decidim::Resourceable` | `decidim-core/lib/decidim/resource_manifest.rb` |
| Taxonomy | Tree of up to 3 levels plus taxonomy filters per space type, replacing types, scopes, areas and categories | `docs/modules/develop/pages/taxonomies.adoc` |

**Taxonomies:** the docs say "Taxonomies replaces the old concepts of 'Participatory process types', 'Assemblies types', 'Scopes', 'Areas' and 'Categories'" (`docs/modules/develop/pages/taxonomies.adoc:5`).
- The migrations are dated 2024-07 to 2024-12 (`decidim-core/db/migrate/20240704115429_create_decidim_taxonomies.rb` and later). The 0.31 docs treat v0.30.x as the previous series (`guide_data_migrations.adoc:3`), so taxonomies were introduced in 0.30. No in-tree text says "0.30" explicitly.
- The legacy models (`category.rb`, `scope.rb`, `area.rb`) and the `Decidim::HasCategory` and `Decidim::Scopable` concerns still exist in **both** versions. For example, `decidim-debates/app/models/decidim/debates/debate.rb` still includes `HasCategory` and `ScopableResource`. New code should use `Decidim::Taxonomizable` together with `Decidim::HasTaxonomyFormAttributes` (form) and the `:taxonomy_filters` setting.
- Migrate old data with `bin/rails decidim:taxonomies:make_plan` and then `decidim:taxonomies:import_plan[file]` (`decidim-core/lib/tasks/decidim_taxonomies.rake`).

### Component manifest (`Decidim.register_component`) — real example `decidim-pages/lib/decidim/pages/component.rb`
```ruby
Decidim.register_component(:pages) do |component|
  component.engine = Decidim::Pages::Engine
  component.admin_engine = Decidim::Pages::AdminEngine
  component.icon = "media/images/decidim_pages.svg"; component.icon_key = "pages-line"
  component.permissions_class_name = "Decidim::Pages::Permissions"
  component.query_type = "Decidim::Pages::PagesType"
  component.on(:create) { |instance| Decidim::Pages::CreatePage.call(instance) { on(:invalid) { raise "Cannot create page" } } }
  component.register_stat :pages_count do |components, start_at, end_at| ... end
  component.settings(:global) { |s| s.attribute :announcement, type: :text, translated: true, editor: true }
  component.settings(:step)   { |s| s.attribute :announcement, type: :text, translated: true, editor: true }
  component.register_resource(:page) { |r| r.model_class_name = "Decidim::Pages::Page" }
  component.exports :pages do |e| e.collection { |ci| Decidim::Pages::Page.where(component: ci) }; e.include_in_open_data = true; e.serializer Decidim::Pages::PageSerializer end
  component.seeds { |participatory_space| require "decidim/pages/seeds"; Decidim::Pages::Seeds.new(participatory_space:).call }
end
```
Attributes of `ComponentManifest` (`decidim-core/lib/decidim/component_manifest.rb`):
- `engine`, `admin_engine`, `name`, `query_type` (default `"Decidim::Core::ComponentType"`)
- `data_portable_entities` (Array) and `newsletter_participant_entities` (Array)
- `stylesheet`, `admin_stylesheet`, `icon`, `icon_key`
- `actions` (Array[String]): the actions that can be gated by an authorization (verification) in the admin "Permissions" screen
- `permissions_class_name` (default `"Decidim::DefaultPermissions"`), `component_form_class_name` (default `"Decidim::Admin::ComponentForm"`)
- `serializes_specific_data`, `specific_data_serializer_class_name`, `specific_data_importer_class_name`

Methods on the manifest:
- `on(event, &blk)`, `run_hooks(event, context = nil)`
- `seeds`, `settings(:global|:step)`, `exports`, `imports`
- `register_stat(name, opts)`. Options seen in blogs: `primary:`, `priority:`, `icon_name:`, `tooltip_key:`, `tag:`.
- `register_resource(name)`

Example of `data_portable_entities` and `newsletter_participant_entities`: `decidim-debates/lib/decidim/debates/component.rb:11-13`.

**ResourceManifest attributes** (`decidim-core/lib/decidim/resource_manifest.rb`):
- `model_class_name`, `card` (cell path), `template`, `reported_content_cell`
- `searchable` (bool), `actions` (resource-level permission actions, e.g. blogs `%w(like comment)`), `permissions_class_name`, `content_blocks_scope_name`, `route_name`

**Settings types** (`decidim-core/lib/decidim/settings_manifest.rb:107`): `boolean integer integer_with_units string float text array enum select scope time taxonomy_filters`.
- Options: `default`, `required`, `translated`, `editor`, `choices` (array or lambda), `readonly` (lambda), `preview`.
- i18n keys: `decidim.components.<name>.settings.<global|step>.<attr>`, plus the `_help` and `_readonly` variants (`docs/.../components.adoc`).

**Hooks actually fired** (grep of `run_hooks` in `decidim-admin/app/commands` and the space duplicate commands; identical in both versions):

| Hook | Argument | Fired from |
|---|---|---|
| `:create` | component | `decidim-admin/app/commands/decidim/admin/create_component.rb` (runs inside the transaction) |
| `:update` | component | `update_component.rb` |
| `:publish` / `:unpublish` | component | `publish_component.rb` / `unpublish_component.rb` |
| `:permission_update` | a single hash `{component:, resource:}` | `update_component_permissions.rb` |
| `:duplicate` | a single hash `{new_component:, old_component:}` | `duplicate_{participatory_process,assembly,conference}.rb` |

`:destroy`, `:before_destroy` and `:copy` are **never** run by core (see Gotchas).

### Participatory space manifest — `decidim-participatory_processes/lib/decidim/participatory_processes/participatory_space.rb`
- Fields: `model_class_name`, `content_blocks_scope_name`, `participatory_spaces { |org| query }`, `query_type`, `query_finder`, `query_list`, `permissions_class_name`, `breadcrumb_cell`, `register_resource`.
- `context(:public) { engine, layout, helper }` and `context(:admin) { engine, layout }`.
- Also: `exports` (+ `open_data_serializer`), `register_on_destroy_account`, `seeds`, `stats`/`register_stat` (`decidim-core/lib/decidim/participatory_space_manifest.rb`).

## 2. Generators, install, in-app modules

**Generator:** `decidim --component NAME` (`decidim-generators/exe/decidim`), which runs `Decidim::Generators::ComponentGenerator` (`decidim-generators/lib/decidim/generators/component_generator.rb`).
- Options: `--destination_folder` (default `decidim-module-NAME`) and `--external` (adds a Gemfile and runs `bundle install`). It asks for a description and a security email.
- It creates:
  - `lib/decidim/NAME/{engine,admin_engine,admin,component,version}.rb` and `lib/decidim/NAME/test/factories.rb`
  - `app/{controllers,helpers,models,permissions}` skeletons and `app/packs/...`
  - `config/assets.rb`, `config/locales/en.yml`, `config/i18n-tasks.yml`
  - specs, a CI workflow, and a `Rakefile` with `test_app` / `development_app`
- `decidim APP_NAME` generates an app (options in `exe/decidim --help`).

**Engine conventions** (from `decidim-blogs/lib/decidim/blogs/engine.rb`):
- `isolate_namespace Decidim::Blogs` and public `routes do ... end`
- Initializers:
  - `register_icons` (`Decidim.icons.register(...)`)
  - `data_migrate` (adds `db/data`)
  - `add_cells_view_paths` (`Cell::ViewModel.view_paths << .../app/cells` and `.../app/views`)
  - `shakapacker.assets_path` (`Decidim.register_assets_path`)
  - `authorization_transfer`

**AdminEngine:** `isolate_namespace Decidim::Blogs::Admin`, `paths["db/migrate"] = nil`, `paths["lib/tasks"] = nil`, `def load_seed = nil` (`decidim-blogs/lib/decidim/blogs/admin_engine.rb`).

**Assets** (`decidim-blogs/config/assets.rb`):
```ruby
Decidim::Shakapacker.register_path("#{base_path}/app/packs")
Decidim::Shakapacker.register_entrypoints(decidim_blogs: "#{base_path}/app/packs/entrypoints/decidim_blogs.js")
```
In views: `append_javascript_pack_tag "decidim_blogs"` and `append_stylesheet_pack_tag` (`decidim-blogs/app/views/decidim/blogs/posts/show.html.erb`).

**Entry file:** `lib/decidim/blogs.rb` requires `admin`, `api`, `engine`, `admin_engine` and `component`. The manifest is registered on require.

**Installing a module in an app** (`decidim-conferences/README.md`):
1. Add `gem 'decidim-conferences'` to the Gemfile.
2. Run `bundle`.
3. Run `bundle exec rails decidim_conferences:install:migrations`.
4. Run `bundle exec rails db:migrate`.

Data migrations: `bin/rails data:migrate` (`docs/.../guide_data_migrations.adoc`). The upgrade flow is `bin/rails decidim:upgrade`, then `db:migrate`, then `data:migrate` (`v0.32.2/RELEASE_NOTES.md`).

**Module inside the app repo:** `gem "decidim-debates", path: "decidim-debates"`, i.e. a sub-folder gem (`docs/modules/customize/pages/code.adoc`; `docs/.../modules.adoc` mentions the decidim-barcelona sub-folder approach). The generator's `--destination_folder` lets you place it there directly.

## 3. Controller → Form → Command (→ Query) → Permissions

**Controller (frontend)** — `decidim-blogs/app/controllers/decidim/blogs/posts_controller.rb`. It inherits from `Decidim::Blogs::ApplicationController`, which inherits from `Decidim::Components::BaseController`.
```ruby
def create
  enforce_permission_to :create, :blogpost
  @form = form(Decidim::Blogs::PostForm).from_params(params, current_component: current_component)
  CreatePost.call(@form) do
    on(:ok)      { |new_post| flash[:notice] = I18n.t(...); redirect_to post_path(new_post) }
    on(:invalid) { flash.now[:alert] = I18n.t(...); render action: "new", status: :unprocessable_entity }
  end
end
def edit; enforce_permission_to :update, :blogpost, blogpost: post; @form = form(PostForm).from_model(post); end
```
- Form factory (`decidim-core/app/controllers/concerns/decidim/form_factory.rb` in 0.31; `decidim-core/lib/decidim/form_factory.rb` in 0.32): `form(K).instance(ctx)`, `.from_model(m, ctx)`, `.from_params(params, ctx)`.
- The factory context is `{current_organization, current_component, current_user, current_participatory_space}`.
- The admin controller inherits `Decidim::<Mod>::Admin::ApplicationController` → `Decidim::Admin::Components::BaseController` and uses `participatory_space_admin_layout`.

**Decidim::Form** (`decidim-core/app/forms/decidim/form.rb` < `decidim-core/lib/decidim/attribute_object/form.rb`):
- Delegates `current_organization/current_user/current_component/current_participatory_space` to the context. Aliases: `organization`, `component`, `participatory_space`.
- `mimic(:name)` sets the param key and `model_name`. `from_params` reads `params[mimicked_model_name]`.
- `map_model(model)` is called by `from_model`.
- `attribute :x, Integer|String|Boolean|Array[...]|Decidim::Attributes::RichText|...` (types in `lib/decidim/attributes/`).
- `include TranslatableAttributes` then `translatable_attribute :title, String`. This creates `title` (a Hash) plus `title_<locale>` (`decidim-core/lib/decidim/translatable_attributes.rb:38`). Validate with `validates :title, translatable_presence: true`.
- Common mixins: `Decidim::HasTaxonomyFormAttributes`, `Decidim::AttachmentAttributes` (`attachments_attribute :documents`), `Decidim::HasUploadValidations` (`decidim-blogs/app/forms/decidim/blogs/post_form.rb`).

**Decidim::Command** (`decidim-core/lib/decidim/command.rb`, Wisper):
- `Klass.call(*args) { on(:ok) {...}; on(:invalid) {...} }`. The block is `instance_eval`'d, and missing methods are forwarded to the caller (the controller).
- Inside the command: `broadcast(:ok, obj)` / `broadcast(:invalid)`, plus `transaction { }`.
- `with_events(with_transaction: false) { }` publishes `ActiveSupport::Notifications` `"<class.underscore.parameterize('.')>:before/:after"` with `event_arguments`, which you must implement. Example: `decidim-proposals/app/commands/...` lines 39-57.
- Base classes in `decidim-core/lib/decidim/commands/`: `CreateResource`, `UpdateResource`, `DestroyResource`, `SoftDeleteResource`, `RestoreResource`, `ResourceHandler`, `HookError`.

```ruby
class CreatePost < Decidim::Commands::CreateResource          # decidim-blogs/app/commands/decidim/blogs/create_post.rb
  fetch_form_attributes :author, :taxonomizations
  protected
  def resource_class = Decidim::Blogs::Post
  def extra_params = { visibility: "all" }                   # forwarded to traceability (action log visibility)
  def attributes = super.merge(title: { I18n.locale => form.title }, component: form.current_component)
  def run_after_hooks = send_notification
end
```
`CreateResource#call` does: `invalid?` → `transaction { run_before_hooks; create_resource (Decidim.traceability.create!); run_after_hooks }` → `broadcast(:ok, resource)`. It rescues `RecordInvalid` and `HookError` and broadcasts `:invalid`.

**Decidim::Query** (`decidim-core/lib/decidim/query.rb`):
- Subclass it, implement `query`, and conventionally add `self.for(...)`.
- Queries compose with `|`/`merge`; the class is Enumerable.
- Example: `decidim-core/app/queries/decidim/public_components.rb`.

**Permissions:**
- `Decidim::DefaultPermissions` (`decidim-core/app/permissions/decidim/default_permissions.rb`) provides:
  - `initialize(user, permission_action, context)`
  - private `allow!`, `disallow!`, `toggle_allow(cond)`
  - `authorized?(action, resource: nil)`, which runs `ActionAuthorizer` (the verification gate)
  - `context`, `current_settings`, `component_settings`, `component`, `space`
- `PermissionAction` (`decidim-core/app/models/decidim/permission_action.rb`) has `action/scope/subject`. Calling `allow!` after a `disallow!` raises `PermissionCannotBeDisallowedError`. If nothing sets a state, `allowed?` raises `PermissionNotSetError`, which `allowed_to?` turns into `false`.
- Controller API (`decidim-core/app/controllers/concerns/decidim/needs_permission.rb`): `enforce_permission_to(action, subject, extra_ctx)` raises `Decidim::ActionForbidden`, which redirects with a flash. `allowed_to?` and `admin_allowed_to?` are view helpers. The permission context holds `current_settings, component_settings, current_organization, current_component, share_token`, plus any extra keys.
- Chains, built by `inject` (each class receives the previous `permission_action`):
  - Frontend, `decidim-core/app/controllers/decidim/components/base_controller.rb`: scope `:public`, chain `[component manifest permissions_class, space manifest permissions_class, Decidim::Admin::Permissions, Decidim::Permissions]`.
  - Admin, `decidim-admin/app/controllers/decidim/admin/components/base_controller.rb`: scope `:admin`, chain `[component, space, Decidim::Admin::Permissions]`.
- **One class handles both scopes.** Pattern in `decidim-debates/app/permissions/decidim/debates/permissions.rb`:
```ruby
def permissions
  return Decidim::Debates::Admin::Permissions.new(user, permission_action, context).permissions if permission_action.scope == :admin
  return permission_action if permission_action.scope != :public
  return permission_action if permission_action.subject != :debate
  case permission_action.action
  when :create then toggle_allow(authorized?(:create) && current_settings&.creation_enabled? && component.participatory_space.can_participate?(user))
  ...
  end
  permission_action
end
```
- **Verification-gated UI:**
  - View helper: `action_authorized_link_to :create, new_debate_path, permissions_holder: current_component, class: ..., data: { "redirect_url" => ... }` (`decidim-debates/app/views/decidim/debates/debates/index.html.erb:14`). Also `action_authorized_button_to`, `logged_link_to` and `logged_button_to` (`decidim-core/lib/decidim/action_authorization_helper.rb`).
  - Controller/helper: `action_authorized_to(action, resource:, permissions_holder:)` returns an `ActionAuthorizer` status (`decidim-core/lib/decidim/action_authorization.rb`, included in `Decidim::ApplicationController`).
  - The actions must appear in `component.actions` (component level) or `resource.actions` (resource level, which also needs the model to return `allow_resource_permissions?` true).

## 4. Model concerns (blogs Post is the reference: `decidim-blogs/app/models/decidim/blogs/post.rb`)

| Concern | File | Notes |
|---|---|---|
| `Decidim::Resourceable` | `decidim-core/lib/decidim/resourceable.rb` | linked resources (`link_resources`, `linked_resources`), `visible?`, `allow_resource_permissions?`, `permissions` |
| `Decidim::HasComponent` + `component_manifest_name "blogs"` | `decidim-core/lib/decidim/has_component.rb` | gives `component`, `participatory_space`, `organization` |
| `Decidim::Traceable` (+ `Decidim::Loggable`) | `decidim-core/lib/decidim/traceable.rb` | `has_paper_trail`. Write with `Decidim.traceability.create!/create/update!/perform_action!(action, resource, user, extra)` (`decidim-core/app/services/decidim/traceability.rb`). Log visibility is one of `admin-only` (default), `public-only`, `private-only`, `all` (`decidim-core/app/services/decidim/action_logger.rb:39`) |
| Admin log presenter | `decidim-blogs/app/presenters/decidim/blogs/admin_log/post_presenter.rb` | `Decidim::<Mod>::AdminLog::<Model>Presenter < Decidim::Log::BasePresenter`, overrides `action_string` and `diff_fields_mapping`. Model: `def self.log_presenter_class_for(_log)`. i18n `decidim.<mod>.admin_log.<model>.<action>` |
| `Decidim::Searchable` | `decidim-core/lib/decidim/searchable.rb` | `searchable_fields({participatory_space: {component: :participatory_space}, A: :title, D: :body, datetime: :created_at}, index_on_create: ->(r){...}, index_on_update: ...)` plus `resource.searchable = true` |
| `Decidim::Comments::CommentableWithComponent` | `decidim-comments/lib/decidim/comments/commentable_with_component.rb` | overrides: `comments_have_alignment?`, `comments_have_votes?`, `users_to_notify_on_comment_created`, `user_allowed_to_comment?` |
| `Decidim::Followable` | `decidim-core/lib/decidim/followable.rb` | `follows`, `followers` |
| `Decidim::Reportable` | `decidim-core/lib/decidim/reportable.rb` | scopes `reported/hidden/not_hidden`. Override `reported_attributes`, `reported_searchable_content_extras` |
| `Decidim::Authorable` / `Decidim::Coauthorable` | `decidim-core/lib/decidim/authorable.rb`, `coauthorable.rb` | `authored_by?`, `official?`, scopes `with_official_origin` etc. |
| `Decidim::Publicable` | `decidim-core/lib/decidim/publicable.rb` | `published`/`unpublished` scopes, `published?`, `publish!`, `unpublish!` (column `published_at`) |
| `Decidim::Likeable` | `decidim-core/lib/decidim/likeable.rb` | `has_many :likes` (counter cache `likes_count`), `liked_by?`. **There is no `Endorsable` in 0.31 or 0.32** ("Rename Endorsement to Like", #14666, in the 0.31.0.rc1 CHANGELOG) |
| `Decidim::SoftDeletable` | `decidim-core/lib/decidim/soft_deletable.rb` | `acts_as_paranoid` (paranoia gem) plus `deleted_at_desc`. Admin side: `include Decidim::Admin::HasTrashableResources` and implement `trashable_deleted_resource_type/_resource/_collection`. Routes: `get :manage_trash, on: :collection; member { patch :soft_delete; patch :restore }` (`decidim-blogs/lib/decidim/blogs/admin_engine.rb`) |
| `Decidim::Taxonomizable` | `decidim-core/lib/decidim/taxonomizable.rb` | `taxonomies`, through `taxonomizations` |
| Others | `decidim-core/lib/decidim/` | `HasAttachments`, `HasAttachmentCollections`, `HasReference`, `TranslatableResource` (`translatable_fields :title, :body`), `FilterableResource`, `Randomable`, `DownloadYourData`, `NewsletterParticipant`, `Amendable`, `Fingerprintable`, `Geocodable` |
| **Hashtaggable** | — | **Does not exist in either version.** Hashtags were removed in 0.31 (#14803, #14868, #14921 in `v0.31.5/CHANGELOG.md`). 0.31 still has `content_parsers/tag_parser.rb` |

## 5. Events and notifications

```ruby
Decidim::EventsManager.publish(                                   # decidim-blogs/app/commands/decidim/blogs/create_post.rb
  event: "decidim.events.blogs.post_created",
  event_class: Decidim::Blogs::CreatePostEvent,
  resource:,
  followers: resource.participatory_space.followers)               # also: affected_users:, extra: {}, force_send: false
```
- Signature (`decidim-core/app/services/decidim/events_manager.rb`): `publish(event:, resource:, event_class: Decidim::Events::BaseEvent, affected_users: [], followers: [], extra: {}, force_send: false)`.
- Only names matching `/^decidim\.events\./` are picked up by `EventPublisherJob` (queue `:events`). That job enqueues `EmailNotificationGeneratorJob` and `NotificationGeneratorJob`.
- The job **skips** the event unless the resource, space and component are published, or `force_send` is set (`decidim-core/app/jobs/decidim/event_publisher_job.rb`).
- Event class: `class CreatePostEvent < Decidim::Events::SimpleEvent; def resource_text = translated_attribute(resource.body); end`.
- `SimpleEvent` (`decidim-core/lib/decidim/events/simple_event.rb`):
  - The i18n scope is the event name (with a `.<user_role>` suffix when `event_has_roles?`).
  - `i18n_attributes :foo` adds interpolations.
  - Notification actions: `action_cell` and `action_data`.
- Required keys under `decidim.events.blogs.post_created`: `email_subject`, `email_intro`, `email_outro`, `notification_title` (`decidim-blogs/config/locales/en.yml:130`). Default interpolations include `resource_path`, `resource_title`, `resource_url` and `participatory_space_title`.
- Recipients are filtered by the user's `notification_types` ("all" / "followed-only" / "own-only") (`docs/.../notifications.adoc`).
- Custom setting: `Decidim.notification_settings(:close_meeting_reminder) { |ns| ns.settings_area = :administrators }` (`decidim-meetings/lib/decidim/meetings/engine.rb:142`; API in `decidim-core/lib/decidim/core.rb:877`).

## 6. Cells, layouts, admin form helpers

- Cards in the redesign: `card`, `card_l`, `card_s`, `card_g` and `card_metadata` cells in `decidim-core/app/cells/decidim/`. **There is no `card_m` cell in either version.**
- Render a card with `card_for post, size: :l` (`decidim-core/app/helpers/decidim/card_helper.rb`; `decidim-blogs/app/views/decidim/blogs/posts/index.html.erb:36`). `CardCell` dispatches to the resource's `resource.card`.
- Resource cell pattern (`decidim-blogs/app/cells/decidim/blogs/post_cell.rb`): `PostCell < Decidim::ViewModel` picks `post_s` / `post_g` / `post_l` from `options[:size]`. `PostLCell < Decidim::CardLCell` overrides `metadata_cell`, `has_description?` and `resource_image_url`. Metadata cells: `post_metadata_cell.rb`.
- Frontend layout: `layout "layouts/decidim/application"` (`decidim-core/app/controllers/decidim/application_controller.rb:58`). Page wrappers live in `decidim-core/app/views/layouts/decidim/shared/` (`_layout_center`, `_layout_item`, `_layout_two_col`), e.g. `render layout: "layouts/decidim/shared/layout_center", locals: { columns: 8 }`.
- Admin layouts: `decidim-admin/app/views/layouts/decidim/admin/`. Component admin uses `participatory_space_admin_layout`.
- Admin form (`decidim-blogs/app/views/decidim/blogs/admin/posts/{new,_form}.html.erb`):
  - `decidim_form_for(@form, html: { class: "form-defaults form new_post" })`
  - `form.translated :text_field, :title`
  - `form.translated :editor, :body, lines: 30`
  - `form.datetime_field`
  - `filter_taxonomy_items_select_field form, :taxonomies, filter`
  - Wrapper markup: `item_show__header`, `item__edit-form`, `item__edit-sticky`
- Other FormBuilder methods (`decidim-core/lib/decidim/form_builder.rb`): `translated`, `translated_one_locale`, `editor`, `upload`, `attachment`, `data_picker`. 0.32 adds `mention_options`.

## 7. Jobs and mailers

- Queues used by `queue_as` (0.31.5):
  - `default`, `exports`, `events`, `user_report`, `translations`, `newsletter`
  - `delete_inactive_participants`, `vote_reminder`, `spam_analysis`, `reminders`
  - `newsletters_opt_in` (0.31 only), `mailers`, `conference_diplomas`, `close_meeting_reminder`
- The generated `config/sidekiq.yml` lists these queues plus `block_user` (`decidim-generators/lib/decidim/generators/app_templates/sidekiq.yml.erb`, identical in both versions). **Add your own queue there** if you use a new one.
- Module jobs: `decidim-blogs/app/jobs/decidim/blogs/{application_job,publish_post_job}.rb`.
- Mailers: inherit `Decidim::ApplicationMailer` (`LocalisedMailer`, `MultitenantAssetHost`, org SMTP/from). Wrap in `with_user(user) { mail(to:, subject:) }`. Example: `decidim-meetings/app/mailers/decidim/meetings/registration_mailer.rb`.

## 8. GraphQL API

- **Component type:** `component.query_type = "Decidim::Blogs::BlogsType"`. `BlogsType < Decidim::Core::ComponentType` with `graphql_name "Blogs"`, plus `field :posts, PostType.connection_type, connection: true` and `field :post` (`decidim-blogs/lib/decidim/api/blogs_type.rb`).
  - Resolve lists with `Decidim::Core::ComponentListBase.new(model_class: Post).call(object, {filter:, order:}, context)`.
  - Resolve single items with `Decidim::Core::ComponentFinderBase`.
- **Resource type:** `PostType < Decidim::Api::Types::BaseObject` implementing `Decidim::Comments::CommentableInterface`, `Core::AttachableInterface`, `AuthorableInterface`, `FollowableInterface`, `TraceableInterface`, `LikeableInterface`, `TimestampsInterface`.
  - Authorization: `def self.authorized?(object, context)` with `allowed_to?(:read, :blogpost, object, context)`.
  - Field types: `Decidim::Core::TranslatedFieldType` and `Decidim::Core::DateTimeType` (`decidim-blogs/lib/decidim/api/post_type.rb`).
- **Registration:** types are autoloaded in `lib/decidim/blogs/api.rb`. They are registered as orphan types automatically from all manifests' `query_type` (`decidim-api/lib/decidim/api.rb`, `orphan_types`). `ComponentInterface.resolve_type` returns `obj.manifest.query_type.constantize`.
- **Mutations:**
  - Register with `Decidim::MutationRegistry.instance.register(Decidim::Debates::DebatesMutationType)` in an initializer `before: "decidim_api.graphiql"`.
  - The union resolves `"Decidim::#{Mod}::#{Mod}MutationType"` (`decidim-api/lib/decidim/api/component_mutation_type.rb`).
  - Mutation classes are `< Decidim::Api::Types::BaseMutation` with `argument`, `resolve` (they build a form with `form(...)` and call a command) and `authorized?`, which raises `Decidim::Api::Errors::MutationNotAuthorizedError` (`v0.32.2/decidim-debates/lib/decidim/api/mutations/close_debate_type.rb`).
  - In 0.31.5 only proposals registers mutations. In 0.32.2 debates, meetings and proposals do.

## 9. Testing

- `spec/spec_helper.rb`: `require "decidim/dev"`, set `ENV["ENGINE_ROOT"]`, `Decidim::Dev.dummy_app_path = File.expand_path(File.join("..", "spec", "decidim_dummy_app"))`, then `require "decidim/dev/test/base_spec_helper"` (`decidim-blogs/spec/spec_helper.rb`).
- Dummy app: `bundle exec rake test_app`, which is an alias for `decidim:generate_external_test_app` (`decidim-generators/lib/decidim/generators/component_templates/Rakefile`; `decidim-dev/lib/tasks/generators.rake`). It generates `spec/decidim_dummy_app` with locales en,ca,es and `--demo`. Use `development_app` for a seeded dev app (`--queue=sidekiq`).
- Factories:
  - Put them in `lib/decidim/<mod>/test/factories.rb`, which requires `decidim/core/test/factories` and `decidim/participatory_processes/test/factories`.
  - Example: `factory :post_component, parent: :component do manifest_name { :blogs } ... end` (`decidim-blogs/lib/decidim/blogs/test/factories.rb`).
  - `spec/factories.rb` just requires that file.
- Shared contexts and examples:
  - Component system specs: `include_context "with a component"` plus `let(:manifest_name) { "blogs" }` and `visit_component`. Admin variants: `"when managing a component as an admin"` and `"... as a process admin"` (`decidim-dev/lib/decidim/dev/test/rspec_support/component_context.rb`).
  - Permissions: `"permission is not set"`, `"delegates permissions to"` (`.../permissions_shared_examples.rb`).
  - Events: `include_context "when a simple event"`, then `it_behaves_like "a simple event"`, `"a simple event email"`, `"a simple event notification"` (`decidim-core/lib/decidim/core/test/shared_examples/simple_event.rb`; usage in `decidim-blogs/spec/events/decidim/blogs/create_post_event_spec.rb`).
  - Many more in `decidim-core/lib/decidim/core/test/shared_examples/`: `admin_log_presenter_examples`, `authorable`, `coauthorable`, `publicable`, `reportable`, `resourceable`, `likeable`, `has_taxonomies`, `softdeleteable_components_examples`, `searchable_results_examples`, ...
- Spec layout in blogs: `spec/{cells,commands,controllers,events,forms,models,permissions,services,system,types}`.

## 10. Data migrations and seeds

- Data migrations (`docs/modules/develop/pages/guide_data_migrations.adoc`, available since 0.31.0):
  - Files go in `db/data/YYYYMMDDHHMMSS_name.rb` and are generated with `bin/rails g data_migration name` inside the engine.
  - Run with `bin/rails data:migrate` and check with `data:migrate:status`.
  - Hook them up in the engine:
```ruby
initializer "your_gem_name.data_migrate", after: "decidim_core.data_migrate" do
  DataMigrate.configure { |c| c.data_migrations_path << root.join("db/data").to_s }
end
```
  - The docs say plain DB migrations or rake tasks remain the preferred approach until v0.33.
- Seeds:
  - Declare them with `component.seeds { |participatory_space| ... }`, typically `class Seeds < Decidim::Seeds` (`decidim-blogs/lib/decidim/blogs/seeds.rb`).
  - Helpers: `slow_seeds?` (env `SLOW_SEEDS`), `number_of_records`, `organization`, `admin_user`, `create_attachments!`.
  - Create the component with `Decidim::Component.create!(name: Decidim::Components::Namer.new(locales, :pages).i18n_name, manifest_name: :pages, published_at: Time.current, participatory_space:)` (`decidim-pages/lib/decidim/pages/seeds.rb`).
  - Use `Decidim::Faker::Localized` for i18n content.

## 0.31.5 vs 0.32.2 differences (dev-relevant, verified)

| Area | 0.31.5 | 0.32.2 |
|---|---|---|
| Ruby (`.ruby-version`) | 3.3.4 | 3.4.7 |
| Component lifecycle docs | `components.adoc` says "Valid hook names are :create and :destroy" (wrong) | New "Life Cycle" section listing create/publish/unpublish/update/permission_update/duplicate. The CHANGELOG has "Remove unused component hook - before_destroy". blogs/debates dropped `on(:before_destroy)` |
| pages manifest | `component.on(:copy)` (never fired) | `component.on(:duplicate)` |
| blogs resource actions | `%w(like comment)` | `%w(like comment vote_comment)` ("configurable restrictions for 'vote comment' action") |
| FormFactory location | `decidim-core/app/controllers/concerns/decidim/form_factory.rb` | `decidim-core/lib/decidim/form_factory.rb` (moved so the API can use it) |
| `enforce_permission_to` | public, logs debug in development | moved under `protected` in `NeedsPermission` |
| Component breadcrumb | `set_component_breadcrumb_item` | `set_breadcrumb_items` (component, parent, item) |
| Private space users | `ParticipatorySpacePrivateUser`, `HasPrivateUsers` | `Decidim::ParticipatorySpace::Member`, `decidim-core/lib/decidim/participatory_space/has_members.rb` ("Rename private participants to members"); private/transparent became "access mode" |
| URLs | no locale segment | `scope "/:locale"` in `decidim-core/config/routes.rb`. `EngineRouter` rewrites the admin locale segment |
| GraphQL write API | proposals mutations only | create/update/close mutations for debates, meetings and proposals. `PermissionNotSetError` rescue removed from `PostType.authorized?` |
| Modules | `decidim-sortitions` present | sortitions removed. Collaborative drafts, UserGroup fields, ParticipatoryProcessType and AssembliesType models removed |
| `Decidim::Seeds` | — | adds `SEEDS_CONFIG` (slow/fast counts) |
| Docs | `docs/.../api.adoc` | `docs/.../api/{index,core-concepts,authentication}.adoc` + `reference/` |

Unchanged in both versions: `DefaultPermissions`, `EventsManager`, `SimpleEvent`, `Traceability`, `CreateResource`, `Decidim::Form`, `ActionAuthorization`, `ComponentManifest` (no diff), `settings_manifest` TYPES.

## Gotchas

1. **The `:destroy`, `:before_destroy` and `:copy` hooks never run.** No core code calls `run_hooks` with them. In 0.31.5 blogs and debates still register `on(:before_destroy)`, pages registers `:copy`/`:destroy`, and the generator template suggests `before_destroy`; all of these are dead. Use `:duplicate` for copies. Components are soft-deleted (trash).
2. **Hook context is one positional argument.** `:duplicate` and `:permission_update` receive a single Hash (`hook.call(context)`), so write `on(:duplicate) { |ctx| ctx[:new_component] }`. The 0.32 docs example `|new_component, old_component|` does not match the code. `Decidim::Component` has no `run_hooks`; call `component.manifest.run_hooks(...)`.
3. **The generated component does not set `permissions_class_name`.** The generator template omits it, so the default `Decidim::DefaultPermissions` is used and returns early (its `target_scope` is `""`). The generated `Admin::Permissions` is not wired until you set `component.permissions_class_name` and delegate admin scope to it, as debates does.
4. **Once a permission is disallowed, it cannot be allowed later.** `allow!` after `disallow!` raises, and an unset state means forbidden. Always `return permission_action` early for subjects or scopes you do not own, so later classes in the chain can decide.
5. **Unpublished resources get no notifications.** Events are silently dropped when the resource, component or space is unpublished, unless `force_send: true`. Event names must start with `decidim.events.`.
6. **`decidim:upgrade` ignores custom engines for migrations.** It only installs migrations from a hard-coded `FROM` list (`decidim-core/lib/tasks/decidim_tasks.rake`). Custom modules need `bin/rails decidim_<mod>:install:migrations`.
7. **Use `Decidim::Likeable`, not `Endorsable`, in 0.31+.** Also there is no `Hashtaggable` and no `card_m` cell (the cells doc still mentions "Card M"). Taxonomies are the supported classification: do not add new categories, scopes or areas.
8. **Set `resource.searchable = true` and include `Searchable`** with `searchable_fields`. Re-index on component publish/unpublish with `UpdateSearchIndexesJob` / `RemoveSearchIndexesJob`, as in `blogs/component.rb`.
9. **Resource-level permissions need two things.** The `resource.actions` list in the manifest, and the model must return `true` from `allow_resource_permissions?`.
10. **Register cell view paths and icons in the engine.** If you skip `Cell::ViewModel.view_paths << ...`, cells will not find their templates. Register icons with `Decidim.icons.register`.
