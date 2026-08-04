# GitHub Release template

Copy into the release body and fill every `⟨…⟩`. The four sections are separate on purpose:
**a declared minimum is not a tested claim**, and the release must never present
`LSMinimumSystemVersion` as coverage. If a section would be empty, write "none", not silence.

Pre-publish checklist (all must be true, else the release stays blocked):

- [ ] `scripts/package-release.sh` ran in **release** mode to completion (Developer ID +
      Hardened Runtime + secure timestamp, notarization **Accepted**, stapled,
      `spctl --assess` passed on the mounted app).
- [ ] The facts below were collected **from the release artefact on the release day** — not
      copied from an earlier round of development notes.
- [ ] Architecture claims match what was actually built (arm64-only until Universal 2 is real).

---

## TriCap ⟨version⟩

⟨One paragraph: what TriCap is — menu-bar screenshots, short recordings to animated WebP,
pinning, Markdown/Obsidian references, fully local.⟩

### Minimum requirement

- macOS ⟨14.0 — from `LSMinimumSystemVersion` at release time⟩
- ⟨architecture of the artefact, e.g. Apple Silicon (arm64) only⟩

*This is the configured minimum. It is not a promise that every listed version was exercised —
see the next section for what actually was.*

### Verified environments

Only environments where this exact artefact was installed and exercised by a human. One row per
machine; delete the example row.

| macOS (build) | Hardware | Displays | What was verified |
|---|---|---|---|
| ⟨e.g. 26.5.2 (25F84)⟩ | ⟨e.g. MacBook Air M2⟩ | ⟨e.g. built-in 2x + 1280×800 2x⟩ | ⟨e.g. install from DMG, first-launch Gatekeeper prompt, ⌥⇧5 capture, clipboard paste, recording + export, F3 pin, login item⟩ |

### Not yet verified

⟨Honest list. Typical entries while they remain true:⟩
- ⟨macOS 14.x / 15.x — declared minimum, never exercised⟩
- ⟨Intel Macs — no build exists⟩
- ⟨login item across a real logout/login⟩
- ⟨mixed-scale-factor multi-display setups⟩

### Known limitations

- Pixelation (mosaic) is visual obscuration, not irreversible redaction — cover secrets with a
  filled rectangle instead.
- ⟨architecture limitation, e.g. Apple Silicon only; Intel users cannot run this build⟩
- ⟨anything from release/RELEASE_PLAN.md "Not yet verified" that ships unresolved⟩

### Checksums

```
shasum -a 256 ⟨TriCap-x.y.z.dmg⟩
⟨paste output⟩
```
