# Formatos de intercambio de encuestas (Decidim)

Este documento define dos formatos JSON:

| Formato | `format` | Propósito |
|---|---|---|
| Definición de encuesta | `decidim.survey` | Crear o actualizar una encuesta (cuestionario, preguntas, opciones, filas de matriz, condiciones). |
| Respuestas de encuesta | `decidim.survey.responses` | Importar o exportar participaciones (respuestas de usuarios) de una encuesta existente. |

Ambos formatos son **simétricos**: lo que exporta el exportador debe poder reimportarse sin pérdida.

## 0. Reglas para quien implemente

1. La fuente de verdad es el código de Decidim en la versión del `Gemfile.lock`. Si cambia la versión, revisa cada ruta citada en la sección 7.
2. No reutilices el import/export nativo para esto:
   - `Decidim::Surveys::DataSerializer` / `DataImporter` (`decidim-surveys/app/serializers/decidim/surveys/`) **omiten `matrix_rows` y `display_conditions`**, solo crean (no actualizan) y vuelcan ids numéricos de la base de datos.
   - `Decidim::Forms::UserResponsesSerializer` exporta texto plano (`"1. ¿Pregunta?" → "texto"`) y no se puede reimportar.
3. Reutiliza los forms y comandos de Decidim para validar y guardar (secciones 3.6 y 4.6). Así las reglas son las mismas que en la interfaz.
4. Ejecuta todo dentro del contenedor de desarrollo (`docker compose -f docker-compose.dev.yml`, contenedor `decidimos-app-1`), nunca contra el compose de producción.
5. Palabras normativas: **DEBE** = obligatorio; **NO DEBE** = prohibido; **PUEDE** = opcional.
6. **Ningún fichero contiene ids numéricos de la base de datos.** Todo elemento existente se identifica con un **UUID calculado a partir de su propio contenido** (sección 5). Un importador que acepte un id numérico (`id`, `user_id`, `question_id`, `session_token`, ...) en el fichero incumple esta especificación.
7. **No hay migración de base de datos.** Los UUID no se guardan en ningún sitio: se calculan cada vez a partir del estado actual de la base de datos (sección 5).

## 1. Modelo de datos interno de Decidim

```
Decidim::Surveys::Survey                    (decidim_surveys_surveys)
  starts_at, ends_at, announcement{locale}, allow_responses, allow_unregistered,
  allow_editing_responses, clean_after_publish, published_at
  └─1:1─ Decidim::Forms::Questionnaire      (decidim_forms_questionnaires)
           title{locale}, description{locale,HTML}, tos{locale,HTML}, salt,
           questionnaire_for (polimórfico: Survey, Meeting, ...)
           └─ Decidim::Forms::Question       (decidim_forms_questions)
                position, question_type, mandatory, body{locale}, description{locale, texto plano},
                max_choices, max_characters (0 = sin límite)
                ├─ ResponseOption            (decidim_forms_response_options)   body{locale}, free_text
                │    SIN columna position: se ordena por id ASC (default_scope)
                ├─ QuestionMatrixRow         (decidim_forms_question_matrix_rows) body{locale}, position
                └─ DisplayCondition          (decidim_forms_display_conditions)
                     condition_question → Question, condition_type (enum entero),
                     response_option?, condition_value{locale}?, mandatory

Respuestas:
Decidim::Forms::Response                    (decidim_forms_responses)  — UNA FILA POR PREGUNTA
  questionnaire, question, user? (nil = anónimo), body, session_token, ip_hash, created_at
  ├─ ResponseChoice                         (decidim_forms_response_choices)
  │    response_option_id, matrix_row_id?, body (COPIA del texto de la opción), custom_body, position
  └─ attachments (Decidim::HasAttachments)  — solo preguntas "files"
```

Todas estas tablas usan **claves primarias enteras secuenciales** y ninguna tiene columna UUID. `Questionnaire#salt` (string aleatorio que se asigna al crear el cuestionario) se usa como parte de la clave para calcular los UUID (sección 5.3).

**Campos traducidos** (`jsonb`): `{ "es": "...", "en": "...", "machine_translations": { "fr": "..." } }`.

**Tipos de pregunta** (`Decidim::Forms::Question::TYPES`):
`short_response`, `long_response`, `single_option`, `multiple_option`, `sorting`, `files`, `matrix_single`, `matrix_multiple`, `separator`, `title_and_description`.

**`condition_type`** (enum en este orden, se guarda como entero 0..4): `responded`, `not_responded`, `equal`, `not_equal`, `match`.

---

## 2. Tipos compartidos

```ts
/** Texto traducido. Las claves son locales de la organización ("es", "en", ...). */
export type Translated = { [locale: string]: string } & {
  /** Solo en exportación. Al importar PUEDE ignorarse. NUNCA entra en el cálculo del UUID. */
  machine_translations?: { [locale: string]: string };
};

/** Igual que Translated, pero el contenido es HTML (rich text). */
export type TranslatedHtml = Translated;

/**
 * Clave legible definida por el autor del fichero. Solo sirve para referencias DENTRO de un
 * fichero decidim.survey (no se guarda en el servidor). Patrón OBLIGATORIO: /^[a-z0-9_]{1,64}$/
 * (no admite guiones, así que nunca se confunde con un UUID).
 */
export type Key = string;

/**
 * UUID versión 8 (RFC 9562), calculado por el servidor a partir del contenido (sección 5.3).
 * Patrón: /^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
 */
export type Uuid = string;

/**
 * Referencia a un elemento dentro de un fichero decidim.survey:
 *  - Key  → `key` declarada en ese mismo fichero
 *  - Uuid → elemento existente en el servidor
 * Se distinguen por el patrón. NO existe referencia por id numérico.
 * En los ficheros de respuestas solo se usa Uuid (sección 4).
 */
export type Ref = Key | Uuid;

/** Firma de integridad del fichero completo (sección 5.6). */
export interface Integrity {
  algorithm: "HMAC-SHA256";
  canonicalization: "JCS";            // RFC 8785, sin el campo `integrity`
  key_id: string;                     // versión de la clave, para poder rotarla
  signature: string;                  // base64url
}
```

---

## 3. Formato `decidim.survey` (definición de encuesta)

### 3.1 Esquema TypeScript

```ts
export interface SurveyExchangeFile {
  format: "decidim.survey";
  version: 1;
  decidim_version?: string;           // informativo, ej. "0.31.5"
  exported_at?: string;               // ISO 8601
  /** Solo informativo. NO se usa para elegir el destino (ver SEC2). */
  source?: { host?: string };
  /**
   * "replace" (default): el fichero es la verdad. Lo que exista en la BD y no venga en el fichero se borra.
   * "merge": se actualiza lo que coincide por uuid, se crea lo nuevo y solo se borra lo que lleva deleted: true.
   */
  mode?: "replace" | "merge";
  survey: SurveyData;
  /** Presente en todo fichero exportado. Opcional al importar; si viene, DEBE ser válida. */
  integrity?: Integrity;
}

export interface SurveyData {
  /**
   * Huella de la versión exportada (sección 5.4). Al importar, si viene, DEBE coincidir con la
   * huella ACTUAL de la encuesta destino; si no coincide, alguien la cambió después del export
   * y el import se rechaza (error "stale_reference").
   */
  uuid?: Uuid;
  settings?: SurveySettings;
  questionnaire: QuestionnaireData;
}

export interface SurveySettings {
  starts_at?: string | null;
  ends_at?: string | null;
  allow_responses?: boolean;
  allow_unregistered?: boolean;
  allow_editing_responses?: boolean;
  clean_after_publish?: boolean;
  announcement?: TranslatedHtml;
}

export interface QuestionnaireData {
  title: Translated;                  // OBLIGATORIO en el locale por defecto
  description?: TranslatedHtml;
  tos: TranslatedHtml;                // OBLIGATORIO en el locale por defecto
  /** El índice en el array ES la position (0..n-1). No existe campo position. */
  questions: Question[];
}

interface QuestionBase {
  key: Key;                           // único en todo el fichero
  /** Elemento existente tal como estaba al exportar. Si falta, el elemento es nuevo. */
  uuid?: Uuid;
  deleted?: boolean;                  // solo con mode "merge"
  mandatory?: boolean;                // default false
  max_characters?: number;            // entero >= 0; 0 = sin límite; aplica a body y a free_text
  display_conditions?: DisplayCondition[];
}

interface WithBody {
  body: Translated;                   // OBLIGATORIO en el locale por defecto
  description?: Translated;           // texto plano (no HTML)
}

export interface TextQuestion extends QuestionBase, WithBody {
  question_type: "short_response" | "long_response";
}
export interface FilesQuestion extends QuestionBase, WithBody {
  question_type: "files";
}
export interface SingleChoiceQuestion extends QuestionBase, WithBody {
  question_type: "single_option" | "sorting";
  response_options: ResponseOption[];
}
export interface MultipleChoiceQuestion extends QuestionBase, WithBody {
  question_type: "multiple_option";
  response_options: ResponseOption[];
  max_choices?: number | null;        // null = sin límite; si existe: entero > 1 y <= response_options.length
}
export interface MatrixQuestion extends QuestionBase, WithBody {
  question_type: "matrix_single" | "matrix_multiple";
  response_options: [ResponseOption, ...ResponseOption[]]; // columnas, al menos 1
  matrix_rows: [MatrixRow, ...MatrixRow[]];                // filas, al menos 1
  max_choices?: number | null;        // solo matrix_multiple; se aplica a cada fila
}
export interface TitleAndDescription extends QuestionBase, WithBody {
  question_type: "title_and_description";
}
export interface Separator extends QuestionBase {
  question_type: "separator";         // sin body
}

export type Question =
  | TextQuestion | FilesQuestion | SingleChoiceQuestion | MultipleChoiceQuestion
  | MatrixQuestion | TitleAndDescription | Separator;

export interface ResponseOption {
  key: Key;                           // único dentro de su pregunta
  uuid?: Uuid;
  deleted?: boolean;
  body: Translated;
  free_text?: boolean;                // añade un campo de texto libre ("Otro: ...")
}

export interface MatrixRow {
  key: Key;                           // único dentro de su pregunta
  uuid?: Uuid;
  deleted?: boolean;
  body: Translated;                   // position = índice en el array
}

interface ConditionBase {
  uuid?: Uuid;
  deleted?: boolean;
  condition_question: Ref;            // OTRA pregunta de este mismo cuestionario
  /** true = condición obligatoria (AND). false = basta con que se cumpla una de las no obligatorias (OR). */
  mandatory?: boolean;
}

export type DisplayCondition =
  | (ConditionBase & { condition_type: "responded" | "not_responded" })
  | (ConditionBase & {
      condition_type: "equal" | "not_equal";
      response_option: Ref;           // opción de condition_question
    })
  | (ConditionBase & {
      condition_type: "match";
      condition_value: Translated;    // regex sin distinción de mayúsculas, por locale (ver SEC10)
    });
```

### 3.2 Reglas de validación (DEBE)

| # | Regla | Origen en Decidim |
|---|---|---|
| S1 | `questionnaire.title` y `questionnaire.tos` presentes en el locale por defecto de la organización. | `Admin::QuestionnaireForm` |
| S2 | `question_type` ∈ `Question::TYPES`. | `Admin::QuestionForm` |
| S3 | `body` presente en el locale por defecto, salvo en `separator` y en elementos con `deleted: true`. | `QuestionForm#requires_body?` |
| S4 | Matrices: `matrix_rows` y `response_options` no vacíos. | `QuestionForm` |
| S5 | `max_choices`: solo en `multiple_option` / `matrix_multiple`; entero > 1 y <= número de opciones. | `QuestionForm`, `admin/forms.js:318` |
| S6 | `max_characters`: entero >= 0. | `QuestionForm` |
| S7 | `response_options` solo en tipos de elección (`single_option`, `multiple_option`, `sorting`, `matrix_*`). `matrix_rows` solo en `matrix_*`. | `admin/forms.js` (`MULTIPLE_CHOICE_VALUES`, `MATRIX_VALUES`) |
| S8 | Condición: `condition_question` existe, es distinta de la propia pregunta y no es `sorting`, `separator` ni `title_and_description`. | `DisplayConditionForm#questions_for_select` |
| S9 | Condición: la pregunta que tiene la condición NO puede estar en la position 0. | `DisplayConditionForm#condition_question_position` |
| S10 | `equal` / `not_equal`: `response_option` obligatorio y pertenece a `condition_question`. | `DisplayConditionForm#valid_response_option?` |
| S11 | `match`: `condition_value` presente en el locale por defecto. | `DisplayConditionForm` |
| S12 | `key` único: preguntas en todo el fichero; opciones y filas dentro de su pregunta. Patrón de `Key` y `Uuid` (sección 2). | propia de este formato |
| S13 | Recomendado (no lo exige Decidim): `condition_question` debería ir antes que la pregunta condicionada. | — |
| S14 | El fichero no contiene campos fuera del esquema (validación con `additionalProperties: false`). En particular, cualquier `id` numérico es un error. | propia de este formato |

### 3.3 Restricciones de actualización (DEBE)

- **U1 — Encuesta con respuestas.** Si `questionnaire.questions_editable?` es `false` (el componente está publicado y ya hay respuestas), las preguntas no se pueden modificar. `UpdateQuestions` en ese caso no hace nada y no avisa. El importador **DEBE** abortar con un error explícito. Solo `title`, `description`, `tos` y `settings` se pueden actualizar.
- **U2 — Orden de opciones.** `ResponseOption` no tiene `position`; se ordena por `id`. Si en un update cambia el orden de las opciones, el importador **DEBE** borrarlas y volver a crearlas (y reasignar las condiciones `equal`/`not_equal` que apunten a ellas). Como el UUID depende del contenido y la posición, las opciones recreadas tendrán UUID nuevos de todas formas.
- **U3 — Emparejamiento.** Para cada elemento del fichero:
  1. Si trae `uuid`: el servidor calcula los UUID **actuales** de todos los elementos del mismo tipo del cuestionario destino (sección 5.3) y busca uno igual. Si no hay ninguno → error `stale_reference` (el elemento cambió o no existe). Nunca se crea un elemento nuevo a partir de un UUID.
  2. Si no trae `uuid`: el elemento es **nuevo** y se crea. Las `key` no se guardan en el servidor, así que no sirven para emparejar entre imports distintos.
- **U4 — Transacción.** Todo el import va en una única transacción. Si falla algo, no se guarda nada.
- **U5 — Trabajar siempre desde un export.** Para modificar una encuesta existente, el flujo correcto es: exportar → editar el fichero → importar. Un fichero escrito a mano sin `uuid`, importado con `mode: "replace"`, **borra y vuelve a crear** todas las preguntas.

### 3.4 Correspondencia con la base de datos

| Campo del fichero | Columna |
|---|---|
| `survey.settings.*` | `decidim_surveys_surveys.*` (mismo nombre) |
| `questionnaire.title/description/tos` | `decidim_forms_questionnaires.title/description/tos` |
| índice en `questions[]` | `decidim_forms_questions.position` |
| `question_type, mandatory, body, description, max_choices, max_characters` | mismas columnas en `decidim_forms_questions` |
| `response_options[].body/free_text` | `decidim_forms_response_options.body/free_text` |
| índice en `matrix_rows[]` | `decidim_forms_question_matrix_rows.position` |
| `display_conditions[].condition_question` (Ref → id) | `decidim_forms_display_conditions.decidim_condition_question_id` |
| `display_conditions[].response_option` (Ref → id) | `decidim_response_option_id` |
| `display_conditions[].condition_type` | `condition_type` (enum entero) |
| `display_conditions[].condition_value` | `condition_value` (jsonb) |
| `uuid` | **No se guarda.** Se calcula (sección 5.3). |
| `key` | **No se guarda.** Solo vive dentro del fichero. |

### 3.5 Algoritmo de importación

1. Comprobar los permisos del usuario sobre la encuesta destino (SEC1). El destino viene del contexto de la petición, no del fichero (SEC2).
2. Validar `format === "decidim.survey"`, `version === 1`, el tamaño (SEC9) y el esquema (S1–S14). Si viene `integrity`, verificarla (5.6).
3. Comprobar U1.
4. Si viene `survey.uuid`, calcular la huella actual del destino (5.4) y compararla. Si difiere → `stale_reference`.
5. Calcular los UUID actuales de todos los elementos del destino y construir en memoria el índice `uuid → registro`.
6. En una transacción:
   1. Actualizar `Survey` (settings) y `Questionnaire` (title, description, tos).
   2. Resolver cada elemento según U3 y crear o actualizar preguntas, opciones y filas, **sin condiciones**. Construir en memoria `key → registro` para este fichero.
   3. Con `mode: "replace"`, borrar las preguntas, opciones y filas que no aparecen en el fichero.
   4. Crear las condiciones, resolviendo `condition_question` y `response_option` (Key → registro de este fichero, Uuid → índice del paso 5).
7. Registrar la acción con `Decidim.traceability` (SEC11) y devolver un informe con la nueva huella y los nuevos UUID (que hay que recalcular, porque el contenido cambió).

### 3.6 Implementación recomendada

Construir un `Decidim::Forms::Admin::QuestionsForm` con los atributos que esperan los forms (`questions[].response_options[]`, `matrix_rows[]`, `display_conditions[]` con `decidim_condition_question_id`, `decidim_response_option_id`, `deleted`) y llamar a `Decidim::Forms::Admin::UpdateQuestions.new(form, questionnaire).call`. Los ids numéricos que necesitan esos forms los obtiene **el servidor** al resolver los UUID; nunca salen del fichero. Las condiciones necesitan ids reales, así que hay que hacer dos pasadas: primero preguntas y opciones, después condiciones.

### 3.7 Ejemplo

Fichero escrito a mano (crea la encuesta; sin UUID ni firma):

```json
{
  "format": "decidim.survey",
  "version": 1,
  "mode": "replace",
  "survey": {
    "settings": { "allow_responses": true, "allow_unregistered": false, "allow_editing_responses": false },
    "questionnaire": {
      "title": { "en": "Fruit Survey" },
      "description": { "en": "<p>Quick questions about your fruit habits.</p>" },
      "tos": { "en": "<p>Your responses will be used only for this survey.</p>" },
      "questions": [
        {
          "key": "favorite_fruit",
          "question_type": "single_option",
          "mandatory": true,
          "body": { "en": "What is your favorite fruit?" },
          "description": { "en": "Choose one" },
          "response_options": [
            { "key": "apple", "body": { "en": "🍎 Apple" } },
            { "key": "mango", "body": { "en": "🥭 Mango" } },
            { "key": "other", "body": { "en": "Other" }, "free_text": true }
          ]
        },
        {
          "key": "why_mango",
          "question_type": "short_response",
          "body": { "en": "Why mango?" },
          "display_conditions": [
            { "condition_question": "favorite_fruit", "condition_type": "equal", "response_option": "mango", "mandatory": true }
          ]
        },
        {
          "key": "rating",
          "question_type": "matrix_single",
          "body": { "en": "Rate each fruit" },
          "matrix_rows": [
            { "key": "apple", "body": { "en": "Apple" } },
            { "key": "mango", "body": { "en": "Mango" } }
          ],
          "response_options": [
            { "key": "bad",  "body": { "en": "Bad" } },
            { "key": "good", "body": { "en": "Good" } }
          ]
        },
        {
          "key": "comments",
          "question_type": "long_response",
          "body": { "en": "Anything else?" },
          "max_characters": 0
        }
      ]
    }
  }
}
```

Fragmento del mismo elemento en un fichero **exportado** (con UUID; los valores son ilustrativos):

```json
{
  "key": "q0",
  "uuid": "0fabeb5c-82f6-810c-b48d-fbbc308b6578",
  "question_type": "single_option",
  "response_options": [
    { "key": "q0_o0", "uuid": "5e1d7c3a-2b9f-8a41-9c06-d7e2f1a0b3c4", "body": { "en": "🍎 Apple" } }
  ]
}
```

El exportador genera las `key` a partir de la posición (`q<i>`, `q<i>_o<j>`, `q<i>_r<j>`), porque las originales no se guardan.

### 3.8 Lo que Decidim no soporta (se pierde al convertir desde otros formatos)

- Emojis o iconos por opción: se ponen delante del texto en `body` (`"🍎 Apple"`).
- Opciones en varias columnas, `placeholder` y número de filas de un textarea: no hay campos para eso. Solo se podría con overrides de vista o CSS.
- Un `value` por opción, distinto del texto visible: no se guarda en Decidim. El UUID de la opción (estable mientras no cambie la encuesta) es lo que identifica la opción en el intercambio de respuestas.

---

## 4. Formato `decidim.survey.responses` (respuestas)

### 4.1 Conceptos

- **Participación (`Submission`)**: lo que la web llama "una respuesta a la encuesta". En la base de datos son **N filas `Response`, una por pregunta**, que comparten `session_token` (y `user`, si está registrado).
- **Referencias por UUID.** Las preguntas, opciones y filas se referencian **solo por `uuid`**, tal como aparecen en un export de la definición. Flujo para un fichero escrito a mano: exportar la definición → copiar los UUID → construir el fichero de respuestas.
- **Estabilidad.** Si la encuesta ya tiene respuestas y el componente está publicado, sus preguntas no se pueden editar (U1). Por tanto, a partir de la primera respuesta los UUID de preguntas, opciones y filas son estables en la práctica.
- **`respondent_uuid` / `submission.uuid`**: se calculan a partir del `session_token` del participante (sección 5.3). Como la clave depende del cuestionario, el mismo participante tiene UUID distintos en cada encuesta.
- **`session_token`**: `Decidim::Tokenizer.new(salt: questionnaire.salt || questionnaire.id, length: 10).int_digest(x).to_s`, donde:
  - usuario registrado: `x = user.id`. El importador **DEBE** calcularlo así para que `questionnaire.responded_by?` detecte duplicados y el usuario no pueda volver a responder en la web.
  - anónimo: en la web `x = session[:session_id]`. En un import no hay sesión, así que **DEBE** usarse `x = "import:" + external_id`. Por eso `external_id` es obligatorio para participantes anónimos nuevos.
  - El `session_token` es un dato **interno**: **NO DEBE** aparecer en ningún fichero (SEC5).
- **`ip_hash`**: `tokenize(remote_ip)` con el mismo tokenizer, o `null`.
- **`ResponseChoice.body`** es una **copia** del texto de la opción en el locale de la participación (`translated_attribute(response_option.body)`), no una referencia.
- **`separator` y `title_and_description`** también generan una fila `Response` con `body` igual a `"separator"` o `"title-and-description"`. El importador **DEBE** crearlas para que el resultado sea igual que una respuesta hecha en la web.

### 4.2 Esquema TypeScript

```ts
export interface SurveyResponsesFile {
  format: "decidim.survey.responses";
  version: 1;
  exported_at?: string;

  /**
   * Huella de la definición (sección 5.4). Es una COMPROBACIÓN, no un selector: DEBE coincidir
   * con la huella actual de la encuesta elegida en la petición (SEC2). Garantiza que las
   * respuestas son para exactamente esa versión de las preguntas.
   */
  target: { survey_uuid: Uuid };

  options?: {
    /** Qué hacer si el participante ya respondió. Default "skip". */
    on_existing?: "skip" | "replace" | "error";
    /**
     * "strict" (default): si falla una validación, se rechaza la participación entera.
     * "lenient": guarda las respuestas válidas e informa del resto.
     */
    validation?: "strict" | "lenient";
    /** Descarta respuestas a preguntas cuyas display_conditions no se cumplen, como la web. Default true. */
    enforce_display_conditions?: boolean;
    /** Publica los eventos y notificaciones de "respondió encuesta". Default false. */
    publish_events?: boolean;
  };

  submissions: Submission[];

  /** Presente en todo fichero exportado. Opcional al importar; si viene, DEBE ser válida. */
  integrity?: Integrity;
}

export interface Submission {
  /** Solo en exportación (informativo). Al importar se ignora: la identidad la da `respondent`. */
  uuid?: Uuid;
  /**
   * Id del sistema de origen (Typeform, papel, ...). Único en el fichero.
   * OBLIGATORIO si respondent.kind = "anonymous": de él sale el session_token (4.1).
   */
  external_id?: string;
  respondent: Respondent;
  /** Response#created_at. Default: ahora. */
  submitted_at?: string;
  /** Locale con el que se copia el texto de la opción en choice.body. Default: locale por defecto de la organización. */
  locale?: string;
  /** IP en claro; el servidor la hashea y nunca la guarda tal cual. No se acepta un ip_hash ya calculado (SEC5). */
  ip?: string;
  answers: Answer[];
}

export type Respondent =
  /** Participante que ya respondió a ESTE cuestionario (round-trip desde un export). */
  | { kind: "existing"; respondent_uuid: Uuid }
  /** Persona sin cuenta. Requiere Submission.external_id. */
  | { kind: "anonymous" }
  /**
   * Usuario registrado de la organización, identificado por email o nickname.
   * DESACTIVADO por defecto: solo se acepta si la importación se lanza con
   * `allow_identified_respondents` (SEC7). Nunca por id numérico.
   */
  | { kind: "user"; email?: string; nickname?: string };

interface AnswerBase {
  question: Uuid;
  /** DEBE coincidir con Question#question_type real. */
  type: string;
}

export interface TextAnswer extends AnswerBase {
  type: "short_response" | "long_response";
  body: string;
}

export interface ChoiceSelection {
  option: Uuid;
  /** Solo si la opción tiene free_text: true. Se guarda en custom_body. */
  free_text?: string;
}

export interface SingleOptionAnswer extends AnswerBase {
  type: "single_option";
  selection: ChoiceSelection;
}

export interface MultipleOptionAnswer extends AnswerBase {
  type: "multiple_option";
  selections: ChoiceSelection[];
}

export interface SortingAnswer extends AnswerBase {
  type: "sorting";
  /** TODAS las opciones, en el orden elegido. El índice es la position. */
  ranking: Uuid[];
}

export interface MatrixSingleAnswer extends AnswerBase {
  type: "matrix_single";
  rows: { row: Uuid; selection: ChoiceSelection }[];
}

export interface MatrixMultipleAnswer extends AnswerBase {
  type: "matrix_multiple";
  rows: { row: Uuid; selections: ChoiceSelection[] }[];
}

export interface FilesAnswer extends AnswerBase {
  type: "files";
  files: FileUpload[];
}

/** Solo contenido embebido. No se aceptan URLs para descargar (SEC12). */
export interface FileUpload {
  filename: string;
  content_type: string;
  title?: string;
  base64: string;
}

export type Answer =
  | TextAnswer | SingleOptionAnswer | MultipleOptionAnswer | SortingAnswer
  | MatrixSingleAnswer | MatrixMultipleAnswer | FilesAnswer;
// separator / title_and_description no se envían (ver 4.1).

/** Lo que devuelve el importador. */
export interface ImportReport {
  imported: number;
  skipped: { ref: string /* external_id o respondent_uuid */; reason: "already_responded" }[];
  errors: { ref: string; question?: Uuid; code: string; message: string }[];
  /** external_id → UUID calculados para la participación creada. */
  assigned: Record<string, { submission_uuid: Uuid; respondent_uuid: Uuid }>;
}
```

### 4.3 Reglas de validación por respuesta (DEBE)

Equivalen a `Decidim::Forms::ResponseForm`:

| # | Regla |
|---|---|
| R1 | `question` coincide con el UUID actual de una pregunta **del cuestionario destino**, y `type` coincide con su `question_type`. Si no coincide → `stale_reference`. |
| R2 | Cada `option` y cada `row` coinciden con el UUID actual de una opción o fila **de esa pregunta**. |
| R3 | `free_text` solo si la opción tiene `free_text: true`. |
| R4 | `mandatory` en tipos de texto: `body` no vacío, solo si la pregunta se muestra (display conditions cumplidas). |
| R5 | `mandatory` en tipos de elección: al menos una selección, solo si la pregunta se muestra. |
| R6 | `max_choices` (si existe): número de selecciones <= `max_choices`. En matrices, por fila. |
| R7 | `sorting`: `ranking` contiene todas las opciones de la pregunta, cada una una sola vez. |
| R8 | Matriz `mandatory`: una entrada por cada fila de la pregunta. |
| R9 | `max_characters > 0`: `body.length` y cada `free_text.length` <= `max_characters`. |
| R10 | `files` `mandatory`: al menos un fichero. Los ficheros DEBEN pasar las validaciones de adjuntos de Decidim (tamaño y extensiones de la organización). |
| R11 | `single_option` y `matrix_single`: una sola selección (por fila, en matrices). |
| R12 | Como mucho una `Answer` por pregunta dentro de una `Submission`. |

Reglas de participación:

| # | Regla |
|---|---|
| P1 | `kind: "existing"`: el `respondent_uuid` coincide con el UUID calculado de algún `session_token` que ya tiene respuestas en este cuestionario. Si no, error (nunca se crea). |
| P2 | `kind: "user"`: solo si `allow_identified_respondents` está activo (SEC7). El usuario existe, no está borrado ni bloqueado y pertenece a la organización de la encuesta (`Response#user_questionnaire_same_organization`). |
| P3 | `kind: "anonymous"`: `external_id` presente. `external_id` único en el fichero. |
| P4 | Duplicados: si `questionnaire.responded_by?(user || session_token)`, se aplica `on_existing`. Con `"replace"` se borran las `Response` de ese participante (como `ResponseQuestionnaire#clear_responses!`). |
| P5 | Con `enforce_display_conditions: true`, las respuestas a preguntas no mostradas se descartan y no cuentan como error. |

### 4.4 Correspondencia con la base de datos (por cada `Answer`)

| Tipo | `Response.body` | `ResponseChoice` |
|---|---|---|
| `short_response` / `long_response` | `body` | — |
| `single_option` | `null` | 1 fila: `response_option_id`, `body` = texto de la opción en `locale`, `custom_body` = `free_text` |
| `multiple_option` | `null` | 1 fila por selección (igual que arriba) |
| `sorting` | `null` | 1 fila por opción, `position` = índice en `ranking` |
| `matrix_single` / `matrix_multiple` | `null` | 1 fila por (fila × selección), con `decidim_question_matrix_row_id` |
| `files` | `null` | — ; se crean `Decidim::Attachment` vinculados a la `Response` |
| `separator` | `"separator"` | — |
| `title_and_description` | `"title-and-description"` | — |

Campos comunes de cada `Response`: `questionnaire`, `question`, `user` (o `nil`), `session_token`, `ip_hash`, `created_at = submitted_at`. Todos los ids los obtiene el servidor al resolver los UUID.

### 4.5 Algoritmo de importación

1. Comprobar permisos (SEC1). El destino viene del contexto de la petición (SEC2).
2. Validar `format`, `version`, tamaño (SEC9) y esquema. Si viene `integrity`, verificarla (5.6).
3. Calcular la huella actual del destino (5.4) y compararla con `target.survey_uuid`. Si difiere → `stale_reference` y se rechaza el fichero entero.
4. Calcular en memoria los índices `uuid → pregunta / opción / fila` del destino y, si alguna participación usa `kind: "existing"`, `respondent_uuid → session_token` para los participantes actuales.
5. Por cada `Submission`, en su propia transacción (o en una global si `validation: "strict"` y se quiere todo o nada):
   1. Resolver el participante (P1–P3): obtener `user` y `session_token`, o calcular `session_token = tokenize("import:" + external_id)`. Calcular `ip_hash` si viene `ip`.
   2. Comprobar duplicados (P4).
   3. Resolver todas las referencias con los índices del paso 4 (R1–R2).
   4. Evaluar las display conditions con el conjunto de respuestas de la participación (P5).
   5. Validar R3–R12.
   6. Crear las filas `Response`, `ResponseChoice` y adjuntos (4.4).
   7. Si `publish_events`, publicar el evento como hace `ResponseQuestionnaire#with_events`.
6. Registrar la acción con `Decidim.traceability` (SEC11) y devolver `ImportReport`.

### 4.6 Implementación recomendada (por verificar)

Opción A, preferida: convertir cada `Submission` al formato de parámetros de la web (`questionnaire[responses][i][question_id|body|choices[j][response_option_id|body|custom_body|position|matrix_row_id]]`), con los ids que el servidor obtiene al resolver los UUID, y construir el form así:

```ruby
form = Decidim::Forms::QuestionnaireForm.from_params(params)
                                        .with_context(session_token:, ip_hash:, current_user: user)
Decidim::Forms::ResponseQuestionnaire.new(form, questionnaire).call
```

Con eso se reutilizan las validaciones, el filtrado por display conditions y la gestión de adjuntos. Limitaciones:

- No permite fijar `created_at`: hay que hacer un `update_all(created_at:)` después.
- Siempre publica eventos. Si `publish_events: false`, usa la opción B.
- `QuestionnaireForm` exige `tos_agreement` y `session_token` en el contexto (`session_token_in_context`).

Opción B: crear las filas directamente como hace `ResponseQuestionnaire#response_questionnaire`, después de validar cada respuesta con `ResponseForm`.

**No verificado:** no se ha comprobado en ejecución que la opción A funcione fuera de un controlador. Prueba propuesta: ejecutar un `bin/rails runner` en `decidimos-app-1` que importe una participación anónima en una encuesta de prueba y después la borre.

### 4.7 Exportación

El exportador DEBE:
- emitir `target.survey_uuid` con la huella actual (5.4);
- agrupar las `Response` por `session_token` → una `Submission` por grupo, con `uuid` y `respondent: { kind: "existing", respondent_uuid }` calculados (5.3), para todos los participantes, registrados o anónimos. **No** emite `user_id`, email, nickname, `session_token` ni `ip_hash`;
- emitir `question`, `option` y `row` como UUID;
- omitir las filas de `separator` y `title_and_description`;
- para `files`, emitir el contenido en `base64` (o, si se decide que pesa demasiado, omitirlos e indicarlo en el informe; ver D6);
- firmar el fichero (`integrity`, 5.6).

### 4.8 Ejemplo

Fichero de importación desde otro sistema. Los UUID se copian de un export de la definición; los valores son ilustrativos:

```json
{
  "format": "decidim.survey.responses",
  "version": 1,
  "target": { "survey_uuid": "4a8f2e61-07c3-8d95-b1e4-6f2a9c0d3b78" },
  "options": { "on_existing": "skip", "validation": "strict" },
  "submissions": [
    {
      "external_id": "paper-form-016",
      "respondent": { "kind": "anonymous" },
      "submitted_at": "2026-11-20T14:05:00Z",
      "locale": "en",
      "answers": [
        { "question": "0fabeb5c-82f6-810c-b48d-fbbc308b6578", "type": "single_option",
          "selection": { "option": "9c41d2e7-5a08-8b36-a2f9-e1c7d4b05a63" } },
        { "question": "71e0c9b4-3d26-8f5a-8c17-b9a4e2d6f031", "type": "short_response",
          "body": "Sweet and tropical" }
      ]
    },
    {
      "external_id": "paper-form-017",
      "respondent": { "kind": "anonymous" },
      "submitted_at": "2026-11-21T09:30:00Z",
      "answers": [
        { "question": "0fabeb5c-82f6-810c-b48d-fbbc308b6578", "type": "single_option",
          "selection": { "option": "d83b6f15-c94e-8027-9e5d-3a1f7b2c8e46", "free_text": "Guava" } }
      ]
    }
  ]
}
```

Una participación en un fichero **exportado**:

```json
{
  "uuid": "2d7b9e04-f1a3-8c62-95e8-07c4b1d3a9f5",
  "respondent": { "kind": "existing", "respondent_uuid": "b65e1a93-4c0f-8d27-ab38-e9f2c7d14056" },
  "submitted_at": "2026-11-20T14:05:00Z",
  "answers": [
    { "question": "0fabeb5c-82f6-810c-b48d-fbbc308b6578", "type": "single_option",
      "selection": { "option": "9c41d2e7-5a08-8b36-a2f9-e1c7d4b05a63" } }
  ]
}
```

---

## 5. Identificadores y seguridad

### 5.1 Por qué UUID y no ids numéricos

Los ids de Decidim son enteros secuenciales y **adivinables**. Si un fichero pudiera referenciar ids numéricos, quien prepara el fichero podría:

- añadir condiciones o respuestas que apunten a preguntas u opciones de **otra encuesta** u otra organización;
- sobrescribir elementos ajenos en un update;
- suplantar participantes: con `user_id` o `session_token` en el fichero, y `on_existing: "replace"`, podría **borrar y reescribir las respuestas de otra persona**;
- enumerar el contenido de la plataforma a partir de exports.

### 5.2 Por qué UUID calculados a partir del contenido

Cada UUID es una función de **su propio contenido** y de una clave secreta del servidor, ligada a cada cuestionario. Propiedades:

| Propiedad | Consecuencia |
|---|---|
| **Determinista** | El mismo contenido da siempre el mismo UUID. No hay que guardarlo: **no hace falta migración**. |
| **Cambia si cambia el contenido** | El UUID identifica una **versión** del elemento. Si alguien edita la encuesta después de un export, los UUID del fichero ya no coinciden y el import falla con `stale_reference`, en vez de sobrescribir cambios ajenos (bloqueo optimista). |
| **Con clave secreta (HMAC)** | Sin el secreto del servidor no se puede calcular ni falsificar un UUID válido, aunque se conozca el contenido. Por tanto, un UUID presente en un fichero prueba que lo emitió el servidor. |
| **Clave distinta por cuestionario** | Dos encuestas con preguntas idénticas tienen UUID distintos. Un UUID de una encuesta nunca coincide con nada de otra. |
| **No revela nada** | No contiene ids, fechas ni contenido en claro. |

Limitaciones que el implementador DEBE tener presentes:

- **El UUID no es permanente.** Editar el texto de una pregunta, cambiar su tipo o reordenar las preguntas cambia los UUID afectados (ver tabla 5.3). Cualquier fichero que contenga UUID solo es válido contra la versión exacta de la que se exportó. Para trabajar con una versión nueva, hay que volver a exportar.
- **Las `key` no persisten.** Solo valen dentro de un fichero (U3, U5).
- **El UUID no sustituye a la autorización.** La protección real son SEC1–SEC3.

### 5.3 Cálculo del UUID (normativo)

**Paso 1 — Clave del servidor (`K_app`, 32 bytes).**

```ruby
K_app = Rails.application.key_generator.generate_key("decidim-survey-exchange/uuid/v1", 32)
```

Se deriva de `secret_key_base`. Es distinta de la clave de firma (5.6).

**Paso 2 — Clave del cuestionario (`K_q`).**

```
K_q = HMAC-SHA256(K_app, "decidim-survey-exchange/v1|" + scope)
scope = "salt:" + questionnaire.salt     si salt no es null ni vacío
        "id:"   + questionnaire.id       si no (cuestionarios antiguos sin salt; ver D9)
```

El id numérico solo se usa dentro del HMAC, así que no se expone.

**Paso 3 — Proyección.** Para cada elemento se construye un objeto con **solo** los campos indicados en la tabla de abajo. Después:

1. **Normalizar los `Translated`:** quitar `machine_translations` (las traducciones automáticas cambian solas en segundo plano y harían variar el UUID); quitar los locales con valor `""` o `null`. Si no queda ningún locale → `null`.
2. **Normalizar los valores por defecto:** `mandatory: null → false`, `free_text: null → false`, `max_characters: null → 0`. `max_choices` se queda en `null` si no tiene valor.
3. **Pasar por JSON y volver:** `JSON.parse(JSON.stringify(proyeccion))` en JS, o `JSON.parse(JSON.generate(proyeccion))` en Ruby. Así quedan solo tipos JSON puros (string, número entero, booleano, null, objeto, array). La proyección NO DEBE contener números decimales ni fechas.

**Paso 4 — Serialización canónica (JCS, RFC 8785).** Claves de objeto ordenadas por código, sin espacios, strings en UTF-8 sin escapar caracteres no ASCII. `JSON.stringify` **no basta por sí solo**, porque respeta el orden de inserción de las claves, que no tiene por qué coincidir entre Ruby y JS.

**Paso 5 — UUID v8.**

```
h = HMAC-SHA256(K_q, utf8(JCS(proyeccion)))
b = h[0..15]
b[6] = (b[6] & 0x0f) | 0x80     # versión 8
b[8] = (b[8] & 0x3f) | 0x80     # variante RFC 9562
uuid = hex(b) con guiones 8-4-4-4-12, minúsculas
```

**Proyecciones (qué entra en cada UUID):**

| Elemento | Proyección | Cambia el UUID si... |
|---|---|---|
| Pregunta | `{ kind: "question", position, question_type, mandatory, body, description, max_choices, max_characters }` | se edita cualquiera de esos campos o se mueve de posición |
| Opción | `{ kind: "response_option", question_position, index, body, free_text }` — `index` = posición en `question.response_options` (orden por id) | cambia su texto o `free_text`, su orden, o la pregunta se mueve |
| Fila de matriz | `{ kind: "matrix_row", question_position, position, body }` | cambia su texto o posición, o la pregunta se mueve |
| Condición | `{ kind: "display_condition", question_position, condition_question_position, condition_type, response_option_index, condition_value, mandatory }` — `response_option_index` y `condition_value` son `null` si no aplican; `condition_type` como string | cambia cualquiera de esos campos |
| Huella de la encuesta (`survey.uuid`, `target.survey_uuid`) | `{ kind: "survey", questions: [ { uuid, options: [uuid…], matrix_rows: [uuid…], display_conditions: [uuid…] } … ] }` en orden de posición | cambia **cualquier** pregunta, opción, fila o condición, o se añade o borra alguna |
| Participante (`respondent_uuid`) | `{ kind: "respondent", session_token }` | nunca (para un mismo participante y cuestionario) |
| Participación (`Submission.uuid`) | `{ kind: "submission", session_token }` | nunca |

Notas sobre las proyecciones:
- No se incluyen ids numéricos. Los elementos hijos se distinguen por posición, así que dos opciones con el mismo texto en la misma pregunta tienen UUID distintos. Lo mismo pasa con varios `separator` iguales.
- La huella de la encuesta **no incluye** `title`, `description`, `tos` ni `settings`. Esos campos se pueden editar aunque haya respuestas (U1), y cambiar las fechas o el título no debe invalidar los ficheros de respuestas preparados para la misma versión de las preguntas.
- Ninguna proyección incluye a su elemento padre por UUID. Por eso, editar el texto de una pregunta no cambia los UUID de sus opciones.

**Vector de prueba.** Con este vector se comprueba que una implementación produce exactamente los mismos bytes. Resultado verificado de forma independiente en Node y en Ruby 3.3.4 (imagen `decidimos-app`):

```
K_app (hex)  = 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
scope        = "salt:test-salt"
K_q (hex)    = e5a2a3a7945193aad40957928a3c28e57fd1a6822a6a39adff9f3a5e529d0fa3
proyección   = { kind: "question", position: 0, question_type: "single_option", mandatory: true,
                 body: { en: "What is your favorite fruit?" }, description: { en: "Choose one" },
                 max_choices: null, max_characters: 0 }
JCS          = {"body":{"en":"What is your favorite fruit?"},"description":{"en":"Choose one"},"kind":"question","mandatory":true,"max_characters":0,"max_choices":null,"position":0,"question_type":"single_option"}
uuid         = 0fabeb5c-82f6-810c-b48d-fbbc308b6578
```

Implementación de referencia en TypeScript (Node):

```ts
import { createHmac } from "node:crypto";

const jcs = (v: unknown): string => {
  if (v === null || typeof v !== "object") return JSON.stringify(v);
  if (Array.isArray(v)) return "[" + v.map(jcs).join(",") + "]";
  const o = v as Record<string, unknown>;
  return "{" + Object.keys(o).sort().map((k) => JSON.stringify(k) + ":" + jcs(o[k])).join(",") + "}";
};

export const contentUuid = (kQ: Buffer, projection: object): string => {
  const canonical = jcs(JSON.parse(JSON.stringify(projection)));
  const b = Buffer.from(createHmac("sha256", kQ).update(canonical, "utf8").digest().subarray(0, 16));
  b[6] = (b[6] & 0x0f) | 0x80;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = b.toString("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
};
```

Esta `jcs` mínima solo vale porque las proyecciones contienen strings, enteros, booleanos y null. Si alguna vez entran decimales, hay que usar una implementación completa de RFC 8785. En Ruby, el equivalente usa `OpenSSL::HMAC.digest("SHA256", ...)` y `JSON.generate` por valor, recorriendo las claves con `keys.sort`.

### 5.4 Resolución en el import

- El servidor **nunca confía en un UUID del fichero**. Calcula los UUID actuales del cuestionario destino y compara.
- Cálculo: una sola carga de preguntas, opciones, filas y condiciones del cuestionario, y un HMAC por elemento. Para `respondent_uuid`, un HMAC por cada `session_token` distinto que ya tenga respuestas en el cuestionario. Todo se indexa en memoria durante la petición.
- Un UUID que no coincide con nada da siempre el mismo error (`stale_reference`), exista o no en otra parte.

### 5.5 Reglas de seguridad (DEBE)

| # | Regla |
|---|---|
| SEC1 | **Autorización.** Solo puede importar quien puede editar el cuestionario en el panel de admin de ese componente (mismas comprobaciones de `Decidim::Surveys::Admin::Permissions` que la pantalla de edición). Ningún endpoint público ni de participante. Pendiente de confirmar la acción exacta del permiso (D7). |
| SEC2 | **El destino lo decide la petición, no el fichero.** La encuesta destino sale de la ruta o del parámetro del comando (componente y encuesta del admin). `survey.uuid` / `target.survey_uuid` del fichero solo se comparan con la huella actual de ese destino. |
| SEC3 | **Ámbito.** Las referencias se resuelven contra los UUID calculados **solo** para el cuestionario destino. Una opción o fila se resuelve dentro de su pregunta. |
| SEC4 | **Sin ids numéricos.** El validador rechaza cualquier campo fuera del esquema (`additionalProperties: false`) y cualquier valor numérico en una posición de referencia. |
| SEC5 | **Sin datos internos en los ficheros.** `session_token`, `ip_hash`, `user_id` y `salt` nunca se exportan ni se aceptan. |
| SEC6 | **UUID no falsificables.** Los UUID se calculan con HMAC y una clave secreta (5.3), así que no se pueden generar fuera del servidor. Por eso un fichero sin firma (`integrity`) puede usar UUID copiados de un export. Si el fichero trae firma, DEBE ser válida; si no lo es, se rechaza el fichero entero. |
| SEC7 | **Respuestas en nombre de usuarios.** `respondent.kind: "user"` permite atribuir respuestas a una persona real, lo que equivale a suplantarla. Está desactivado por defecto; activarlo exige una opción explícita del comando (`allow_identified_respondents`), que el usuario que importa sea admin de la organización y que quede en el log de auditoría (SEC11). |
| SEC8 | **Idempotencia.** Reimportar el mismo fichero no duplica respuestas: el `session_token` de los anónimos sale de `external_id` y el de los registrados de `user.id`, así que `responded_by?` detecta la repetición y se aplica `on_existing`. |
| SEC9 | **Límites.** Tamaño máximo del fichero, de `submissions`, de `questions`, de opciones por pregunta y de cada texto (valores a decidir en D8). Se comprueban antes de parsear el contenido completo cuando sea posible. |
| SEC10 | **Regex de `match`.** `DisplayCondition#fulfilled?` hace `Regexp.new(value, Regexp::IGNORECASE)` con el texto de `condition_value`. Un patrón malicioso puede bloquear el servidor (ReDoS). El importador DEBE limitar la longitud del patrón, comprobar que compila y evaluarlo con `Regexp.timeout` (disponible: la imagen usa Ruby 3.3.4, ver `Dockerfile`). |
| SEC11 | **Auditoría.** Cada import se registra con `Decidim.traceability.perform_action!` (actor, encuesta, número de elementos y participaciones, hash SHA-256 del fichero). |
| SEC12 | **Ficheros adjuntos.** Solo `base64`; nunca descargar URLs indicadas en el fichero (evita SSRF). Se validan tipo y tamaño con las reglas de adjuntos de la organización. |
| SEC13 | **HTML.** `description`, `tos` y `announcement` pasan por los mismos forms que el admin (`QuestionnaireForm`, `SurveySettingsForm`). Ojo: en 0.31.5 `Decidim::Attributes::RichText` **no sanea** (solo quita `\r` y procesa blobs) y `announcement` es un `String`; el saneado lo hace Decidim al **renderizar**. El import guarda lo mismo que guardaría el editor del admin, ni más ni menos. |
| SEC14 | **Secreto.** Si cambia `secret_key_base`, cambian todos los UUID y todos los ficheros exportados dejan de ser válidos. Rotar ese secreto equivale a invalidar todos los exports. |

### 5.6 Firma de integridad del fichero

- **Clave:** `Rails.application.key_generator.generate_key("decidim-survey-exchange/signature/v1", 32)`. `key_id` identifica la versión de la clave.
- **Contenido firmado:** el JSON completo **sin** el campo `integrity`, pasado por `JSON.parse(JSON.stringify(...))` y canonicalizado con JCS (igual que en 5.3).
- **Algoritmo:** HMAC-SHA256. Se compara con `ActiveSupport::SecurityUtils.secure_compare`.
- **Para qué sirve:** los UUID protegen cada referencia, pero no el resto del fichero. La firma prueba que el fichero completo (textos, opciones, respuestas) salió tal cual de **esta** instalación. Es opcional al importar (SEC6). Un fichero firmado por otra instalación no se puede verificar y se trata como no firmado.

---

## 6. Decisiones y preguntas abiertas

| # | Tema | Estado |
|---|---|---|
| D1 | Los UUID se calculan con clave secreta, así que **solo el servidor** puede calcularlos. Si alguna herramienta externa (por ejemplo, un editor en TypeScript) tuviera que calcular UUID por su cuenta, habría que usar una clave pública (UUID v5 o SHA-256 sin secreto) y se perdería la propiedad "no falsificable" (SEC6), con lo que la firma pasaría a ser obligatoria. | Decidido: con clave secreta. Revisar si aparece ese caso de uso. |
| D2 | Punto de entrada: rake task, botón en el admin o endpoint API. Cualquiera DEBE cumplir SEC1–SEC2. | Decidido: panel de admin del componente de encuestas (pestaña "Importar / exportar" de cada encuesta, opción "Exportar" en el listado y botón "Importar encuesta" para crear una nueva). Ver `config/initializers/survey_exchange.rb`. |
| D3 | Opción A u opción B para guardar respuestas (4.6). | Abierto. Hay que verificar la opción A. |
| D4 | Si al reemplazar preguntas con `mode: "replace"` se permite `override_edit!` aunque haya respuestas. | Decidido: no. Si las preguntas del fichero coinciden exactamente con las actuales (mismos UUID y contenido) se aplican título, descripción, términos y ajustes; si no, error `questions_not_editable`. |
| D5 | Si Decidim impide más de una respuesta por usuario aunque `allow_editing_responses` sea false (`ResponseQuestionnaire#user_already_responded?`). | Visto en el código; falta comprobarlo en ejecución. |
| D6 | Si el export de respuestas incluye los adjuntos en base64 o los omite. | Abierto. |
| D7 | Acción exacta de permiso para SEC1 (la que usa el admin para editar el cuestionario de una encuesta). | Decidido: `enforce_permission_to(:update, :questionnaire, questionnaire: survey)` para exportar e importar (igual que `Questions::SurveysController#edit_questions`) y `(:create, :questionnaire)` para crear una encuesta desde archivo. |
| D8 | Valores de los límites de SEC9. | Decidido (`DecidimCujae::SurveyExchange::LIMITS`): fichero 2 MB, 300 preguntas, 200 opciones y 200 filas por pregunta, 50 condiciones por pregunta, 5 000 caracteres por texto, 100 000 por HTML y 500 por regex. Además `Regexp.timeout = 1.0` global (SEC10). |
| D9 | Cuántos cuestionarios tienen `salt` nulo (y usan el ámbito `id:`). Comando: `docker exec decidimos-app-1 bin/rails runner 'p Decidim::Forms::Questionnaire.where(salt: [nil, ""]).count'`. | 0 en dev (2026-11-26). Falta comprobarlo en producción. |
| D10 | Orden en `mode: "merge"`. | Decidido: los elementos del fichero (sin `deleted`) van primero, en el orden del fichero, y los elementos existentes que el fichero omite se conservan detrás, en su orden actual. Las condiciones de visualización se borran y se recrean siempre (su UUID solo depende del contenido, así que no cambia si no cambian). |
| D11 | `integrity.key_id`. | Decidido: `"v1:" + HMAC-SHA256(clave_de_firma, "key-id")[0..15]`. Si no coincide con el de esta instalación, el fichero se trata como no firmado (aviso); si coincide y la firma no es válida, se rechaza (SEC6). |

## 7. Referencias de código (`~/.cache/decidim-src/v0.31.5/`)

| Tema | Archivo |
|---|---|
| Modelos de definición | `decidim-forms/app/models/decidim/forms/{questionnaire,question,response_option,question_matrix_row,display_condition}.rb` |
| `Questionnaire#salt` (`set_default_salt`) | `decidim-forms/app/models/decidim/forms/questionnaire.rb` |
| Modelos de respuesta | `decidim-forms/app/models/decidim/forms/{response,response_choice}.rb` |
| Validaciones de la definición | `decidim-forms/app/forms/decidim/forms/admin/{questionnaire,questions,question,response_option,question_matrix_row,display_condition}_form.rb` |
| Guardado de la definición | `decidim-forms/app/commands/decidim/forms/admin/update_questions.rb` |
| Reglas de UI (max_choices, tipos con opciones) | `decidim-forms/app/packs/src/decidim/forms/admin/forms.js` |
| Validaciones de respuesta | `decidim-forms/app/forms/decidim/forms/{questionnaire_form,response_form,response_choice_form}.rb` |
| Guardado de respuestas | `decidim-forms/app/commands/decidim/forms/response_questionnaire.rb` |
| `session_token`, `ip_hash`, `tokenize` | `decidim-forms/app/controllers/decidim/forms/concerns/has_questionnaire.rb` (líneas ~137-156) |
| Tokenizer | `decidim-core/app/services/decidim/tokenizer.rb` |
| Regex de `match` (`Regexp.new`) | `decidim-forms/app/models/decidim/forms/display_condition.rb` (`response_form_matches?`) |
| `choice.body` = texto traducido de la opción | `decidim-forms/app/views/decidim/forms/questionnaires/responses/_multiple_option.html.erb` |
| Body de relleno en separator y title_and_description | `decidim-forms/app/views/decidim/forms/questionnaires/responses/_{separator,title_and_description}.html.erb` |
| Import/export nativo (con pérdidas) | `decidim-surveys/app/serializers/decidim/surveys/data_{serializer,importer}.rb`, `decidim-forms/lib/decidim/forms/user_responses_serializer.rb` |
| Registro del componente surveys | `decidim-surveys/lib/decidim/surveys/component.rb` |
| Esquema de tablas | `db/schema.rb` (`decidim_forms_*`, `decidim_surveys_surveys`) |
