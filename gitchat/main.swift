import AppKit

setvbuf(stdout, nil, _IOLBF, 0)   // line-buffer logs even when piped to a file

// Top-level code isn't implicitly MainActor in language mode 5.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()   // never returns; `delegate` stays alive for the app's lifetime
}
