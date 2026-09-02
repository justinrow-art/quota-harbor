# Theme artwork review record

Date: 2026-07-17 (Asia/Taipei)

## Scope and reviewer disclosure

This record covers the six AI-generated source masters and their six runtime
PNG derivatives. The project owner selected and approved all six visual
directions. A separate Codex agent performed an independent visual and
mechanical review. The independent reviewer was an AI agent, not a named human
art, accessibility or legal professional.

The review found no visible people, faces, characters, text, numbers, logos,
watermarks, brands or recognizable third-party franchise elements. The prompts
also prohibited imitation of a named artist, studio or franchise. This is a
good-faith release check, not a copyright, trademark or jurisdiction-specific
legal opinion.

## Retained mechanical evidence

Apple ImageIO decoded every source and runtime file as a single-frame
1254-by-1254 PNG. Runtime derivatives report the `sRGB IEC61966-2.1` profile.
The generator returned native 1254-by-1254 files; they were not upscaled or
represented as native 2048-pixel outputs.

| Theme | Source SHA-256 | Runtime SHA-256 |
| --- | --- | --- |
| Morandi | `b8e1e353d5573e5fb6db7eb3ce930fdd9c51ad6b2b0d537f60133e55780b7bb7` | `cadcee3e750866a93b42f2c85dc20b318eecce3817561ef9209633812a850cbe` |
| Cyberpunk | `bfb7a50a0c8ed3fa124d4950e9711ac1c08051c73656cb6d18da32500e3600fa` | `6c39f3cbc44917b4562616bb0efb6689c51c1269aebe637834558981f757863e` |
| Warm hand-drawn | `e59cecd2f0f44f43843facfdd9007cec1bc1171e499583d69251bf9821868fc2` | `219b80f9d6e1252fb3c118da6d5b89b575f508dbd3193c1c8a210750dda8300f` |
| Glass | `c6f2c562a09b25b2c1abf93ff2fc5e3eaa156867b43727540d92ad53044bcf05` | `366795649d003433a19f411ba42dae9476c712ecd7c9c64095e070bfdc1dfa9a` |
| Sketch | `1535913dd18cbf982e666b6630cd2cce29c4a83592ee205bd049511204dfb5d3` | `e3a02e9e9c8960c53be71194345bf401a562f66a497b7e9bbf6b5d765234a4c6` |
| Cartoon illustration | `2462b2f259f4a69c2ecd55a35821cbce62e495e351d7aea1e736233cb5031dbc` | `a60efeea90df3145b27d9397ed902d47a52ef7e9a5e079e026c42ef613a24d99` |

Reproduce the file-level evidence from the repository root with ImageIO and
`shasum -a 256`. The canonical paths and the deterministic preparation script
are recorded in `theme-assets.json`.

## Runtime readability evidence

Runtime artwork is decorative. The app applies a 0.85 semantic-background
scrim before text and uses the existing resolved-theme contrast validation.
The checked-in theme tests cover light/dark appearances, semantic text and icon
roles, accessibility modes, and the six-theme state matrix. This record does
not publish an exact per-pixel minimum contrast value because no standalone
calculation artifact for such a number is retained in the workspace.
