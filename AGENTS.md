# Agent notes

## Release merge commit = App Store What's New

When merging `dev` into `release`, the **merge commit message body** is uploaded as the App Store "What's New" text. Write that body for customers, not for git history.

Rules:

- First line can be a short subject (`Release 1.1` or the default merge subject). CI strips a leading `Merge branch` / `Merge pull request` line and uses everything after it.
- The body is what shoppers see. Use 2–8 short bullets or short sentences.
- Describe user-visible changes only: new features, fixes, and behavior they will notice.
- Do not mention files, types, PRs, SHAs, tickets, "refactors", or internal bug IDs.
- No marketing fluff or "various improvements" with no specifics.
- Stay under 4000 characters. Aim for under 500.
- If a GitHub PR is the merge vehicle, put the same What's New text in the PR body so it lands in the merge commit.

Example:

```
Release 1.1

• Log swimming with lengths per stroke and a better calorie estimate
• Weight from Apple Health now shows up in the diary
• Fixed a crash when removing items from an AI food estimate
• Corrected USDA branded-food calories so a cup of milk matches the label
```
