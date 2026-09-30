import Foundation

struct BlockPageRenderStatus: Equatable {
    var activeRuleCount: Int
    var activeDomainCount: Int
    var lockdownEndsAt: Date?
}

struct BlockPageTemporaryPauseOption: Equatable, Sendable {
    var rule: BlockPageRuleDescriptor
    var challenge: BlockPagePauseChallenge
}

enum BlockPageRenderer {
    static let returnMessage = "Holdfast has returned this time to you."

    static func html(
        host: String,
        status: BlockPageRenderStatus?,
        temporaryPauseOptions: [BlockPageTemporaryPauseOption] = [],
        appRequiredRules: [String] = [],
        now: Date = Date()
    ) -> String {
        let safeHost = escape(host.isEmpty ? "This site" : host)

        var detail = ""
        if let endsAt = status?.lockdownEndsAt, endsAt > now {
            detail = """
            <p class="lock">Lockdown session — \(remainingDescription(endsAt.timeIntervalSince(now))) remaining</p>
            """
        } else if let status {
            detail = """
            <p class="lock">\(status.activeRuleCount) rule(s) active · \(status.activeDomainCount) domain(s)</p>
            """
        }

        let pauseControls = temporaryPauseOptions.isEmpty
            ? ""
            : """
            <section class="pause" aria-labelledby="pause-title">
              <h2 id="pause-title">Need a deliberate exception?</h2>
              <p>Type the confirmation passage, then choose how long to pause one specific rule. It turns back on automatically.</p>
              \(temporaryPauseOptions.map(pauseForm).joined(separator: "\n"))
            </section>
            """

        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Blocked — \(safeHost)</title><style>
        :root{color-scheme:light dark}
        *{box-sizing:border-box}
        body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
          font:16px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;
          background:radial-gradient(circle at 50% 10%,#ecf7ff 0,#f5f5f7 44%);color:#1d1d1f;padding:24px}
        .card{max-width:34rem;width:100%;background:rgba(255,255,255,.94);border:1px solid rgba(37,99,235,.12);
          border-radius:22px;padding:38px 34px;box-shadow:0 1px 3px rgba(0,0,0,.08),0 18px 48px rgba(30,64,175,.10);text-align:center}
        .mark{display:grid;place-items:center;width:64px;height:64px;margin:0 auto 18px;border-radius:18px;
          background:linear-gradient(145deg,#09133f,#182563);color:#55e6ee;font-size:38px;font-weight:800;
          box-shadow:inset 0 0 0 1px rgba(96,165,250,.25),0 10px 24px rgba(15,23,42,.18)}
        h1{font-size:1.45rem;line-height:1.25;margin:0 auto 9px;max-width:27rem;letter-spacing:-.02em}
        .lead{margin:0;color:#5c5c61;font-size:.94rem}
        .host{font:600 1.05rem/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;
          background:#f0f3f9;border-radius:10px;padding:9px 13px;margin:19px 0;word-break:break-all}
        p{margin:8px 0;color:#5c5c61;font-size:.92rem}
        .lock{color:#8a5a00;font-weight:600}
        .pause{margin-top:25px;padding-top:21px;border-top:1px solid #e8e8ed;text-align:left}
        h2{font-size:1.08rem;margin:0 0 7px;text-align:center}
        .pause-rule{margin-top:16px;padding:16px;border:1px solid #dfe4ee;border-radius:14px;background:#f8faff}
        .rule-name{margin:0 0 10px;color:#1d1d1f;font-weight:700;text-align:center}
        .passage{padding:12px;border-radius:10px;background:#eef2f8;color:#34343a;font-size:.86rem;user-select:none}
        label{display:block;margin:12px 0 6px;color:#34343a;font-size:.86rem;font-weight:600}
        fieldset{border:1px solid #8a94a6;margin:14px 0;padding:10px 12px}
        legend{font-size:.85rem;font-weight:600;padding:0 6px}
        fieldset label{padding:8px;margin:0;cursor:pointer}
        fieldset input{accent-color:#356dde;margin-right:6px}
        fieldset p{font-size:.8rem}
        textarea{width:100%;min-height:92px;resize:vertical;border:1px solid #b8c1d1;border-radius:10px;padding:10px;
          background:#fff;color:#1d1d1f;font:inherit}
        .durations{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-top:10px}
        button{appearance:none;border:0;border-radius:10px;padding:10px 7px;background:#182563;color:#fff;
          font:600 .86rem/1.2 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;cursor:pointer}
        button:hover{background:#243785}button:focus-visible,textarea:focus-visible{outline:3px solid #55e6ee;outline-offset:2px}
        .foot{margin-top:23px;padding-top:17px;border-top:1px solid #e8e8ed;font-size:.82rem;color:#74747a}
        @media (prefers-color-scheme:dark){
          body{background:radial-gradient(circle at 50% 10%,#101c44 0,#05070e 48%);color:#f5f5f7}
          .card{background:rgba(20,23,34,.96);border-color:rgba(96,165,250,.18);box-shadow:none}
          .host{background:#252b3c}
          p,.lead{color:#a7a7ad}.lock{color:#ffb340}
          .pause,.foot{border-top-color:#383e50}.pause-rule{background:#1d2230;border-color:#383e50}
          .rule-name,label{color:#f5f5f7}.passage{background:#252b3c;color:#d5d5db}
          textarea{background:#151923;border-color:#51596d;color:#f5f5f7}
          .foot{border-top-color:#383e50;color:#92929a}}
        </style></head><body><main class="card">
        <div class="mark" aria-hidden="true">↗</div>
        <h1>\(returnMessage)</h1>
        <p class="lead">This destination is unavailable while your blocking rule is active.</p>
        <div class="host">\(safeHost)</div>
        \(detail)
        \(pauseControls)
        \(appRequiredRules.isEmpty ? "" : "<p>Temporary access for \(escape(appRequiredRules.joined(separator: ", "))) uses passage backoff. Open Holdfast, select the Blocking Group, and choose Disable temporarily.</p>")
        <p class="foot">The interruption is working exactly as you asked it to.</p>
        </main><script>\(BlockPageTypingGuard.script)</script></body></html>
        """
    }

    static func pauseGrantedHTML(host: String, ruleName: String, durationSeconds: Int) -> String {
        let safeHost = escape(host.isEmpty ? "this site" : host)
        let safeRule = escape(ruleName)
        let duration = escape(BlockPagePauseDuration.label(for: durationSeconds) ?? "a short time")
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="refresh" content="4;url=https://\(safeHost)/">
        <title>Temporary exception granted</title><style>
        :root{color-scheme:light dark}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;
          font:16px/1.55 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;background:#f5f5f7;color:#1d1d1f;padding:24px}
        main{max-width:34rem;background:#fff;border-radius:22px;padding:36px;text-align:center;box-shadow:0 18px 48px rgba(30,64,175,.10)}
        h1{font-size:1.4rem;margin:0 0 10px}p{color:#5c5c61}a{color:#182563;font-weight:700}
        @media(prefers-color-scheme:dark){body{background:#05070e;color:#f5f5f7}main{background:#141722}p{color:#a7a7ad}a{color:#55e6ee}}
        </style></head><body><main><h1>Temporary exception granted</h1>
        <p><strong>\(safeRule)</strong> is paused for \(duration). It will turn back on automatically.</p>
        <p>The original site will retry in a few seconds.</p><a href="https://\(safeHost)/">Try \(safeHost) now</a>
        </main></body></html>
        """
    }

    static func requestErrorHTML(message: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Temporary exception not granted</title></head><body>
        <main><h1>Temporary exception not granted</h1><p>\(escape(message))</p><p>Return to the blocked page and try again.</p></main>
        </body></html>
        """
    }

    private static func pauseForm(_ option: BlockPageTemporaryPauseOption) -> String {
        let ruleName = escape(option.rule.name.isEmpty ? "Unnamed rule" : option.rule.name)
        let passage = escape(option.challenge.passage)
        let token = escape(option.challenge.token)
        let ruleID = escape(option.rule.id.uuidString.lowercased())
        let buttons = BlockPagePauseDuration.allowedSeconds.compactMap { seconds -> String? in
            guard let label = BlockPagePauseDuration.label(for: seconds) else { return nil }
            return "<button type=\"submit\" name=\"durationSeconds\" value=\"\(seconds)\" disabled>\(escape(label))</button>"
        }.joined()
        return """
        <form class="pause-rule" method="post" action="/temporary-pause" autocomplete="off">
          <p class="rule-name">\(ruleName)</p>
          <fieldset><legend>Intention</legend>
            <label><input type="radio" name="intent" value="consciousIntervention" required> Conscious intervention</label>
            <label><input type="radio" name="intent" value="eDulgance" required> e-dulgance</label>
            <p>For your history only. The passage and access limits stay the same.</p>
          </fieldset>
          <p class="passage" aria-label="Confirmation passage">\(passage)</p>
          <input type="hidden" name="challenge" value="\(token)">
          <input type="hidden" name="ruleID" value="\(ruleID)">
          <label for="passage-\(ruleID)">Type the passage exactly</label>
          <p>Type directly. Pasting, dropping text, and autofill are disabled.</p>
          <noscript>JavaScript must be enabled to verify direct typing.</noscript>
          <textarea id="passage-\(ruleID)" name="passage" required spellcheck="false" autocapitalize="off" autocomplete="off" maxlength="12000"></textarea>
          <div class="durations" aria-label="Pause duration">\(buttons)</div>
        </form>
        """
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func remainingDescription(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(max(1, minutes))m"
    }
}
