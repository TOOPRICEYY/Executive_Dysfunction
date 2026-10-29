# Holdfast for Windows — development specification

Status: specification only. No source in this repository implements it yet.
Date: 2026-10-02.

## 1. Scope

This document specifies the parts of a Windows edition that do not themselves
block anything:

- the desktop app (window, dashboard, editors, dialogs, tray icon);
- a portable core library that reproduces the Apple apps' schedule, status and
  lock rules exactly;
- sync of rules with the Mac through an iCloud Drive file;
- the boundary where an enforcement component plugs in.

**Out of scope.** The enforcement component itself — whatever actually blocks
websites or programs, and anything that protects it — is not specified here.
The app must work, and must say so honestly, when no enforcer is present.

## 2. Architecture

```
Platform/Windows/
  core/        HoldfastCore   portable C++20 static library,
