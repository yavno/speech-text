---
tags: [add-to-a-list]
max_turns: 30
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill, Edit, Write]
---

Whisper keeps pasting "Untertitel im Auftrag des ZDF" when I'm silent, and sometimes just "Danke". Add both to the silence hallucination filter. Seen in openai/whisper discussion #928.
