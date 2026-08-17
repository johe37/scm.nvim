# scm.nvim

A VS Code style source control view for Neovim: a sidebar listing your current
changes, and a side-by-side diff where the left window is the old version and the
right window is the real file — editable, savable, and re-diffed as you type.

The same sidebar also browses history, GitLens style: commit lists, one commit's
metadata and files, and a jump from any line to the commit that wrote it.

No dependencies beyond `git` and Neovim ≥ 0.10.

```
┌──────────────────────────┬───────────────────────────┬───────────────────────────┐
│ Source Control           │ Index: lua/plugins/scm.lua│ lua/plugins/scm.lua       │
│ master                   ├───────────────────────────┼───────────────────────────┤
│ nvim                     │ local a = 1               │ local a = 1               │
│                          │ local b = 2               │ local b = 42              │
│ v Staged Changes (1)     │ return a + b              │ return a + b              │
│   M  scm.lua  lua/plugins│                           │                           │
│ v Changes (2)            │        read-only          │       you type here       │
│   M  init.lua            │                           │                           │
│   D  gone.lua            │                           │                           │
│ v Untracked (1)          │                           │                           │
│   ?  scratch.txt         │                           │                           │
└──────────────────────────┴───────────────────────────┴───────────────────────────┘
```

## Commands

| Command | What it does |
| --- | --- |
| `:Scm` | Toggle the source control panel |
| `:ScmOpen` / `:ScmClose` | Open / close the panel |
| `:ScmRefresh` | Re-read `git status` |
| `:ScmDiff [rev]` | Diff the current file side by side (against `rev` if given) |
| `:ScmDiffClose` | Close the diff and leave diff mode |
| `:ScmCommit [amend]` | Open a commit message buffer for the staged changes |
| `:ScmLog [rev]` | Browse the commit history in the panel |
| `:ScmFileLog` | Browse the history of the current file |
| `:ScmShow [rev]` | Inspect a commit and the files it touched (default `HEAD`) |
| `:ScmBlame` | Inspect the commit that last touched the current line |

## The three views

The sidebar hosts one view at a time and `<BS>` walks back through the ones you
came from:

- **status** — the working tree (this is what `:Scm` opens)
- **log** — a commit list, repo-wide (`L`) or for a single file (`l`)
- **commit** — one commit: sha, author, date, full message, and its files

## Panel mappings

Working tree:

| Key | Action |
| --- | --- |
| `<CR>` / `o` / double click | Open the side-by-side diff and jump into it |
| `p` | Same, but keep the cursor in the panel |
| `s` / `u` / `-` | Stage / unstage / toggle the file under the cursor |
| `S` / `U` | Stage everything in this section / unstage everything |
| `X` | Discard changes (deletes the file if it is untracked) |
| `cc` / `ca` | Commit / amend the last commit |
| `<Tab>` | Collapse or expand the section under the cursor |

History:

| Key | Action |
| --- | --- |
| `L` | Commit history for the repository |
| `l` | History of the file under the cursor |
| `<CR>` | On a commit: inspect it — in a file's history: diff that file at that commit |
| | On a commit's file: diff it against the parent commit |
| `i` | Inspect the commit under the cursor |
| `D` | Open the commit as one unified patch in the editor area |
| `m` | Load another 50 commits |
| `y` | Yank the commit sha |
| `<BS>` | Back to the previous view |

Anywhere:

| Key | Action |
| --- | --- |
| `J` / `K` | Jump to the next / previous item |
| `r` | Refresh |
| `q` | Close the panel and any open diff |
| `g?` | Show this list |

## Diff mappings

| Key | Action |
| --- | --- |
| `]c` / `[c` | Next / previous change (built-in diff mode) |
| `do` / `dp` | Obtain / put a hunk (built-in diff mode) |
| `q` | Close the diff |
| `<leader>gS` | Stage the file you are looking at |

## What each section diffs

The panel mirrors what VS Code shows when you click an entry:

- **Changes** — index (or `HEAD` for a file that is not in the index) on the left,
  the file on disk on the right. The right side is the real buffer: edit it, `:w`
  it, and the highlights follow.
- **Staged Changes** — `HEAD` on the left, the staged blob on the right. Both are
  read-only, because the index is not a file you can type into. Unstage with `u`
  if you want to edit.
- **Untracked** — an empty buffer on the left, the new file on the right.
- **Merge Conflicts** — "ours" (`:2:`) on the left, the file with its conflict
  markers on the right, editable so you can resolve it in place.
- **A commit's file** — the parent commit's version on the left, the commit's own
  version on the right. Both read-only: history is not editable. A file added in
  the commit gets an empty left side, a deleted one an empty right side, and a
  renamed one is compared against its old path.

A file's history follows renames (`git log --follow`), so a commit that renamed
the file is annotated with the name it had before, and diffing it compares the
right pair of paths.

## Setup

```lua
require("scm").setup({
  width = 42,               -- panel width
  position = "left",        -- "left" | "right"
  fold_unchanged = false,   -- true to fold away unchanged regions
  confirm_discard = true,   -- ask before discarding / deleting
  live_diff = true,         -- re-diff shortly after you stop typing
  live_diff_debounce = 150,
  set_diffopt = true,       -- apply readable side-by-side diff options
  auto_refresh = true,      -- refresh after writes and on focus gained
})
```

Highlight groups (all `default`-linked, so a colorscheme can override them):
`ScmTitle`, `ScmSection`, `ScmBranch`, `ScmDim`, `ScmPath`, `ScmAdded`,
`ScmModified`, `ScmDeleted`, `ScmRenamed`, `ScmConflict`, `ScmUntracked`,
`ScmSha`, `ScmDiffOld`, `ScmDiffNew`.

## Layout

```
scm.nvim/
├── lua/scm/
│   ├── init.lua     -- setup, highlights, autocmds, public API
│   ├── config.lua   -- options
│   ├── state.lua    -- shared window/buffer state
│   ├── git.lua      -- git CLI wrapper (status, log, blobs, stage, commit, blame)
│   ├── panel.lua    -- the sidebar: window, views, keymaps
│   ├── log.lua      -- the history views (commit list, commit details, blame)
│   ├── diff.lua     -- the side-by-side view
│   └── commit.lua   -- the commit message buffer
└── plugin/scm.lua   -- user commands
```
