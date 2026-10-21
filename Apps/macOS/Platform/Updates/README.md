# Updates

`UpdateService` is the whole of it: «Проверить обновления…» in the Direct build,
«Перезапустить» in the store build and in a build that cannot verify an update, and the thin
layer over Sparkle behind the first of those. Sparkle answers a check in its own windows — an
update to install, or «Установлена последняя версия» — and only an installed update restarts
the app.

Three facts worth knowing before changing anything here:

- **Sparkle's XPC services stay inside `Sparkle.framework`.** Sparkle 2 refuses to start when
  it finds them copied into `Contents/XPCServices` of the application. A sandboxed app turns
  them on with `SUEnableInstallerLauncherService` in its `Info.plist` instead.
- **A build that cannot verify an update never looks for one.** Until a release puts the
  owner's real EdDSA key in place of the placeholder, `UpdateService.canVerifyUpdates` is
  false, the menu item says «Перезапустить» and no updater is ever started.
- **The store build has none of this.** `#if APPSTORE` everywhere, no feed, no key, and
  `make check-appstore-clean` looks inside the built bundle to make sure.
