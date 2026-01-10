# Current Bugs

- [x] misplaced `free` command content:
```
 free -h
              total        used        free
Mem:    1.9G    55.5M    1.9G
```

- [x] Needs to press enter two times in the installer's "Press ENTER to continue or Ctrl+C to abort" step.
- [x] "Are you sure you want to install? Type 'YES' to confirm:" doesn't handle case sensitivity (eg, "yes" doesn't work).
- [x] fix the gtop when i scroll on processes list with arrow up/down, it always trigger an update.
