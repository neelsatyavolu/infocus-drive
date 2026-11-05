import SwiftUI

/// Settings → About: who built the Portal, how it runs, that it is open source, and how to
/// contribute. The same copy as the web's Settings → About (`components/about-portal.tsx`).
struct AboutPortalText: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("I'm [Neel Satyavolu](https://n3el.dev), and I built the InFocus Portal to run the class: package cycles, cut review, grades, the show calendar, the teleprompter, meetings, and the rest of what you see here.")
            Text("It's a Next.js and TypeScript app with a Postgres database, running on Cloudflare Workers. Videos are stored on InFocus Drive, a NAS that the class runs itself, and there are companion apps for iPhone and Mac.")
            Text("The Portal is open source under the MIT license. All of the code is public on [GitHub](https://github.com/neelsatyavolu/infocus-portal). Student data, grades, and media are not in the code and never will be.")
            Text("Contributions and suggestions are welcome. Open an issue or a pull request on GitHub, or email me at [neel@xanom.co](mailto:neel@xanom.co).")
        }
        .font(.small)
        .foregroundStyle(Brand.foreground)
        .tint(Brand.green)
        .padding(.vertical, 4)
    }
}
