# Contributing to Copy

Copy is built in the open and contributions are welcome. This page covers the two
things worth knowing before you send a pull request: how to run the code, and the
sign-off the CI expects on every commit.

## Where to start

- 🐛 [Open an issue](https://github.com/tarikbc/Copy/issues) for a bug or a
  feature idea. A short screen recording beats a long description.
- 🔧 Send a pull request. Small and focused lands faster than large and sweeping.

## Building and testing

```sh
swift test --package-path CopyCore      # the engine and its test suite
xcodegen generate                       # regenerate Copy.xcodeproj
xcodebuild -project Copy.xcodeproj -scheme Copy -configuration Debug build
xcodebuild -project Copy.xcodeproj -scheme Copy -configuration Debug test
```

The core engine lives in `CopyCore` and has its own tests. Please add or update
tests for any engine change.

`Copy.xcodeproj` is generated from `project.yml` and is not committed. If you run
`swift test` before committing, check that `CopyCore/Package.resolved` still pins
GRDB, KeyboardShortcuts, and Sparkle. The two tools disagree about that file and
CI will tell you if a pin went missing.

## House style

The design language is deliberately quiet and native. No colored card stripes, no
clutter, nothing that announces itself. The app keeps a macOS 14 floor, with
newer-OS features behind availability checks.

## Sign your commits off

Every commit needs a `Signed-off-by` trailer matching its author. CI checks this
and the `signoff` check goes red on the pull request otherwise.

Add one with `-s`:

```sh
git commit -s -m "Fix the paste stack losing order on wake"
```

That appends a line built from your git `user.name` and `user.email`:

```
Signed-off-by: Jane Hacker <jane@example.com>
```

To fix commits you already made:

```sh
git commit --amend -s --no-edit     # just the last one
git rebase --signoff origin/main    # every commit on your branch
```

Then force-push your branch.

### Or let a hook remember for you

The repo ships a `prepare-commit-msg` hook that adds the trailer to every commit.
Turn it on once per clone:

```sh
git config core.hooksPath .githooks
```

After that, plain `git commit` is signed off and `-s` becomes optional. The hook
skips merge commits, never duplicates a trailer you already wrote, and does
nothing if your git identity is unset. It is a dozen lines of `sh`; read it at
[`.githooks/prepare-commit-msg`](.githooks/prepare-commit-msg) before you enable
it, the same as you would any hook.

### What you are certifying

The trailer says you have the right to submit the code under GPL-3.0. It is the
[Developer Certificate of Origin](DCO), the same one the Linux kernel uses. Read
the four clauses in [`DCO`](DCO); they are short.

Two things it is *not*. It is not a copyright assignment, so you keep the
copyright in what you write. And it is not a relicensing grant, so your
contribution stays GPL-3.0 unless you later agree otherwise.

## Licensing of contributions

Contributions are licensed under [GPL-3.0](LICENSE), the same as the rest of the
project. Please do not paste in code you found elsewhere unless its license is
GPL-3.0 compatible and you say so in the pull request.

The name and the artwork sit outside that grant. See [TRADEMARK.md](TRADEMARK.md)
if you are packaging or forking rather than contributing.
