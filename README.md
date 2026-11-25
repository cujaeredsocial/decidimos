# decidimos

Plataforma de participación ciudadana orientada al entorno cubano, basada en [Decidim](https://github.com/decidim/decidim) 0.31: democracia participativa y gobierno abierto, de código abierto.

## Desarrollo

Levantar el entorno (app, PostgreSQL, Redis y pgweb):

```sh
docker compose -f docker-compose.dev.yml up -d
```

Crear la base de datos la primera vez:

```sh
docker compose -f docker-compose.dev.yml exec app bundle exec rails db:create db:migrate db:seed assets:precompile
```

- App: http://localhost:3000
- pgweb: http://localhost:3000/pgweb, solo para administradores con sesión iniciada.
- Los usuarios de prueba que crea `db:seed` tienen la contraseña `decidim123456789`.

Usa siempre `docker-compose.dev.yml` en desarrollo. `docker-compose.yml` es el de producción.

## Producción

Se despliega de dos formas:

- **CapRover** (`captain-definition`): construye la imagen con el `Dockerfile`, que instala las gemas y compila los assets.
- **Docker Compose** (`docker-compose.yml`): usa la imagen `decidim/decidim:0.31.5` con el código montado. Tras actualizar el código hay que ejecutar `bundle install` y `bundle exec rails assets:precompile` dentro del contenedor.

Con Docker Compose:

1. Revisa el `.env` (variables abajo).
2. Levanta los servicios:

   ```sh
   docker compose up -d
   ```

La app escucha en el puerto 3000. Los datos de PostgreSQL y los archivos subidos están en `/srv/decidimos/`.

### Variables de entorno

Van en el `.env`, o en las variables de entorno de la app si se usa CapRover. Reinicia la app después de cambiarlas.

| Variable | Obligatoria | Para qué |
| --- | --- | --- |
| `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_USERNAME`, `DATABASE_PASSWORD`, `DATABASE_URL` | Sí | Conexión a PostgreSQL |
| `DB_ADMIN_USER`, `DB_ADMIN_PASSWORD` | Sí con Docker Compose | Usuario y contraseña de pgweb |
| `ENZONA_CLIENT_ID` | Sí, para verificar con EnZona | Client ID de la aplicación OAuth de EnZona (XETID) |
| `ENZONA_CLIENT_SECRET` | Sí, para verificar con EnZona | Client secret de esa aplicación |
| `ENZONA_SITE` | No | Servidor de identidad de EnZona. Por defecto `https://identity.enzona.net` |
| `ENZONA_SSL_VERIFY` | No | `true` para verificar el certificado TLS de EnZona. Por defecto no se verifica |
| `ENZONA_CALLBACK_PATH` | No | URL de retorno que se envía a EnZona: `/users/auth/xetid/callback` (por defecto) o `/verified_account/authorization/callback` |

### EnZona

EnZona se usa como alternativa para verificar que un participante es una persona real (`lib/decidim_cujae/verified_account.rb`).
Una cuenta se verifica de dos formas:

- El participante inicia sesión en EnZona desde *Mi cuenta → Autorizaciones*. Una identidad de EnZona solo puede verificar una cuenta.
- Un administrador lo verifica a mano en *Admin → Participantes → Verificación de cuentas*.

#### Actualizar desde la versión con login por EnZona

Las versiones anteriores usaban EnZona (`xetid`) para iniciar sesión, configurado en `/system`. Tras desplegar esta versión, haz una copia de la base de datos y ejecuta una sola vez:

```sh
bundle exec rails decidim_cujae:verified_account:migrate_from_enzona_login
```

## Puesta en marcha

Después del primer despliegue:

1. Crea un administrador del sistema: `bundle exec rails decidim_system:create_admin`.
2. Entra en `<url de la app>/system` con esas credenciales.
3. Crea una organización. Elige sus idiomas y el idioma por defecto.
4. Pon el host correcto de la organización, incluido el subdominio si lo hay. Si no coincide, la app no funciona.
5. En "Autorizaciones disponibles", marca "Cuenta verificada (Con varios pasos)".
6. Completa el resto del formulario y guárdalo.
7. En los permisos de cada componente, exige "Cuenta verificada" en las acciones que deban hacer solo personas verificadas.

## Cuentas de usuario

- **Confirmación:** un administrador puede confirmar a mano las cuentas nuevas en *Admin → Participantes → Confirmación de cuentas*.
- **Verificación:** confirmar una cuenta no verifica la identidad de la persona. La verificación es un paso aparte (ver [EnZona](#enzona)).
