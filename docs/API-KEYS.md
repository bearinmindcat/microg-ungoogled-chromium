# Google API keys and OAuth credentials

## Why they are needed

`ungoogled-chromium/flags.gn` deliberately blanks them:

```gn
google_api_key=""
google_default_client_id=""
google_default_client_secret=""
use_official_google_api_keys=false
```

With blank values Chromium **compiles the entire sign-in UI out**. There is no error and
no warning -- the sign-in entry point simply never appears, and microG has nothing to talk
to. This is the single easiest way to produce a build that looks fine and cannot sync.

## Where they are set

They are committed in `android_flags.release.gn`, which `build.sh` composes into `args.gn`
*after* `ungoogled-chromium/flags.gn`, so they override its blanks. They are already public
(see below), so keeping them out of the tree bought little.

`build.sh` also accepts them from the environment as an optional override, which is the
right route for CI secrets or for swapping in your own:

```bash
export GOOGLE_DEFAULT_CLIENT_ID="…apps.googleusercontent.com"
export GOOGLE_DEFAULT_CLIENT_SECRET="…"
export GOOGLE_API_KEY="…"          # optional; geolocation etc.
./build.sh --arch arm64 --target chrome_public_apk_target
```

If unset, the committed values in `android_flags.release.gn` are used.

Chromium also supports supplying them at **runtime** instead of compile time, via the same
three variable names — see
<https://chromium.googlesource.com/chromium/src/+/refs/heads/main/docs/api_keys.md>.

## Which credentials, and why not your own

The pair commonly used for this build originated as **OAuth2 credentials Google issued to
Linux distributions** shipping Chromium. In **March 2021 Google announced it was revoking
them**; Gentoo, Arch and Debian removed them from their packages and users lost sync
(<https://www.gentoo.org/support/news-items/2021-08-11-oauth2-creds-chromium.html>).
The pair now circulates in gists and forum posts as the way to restore sync in a
self-built Chromium.

You **can** register your own OAuth client, and Chromium documents how. But sign-in and
sync are deliberately restricted: Google grants the `chromesync` scope only to approved
clients, and the documented path for everyone else is adding a test account to
`google-browser-signin-testaccounts@chromium.org`. A self-registered client will give you
API keys for things like geolocation, but **will not give you working sync**. That is the
only reason a distro credential is used here rather than one of your own.

Consequences worth understanding:

- The credential is not yours and was not licensed to you. It can be revoked at any time,
  and if it is, sign-in breaks for every build using it. There is no self-service fix,
  because you cannot grant yourself the sync scope.
- Mass reuse is what triggered the 2021 revocation. Publishing a working pair in a public
  repository accelerates exactly that.

## What keeping them out of the repo does and does not do

**Does:** stops the pair being scraped from a public repo, avoids GitHub secret scanning,
and keeps the value in one place you control (a CI secret) rather than in git history.

**Does not:** hide usage from Google. Every token request carries the client id to Google's
servers, so they can see which client is in use, from which package, and at what volume —
which is how the 2021 revocation happened. Moving the value out of the repo is about
limiting reuse by others, not about concealment.

## Related failure that looks like a key problem

`UNREGISTERED_ON_API_CONSOLE` ("This android application is not registered to use OAuth2.0")
is **not** a credentials problem. It means `GoogleAuthUtil` bound to real Google Play
Services instead of microG, and it is fixed by the post-build smali redirect, not by
changing keys. See `microg/apply_microg_smali_patch.sh`.
