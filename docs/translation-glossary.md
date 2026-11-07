# Translation glossary

How the app's own terms, and the macOS names it points to, are translated, so that
each reads the same on every page. The translations job reads this with every string's
English and comment (docs/specs/2026-11-04-localization.md › The translations pull
request); a fix to a term is made here and in the catalogs together.

A term in the table is used as given, inflected as the sentence needs. A term not here
is translated as the sentence needs.

## Rules for every language

- **Never translated:**
  - **SpeechText**, vendor names (Apple, OpenAI, Groq, ElevenLabs, Deepgram, …) and
    model names (Whisper, Parakeet, GPT-4o Transcribe, …);
  - key symbols (⌘ ⌥ ⌃ ⇧ fn) and anything in `code`;
  - the format specifiers: `%@`, `%lld`, `%1$@` and the like. A translation may reorder
    them, with positional forms (`%2$lld … %1$@`), but it may not drop, add or change one.
    `scripts/strings/check.py translations` checks this.
- **Markdown:** emphasis, code spans and links stay as in the English, with the same
  link targets.
- **macOS names:** a System Settings pane, a permission or a macOS feature is named as
  macOS names it in that language (the table below), so the user finds it.
- **Case:** sentence case. English capitalizes menu items and buttons ("Use as Default");
  Spanish and Ukrainian do not.
- **Plurals:** a string with a count gets every form the language has. Spanish: *one*,
  *many*, *other*; Ukrainian: *one*, *few*, *many*, *other*. The English *one* form may
  leave the number out ("Used once"); a translation may too, where natural.
- **Numbers** are written the app's language's way, whatever the Mac's region: 483,3 MB, $0,01 and 0,4 s in Spanish and Ukrainian. The code formats them (`numberLocale` in SpeechTextCore); a translation never rewrites a number.
- **Numbers and units** stay on one line: a non-breaking space between a number and its unit (7 днів, 40 сл./хв, 19 GB), and a word joiner after the dash of a range (3–⁠19).
- **Length:** buttons, chips, tabs and column headings have little room. Prefer the
  shorter of two equal wordings there. The comment says where a string appears.

## Spanish (`es`)

Neutral Spanish, addressed as *tú*, as macOS's Spanish is. Quotation marks “ ”.

| English | Spanish |
|---|---|
| dictation (a recording turned into text) | dictado |
| dictate | dictar |
| AI Rewrite | Reescritura con IA |
| AI | IA |
| AI mode | modo IA |
| Edit (rewriting selected text by voice) | Editar; the feature: Edición |
| Edit selection (the feature's name, on Home, in Usage, in the overlay; Edit Selection in the menu and the shortcut list) | Editar selección |
| Hold to talk | Mantén para hablar |
| Press to toggle | Pulsa para alternar (imperative, as Hold to talk) |
| Apple Dictation · Apple on-device (speech models) | Dictado de Apple · Apple en el dispositivo |
| double tap (a shortcut) | doble pulsación |
| Record Window | Ventana de grabación |
| Home · History · Usage · Prompts · Dictionary | Inicio · Historial · Uso · Prompts · Diccionario |
| Notepad · Notetaker (pages) | Notas · Reuniones |
| prompt | prompt (m.) |
| When to use (a prompt's field) | Cuándo usarlo |
| Instructions (a prompt's field) | Instrucciones |
| Default (the default prompt) | Predeterminado |
| Replacements | Sustituciones |
| Settings (the app's window) | Ajustes |
| Setup (the first-run window) | Configuración inicial |
| speech engine | motor de voz |
| speech model | modelo de voz |
| provider | proveedor |
| API key | clave de API |
| shortcut | atajo |
| paste | pegar |
| transcription · transcribe | transcripción · transcribir |
| on this Mac | en este Mac |
| skin · Techno · Minimal | aspecto · Techno · Minimal |
| System Settings | Ajustes del Sistema |
| Privacy & Security | Privacidad y seguridad |
| Keyboard · Dictation (macOS) | Teclado · Dictado |
| Accessibility | Accesibilidad |
| Microphone · Speech Recognition · Automation | Micrófono · Reconocimiento de voz · Automatización |
| Sound | Sonido |
| Login Items | Ítems de inicio de sesión |
| menu bar · Dock · Control Center | barra de menús · Dock · Centro de control |

## Ukrainian (`uk`)

Addressed as *ви*, lowercase, as macOS's Ukrainian is. Quotation marks « ».

| English | Ukrainian |
|---|---|
| dictation (a recording turned into text) | диктування; counted: диктовка (1 диктовка, 3 диктовки, 5 диктовок) |
| dictate | диктувати |
| AI Rewrite | ШІ‑переписування (ШІ‑переписуванню, ШІ‑переписуванням…), with a non-breaking hyphen (U+2011) so it never breaks at the hyphen; the History filter switch says ШІ |
| AI | ШІ |
| AI mode | режим ШІ |
| Edit (rewriting selected text by voice) | Редагувати; the feature: Редагування |
| Edit selection (the feature's name; Edit Selection in the menu and the shortcut list) | Редагування виділеного; the menu item: Редагувати виділене |
| Hold to talk | Затисніть і говоріть; *hold* (the key) is затисніть everywhere, never утримуйте |
| Recording (the state, a heading) | Запис |
| Apple Dictation · Apple on-device (speech models) | Диктування Apple · Apple на пристрої |
| double tap (a shortcut) | подвійне натискання |
| Record Window | Вікно запису |
| Home · History · Usage · Prompts · Dictionary | Головна · Історія · Облік · Промпти · Словник |
| Notepad · Notetaker (pages) | Нотатник · Зустрічі |
| prompt | промпт |
| When to use (a prompt's field) | Коли використовувати |
| Instructions (a prompt's field) | Інструкції |
| Default (the default prompt) | Типовий |
| Replacements | Заміни |
| Settings (the app's window) | Параметри, as macOS names an app's settings; *setup* stays налаштування |
| Setup (the first-run window) | Початкове налаштування |
| speech engine | рушій мовлення |
| speech model | модель мовлення |
| provider | провайдер |
| API key | API-ключ |
| shortcut | скорочення клавіш; short: скорочення |
| paste | вставити |
| transcription · transcribe | транскрипція · транскрибувати |
| on this Mac | на цьому Mac |
| skin · Techno · Minimal | оформлення · Techno · Minimal |
| System Settings | Системні параметри; a path after a preposition takes the locative: «у Системних параметрах › Звук» |
| Privacy & Security | Приватність і безпека |
| Keyboard · Dictation (macOS) | Клавіатура · Диктування |
| Accessibility | Універсальний доступ |
| Microphone · Speech Recognition · Automation | Мікрофон · Розпізнавання мовлення · Автоматизація |
| Sound | Звук |
| Login Items | Елементи входу |
| menu bar · Dock · Control Center | смуга меню · Dock · Центр керування |

## Adding a language

A new language is not done when every string has a value. Before it is turned on:

1. **Every window is looked at and compared with English.** Run
   `scripts/window-snapshots.sh --languages "en <code>"` and go through every screen in
   `index.html` beside its English: text cut off or clipped, a word broken across lines,
   a button pushed out of its window, English left over, a sentence that reads wrong.
   Write the assessment down in the pull request that turns the language on, screen by
   screen, with what was fixed.
2. **Every term is right and the same everywhere.** Each row of this glossary gets the
   language's word, the macOS names the ones macOS itself uses in that language (Settings
   is *Параметри* in Ukrainian, not *Налаштування*), a page's name in the sidebar fits it
   at full size (*Облік*, not *Використання*; the rail is 68 pt wide at 11.5 pt), and every string that names a page,
   a feature or a setting uses that word — in the window itself, in the notices that send
   the user there, and in the paths (*Settings › AI Rewrite*). Grammar around a name
   follows the language (Ukrainian puts a path after «у» in the locative).

