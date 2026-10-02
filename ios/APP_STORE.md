# InFocus Portal (iOS): TestFlight and App Store

Everything needed to put the iPhone/iPad app on TestFlight, and later the App Store.

## App record (once)

App Store Connect → Apps → **+** → New App (an Admin must do this; the API can't create apps):

| Field | Value |
|---|---|
| Platform | iOS |
| Name | InFocus Portal |
| Primary language | English (U.S.) |
| Bundle ID | com.infocuspaly.portal |
| SKU | infocus-portal-ios |
| User access | Full access |

Then `ios/scripts/release-ios.sh` uploads builds; they appear under TestFlight after processing (5–15 minutes).
**Internal testers** (people on the App Store Connect team) need no review. **External testers** (students) need Beta App Review once per version, plus the privacy policy URL and the review sign-in below.

## Guideline checklist

| Guideline | How the app meets it |
|---|---|
| 2.1 App completeness | Everything works for a signed-in class member. App Review can't sign in with a school Google account, so give them an **email-code demo account** (see Review notes). |
| 2.5.6 Web content | WKWebView only. Other sites open in Safari sheets. |
| 4.2 Minimum functionality | Beyond the website: native sign-in hand-off, push notifications that open the right page, a native offline screen, downloads to the share sheet, and camera/library uploads. |
| 5.1.1(i) Privacy policy | Required for external TestFlight and the App Store. The Portal has no public privacy page yet; add one (e.g. `/privacy`) before external testing. |
| 5.1.1(ii) Permissions | Notifications are offered once after sign-in with a native explanation first. Camera, microphone and photos are only requested when the person uploads. |
| 5.1.1(v) Account deletion | Accounts are created by the program's staff (Admin → People), not in the app. Say so in the review notes. |
| Export compliance | HTTPS only; `ITSAppUsesNonExemptEncryption = false`. |
| Privacy manifest | `PrivacyInfo.xcprivacy`: no tracking; name, email and the push token are collected for app functionality and linked to the account; UserDefaults (CA92.1). |
| SDK / Xcode | Built by `scripts/release-ios.sh` with the release Xcode (beta builds are rejected). |

## Listing

- **Subtitle:** The InFocus class, in your pocket
- **Category:** Education · secondary Productivity
- **Keywords:** `infocus,paly,broadcast,journalism,class,packages,grades,teleprompter,show,student,news`
- **Promotional text:** Packages, grades, scripts and the show calendar for InFocus members, with notifications when something needs you.

**Description**

> InFocus Portal is the class app for InFocus, Palo Alto High School's student broadcast network.
>
> Sign in with your school account to:
> • Follow your package through every stage, from pitch to Final Cut
> • See feedback and approvals the moment producers post them
> • Check grades, extensions and the master calendar
> • Read and run teleprompter scripts
> • Upload footage straight from your phone
>
> Turn on notifications to hear about approvals, feedback, deadlines and messages, the same things the Portal emails you about. Tap one to jump straight to that page.
>
> For InFocus members; accounts are set up by the program's staff.

## App Privacy answers

- **Tracking:** No.
- **Contact info → Name, Email address:** App Functionality; linked to the user; not used for tracking.
- **Identifiers → Device ID** (the push token kept with the account): App Functionality; linked; not tracking.
- **User content → Photos or videos, Other user content** (uploads, comments, scripts): App Functionality; linked; not tracking.
- Everything else: not collected.

## Age rating

None for every content question. Unrestricted web access: No (other sites open in Safari sheets). User-generated content is shared only within the class.

## Review notes (fill in the demo account before submitting)

> InFocus Portal is the class app for a high school broadcast journalism program. Accounts are created by the program's staff; there is no public sign-up.
>
> To sign in: tap **Sign in with an email code**, enter the demo address below, and enter the code we send (or the fixed code below). The demo account sees sample packages and grades.
> Demo email: ________  Code: ________
>
> Notifications are offered after sign-in. They carry Portal emails (approvals, feedback, deadlines) and open the matching page when tapped.

## TestFlight "What to test"

> Sign in with your school account (or an email code), allow notifications, then: open a group's stage and leave a comment, upload a clip from your camera roll, download a file, pull down to refresh, turn on Airplane Mode to see the offline screen, and sign out from the Portal's menu. Ask someone to approve your pitch and check that the notification opens that page.
