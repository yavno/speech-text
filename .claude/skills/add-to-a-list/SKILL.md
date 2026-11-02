---
name: add-to-a-list
description: Add entries to one of SpeechText's data lists — password managers kept out of AI Rewrite's context (FocusContext.excludedBundleIDs), keyboard layouts mapped to languages (layoutToLanguage), silence-hallucination phrases (HallucinationFilter phrases and prefixes) — or a list like them. Use it for issues such as "add Proton Pass", "support the Greek layout", "filter 'Untertitel im Auftrag des ZDF'", and any change that only adds values to a table in SpeechTextCore.
---

# Add to a list

Each list protects or decides something, and a wrong entry fails silently: a guessed
bundle ID protects nothing, a dictatable word in the hallucination filter deletes real
speech. So every entry is read from a real source, and the pull request says which.

Follow the `contribute` skill for the workflow. For the list itself:

| List | Where | Read the value from | Test |
|---|---|---|---|
| Password managers | `FocusContext.excludedBundleIDs`, `FocusContext.swift` | a real install: `osascript -e 'id of app "<Name>"'`, or its `Info.plist` | one `XCTAssertNil(capture(bundleID: …))` per app in `FocusContextTests` (`RefinementTests.swift`) |
| Keyboard layouts | `layoutToLanguage`, `Settings.swift` | the layout turned on and selected, then `defaults read com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID`; the key is the part after `com.apple.keylayout.` | every value is a code in `spokenLanguageCatalog` (`CatalogueTests.swift`; the table is `private` until a test needs it) |
| Hallucination phrases | `HallucinationFilter.phrases` / `.prefixes`, `HallucinationFilter.swift` | a place the phrase was seen as a hallucination: an issue in a speech-model project, a forum thread, a dictation of your own | one case per entry in `HallucinationFilterTests` (`TranscriptCleanupTests.swift`) |

Files are in `Packages/SpeechTextCore/Sources/SpeechTextCore/` and `SpeechText/SpeechTextTests/`.

Rules the lists keep:
- Keep each list's order (alphabetical where it is) and its comments' style.
- Hallucinations: a `phrases` entry is the whole result, written as `normalized` leaves it
  (lowercase, letters and digits, single spaces); a `prefixes` entry is the opening words
  of a credit followed by a name. Never a word or short phrase a person might really
  dictate alone ("Danke", "Merci", "Thank you").
- Layouts: a code must already be in `spokenLanguageCatalog`; adding a language is a
  larger change.
- A value you could not read from a real source stays out, even when the user says to
  go with the usual one: a remembered bundle ID or layout name is a guess, and nothing
  fails when it is wrong. Leave it out, give the user the command that reads it, and say
  another pull request can add it.

Run only the affected tests first, e.g.
`xcodebuild test … -only-testing:SpeechTextTests/FocusContextTests`, then the whole suite.

In the pull request, list each entry with how it was read.
