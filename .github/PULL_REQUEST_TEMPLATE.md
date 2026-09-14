<!-- Thanks for sending this. Nothing here is mandatory except the sign-off. -->

## What this changes

<!-- One or two sentences. If it fixes an issue, write "Fixes #123". -->

## How you tested it

<!-- The commands you ran, or the steps you clicked through. A short screen
     recording is worth a lot for anything that moves on screen. -->

---

- [ ] Every commit is signed off (`git commit -s`, or turn on the hook once with
      `git config core.hooksPath .githooks`). The DCO check enforces this. See
      [CONTRIBUTING.md](../blob/main/CONTRIBUTING.md).
- [ ] Engine changes come with tests (`swift test --package-path CopyCore`)
- [ ] `CopyCore/Package.resolved` still pins GRDB, KeyboardShortcuts and Sparkle
