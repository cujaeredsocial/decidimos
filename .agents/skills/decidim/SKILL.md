---
name: decidim
description: Use when working on any Decidim application or module (Gemfile has gem "decidim") - implementing features, authentication/OmniAuth/OAuth providers, verifications/authorization handlers, permissions, components, participatory spaces, overrides of views/cells, initializer/ENV config, upgrades between Decidim versions, deployment, rake tasks, or answering "how does Decidim do X". Also for errors raised inside decidim-* gems.
---

# Decidim

## Core principle

**The source code of the exact Decidim version the app runs is the only source of truth.** Not memory, not blog posts, not the docs of another version. Decidim changes APIs between minor versions (0.31 → 0.32: Rails 8.1, locale in URLs, private spaces → members, `Endorsable` → `Likeable` in 0.31). Anything you have not seen in that tree is unverified.

## Workflow (every Decidim task)

1. **Pin the version.** Run `bash ~/.claude/skills/decidim/scripts/decidim-src.sh <app_dir>`. It reads `Gemfile.lock`, shallow-clones that tag into `~/.cache/decidim-src/v<ver>` if missing, and prints the path (`$SRC` below), the **latest patch of the app's minor series** and the latest stable release, all from RubyGems. If the app is behind on patch level, say so explicitly: patches carry security fixes (GHSA). Take the version facts from this output. The `~/.cache` contents only show what was downloaded, not what was released.
2. **Check whether Decidim already does it** (table below + `grep -rn` in `$SRC`). Configuring a built-in feature beats writing code. Write custom code only after confirming no built-in feature covers the need, and say which one you ruled out.
3. **Read the reference** in `references/` for the area (map below). Then open the cited `$SRC` files: references are a map to the source, not a substitute for reading it.
4. **Find the closest upstream implementation and mirror it.** Small modules make good templates: `decidim-pages`, `decidim-blogs`, `decidim-debates`. Example handlers live in `$SRC/decidim-generators/lib/decidim/generators/app_templates/` (`dummy_authorization_handler.rb`, `verifications_initializer.rb` …). Copy its structure, names, i18n keys and registration.
5. **Verify every identifier before you hand it over.** Each class, method signature, keyword argument, route helper, i18n key path, ENV var, rake task and config option you write must be either:
   - (a) found by grep in `$SRC` at the app's version, or
   - (b) proven by running it in the app (see "Running things").

   If you can't do either, it is a **blocker**: state it as an open question with the exact command that would resolve it. Never present it as fact, and never hide it under "from memory".
6. **Look at the app's own code.** Read `config/initializers/*`, `app/`, `lib/`, `config/locales`, `.env` (names only) and any previous overrides before you change anything, so you extend what exists and don't duplicate it.
7. **Verify the result.** Boot the app or run a runner/test (see "Running things") and report what you actually ran and what it printed.

## Built-in features to check before writing code

| Need | Built-in Decidim feature (verify in `$SRC`) |
|---|---|
| Admins acting for people without device/email (elderly, workshops) | **Impersonation / managed users** (admin → Participants → Impersonate). Needs ≥1 *direct* authorization handler enabled for the org. → `auth-and-verifications.md` §5 |
| Verify identity (CI/DNI, census) and gate actions | **Authorization handler** + component **Permissions** per action; `csv_census` workflow for uploaded census lists → §4 |
| Participate without an account | **Ephemeral authorizations** (exist in 0.31 and 0.32) → §4 |
| Login-only, no self sign-up / only social login | org `users_registration_mode`: `enabled` / `existing` / `disabled` (set in /system) → §2 |
| External SSO (OAuth2/OIDC) | `Decidim.omniauth_providers[:x]` + `OmniAuth::Builder` + enable per org in /system → §3 |
| Session length / remember me | `DECIDIM_EXPIRE_SESSION_AFTER`, `DECIDIM_ENABLE_REMEMBER_ME` → §1 |
| Restrict the whole site to logged-in users | org setting "force users to authenticate" → §7 |
| Roles to see results (surveys, debates) | Space roles: admin / collaborator / moderator / evaluator; org roles: admin / user_manager → §6 |
| Homepage sections, menus, extra HTML | content blocks, `Decidim.menu`, view hooks → `app-customization.md` §3 |

## Reference map (`~/.claude/skills/decidim/references/`)

| File | Use for |
|---|---|
| `auth-and-verifications.md` | Devise, registration modes, sessions, OmniAuth custom providers and callback/matching logic, verification workflows and handlers, conflicts, ephemeral participation, impersonation, roles, private access |
| `app-customization.md` | `Decidim.configure` + ENV table (`Decidim::Env`, no secrets.yml), overriding views/cells/controllers (decorators + `to_prepare`), view hooks, content blocks, menus, Shakapacker/Tailwind/icons/images, i18n overrides, CSP |
| `module-development.md` | component/space manifests, generators, Controller→Form→Command→Permissions flow, model concerns, events/notifications, cells, jobs, GraphQL, testing, data migrations |
| `versions-upgrade-ops.md` | version matrix (Ruby/Rails/Node/PG), patch and minor upgrade steps, breaking changes 0.31→0.32, cron/rake tasks, Sidekiq, storage/SMTP, Docker-only workflow |

These were verified against v0.31.5 and v0.32.2 on 2026-11-15. **On any other version, re-check every cited path in that version's `$SRC`.** Docs for the exact version are in `$SRC/docs/modules/**/pages/*.adoc`. Some docs are stale (they still mention `secrets.yml`); when docs and code disagree, the code wins.

## Searching the source fast

```bash
SRC=$(bash ~/.claude/skills/decidim/scripts/decidim-src.sh . 2>/dev/null | tail -1)
grep -rn "def self.register_workflow\|register_workflow" $SRC/decidim-verifications/lib | head
grep -rn "Decidim::Env.new(\"DECIDIM_" $SRC/decidim-core/lib/decidim/core.rb      # all ENV options
grep -rln "class .*AuthorizationHandler" $SRC --include=*.rb | head               # real examples
grep -rn "authorization_handlers:" -A6 $SRC/decidim-*/config/locales/en.yml | head -20  # real i18n key paths
grep -rn "t(\"\.\|I18n.t(\"decidim\." $SRC/decidim-verifications/app | head          # how keys are looked up
diff -r $SRC/decidim-core/app/views ~/.cache/decidim-src/v<other>/decidim-core/app/views -q  # what changed between versions
```

For a method signature, open the definition (`grep -rn "def nicknamize" $SRC`). Don't infer it from a call site.

## Running things (no Ruby on host is common: use the container)

- Find the service and container names in `docker-compose.yml`, then run `docker compose exec <app> bin/rails runner 'p Decidim.version'`.
- Smoke-test any API before using it, e.g. `bin/rails runner 'p Decidim::UserBaseEntity.method(:nicknamize).parameters'`, `bin/rails routes -g omniauth`, `bin/rails runner 'p Decidim::Verifications.workflows.map(&:name)'`.
- If no runtime is reachable (permission denied, no Docker), say so and fall back to (a) grep evidence for every identifier.

## Output contract when you propose or deliver an implementation

1. **Version line**: app version, latest stable, and any security patch the app lacks.
2. **Built-in check**: which built-in feature(s) you considered and why they do or don't cover the need.
3. **Changes**: files + code, mirroring a named upstream file (`mirrors $SRC/...`).
4. **Evidence table**: each non-trivial identifier → `$SRC` path:line or the command output that proved it.
5. **Open blockers**: each unverified item with the command that settles it. If it's empty, say so.
6. **How to deploy/test**: the exact commands for this app's setup (migrations, `decidim:upgrade`, asset build, restart, enabling in /system or the admin panel).

## Red flags: stop and verify

- "This is how it worked in Decidim 0.2x" or "the docs say": check the code at the app's version.
- Writing `routes.prepend`, monkey-patches or custom controllers before checking for a built-in feature, a view hook or a decorator pattern in `app-customization.md`.
- Inventing an i18n key path, a `/system` checkbox label or a permission action name. Grep for it.
- Giving a fake email, nickname or password scheme without checking `Decidim::User` validations (format, uniqueness per org, strong-password rules: 10 chars, 15 for admins, no name/email inside).
- A component hook such as `on(:destroy)` or `on(:copy)`: core only fires `:create`, `:update`, `:publish`, `:unpublish`, `:permission_update` and `:duplicate`.
- An OmniAuth provider whose email is not verified: Decidim matches accounts by verified email, which opens an account-takeover risk (§3 Gotchas).
- Ending with a list of "from memory, test these" items. Do the tests now, or file them as blockers with exact commands.
