#!/bin/bash
#
# Build / run helper for Irctell -- everything Xcode does with Cmd-R, without
# opening Xcode. Run './build.sh --help' for the full command list.

set -euo pipefail

cd "$(dirname "$0")"

PROJECT="Irctell.xcodeproj"
SCHEME="Irctell"
CONFIG="${CONFIG:-Debug}"

# Pinning the destination avoids xcodebuild's "using the first of multiple
# matching destinations" warning, which it emits because a Mac can build both
# arm64 and x86_64.
DESTINATION="platform=macOS,arch=$(uname -m)"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# ANSI colours, but only when stdout is a terminal, so piping stays clean.
if [ -t 1 ]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'
else
    BOLD=""; RED=""; GREEN=""; YELLOW=""; OFF=""
fi

info() { printf '%s==>%s %s\n' "$BOLD" "$OFF" "$*"; }
die()  { printf '%s==> %s%s\n' "$RED" "$*" "$OFF" >&2; exit 1; }

show_help() {
    cat <<EOF
${BOLD}Build / run helper for Irctell${OFF} -- everything Xcode does with Cmd-R,
without opening Xcode.

Usage: ./build.sh [command] [args]

Everyday commands:
  build              build (Debug) -- what runs with no command at all
  run                build, quit any running copy, and relaunch it
  test               run the unit tests
  path               print the path of the built .app
  stop               quit a running instance
  clean              delete build products

Release commands, in the order a release actually goes out:
  version [x.y.z]    show the current version, or bump to a new one
  dmg                build Release, sign it, and package
                     build/Irctell-<version>.dmg, plus the matching
                     build/Irctell-<version>-debug-symbols.zip that
                     crash reports are read with
  notarize           submit that .dmg to Apple and staple the ticket
  publish            create the GitHub release for <version> with the .dmg
                     and the debug symbols, once it has checked the .dmg is
                     notarized, no older than the source it was built from,
                     and that the symbols belong to the app inside it

  release            a bare Release-configuration build, for trying one
                     locally -- unsigned, no .dmg. Packaging one to ship
                     is 'dmg', not this.

Environment variables:
  CONFIG             Debug or Release; build/run/clean read it, default Debug
  NOTARY_PROFILE     the notarytool keychain profile to submit under,
                     default Irctell
EOF
}

# Ask xcodebuild where it puts the product rather than hardcoding a DerivedData
# path -- that path contains a hash of the project location and will differ on
# any other machine.
app_path() {
    local dir
    dir=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
                     -destination "$DESTINATION" -showBuildSettings 2>/dev/null \
          | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/{print $2; exit}')
    [ -n "$dir" ] || die "could not determine BUILT_PRODUCTS_DIR"
    printf '%s/%s.app\n' "$dir" "$SCHEME"
}

# sherpa-onnx's static libraries, for the natural voices: not in git, so
# fetched on the first build, at a fixed release, checked against its hash.
SHERPA_VERSION=1.13.8
SHERPA_ARCHIVE="sherpa-onnx-v$SHERPA_VERSION-osx-universal2-static-lib"
SHERPA_SHA256=5c8fd6490eafed66374e3b0cd6f7ef8e1bc87a64550d38bedde57775cf914d7e
SHERPA_LIB="Vendor/sherpa-onnx/lib"

fetch_vendor() {
    [ -f "$SHERPA_LIB/.version-$SHERPA_VERSION" ] && return
    info "Fetching sherpa-onnx $SHERPA_VERSION..."
    local tmp
    tmp=$(mktemp -d -t irctell-vendor)
    curl -fsSL -o "$tmp/lib.tar.bz2" \
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/v$SHERPA_VERSION/$SHERPA_ARCHIVE.tar.bz2" \
        || die "could not download sherpa-onnx"
    echo "$SHERPA_SHA256  $tmp/lib.tar.bz2" | shasum -a 256 -c - >/dev/null \
        || die "sherpa-onnx download does not match its checksum"
    tar xjf "$tmp/lib.tar.bz2" -C "$tmp"
    rm -rf "$SHERPA_LIB"
    mkdir -p "$SHERPA_LIB"
    cp "$tmp/$SHERPA_ARCHIVE"/lib/*.a "$SHERPA_LIB/"
    touch "$SHERPA_LIB/.version-$SHERPA_VERSION"
    rm -rf "$tmp"
}

build() {
    fetch_vendor
    local log
    log=$(mktemp -t irctell-build)
    # Trap rather than a plain rm at the end, so an interrupted build still
    # cleans up after itself.
    trap 'rm -f "$log"' RETURN

    generate_release_notes

    # A Release build is stripped of its symbol table. Xcode only strips as
    # part of an archive or install, never on a plain `build`; this turns on
    # Xcode's own strip step, which runs after the .dSYM is written and before
    # signing -- the .dSYM is what crash reports are symbolicated with.
    local postprocess=NO
    if [ "$CONFIG" = Release ]; then
        postprocess=YES
    fi

    info "Building $SCHEME ($CONFIG)..."

    if xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
                  -destination "$DESTINATION" \
                  DEPLOYMENT_POSTPROCESSING="$postprocess" build >"$log" 2>&1; then
        # xcodebuild is extremely chatty. On success, surface only real
        # diagnostics -- lines that start with an absolute source path.
        local warnings
        warnings=$(grep -E '^/.*: warning:' "$log" | sort -u || true)
        if [ -n "$warnings" ]; then
            printf '%s%s%s\n' "$YELLOW" "$warnings" "$OFF"
        fi
        # The Dock and Finder show the icon LaunchServices has on record for
        # this path: re-registered after every build, however it is launched.
        "$LSREGISTER" -f "$(app_path)" >/dev/null 2>&1 || true
        printf '%s==> Build succeeded%s\n' "$GREEN" "$OFF"
    else
        grep -E '^/.*: (error|warning):' "$log" || tail -40 "$log"
        die "Build failed"
    fi
}

stop_app() {
    if pgrep -x "$SCHEME" >/dev/null; then
        info "Quitting running $SCHEME..."
        osascript -e "tell application \"$SCHEME\" to quit" >/dev/null 2>&1 || true
        # Give it a moment to go away, then insist.
        for _ in $(seq 1 30); do
            pgrep -x "$SCHEME" >/dev/null || return 0
            /bin/sleep 0.1
        done
        pkill -x "$SCHEME" || true
    fi
}

# Unit tests. The test bundle is injected into the app, so the app launches and
# floods stderr with unrelated system logging; only the test lines are shown.
run_tests() {
    fetch_vendor
    local log
    log=$(mktemp -t irctell-test)
    trap 'rm -f "$log"' RETURN

    generate_release_notes

    info "Testing $SCHEME..."

    if xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
                  -destination "$DESTINATION" test >"$log" 2>&1; then
        grep -E "^Test Case .*(passed|failed)" "$log" \
            | sed -E "s/^Test Case '-\[[A-Za-z]+ (.*)\]'/    \1/" \
            | sed 's/ (.*seconds).*//' || true
        grep -E "^\s*Executed [0-9]+ test" "$log" | tail -1 | sed 's/^[[:space:]]*/    /'
        printf '%s==> Tests passed%s\n' "$GREEN" "$OFF"
    else
        grep -E "^Test Case .*failed|error:|XCTAssert" "$log" | head -40
        grep -E "^\s*Executed [0-9]+ test" "$log" | tail -1
        die "Tests failed"
    fi
}

# The Developer ID certificate to sign with, by its SHA-1 hash -- never by
# its name. The name, "Peter Verhás", has an accented letter that codesign
# mis-decodes as MacRoman and then fails to match; and two certificates carry
# that same name: the original-authority one ending on 1 February 2027, and
# its G2 replacement, which this hash is. Taking "the first one listed" picked
# the old certificate. Override for a later certificate with
#   DEVELOPER_ID=<sha-1 hash> ./build.sh ...
# (`security find-identity -v -p codesigning` lists the hashes.)
DEVELOPER_ID="${DEVELOPER_ID:-4F265A5D1E4D6CBA168179118CFC740B60C1778E}"

# The configured certificate's hash, when it is in the keychain and can sign;
# empty otherwise -- then the build is unsigned, and no other certificate is
# ever used in its place.
#
# `|| true` throughout: under `set -e` a pipeline that finds nothing must mean
# "no Developer ID here", not abort the whole build.
developer_id() {
    security find-identity -v -p codesigning 2>/dev/null \
        | awk -v id="$DEVELOPER_ID" 'toupper($2) == toupper(id) { print $2; exit }' || true
}

# For status messages only -- the name, and the hash that is actually used.
# Never pass this to codesign, see above.
developer_id_name() {
    security find-identity -v -p codesigning 2>/dev/null \
        | awk -v id="$DEVELOPER_ID" 'toupper($2) == toupper(id) { print; exit }' \
        | sed 's/.*"\(.*\)"/\1/' \
        | sed "s/\$/ [$DEVELOPER_ID]/" || true
}

# Submit the image to Apple and staple the resulting ticket, so the app opens
# without a warning even on a machine that has never seen it.
#
# Needs credentials stored once with:
#   xcrun notarytool store-credentials Irctell \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
# The version lives in the project file, twice -- once per build configuration --
# and there is no Info.plist to edit: GENERATE_INFOPLIST_FILE is on, so Xcode
# synthesises one from these settings at build time.
#
# sed rather than awk fields: the lines are tab-indented, so which field holds
# the value depends on how the separator treats leading whitespace -- and
# getting that wrong reads an empty string.
current_marketing_version() {
    sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' "$PROJECT/project.pbxproj" | head -1
}

RELEASE_NOTES_OUT="Irctell/ReleaseNotes.txt"

# Concatenates every release-notes-*.md into one bundled resource, newest
# version first. Irctell/ReleaseNotes.txt lives inside the Irctell group,
# which Xcode's file-system-synchronized group copies straight into the app's
# Resources on every build -- no project-file entry needed for it.
generate_release_notes() {
    shopt -s nullglob
    local files=(release-notes-*.md)
    shopt -u nullglob
    [ "${#files[@]}" -gt 0 ] || die "no release-notes-*.md files found"

    local versions
    versions=$(for f in "${files[@]}"; do
        [[ "$f" =~ ^release-notes-(.+)\.md$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"
    done | sort -rV)

    : > "$RELEASE_NOTES_OUT"
    local version first=1
    while IFS= read -r version; do
        [ "$first" = 1 ] || printf '\n\n' >> "$RELEASE_NOTES_OUT"
        first=0
        cat "release-notes-$version.md" >> "$RELEASE_NOTES_OUT"
    done <<< "$versions"
}

# Setting the version by hand is the kind of thing that is easy to half-do.
# Change only the Release copy and a debug build reports a different version
# from the one you shipped; forget CURRENT_PROJECT_VERSION and Apple rejects
# the second upload of a version as a duplicate, because that number is what
# distinguishes two builds of the same release.
show_or_set_version() {
    local wanted="${1:-}"
    local current build_number
    current=$(current_marketing_version)
    build_number=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \(.*\);/\1/p' \
                   "$PROJECT/project.pbxproj" | head -1)
    [ -n "$current" ] || die "no MARKETING_VERSION in $PROJECT/project.pbxproj"
    case "$build_number" in
        ''|*[!0-9]*) die "CURRENT_PROJECT_VERSION is '$build_number', which is not a number" ;;
    esac

    if [ -z "$wanted" ]; then
        printf '%s (build %s)\n' "$current" "$build_number"
        return
    fi

    # Semantic versioning, since that is what the README promises and what the
    # DMG filename becomes.
    case "$wanted" in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) die "version must look like 1.2.3, not '$wanted'" ;;
    esac

    local count
    count=$(grep -c "MARKETING_VERSION = " "$PROJECT/project.pbxproj" || true)
    [ "$count" -ge 2 ] || die "expected a MARKETING_VERSION per configuration, found $count"

    # Every occurrence, so the configurations cannot drift apart.
    sed -i '' "s/MARKETING_VERSION = .*;/MARKETING_VERSION = $wanted;/g" \
        "$PROJECT/project.pbxproj"
    sed -i '' "s/CURRENT_PROJECT_VERSION = .*;/CURRENT_PROJECT_VERSION = $(( build_number + 1 ));/g" \
        "$PROJECT/project.pbxproj"

    printf '%s==> %s (build %s) -- was %s (build %s)%s\n' \
        "$GREEN" "$wanted" "$(( build_number + 1 ))" "$current" "$build_number" "$OFF"
    printf '    %s\n' "The next ./build.sh dmg writes build/Irctell-$wanted.dmg"
}

notarize_dmg() {
    local dmg
    dmg=$(/bin/ls -t "$PWD/build"/Irctell-*.dmg 2>/dev/null | head -1)
    [ -n "$dmg" ] || die "no disk image in ./build -- run ./build.sh dmg first"

    [ -n "$(developer_id || true)" ] || die "notarizing needs a Developer ID certificate"

    # A stale image is the easy mistake: `dmg` and `notarize` are separate
    # commands, and the newest image in ./build may predate the certificate.
    local mount device
    mount=$(mktemp -d)
    # The device is detached by name, not by mount point: detaching by path
    # fails once the path is gone, and an image left attached makes the next
    # `hdiutil create` fail with nothing more helpful than "Resource busy".
    device=$(hdiutil attach -nobrowse -noverify "$dmg" -mountpoint "$mount" \
             | awk '/^\/dev\/disk/{print $1; exit}')
    local signed_ok=0 inside
    inside=$(codesign -dvv "$mount"/*.app 2>&1 || true)
    case "$inside" in *"Authority=Developer ID Application"*) signed_ok=1 ;; esac
    [ -n "$device" ] && hdiutil detach "$device" -force -quiet || true
    rmdir "$mount" 2>/dev/null || true
    [ "$signed_ok" = 1 ] || die "$(basename "$dmg") holds an app that is not Developer ID signed -- run ./build.sh dmg again"

    info "Submitting $(basename "$dmg") to Apple (this takes a few minutes)"
    local output status submission
    # notarytool exits 0 when the *submission* succeeded, whatever the verdict
    # was, so the verdict has to be read rather than assumed. Stapling a
    # rejected submission is what this used to do, and it failed confusingly
    # several minutes after the real error had already scrolled past.
    output=$(xcrun notarytool submit "$dmg" \
                --keychain-profile "${NOTARY_PROFILE:-Irctell}" --wait 2>&1) || true
    printf '%s\n' "$output" | sed 's/^/    /'

    submission=$(printf '%s\n' "$output" | awk '/^ *id: /{print $2; exit}')
    status=$(printf '%s\n' "$output" | awk '/^ *status: /{print $2; exit}')

    if [ "$status" != "Accepted" ]; then
        printf '%s==> Notarization was %s. Apple says:%s\n' "$YELLOW" "${status:-unknown}" "$OFF"
        [ -n "$submission" ] && xcrun notarytool log "$submission" \
            --keychain-profile "${NOTARY_PROFILE:-Irctell}" 2>&1 | sed 's/^/    /'
        die "notarization failed -- nothing was stapled"
    fi

    info "Stapling the ticket"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    printf '%s==> Notarized: %s%s\n' "$GREEN" "$dmg" "$OFF"
}

# Uploads the current version's .dmg to GitHub as a release, tagging it on
# the way. Separate from `dmg` and `notarize` on purpose: those two produce
# and vouch for one file on this Mac, entirely offline, and can be repeated
# as often as a build needs fixing; this one is the single irreversible step
# that tells the world -- creating a public tag and release nothing here
# will quietly redo.
publish_release() {
    # Published from what everyone else can also see, not from whatever this
    # one checkout happens to be holding: nothing uncommitted, and nothing
    # committed that has not actually reached the remote yet.
    if [ -n "$(git status --porcelain)" ]; then
        git status --short | sed 's/^/    /'
        die "there are uncommitted changes -- commit or discard them before publishing"
    fi
    local upstream
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
    [ -n "$upstream" ] || die "no upstream branch is configured for $(git branch --show-current)"
    local ahead
    ahead=$(git rev-list --count "$upstream"..HEAD)
    if [ "$ahead" != 0 ]; then
        git log --oneline "$upstream"..HEAD | sed 's/^/    /'
        die "$ahead commit(s) are not pushed to $upstream -- push before publishing"
    fi

    local version dmg
    version=$(current_marketing_version)
    [ -n "$version" ] || die "no MARKETING_VERSION in $PROJECT/project.pbxproj"
    dmg="$PWD/build/Irctell-$version.dmg"
    [ -f "$dmg" ] || die "$dmg does not exist -- run ./build.sh dmg first"

    local notes="release-notes-$version.md"
    [ -f "$notes" ] || die "$notes does not exist -- write this release's notes first"

    # Recent: nothing the image was built from has changed since. `dmg` and
    # `publish` are separate commands specifically so a build can be
    # inspected before it ships -- which also means an edit made in between,
    # however small, would otherwise go out silently unpackaged.
    local newer
    newer=$(find Irctell IrctellTests Irctell.xcodeproj "$notes" build.sh \
                 -type f -newer "$dmg" 2>/dev/null)
    if [ -n "$newer" ]; then
        printf '%s\n' "$newer" | sed 's/^/    /'
        die "$(basename "$dmg") is older than the file(s) above -- run ./build.sh dmg again"
    fi

    # Notarized: asked of the file itself, the same way Gatekeeper does,
    # rather than assumed from having run `notarize` at some point.
    xcrun stapler validate "$dmg" >/dev/null 2>&1 \
        || die "$(basename "$dmg") is not notarized -- run ./build.sh notarize first"

    # The debug symbols go up with the image, and must be the ones for the
    # app inside it: both files are named only by version, so a zip left from
    # an earlier `dmg` run of the same version would otherwise be published
    # without complaint, and found out only when a crash report from it could
    # not be read.
    local symbols="$PWD/build/Irctell-$version-debug-symbols.zip"
    [ -f "$symbols" ] || die "$symbols does not exist -- run ./build.sh dmg again"
    local scratch mount device app_uuids symbol_uuids
    scratch=$(mktemp -d)
    mount="$scratch/image"
    mkdir "$mount"
    device=$(hdiutil attach -nobrowse -noverify -readonly "$dmg" -mountpoint "$mount" \
             | awk '/^\/dev\/disk/{print $1; exit}')
    app_uuids=$(build_uuids "$mount/Irctell.app/Contents/MacOS/Irctell" 2>/dev/null || true)
    [ -n "$device" ] && hdiutil detach "$device" -force -quiet || true
    ditto -x -k "$symbols" "$scratch/symbols"
    symbol_uuids=$(build_uuids "$scratch/symbols/Irctell.app.dSYM" 2>/dev/null || true)
    rm -rf "$scratch"
    [ -n "$app_uuids" ] || die "could not read the app's build UUIDs from $(basename "$dmg")"
    [ "$app_uuids" = "$symbol_uuids" ] \
        || die "$(basename "$symbols") is not from the build inside $(basename "$dmg") -- run ./build.sh dmg again"

    command -v gh >/dev/null 2>&1 || die "the GitHub CLI ('gh') is not installed"

    # GitHub adds the two source archives on its own; the image and the
    # symbols are the only files uploaded. The app's update check picks the
    # .dmg by name, so a second asset does not get in its way.
    info "Publishing $(basename "$dmg") and $(basename "$symbols") as the $version release on GitHub"
    gh release create "$version" "$dmg" "$symbols" --title "$version" --notes-file "$notes"
    printf '%s==> Released %s%s\n' "$GREEN" "$version" "$OFF"
}

# Package the Release build as a disk image with an Applications shortcut, the
# arrangement users expect: mount, drag across, eject.
make_dmg() {
    # Checked before spending time on a build and a signature: a version
    # bumped without release notes to go with it is the one way this app
    # could ship saying nothing about what changed.
    local wanted_version
    wanted_version=$(current_marketing_version)
    [ -n "$wanted_version" ] || die "no MARKETING_VERSION in $PROJECT/project.pbxproj"
    local notes_file="release-notes-$wanted_version.md"
    [ -f "$notes_file" ] \
        || die "$notes_file does not exist -- write this release's notes before packaging a dmg for it"
    local heading expected_heading
    heading=$(head -1 "$notes_file")
    expected_heading="# Irctell $wanted_version"
    [ "$heading" = "$expected_heading" ] \
        || die "$notes_file's first line is '$heading', expected '$expected_heading'"

    CONFIG=Release
    build

    local app version staging dmg
    app=$(app_path)
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
              "$app/Contents/Info.plist")
    [ "$version" = "$wanted_version" ] \
        || die "built app reports version $version but project.pbxproj says $wanted_version"
    dmg="$PWD/build/Irctell-$version.dmg"

    # The shipped executable has no symbol names any more, so a crash report
    # from it can only be read against this build's .dSYM -- and no later
    # build can reproduce that. Zipped beside the image, for `publish` to
    # attach to the release. --keepParent keeps the Irctell.app.dSYM folder
    # name inside the zip, which is what symbolication tools look for.
    [ -d "$app.dSYM" ] || die "no $app.dSYM -- a stripped build without it cannot be symbolicated"
    local symbols="$PWD/build/Irctell-$version-debug-symbols.zip"
    mkdir -p "$PWD/build"
    rm -f "$symbols"
    ditto -c -k --keepParent "$app.dSYM" "$symbols" \
        || die "could not zip $app.dSYM"

    staging=$(mktemp -d)
    trap 'rm -rf "$staging"' RETURN

    # Sign the app with a Developer ID when one exists. Without this the image
    # is just a container for an ad-hoc signed app, and Gatekeeper refuses it.
    local identity
    identity=$(developer_id || true)
    if [ -n "$identity" ]; then
        info "Signing the app as $(developer_id_name)"

        # Xcode injects com.apple.security.get-task-allow -- the "a debugger may
        # attach to me" entitlement -- into every build it signs, and Apple
        # refuses to notarize anything carrying it. Re-signing without
        # --entitlements keeps whatever is already embedded, so an explicit
        # empty set is the only way to be rid of it.
        local entitlements
        entitlements=$(mktemp -t irctell-entitlements)
        cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
PLIST

        # No --deep (deprecated, can silently skip or mis-sign things):
        # anything present under Frameworks -- e.g. a Swift runtime
        # compatibility shim CopySwiftLibs may embed -- is signed first,
        # inside-out, the way Apple's own docs recommend, before the outer
        # bundle below.
        local frameworks_dir="$app/Contents/Frameworks"
        if [ -d "$frameworks_dir" ]; then
            while IFS= read -r -d '' item; do
                codesign --force --options runtime --timestamp --sign "$identity" "$item"
            done < <(find "$frameworks_dir" -mindepth 1 -maxdepth 1 \
                          \( -name "*.dylib" -o -name "*.framework" \) -print0)
        fi

        # --options runtime and --timestamp are both required before Apple
        # will notarize.
        codesign --force --options runtime --timestamp \
                 --entitlements "$entitlements" \
                 --sign "$identity" "$app"
        rm -f "$entitlements"
        codesign --verify --deep --strict --verbose=1 "$app" 2>&1 | sed 's/^/    /'

        # Checked here rather than discovered by Apple twenty minutes later.
        # Each of these was an error in a rejected submission.
        #
        # Matched with `case` rather than piped into `grep -q`: grep exits at
        # the first match, codesign then dies of SIGPIPE, and `pipefail` reports
        # the whole pipeline as failed -- so the check rejected a perfectly good
        # signature. `set -euo pipefail` and `grep -q` do not mix.
        local description entitlements_now
        description=$(codesign -dvv "$app" 2>&1)
        case "$description" in
            *"Authority=Developer ID Application"*) ;;
            *) die "the app is not signed with a Developer ID certificate" ;;
        esac
        case "$description" in
            *"Timestamp="*) ;;
            *) die "the signature has no secure timestamp" ;;
        esac
        entitlements_now=$(codesign -d --entitlements - "$app" 2>/dev/null | tr -d '\0')
        case "$entitlements_now" in
            *get-task-allow*) die "the app still carries com.apple.security.get-task-allow" ;;
        esac
    fi

    info "Staging $app"
    cp -R "$app" "$staging/"

    mkdir -p "$PWD/build"
    rm -f "$dmg"

    info "Building $dmg"

    # Built explicitly rather than with `hdiutil create -srcfolder`, which does
    # its own create-attach-copy-detach-convert internally and fails as a whole
    # with nothing but "Resource busy" when any step of that is unhappy --
    # measured on this machine, where `create -size`, `attach` and `mount` all
    # worked and only `-srcfolder` did not. Doing the steps here means a failure
    # names which step failed, and it is what the DMG tools all do for the same
    # reason.
    local size_kb blank device attached mountpoint
    size_kb=$(du -sk "$staging" | awk '{print $1}')
    # Slack for the filesystem's own structures; an image sized to its contents
    # exactly has no room to write them.
    size_kb=$(( size_kb + 20480 ))

    blank="${dmg%.dmg}-rw.dmg"
    rm -f "$blank"
    hdiutil create -size "${size_kb}k" -volname "Irctell $version" \
                   -fs HFS+ -ov "$blank" >/dev/null \
        || die "could not create the empty image"

    attached=$(hdiutil attach -nobrowse -noverify -readwrite "$blank") \
        || die "could not attach the image"
    device=$(printf '%s\n' "$attached" | awk '/^\/dev\/disk/{print $1; exit}')
    mountpoint=$(printf '%s\n' "$attached" | sed -n 's|.*[[:space:]]\(/Volumes/.*\)$|\1|p' | head -1)
    [ -n "$mountpoint" ] || die "the image attached but did not mount"

    ditto "$app" "$mountpoint/$(basename "$app")" || {
        hdiutil detach "$device" -force -quiet || true
        die "could not copy the app into the image"
    }
    ln -s /Applications "$mountpoint/Applications"

    hdiutil detach "$device" -force -quiet || die "could not detach the image"
    hdiutil convert "$blank" -format UDZO -ov -o "$dmg" >/dev/null \
        || die "could not compress the image"
    rm -f "$blank"

    # Sign the image itself too, so Gatekeeper has something to check before the
    # app is ever copied out of it.
    if [ -n "$identity" ]; then
        info "Signing the image as $(developer_id_name)"
        codesign --sign "$identity" --timestamp "$dmg" || true
    else
        printf '%s==> No Developer ID found: the image is unsigned.%s\n' "$YELLOW" "$OFF"
        printf '    Users will see \"Apple could not verify Irctell is free of malware\"\n'
        printf '    and must allow it in System Settings > Privacy and Security.\n'
        printf '    Control-click > Open stopped working as a bypass in macOS 15.\n'
    fi

    printf '%s==> %s%s\n' "$GREEN" "$dmg" "$OFF"
    du -h "$dmg" "$symbols" | sed 's/^/    /'
}

# The build UUIDs of every architecture in a binary or a .dSYM, one per line,
# sorted. Equal lists mean the symbols belong to exactly that binary.
build_uuids() {
    dwarfdump --uuid "$1" | awk '{print $2}' | sort
}

case "${1:-build}" in
    -h|--help|help) show_help ;;
    build)   build ;;
    release) CONFIG=Release; build ;;
    run)
        build
        stop_app
        app=$(app_path)
        # Re-register with LaunchServices. Without this the Dock keeps showing
        # whatever icon it cached the first time it saw this bundle path, which
        # is a generic placeholder if the app was ever built without an icon.
        "$LSREGISTER" -f "$app" >/dev/null 2>&1 || true
        info "Launching $app"
        open "$app"
        ;;
    clean)
        info "Cleaning..."
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
                   -destination "$DESTINATION" clean >/dev/null
        printf '%s==> Clean%s\n' "$GREEN" "$OFF"
        ;;
    path)  app_path ;;
    stop)  stop_app ;;
    test)     run_tests ;;
    dmg)      make_dmg ;;
    notarize) notarize_dmg ;;
    publish)  publish_release ;;
    version)  show_or_set_version "${2:-}" ;;
    *)
        printf "unknown command '%s'\n\n" "$1" >&2
        show_help >&2
        exit 1
        ;;
esac
