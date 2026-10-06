# scm.nvim

A full-screen source control view for Neovim. `:Scm` (or your `prefix+gg`
mapping) takes over the current window with the change list. Opening a file
replaces that list with a side-by-side diff — left is the old version, right is
the real file, editable, savable, and re-diffed as you type. `q` or `<BS>`
brings the list back.

The same panel also browses history, GitLens style: commit lists, one commit's
metadata and files, and a jump from any line to the commit that wrote it.

No dependencies beyond `git` and Neovim ≥ 0.10.

```
:Scm  —  the change list, full window

 statusline:  Source Control  main ↑1  1 staged · 2 changed      nvim
┌──────────────────────────────────────────────────────────┐
│ ▾ Staged Changes (1)                                     │
│   lua/plugins/ (1)                                       │
│     M  scm.lua                                           │
│                                                          │
│ ▾ Changes (3)                                            │
│   lua/ (2)                                               │
│     M  init.lua                                          │
│     D  gone.lua                                          │
│   M  README.md                                           │
│ ▾ Untracked (1)                                          │
│   ?  scratch.txt                                         │
│                                                          │
│   g? for help                                            │
└──────────────────────────────────────────────────────────┘

<CR>  —  only the diff     q / <BS>  —  back to the list

┌────────────────────────────┬─────────────────────────────┐
│ Index: lua/plugins/scm.lua │ lua/plugins/scm.lua         │
│ local a = 1                │ local a = 1                 │
│ local b = 2                │ local b = 42                │
│        read-only           │       you type here         │
└────────────────────────────┴─────────────────────────────┘
```

## Commands

| Command | What it does |
| --- | --- |
| `:Scm` | Toggle the change list. From history, this comes back to the working tree rather than closing |
| `:ScmOpen` / `:ScmClose` | Open the change list / close the panel |
| `:ScmRefresh` | Re-read `git status` |
| `:ScmDiff [rev]` | Diff the current file side by side (against `rev` if given) |
| `:ScmDiffClose` | Close the diff and leave diff mode |
| `:ScmCommit [amend]` | Open a commit message buffer for the staged changes |
| `:ScmLog [rev]` | Browse the commit history in the panel |
| `:ScmFileLog` | Browse the history of the current file |
| `:ScmShow [rev]` | Inspect a commit and the files it touched (default `HEAD`) |
| `:ScmBlame` | Inspect the commit that last touched the current line |

## The three views

The panel hosts one view at a time. `<BS>` or `q` walks back through the ones
you came from; `:Scm` / your prefix+gg mapping always returns to the working
tree, even if you are in history:

- **status** — the working tree (this is what `:Scm` opens)
- **log** — a commit list, repo-wide (`L`) or for a single file (`l`). When the branch is ahead of its base, the first row opens every file changed against that base
- **vs** — those files, diffed against the base (three-dot), opened from the row in the log
- **commit** — one commit: sha, author, date, full message, and the files that commit touched

Both file lists group by directory. Chains of directories with a single child
are joined into one line (`lua/scm/` rather than `lua/` above `scm/`), so a
change buried five levels deep still costs one indent level. `<Tab>` folds the
directory under the cursor, and `tree = false` gives you a flat list instead.

## Panel mappings

Working tree:

| Key | Action |
| --- | --- |
| `<CR>` / `o` / double click | Open the side-by-side diff (hides the list). On a directory: fold it |
| `p` | Open the side-by-side diff |
| `s` / `u` / `-` | Stage / unstage / toggle the file under the cursor |
| `S` / `U` | Stage everything in this section / unstage everything |
| `X` | Discard changes (deletes the file if it is untracked) |
| `cc` / `ca` | Commit / amend the last commit |
| `<Tab>` | Fold the directory under the cursor, or the whole section |

History:

| Key | Action |
| --- | --- |
| `L` | Commit history for the repository |
| `l` | History of the file under the cursor |
| `<CR>` | On a commit: inspect it — in a file's history: diff that file at that commit |
| | On `vs <branch>`: every file changed against that branch |
| | On a commit's file: diff it against the parent commit. On a file in the vs view: diff it against the base |
| `gf` | Open the working-tree file (not the historical blob) |
| `i` | Inspect the commit under the cursor |
| `D` | Open the commit as one unified patch (`q` / `<BS>` back) |
| `m` | Load another 50 commits |
| `y` | Yank the commit sha |
| `<BS>` | Back to the previous view (history → change list) |
| `q` | Same as `<BS>`; on the change list, close the panel |

Anywhere:

| Key | Action |
| --- | --- |
| `J` / `K` | Jump to the next / previous item |
| `r` | Refresh |
| `q` | Back one view; on the change list, close |
| `g?` | Open this keymap list in the panel |

## Diff mappings

| Key | Action |
| --- | --- |
| `]c` / `[c` | Next / previous change (built-in diff mode) |
| `do` / `dp` | Obtain / put a hunk (built-in diff mode) |
| `q` / `<BS>` | Close the side-by-side view (back to the change list) |
| `gf` | Open the working-tree file for editing (on read-only sides: commits, the index) |
| `<leader>gf` | Same, from either side of the diff |
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
  version on the right. Both read-only: history is not editable. `gf` (or
  `<leader>gf`) closes the diff and opens the working-tree file at the same line
  so you can edit. A file added in the commit gets an empty left side, a deleted
  one an empty right side, and a renamed one is compared against its old path.
- **A file in the vs view** — the base ref on the left, the branch tip on the
  right. Same read-only rules. The left label is the base name (`origin/master`),
  not a parent sha.

A file's history follows renames (`git log --follow`), so a commit that renamed
the file is annotated with the name it had before, and diffing it compares the
right pair of paths.

## Setup

```lua
require("scm").setup({
  tree = true,              -- false for a flat list of paths
  fold_unchanged = false,   -- true to fold away unchanged regions
  confirm_discard = true,   -- ask before discarding / deleting
  live_diff = true,         -- re-diff shortly after you stop typing
  live_diff_debounce = 150,
  set_diffopt = true,       -- apply readable side-by-side diff options
  auto_refresh = true,      -- refresh after writes and on focus gained
})
```

Highlight groups (set with `default`, so a colorscheme can override them):
`ScmTitle`, `ScmSection`, `ScmBranch`, `ScmDim`, `ScmDir`, `ScmPath`, `ScmAdded`,
`ScmModified`, `ScmDeleted`, `ScmRenamed`, `ScmConflict`, `ScmUntracked`,
`ScmSha`, `ScmRef`, `ScmAction`, `ScmDiffOld`, `ScmDiffNew`.
`ScmDiffOld` and `ScmDiffNew` copy the foreground of `Removed` and `Added`
for the diff labels. `ScmRef` marks branch and tag decorations in the log,
and `ScmAction` marks a key you can press.

## Layout

```
scm.nvim/
├── lua/scm/
│   ├── init.lua     -- setup, highlights, autocmds, public API
│   ├── config.lua   -- options
│   ├── state.lua    -- shared window/buffer state
│   ├── git.lua      -- git CLI wrapper (status, log, blobs, stage, commit, blame)
│   ├── panel.lua    -- the panel: window, views, keymaps
│   ├── tree.lua     -- directory grouping for the file lists
│   ├── log.lua      -- the history views (commit list, commit details, blame)
│   ├── diff.lua     -- the side-by-side view
│   └── commit.lua   -- the commit message buffer
└── plugin/scm.lua   -- user commands
```
